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

    /// Recognizes an already-ingested BGR buffer. Runs the pipeline on a
    /// detached, user-initiated task so the (seconds-long) C++ work never blocks
    /// the caller's actor.
    public static func recognize(image: BGRImage) async throws -> RecognizedBoard {
        let raw = await Task.detached(priority: .userInitiated) {
            runPipeline(image)
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
                               quadSource: raw.quadSource)
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
    }

    private static func runPipeline(_ image: BGRImage) -> RawRecognition {
        image.bytes.withUnsafeBufferPointer { buffer in
            let result = recognizeGoban(buffer.baseAddress,
                                        Int32(image.width),
                                        Int32(image.height),
                                        0)
            return RawRecognition(
                status: String(result.status),
                boardSize: Int(result.boardSize),
                rows: result.rows.map { String($0) },
                confidence: result.confidence,
                quadSource: String(result.quadSource)
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
