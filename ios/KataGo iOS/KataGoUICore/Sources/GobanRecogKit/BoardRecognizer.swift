//
//  BoardRecognizer.swift
//  GobanRecogKit
//
//  Swift face of the GobanRecog board-recognition port. Task 9 wired the REAL
//  C++ recognizeGoban seam (run.py::recognize_image); this thin Swift entry
//  point proves the app dependency graph (OpenCV -> CGobanRecog -> GobanRecogKit
//  -> app) links and runs the full pipeline across Swift/C++ interop. The full
//  photo -> board Swift API (rows/SGF synthesis with rules/komi) lands in
//  Task 11.
//

import CGobanRecog
import Foundation

/// Entry point for recognizing a Go board from a photo.
public enum BoardRecognizer {

    /// Runs the C++ `recognizeGoban` pipeline on a BGR uint8 buffer (HxWx3,
    /// tightly packed, `width*3` row stride) and returns the recognition status
    /// ("ok" or "failed:<reason>"). The buffer is BGR, uint8, row-major — the
    /// exact layout of `cv2.imread`. Value-semantic across the interop seam.
    public static func recognizeStatus(bgr: UnsafePointer<UInt8>?, width: Int, height: Int) -> String {
        String(recognizeGoban(bgr, Int32(width), Int32(height), 0).status)
    }
}
