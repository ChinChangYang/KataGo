//
//  BoardRecognizer.swift
//  GobanRecogKit
//
//  Swift face of the GobanRecog board-recognition port. Ingests an encoded
//  image (via BoardImageIngestion), runs the C++ `recognizeGoban` pipeline off
//  the main thread across the Swift/C++ interop seam, and returns a Swift-native
//  `RecognizedBoard` (or throws a typed `BoardRecognitionError`).
//

import CGobanRecog
import CoreGraphics
import Foundation

/// Entry point for recognizing a Go board from a photo.
public enum BoardRecognizer {

    /// Recognizes the board in an encoded image (`Data` from a Photos pick, a
    /// Files URL, an NSOpenPanel selection, or a camera capture). Ingests to
    /// BGR — optionally cropped to `cropNormalized`, a [0,1]² top-left-origin
    /// rect in the upright image space (the crop-phase UI's output) — runs the
    /// CPU-heavy C++ pipeline on a background task, and maps the result:
    ///   - status `ok`     → a `RecognizedBoard`
    ///   - anything else   → `throw BoardRecognitionError.recognitionFailed(reason:)`
    ///     carrying the raw `failed:<reason>` tail.
    ///   - undecodable data or a degenerate crop → `throw BoardRecognitionError.invalidImage`
    public static func recognize(imageData: Data,
                                 cropNormalized: CGRect? = nil) async throws -> RecognizedBoard {
        guard let image = BoardImageIngestion.bgrImage(from: imageData,
                                                       cropNormalized: cropNormalized) else {
            throw BoardRecognitionError.invalidImage
        }
        return try await recognize(image: image)
    }

    /// Recognizes using the board's four outer grid-line intersections as the
    /// user placed them, in normalized [0,1]² top-left-origin coordinates of the
    /// upright image.
    ///
    /// No crop is applied: the quad already says exactly where the board is, and
    /// cropping first would only re-scale the coordinates for no gain. The quad
    /// is converted to pixels against the INGESTED buffer's dimensions, so the
    /// ≤1280 downscale inside ingestion is accounted for automatically.
    ///
    /// `boardSize` should be 9, 13 or 19 — the only sizes the pipeline scores.
    /// The confidence floor does not apply on this path, so this returns a board
    /// the caller should present WITH its confidence rather than trust silently.
    public static func recognize(imageData: Data,
                                 quadNormalized: BoardQuad,
                                 boardSize: Int) async throws -> RecognizedBoard {
        guard let image = BoardImageIngestion.bgrImage(from: imageData) else {
            throw BoardRecognitionError.invalidImage
        }
        let width = Double(image.width)
        let height = Double(image.height)
        let quadPixels = quadNormalized.points.flatMap {
            [Double($0.x) * width, Double($0.y) * height]
        }
        return try await recognize(image: image, quadPixels: quadPixels, boardSize: boardSize)
    }

    /// Recognizes an already-ingested BGR buffer. Runs the pipeline on a
    /// detached, user-initiated task so the (seconds-long) C++ work never blocks
    /// the caller's actor.
    ///
    /// `quadPixels` is 8 values (x,y × TL,TR,BR,BL) in this buffer's pixel
    /// space, or nil for automatic detection.
    public static func recognize(image: BGRImage,
                                 quadPixels: [Double]? = nil,
                                 boardSize: Int = 0) async throws -> RecognizedBoard {
        let raw = await Task.detached(priority: .userInitiated) {
            runPipeline(image, quadPixels: quadPixels, boardSize: boardSize)
        }.value

        guard raw.status == "ok" else {
            // Strip the "failed:" prefix to the bare reason; keep the whole
            // string if it is unexpectedly shaped.
            let reason = raw.status.hasPrefix("failed:")
                ? String(raw.status.dropFirst("failed:".count))
                : raw.status
            throw BoardRecognitionError.recognitionFailed(reason: reason)
        }
        return RecognizedBoard(size: raw.boardSize,
                               rows: raw.rows,
                               confidence: raw.confidence,
                               quadSource: raw.quadSource,
                               detectedQuad: normalizedQuad(raw.corners, in: image))
    }

    /// The pipeline's corner output (image pixels, TL TR BR BL) as a normalized
    /// quad, or nil when it produced none.
    private static func normalizedQuad(_ corners: [Double], in image: BGRImage) -> BoardQuad? {
        guard corners.count == 8, image.width > 0, image.height > 0 else { return nil }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let points = (0..<4).map { k in
            CGPoint(x: CGFloat(corners[2 * k]) / width,
                    y: CGFloat(corners[2 * k + 1]) / height)
        }
        return BoardQuad(points: points)
    }

    /// A Swift-native, `Sendable` snapshot of a `GobanRecogResult` — extracted
    /// synchronously inside the interop call so the C++ value never escapes the
    /// pointer's lifetime or crosses the task boundary.
    private struct RawRecognition: Sendable {
        let status: String
        let boardSize: Int
        let rows: [String]
        let confidence: Double
        let quadSource: String
        let corners: [Double]
    }

    private static func runPipeline(_ image: BGRImage,
                                    quadPixels: [Double]?,
                                    boardSize: Int) -> RawRecognition {
        image.bytes.withUnsafeBufferPointer { buffer in
            let result: GobanRecogResult
            if let quadPixels, quadPixels.count == 8 {
                result = quadPixels.withUnsafeBufferPointer { quad in
                    recognizeGobanWithQuad(buffer.baseAddress,
                                           Int32(image.width),
                                           Int32(image.height),
                                           0,
                                           quad.baseAddress,
                                           Int32(boardSize))
                }
            } else {
                result = recognizeGoban(buffer.baseAddress,
                                        Int32(image.width),
                                        Int32(image.height),
                                        0)
            }
            return RawRecognition(
                status: String(result.status),
                boardSize: Int(result.boardSize),
                rows: result.rows.map { String($0) },
                confidence: result.confidence,
                quadSource: String(result.quadSource),
                corners: result.corners.map { Double($0) }
            )
        }
    }

    /// Runs the C++ `recognizeGoban` pipeline on a BGR uint8 buffer (HxWx3,
    /// tightly packed, `width*3` row stride) and returns the recognition status
    /// ("ok" or "failed:<reason>"). Retained for the linkage smoke test; the
    /// full photo → board path is `recognize(imageData:)`.
    public static func recognizeStatus(bgr: UnsafePointer<UInt8>?, width: Int, height: Int) -> String {
        String(recognizeGoban(bgr, Int32(width), Int32(height), 0).status)
    }
}
