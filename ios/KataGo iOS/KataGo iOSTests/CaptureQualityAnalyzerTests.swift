//
//  CaptureQualityAnalyzerTests.swift
//  KataGo AnytimeTests
//
//  Unit tests for the pure capture-guidance math (GobanRecogKit): framing,
//  exposure, shadow, and rectify checks that a future live camera screen calls
//  per preview frame. All inputs are synthesized in code (no fixtures); the
//  shadow/rectify constants were calibrated against the documented algorithm.
//

import CoreGraphics
import Foundation
import Testing
import GobanRecogKit

struct CaptureQualityAnalyzerTests {

    // MARK: - Grid builders

    /// A `width x height` grid filled with a single luma value.
    private func uniform(_ value: UInt8, width: Int = 128, height: Int = 128) -> LumaGrid {
        LumaGrid(pixels: [UInt8](repeating: value, count: width * height),
                 width: width, height: height)!
    }

    /// `base` everywhere with a centered `rw x rh` rectangle painted `value`.
    private func centeredRect(base: UInt8, rw: Int, rh: Int, value: UInt8,
                              width: Int = 128, height: Int = 128) -> LumaGrid {
        var px = [UInt8](repeating: base, count: width * height)
        let x0 = (width - rw) / 2
        let y0 = (height - rh) / 2
        for y in y0..<(y0 + rh) {
            for x in x0..<(x0 + rw) {
                px[y * width + x] = value
            }
        }
        return LumaGrid(pixels: px, width: width, height: height)!
    }

    /// `base` everywhere with a centered filled disk of radius `radius` painted
    /// `value`.
    private func centeredDisk(base: UInt8, radius: Double, value: UInt8,
                             width: Int = 128, height: Int = 128) -> LumaGrid {
        var px = [UInt8](repeating: base, count: width * height)
        let cx = Double(width) / 2
        let cy = Double(height) / 2
        for y in 0..<height {
            for x in 0..<width {
                let dx = Double(x) + 0.5 - cx
                let dy = Double(y) + 0.5 - cy
                if dx * dx + dy * dy <= radius * radius {
                    px[y * width + x] = value
                }
            }
        }
        return LumaGrid(pixels: px, width: width, height: height)!
    }

    private func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

    // MARK: - 1. Looks good

    @Test func flatBrightCenteredQuadLooksGood() {
        let frame = uniform(180)
        let quad = [point(0.1, 0.1), point(0.9, 0.1), point(0.9, 0.9), point(0.1, 0.9)]
        let guidance = CaptureQualityAnalyzer.analyze(frame: frame, quad: quad,
                                                      imageSize: CGSize(width: 128, height: 128))
        #expect(guidance.looksGood)
        #expect(guidance.issues.isEmpty)
        #expect(guidance.primary == nil)
        #expect(guidance.quad == quad)
    }

    // MARK: - 2. Shadow

    /// A centered 64x64 depression at 150 (17% darker) on a flat 180 board covers
    /// ~13% of the board after the illumination-field blur: in the guidance band
    /// (0.10, 0.25) and above the 0.08 shadow threshold.
    @Test func shadowBlobIsDetected() {
        let board = centeredRect(base: 180, rw: 64, rh: 64, value: 150)
        let frac = CaptureQualityAnalyzer.shadowFraction(rectified: board)
        #expect(frac > 0.10)
        #expect(frac < 0.25)

        // analyze() through a clean, fully-in-frame quad reports .shadow only.
        let quad = [point(0.03, 0.03), point(0.97, 0.03), point(0.97, 0.97), point(0.03, 0.97)]
        let guidance = CaptureQualityAnalyzer.analyze(frame: board, quad: quad,
                                                      imageSize: CGSize(width: 128, height: 128))
        #expect(guidance.issues == [.shadow])
        #expect(guidance.primary == .shadow)
        #expect(!guidance.looksGood)
    }

    /// The same blob at only 4% darkness (173) stays below the depression ratio,
    /// so it is not flagged.
    @Test func shallowBlobIsNotShadow() {
        let board = centeredRect(base: 180, rw: 64, rh: 64, value: 173)
        #expect(CaptureQualityAnalyzer.shadowFraction(rectified: board) < 0.01)
    }

    // MARK: - 3. Glare

    @Test func glareDiskFiresAtFivePercent() {
        // radius 16 disk ~ 4.96% of a 128x128 board (> 2.5% threshold).
        let board = centeredDisk(base: 180, radius: 16, value: 255)
        #expect(CaptureQualityAnalyzer.exposureIssues(rectified: board).contains(.glare))
    }

    @Test func glareDiskDoesNotFireAtOnePercent() {
        // radius 7 disk ~ 0.95% of a 128x128 board (< 2.5% threshold).
        let board = centeredDisk(base: 180, radius: 7, value: 255)
        #expect(!CaptureQualityAnalyzer.exposureIssues(rectified: board).contains(.glare))
    }

    // MARK: - 4. Too dark

    @Test func tooDarkFiresBelowThreshold() {
        #expect(CaptureQualityAnalyzer.exposureIssues(rectified: uniform(50)).contains(.tooDark))
    }

    @Test func tooDarkDoesNotFireAboveThreshold() {
        #expect(!CaptureQualityAnalyzer.exposureIssues(rectified: uniform(90)).contains(.tooDark))
    }

    // MARK: - 5. Framing

    private let squareSize = CGSize(width: 1000, height: 1000)

    @Test func smallQuadIsTooFar() {
        // Centered square of area ~0.10 (< 0.20).
        let s = 0.3162277 // sqrt(0.10)
        let quad = [point(0.5 - s / 2, 0.5 - s / 2), point(0.5 + s / 2, 0.5 - s / 2),
                    point(0.5 + s / 2, 0.5 + s / 2), point(0.5 - s / 2, 0.5 + s / 2)]
        #expect(CaptureQualityAnalyzer.framingIssues(quad: quad, imageSize: squareSize) == [.tooFar])
    }

    @Test func edgeHuggingQuadIsCutOff() {
        // Left corners at x = 0.01 (< 0.02 margin); otherwise a large clean quad.
        let quad = [point(0.01, 0.1), point(0.9, 0.1), point(0.9, 0.9), point(0.1, 0.9)]
        #expect(CaptureQualityAnalyzer.framingIssues(quad: quad, imageSize: squareSize) == [.boardCutOff])
    }

    @Test func trapezoidQuadIsTooTilted() {
        // top side 0.6, bottom side 0.4 -> ratio 1.5 (> 1.35); area 0.30 (>= 0.2);
        // all corners inside the 0.02..0.98 margins.
        let quad = [point(0.2, 0.2), point(0.8, 0.2), point(0.7, 0.8), point(0.3, 0.8)]
        #expect(CaptureQualityAnalyzer.framingIssues(quad: quad, imageSize: squareSize) == [.tooTilted])
    }

    @Test func generousSquareQuadHasNoFramingIssues() {
        let quad = [point(0.15, 0.15), point(0.85, 0.15), point(0.85, 0.85), point(0.15, 0.85)]
        #expect(CaptureQualityAnalyzer.framingIssues(quad: quad, imageSize: squareSize).isEmpty)
    }

    // MARK: - 6. Priority

    @Test func primaryPicksHighestPriorityIssue() {
        let quad = [point(0.1, 0.1), point(0.9, 0.1), point(0.9, 0.9), point(0.1, 0.9)]
        let guidance = CaptureGuidance(quad: quad, issues: [.shadow, .boardCutOff])
        #expect(guidance.primary == .boardCutOff)
    }

    @Test func analyzeWithNilQuadIsNoBoard() {
        let guidance = CaptureQualityAnalyzer.analyze(frame: uniform(180), quad: nil,
                                                      imageSize: CGSize(width: 128, height: 128))
        #expect(guidance.primary == .noBoard)
        #expect(guidance.issues == [.noBoard])
        #expect(guidance.quad == nil)
        #expect(!guidance.looksGood)
    }

    @Test func analyzeWithMalformedQuadIsNoBoard() {
        // A non-4-point quad is treated as no board.
        let three = [point(0.1, 0.1), point(0.9, 0.1), point(0.9, 0.9)]
        let guidance = CaptureQualityAnalyzer.analyze(frame: uniform(180), quad: three,
                                                      imageSize: CGSize(width: 128, height: 128))
        #expect(guidance.issues == [.noBoard])
    }

    // MARK: - 7. Rectify

    /// A 64x64 frame split left(100)/right(200); rectifying an axis-aligned
    /// sub-rectangle straddling the split yields halves at ~100 / ~200 away from
    /// the bilinear seam.
    @Test func rectifyRecoversSplitHalves() {
        var px = [UInt8](repeating: 0, count: 64 * 64)
        for y in 0..<64 {
            for x in 0..<64 {
                px[y * 64 + x] = x < 32 ? 100 : 200
            }
        }
        let frame = LumaGrid(pixels: px, width: 64, height: 64)!
        let quad = [point(0.25, 0.25), point(0.75, 0.25), point(0.75, 0.75), point(0.25, 0.75)]
        let rect = CaptureQualityAnalyzer.rectify(frame: frame, quad: quad, side: 32)
        #expect(rect.width == 32 && rect.height == 32)

        // Well inside each half (seam is at column 16).
        let leftValue = Double(rect.pixels[16 * 32 + 4])
        let rightValue = Double(rect.pixels[16 * 32 + 28])
        #expect(abs(leftValue - 100) < 1.0)
        #expect(abs(rightValue - 200) < 1.0)
    }

    /// Rectifying the full frame (identity quad) is a plain downsample: the split
    /// and corners survive.
    @Test func rectifyIdentityQuadDownsamples() {
        var px = [UInt8](repeating: 0, count: 64 * 64)
        for y in 0..<64 {
            for x in 0..<64 {
                px[y * 64 + x] = x < 32 ? 100 : 200
            }
        }
        let frame = LumaGrid(pixels: px, width: 64, height: 64)!
        let quad = [point(0, 0), point(1, 0), point(1, 1), point(0, 1)]
        let rect = CaptureQualityAnalyzer.rectify(frame: frame, quad: quad, side: 32)

        #expect(abs(Double(rect.pixels[16 * 32 + 4]) - 100) < 1.0)
        #expect(abs(Double(rect.pixels[16 * 32 + 28]) - 200) < 1.0)
        #expect(rect.pixels[0] == 100)
        #expect(rect.pixels[rect.pixels.count - 1] == 200)
    }

    // MARK: - 8. LumaGrid init

    @Test func lumaGridRejectsWrongPixelCount() {
        #expect(LumaGrid(pixels: [UInt8](repeating: 0, count: 10), width: 4, height: 3) == nil)
        #expect(LumaGrid(pixels: [], width: 0, height: 0) == nil)
    }

    @Test func lumaGridAcceptsMatchingPixelCount() {
        let grid = LumaGrid(pixels: [UInt8](repeating: 0, count: 12), width: 4, height: 3)
        #expect(grid != nil)
        #expect(grid?.width == 4)
        #expect(grid?.height == 3)
    }
}
