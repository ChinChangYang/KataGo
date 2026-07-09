//
//  GobanRecogSmokeTests.swift
//  KataGo AnytimeTests
//
//  Proves the OpenCV -> CGobanRecog -> GobanRecogKit -> app dependency graph
//  links and runs the REAL recognition pipeline end-to-end across the Swift/C++
//  interop seam. Task 9 replaced the earlier cv:: linkage smoke (the temporary
//  gobanRecogOpenCVSmoke / placeholder recognizeGoban, both removed) with a
//  drive of the real run.py::recognize_image port: a boardless image is fed
//  through recognizeGoban and must abstain with a value-semantic "failed:"
//  status crossing interop back to Swift.
//

import Testing
import GobanRecogKit

struct GobanRecogSmokeTests {

    /// The real pipeline (detect_board + classify_stones + CONF_FLOOR gate)
    /// links and runs across interop: a uniform image contains no board, so
    /// detect_board raises a DetectionError that recognize_image turns into a
    /// "failed:<reason>" status. Exercising it here proves OpenCV + all of
    /// CGobanRecog are linked into the app's test host and that the byte-buffer
    /// seam returns a readable value-semantic struct.
    @Test func recognizeRealPipelineAbstainsOnBoardlessImage() {
        let width = 200, height = 200
        let bgr = [UInt8](repeating: 120, count: width * height * 3)  // uniform mid-gray BGR
        let status = bgr.withUnsafeBufferPointer { buffer in
            BoardRecognizer.recognizeStatus(bgr: buffer.baseAddress, width: width, height: height)
        }
        #expect(status.hasPrefix("failed:"))
    }
}
