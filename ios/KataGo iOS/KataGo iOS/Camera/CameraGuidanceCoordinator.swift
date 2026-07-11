//
//  CameraGuidanceCoordinator.swift
//  KataGo iOS
//
//  Live board-framing guidance for the manual camera screen (Import ▸ Camera).
//  Taps the capture session's video frames ~6-7x/s, detects the board quad with
//  Vision, runs the pure `CaptureQualityAnalyzer` (GobanRecogKit) on a downscaled
//  luma grid, and publishes one prioritized, actionable message plus a quad
//  overlay. It NEVER runs the ~2 s, non-concurrency-safe `recognizeGoban`; this
//  is guidance only and never blocks the always-enabled shutter.
//
//  iOS/iPadOS only (the app target also builds for visionOS, where rear-camera
//  capture is unavailable), so the whole file is gated behind `#if os(iOS)`.
//
//  Coordinate space (load-bearing): Vision runs on the CVPixelBuffer WITHOUT an
//  orientation, so its quad is buffer-normalized, lower-left origin. Flipping y
//  (y' = 1 - y) yields the top-left-origin normalized space the analyzer expects
//  AND the capture-DEVICE space that `AVCaptureVideoPreviewLayer
//  .layerPointConverted(fromCaptureDevicePoint:)` consumes for the overlay. The
//  luma is extracted from the SAME unrotated buffer, so analyzer inputs stay
//  mutually consistent (the analyzer is orientation-agnostic).
//
//  Concurrency: the coordinator is a plain (non-`@MainActor`) NSObject whose
//  sample-buffer delegate callback runs on a dedicated serial "guidance" queue.
//  The serial queue itself serializes analyses (no reentrancy is possible);
//  the 0.15 s timestamp gate (`lastProcessedTime`, touched ONLY on that queue)
//  does the throttling. Results hop to the main actor through the `onGuidance`
//  callback, carrying only `Sendable` value types (never the pixel buffer). The
//  `GuidancePresenter` and the copy/geometry consumers live on the main actor.
//

#if os(iOS)

import AVFoundation
import CoreGraphics
import Foundation
import GobanRecogKit
import Observation
import QuartzCore
import Vision

// MARK: - GuidanceHysteresis (pure)

/// Anti-flicker state machine for the DISPLAYED guidance message. The displayed
/// value changes only after the same `primary` (including `nil` = looks good) is
/// produced by `requiredStreak` consecutive analyses; a single-frame blip is
/// ignored. It starts by displaying `.noBoard` ("Point the camera at the board")
/// so the chip shows a sensible prompt before the first analysis lands.
///
/// Pure and `Sendable`: no dependencies beyond `GuidanceIssue`. The quad overlay
/// deliberately does NOT go through this — geometry updates every analysis.
struct GuidanceHysteresis {
    /// The value currently shown to the user (`nil` = looks good).
    private(set) var displayed: GuidanceIssue?

    /// The most recent candidate under evaluation and its consecutive streak.
    private var candidate: GuidanceIssue?
    private var streak: Int
    private let requiredStreak: Int

    init(initial: GuidanceIssue? = .noBoard, requiredStreak: Int = 2) {
        self.displayed = initial
        self.candidate = initial
        self.streak = 1
        self.requiredStreak = max(1, requiredStreak)
    }

    /// Feeds one analysis `primary` and returns the value that should be shown.
    /// The display switches only once the same value repeats `requiredStreak`
    /// times in a row; any different value resets the streak, so a lone blip
    /// (streak 1) can never flip the display.
    @discardableResult
    mutating func record(_ primary: GuidanceIssue?) -> GuidanceIssue? {
        if primary == candidate {
            streak += 1
        } else {
            candidate = primary
            streak = 1
        }
        if streak >= requiredStreak {
            displayed = primary
        }
        return displayed
    }
}

// MARK: - GuidanceMessages (pure)

/// Maps a guidance issue (or `nil` = looks good) to its exact user-facing copy.
enum GuidanceMessages {
    /// The one-line message for the chip. `nil` reads as "Looks good".
    static func text(for issue: GuidanceIssue?) -> String {
        guard let issue else { return "Looks good" }
        switch issue {
        case .noBoard: return "Point the camera at the board"
        case .boardCutOff: return "Keep the whole board in frame"
        case .tooFar: return "Move closer to the board"
        case .tooTilted: return "Hold the camera directly above the board"
        case .tooDark: return "Too dark — add more light"
        case .glare: return "Glare on the board — tilt the camera slightly"
        case .shadow: return "Shadow on the board — adjust your position or lighting"
        }
    }

    /// The SF Symbol paired with the message: a filled checkmark when the board
    /// looks good, a viewfinder while there is still something to fix.
    static func symbolName(for issue: GuidanceIssue?) -> String {
        issue == nil ? "checkmark.circle.fill" : "viewfinder"
    }
}

// MARK: - GuidancePresenter (main-actor view model)

/// Main-actor view model the camera view observes. It receives raw analyses from
/// the coordinator, applies message hysteresis, and updates the overlay geometry
/// every frame (no hysteresis on geometry).
@MainActor
@Observable
final class GuidancePresenter {
    /// The issue whose copy the chip shows (`nil` = looks good).
    private(set) var displayedIssue: GuidanceIssue? = .noBoard
    /// The latest board quad in capture-DEVICE space (top-left origin, TL, TR,
    /// BR, BL), or `nil` when no board is detected. Ready for `layerPointConverted`.
    private(set) var deviceQuad: [CGPoint]?

    private var hysteresis = GuidanceHysteresis()

    /// True when the current display is the looks-good state.
    var looksGood: Bool { displayedIssue == nil }

    /// Ingests one analysis result published from the guidance queue.
    func ingest(_ guidance: CaptureGuidance, quad: [CGPoint]?) {
        deviceQuad = quad
        displayedIssue = hysteresis.record(guidance.primary)
    }

    /// Clears the overlay and rewinds the message hysteresis to its initial
    /// prompt. Called when a session interruption ends so a stale "Looks good"
    /// (or a stale quad) can't linger, and guidance re-establishes from a clean
    /// streak once frames resume.
    func reset() {
        deviceQuad = nil
        hysteresis = GuidanceHysteresis()
        displayedIssue = hysteresis.displayed
    }
}

// MARK: - CameraGuidanceCoordinator (AVFoundation / Vision glue)

/// Bridges `AVCaptureVideoDataOutput` frames to the pure analyzer and republishes
/// the result on the main actor. Attach it via
/// `CameraCaptureController.attachGuidanceCoordinator(_:)`.
final class CameraGuidanceCoordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    /// Published on the main actor: the analysis plus the device-space quad for
    /// the overlay. Carries only `Sendable` value types.
    typealias GuidanceCallback = @MainActor @Sendable (CaptureGuidance, [CGPoint]?) -> Void

    private let onGuidance: GuidanceCallback
    private let request: VNDetectRectanglesRequest

    /// Minimum wall-clock gap between processed frames (~6.7 fps).
    private let minInterval: CFTimeInterval = 0.15
    /// Longest edge (px) of the downscaled luma grid handed to the analyzer.
    private let maxLumaDimension = 192

    // Guidance-queue-confined throttle state. Touched ONLY inside
    // `captureOutput(_:didOutput:from:)` on the serial guidance queue, so the
    // plain `var` is race-free without extra synchronization.
    private var lastProcessedTime: CFTimeInterval = 0

    init(onGuidance: @escaping GuidanceCallback) {
        self.onGuidance = onGuidance
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.5
        request.maximumAspectRatio = 1.0
        request.quadratureTolerance = 20
        request.minimumSize = 0.15
        request.minimumConfidence = 0.6
        request.maximumObservations = 3
        self.request = request
        super.init()
    }

    // MARK: Observation selection (pure, testable)

    /// The observation with the greatest quad area, or `nil` for an empty list.
    /// Area is orientation-invariant, so this works on raw or y-flipped quads.
    static func largestQuad(from quads: [[CGPoint]]) -> [CGPoint]? {
        quads.max { quadArea($0) < quadArea($1) }
    }

    /// Twice-signed-area shoelace magnitude, halved. Degenerate (<3 point) quads
    /// have zero area and lose the comparison.
    private static func quadArea(_ quad: [CGPoint]) -> Double {
        guard quad.count >= 3 else { return 0 }
        var sum = 0.0
        for i in 0..<quad.count {
            let a = quad[i]
            let b = quad[(i + 1) % quad.count]
            sum += Double(a.x) * Double(b.y) - Double(b.x) * Double(a.y)
        }
        return abs(sum) / 2.0
    }

    // MARK: Frame processing (guidance queue)

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastProcessedTime >= minInterval else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        lastProcessedTime = now

        let quad = detectQuad(in: pixelBuffer)

        guard let grid = makeLumaGrid(from: pixelBuffer, maxDimension: maxLumaDimension) else {
            return
        }
        let imageSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                               height: CVPixelBufferGetHeight(pixelBuffer))
        let guidance = CaptureQualityAnalyzer.analyze(frame: grid, quad: quad, imageSize: imageSize)

        let publish = onGuidance
        Task { @MainActor in
            publish(guidance, quad)
        }
    }

    // MARK: Vision

    /// Runs the rectangle request on the unrotated buffer and returns the largest
    /// board quad in top-left-origin normalized space (TL, TR, BR, BL), or `nil`.
    private func detectQuad(in pixelBuffer: CVPixelBuffer) -> [CGPoint]? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        let observations = request.results ?? []
        // Vision corners are lower-left origin; flip y to top-left origin.
        let quads = observations.map { observation in
            [flipY(observation.topLeft),
             flipY(observation.topRight),
             flipY(observation.bottomRight),
             flipY(observation.bottomLeft)]
        }
        return Self.largestQuad(from: quads)
    }

    private func flipY(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: 1 - point.y)
    }

    // MARK: Luma downscale

    /// Extracts plane 0 (8-bit luma) of the biplanar buffer and box-decimates it
    /// to a grid whose longest edge is `maxDimension`, preserving aspect. Honors
    /// the plane's `bytesPerRow` padding and reads only the sampled pixels (cheap
    /// regardless of source resolution).
    private func makeLumaGrid(from pixelBuffer: CVPixelBuffer, maxDimension: Int) -> LumaGrid? {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
        let srcWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let srcHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        guard srcWidth > 0, srcHeight > 0, bytesPerRow > 0 else { return nil }

        let longest = max(srcWidth, srcHeight)
        let scale = longest > maxDimension ? Double(maxDimension) / Double(longest) : 1.0
        let dstWidth = max(1, Int((Double(srcWidth) * scale).rounded()))
        let dstHeight = max(1, Int((Double(srcHeight) * scale).rounded()))

        let src = base.assumingMemoryBound(to: UInt8.self)
        var pixels = [UInt8](repeating: 0, count: dstWidth * dstHeight)
        for dy in 0..<dstHeight {
            let sy = min(srcHeight - 1,
                         Int((Double(dy) + 0.5) / Double(dstHeight) * Double(srcHeight)))
            let rowBase = sy * bytesPerRow
            for dx in 0..<dstWidth {
                let sx = min(srcWidth - 1,
                             Int((Double(dx) + 0.5) / Double(dstWidth) * Double(srcWidth)))
                pixels[dy * dstWidth + dx] = src[rowBase + sx]
            }
        }
        return LumaGrid(pixels: pixels, width: dstWidth, height: dstHeight)
    }
}

#endif
