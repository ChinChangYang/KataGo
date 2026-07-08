//
//  GobanRecogSmokeTests.swift
//  KataGo AnytimeTests
//
//  Proves the OpenCV -> CGobanRecog -> GobanRecogKit -> app dependency graph
//  links and runs end-to-end: real cv:: code (core + imgproc + geometry
//  homography) executes across the Swift/C++ interop seam, and the byte-buffer
//  recognizer entry point crosses interop safely.
//

import Testing
import GobanRecogKit

struct GobanRecogSmokeTests {

    /// cv:: code compiles, links, and runs across interop: cvtColor +
    /// morphologyEx (BLACKHAT) + getPerspectiveTransform/warpPerspective +
    /// findHomography(RANSAC). Version prefix proves the vendored 5.0.0 tree is
    /// linked; h_ok=1 proves the homography module ran and rejected outliers.
    @Test func openCVSmokeRunsCoreImgprocAndHomography() {
        let smoke = BoardRecognizer.openCVSmoke()
        #expect(smoke.hasPrefix("5.0.0"))
        #expect(smoke.contains("h_ok=1"))
    }

    /// The placeholder recognizer runs the C++ `recognizeGoban` byte-buffer
    /// seam and surfaces a value-semantic status string back to Swift.
    @Test func recognizePlaceholderReturnsFailedStatus() {
        let status = BoardRecognizer.recognize()
        #expect(status.hasPrefix("failed:"))
    }
}
