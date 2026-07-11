//
//  CameraGuidanceLogicTests.swift
//  KataGo AnytimeTests
//
//  Unit tests for the PURE parts of the live board-framing guidance pipeline:
//  the anti-flicker `GuidanceHysteresis` state machine, the `GuidanceMessages`
//  copy mapping, and `CameraGuidanceCoordinator.largestQuad` observation
//  selection. None of these touch AVFoundation / Vision hardware, so they run in
//  the unit-test target on the iOS Simulator. The AVFoundation/Vision glue in
//  `CameraGuidanceCoordinator` is exercised only on-device (see the task's
//  hardware-only QA list).
//
//  iOS-gated to match the camera source (the whole `CameraGuidanceCoordinator`
//  file is `#if os(iOS)`); the test target only builds for the iOS Simulator.
//

#if os(iOS)

import CoreGraphics
import Testing
import GobanRecogKit
@testable import KataGo_Anytime

@Suite("Camera guidance logic")
struct CameraGuidanceLogicTests {

    // MARK: - Helpers

    /// An axis-aligned square quad in TL, TR, BR, BL order (top-left origin).
    private func square(x: Double, y: Double, side: Double) -> [CGPoint] {
        [CGPoint(x: x, y: y),
         CGPoint(x: x + side, y: y),
         CGPoint(x: x + side, y: y + side),
         CGPoint(x: x, y: y + side)]
    }

    // MARK: - GuidanceHysteresis

    @Test("Displays noBoard before any analysis has run")
    func hysteresisInitialState() {
        let hysteresis = GuidanceHysteresis()
        #expect(hysteresis.displayed == .noBoard)
    }

    @Test("Switches the displayed issue only after two consecutive analyses")
    func hysteresisTwoConsecutiveSwitch() {
        var hysteresis = GuidanceHysteresis()
        #expect(hysteresis.record(.tooFar) == .noBoard)   // first sighting: no switch yet
        #expect(hysteresis.record(.tooFar) == .tooFar)    // second consecutive: switch
        #expect(hysteresis.displayed == .tooFar)
    }

    @Test("Flapping between two issues never switches the display")
    func hysteresisFlappingNeverSwitches() {
        var hysteresis = GuidanceHysteresis()
        for issue in [GuidanceIssue.tooFar, .glare, .tooFar, .glare, .tooFar, .glare] {
            #expect(hysteresis.record(issue) == .noBoard)
        }
        #expect(hysteresis.displayed == .noBoard)
    }

    @Test("A single-frame blip does not disturb an established display")
    func hysteresisSingleBlipIgnored() {
        var hysteresis = GuidanceHysteresis()
        _ = hysteresis.record(.tooFar)
        _ = hysteresis.record(.tooFar)                    // establish tooFar
        #expect(hysteresis.record(.shadow) == .tooFar)    // one-frame blip ignored
        #expect(hysteresis.record(.tooFar) == .tooFar)    // back to tooFar, still tooFar
    }

    @Test("nil (looks good) is a value that also needs two consecutive frames")
    func hysteresisNilCountsAsValue() {
        var hysteresis = GuidanceHysteresis()
        _ = hysteresis.record(.tooFar)
        _ = hysteresis.record(.tooFar)                    // establish tooFar
        #expect(hysteresis.record(nil) == .tooFar)        // first looks-good frame: no switch
        #expect(hysteresis.record(nil) == nil)            // second consecutive: switch to looks good
        #expect(hysteresis.displayed == nil)
    }

    // MARK: - GuidanceMessages

    @Test("Maps every issue (and looks-good) to its exact copy")
    func messageCopy() {
        #expect(GuidanceMessages.text(for: nil) == "Looks good")
        #expect(GuidanceMessages.text(for: .noBoard) == "Point the camera at the board")
        #expect(GuidanceMessages.text(for: .boardCutOff) == "Keep the whole board in frame")
        #expect(GuidanceMessages.text(for: .tooFar) == "Move closer to the board")
        #expect(GuidanceMessages.text(for: .tooTilted) == "Hold the camera directly above the board")
        #expect(GuidanceMessages.text(for: .tooDark) == "Too dark — add more light")
        #expect(GuidanceMessages.text(for: .glare) == "Glare on the board — tilt the camera slightly")
        #expect(GuidanceMessages.text(for: .shadow) == "Shadow on the board — adjust your position or lighting")
    }

    // MARK: - largestQuad

    @Test("largestQuad returns nil when there are no observations")
    func largestQuadEmpty() {
        #expect(CameraGuidanceCoordinator.largestQuad(from: []) == nil)
    }

    @Test("largestQuad returns the sole observation unchanged")
    func largestQuadSingle() {
        let quad = square(x: 0.2, y: 0.2, side: 0.3)
        #expect(CameraGuidanceCoordinator.largestQuad(from: [quad]) == quad)
    }

    @Test("largestQuad picks the observation with the greatest area")
    func largestQuadPicksLarger() {
        let small = square(x: 0.1, y: 0.1, side: 0.2)
        let big = square(x: 0.1, y: 0.1, side: 0.6)
        #expect(CameraGuidanceCoordinator.largestQuad(from: [small, big]) == big)
        #expect(CameraGuidanceCoordinator.largestQuad(from: [big, small]) == big)
    }
}

#endif
