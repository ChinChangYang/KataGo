//
//  BoardRecognizer.swift
//  GobanRecogKit
//
//  Swift face of the GobanRecog board-recognition port. Skeleton only: it
//  bridges the C++ CGobanRecog seam across Swift/C++ interop. The real photo ->
//  board API lands in Task 11; this scaffolding exists so the dependency graph
//  (OpenCV -> CGobanRecog -> GobanRecogKit -> app) is proven end-to-end.
//

import CGobanRecog
import Foundation

/// Entry point for recognizing a Go board from a photo. Skeleton surface only.
public enum BoardRecognizer {

    /// TEMPORARY smoke bridge (removed alongside the C++ smoke function in a
    /// later task): proves cv:: code compiles, links, and runs across the
    /// Swift/C++ interop boundary. Returns e.g. "5.0.0|h_ok=1".
    public static func openCVSmoke() -> String {
        String(gobanRecogOpenCVSmoke())
    }

    /// Placeholder recognizer that runs the C++ `recognizeGoban` seam on an
    /// empty buffer and surfaces its `status`. Proves the byte-buffer seam
    /// (pointer + dimensions + stride) crosses interop safely and returns a
    /// value-semantic struct Swift can read. Real API lands in Task 11.
    public static func recognize() -> String {
        let empty: [UInt8] = []
        let result = empty.withUnsafeBufferPointer { buffer in
            recognizeGoban(buffer.baseAddress, 0, 0, 0)
        }
        return String(result.status)
    }
}
