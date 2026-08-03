//
//  BoardAccessibilityUITests.swift
//  KataGo iOSUITests
//
//  Created by Chin-Chang Yang on 2026/7/19.
//

import XCTest

final class BoardAccessibilityUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        // This is the only UI test class that rotates, and the simulator
        // remembers its orientation ACROSS PROCESSES — so leaving it landscape
        // poisons every class that runs after this one alphabetically, which
        // then measures and scrolls a landscape app while assuming portrait.
        // That cost 9 of the 10 failures in the 2026-08-03 full-suite run
        // (CoreMLCacheFooter, GifExport, GlobalSettingsMenu, PhotoImportGrid,
        // KataGo_iOSUITests) and reproduced in isolation, because the poison is
        // device state rather than test ordering within a process.
        //
        // This block is the net for ordinary `throws` exits only. It does NOT
        // cover a failed assertion: `continueAfterFailure = false` aborts the
        // runner process, and teardown blocks do not run on that path. The
        // rotating test therefore restores portrait inline, before it asserts.
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
    }

    /// Launches the app, gets past the model picker, and lands on a fresh
    /// Human-vs-Human 19x19 so the caller sees a deterministic board.
    @MainActor private func launchToFreshBoard() -> XCUIApplication {
        // The simulator REMEMBERS its orientation across runs, so a previous
        // test that rotated leaves the next one measuring landscape while it
        // thinks it is in portrait. Pin it before launching.
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()

        // Launch the engine with the built-in network if the model picker is up.
        let row = app.staticTexts["Built-in KataGo Network"]
        if row.waitForExistence(timeout: 20) {
            row.tap()
            let play = app.buttons["ModelDetailView.downloadPlayButton"]
            if play.waitForExistence(timeout: 15) {
                play.tap()
            }
        }

        // Engine init + on-the-fly CoreML conversion is slow on the simulator.
        let forwardEnd = app.buttons["Forward to End"]
        XCTAssertTrue(forwardEnd.waitForExistence(timeout: 360),
                      "Board did not appear (engine never finished launching)")

        // A fresh New Game gives a deterministic empty Human-vs-Human 19x19
        // board (the auto-selected game may persist an AI-vs-AI configuration
        // whose auto-played move locks the board into a branch state).
        let back = app.navigationBars.buttons.element(boundBy: 0)  // leading = Back ("Games")
        if back.waitForExistence(timeout: 5) { back.tap() }
        let more = app.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 15), "More menu not found")
        more.tap()
        let newGame = app.buttons["New Game"].firstMatch
        XCTAssertTrue(newGame.waitForExistence(timeout: 10), "New Game menu item not found")
        newGame.tap()
        XCTAssertTrue(app.buttons["More"].firstMatch.waitForExistence(timeout: 60),
                      "New game board did not appear (More button missing)")
        return app
    }

    /// The live board's cell pitch, read off the accessibility grid. "A 1" and
    /// "T 19" are opposite corners of a 19x19 (columns skip I, so A..T is 19
    /// columns) — 18 gaps in each axis.
    ///
    /// The sleep is load-bearing: XCUIElement frames read before SwiftUI has
    /// settled come back collapsed, which once produced a nonsense 2.37 pt pitch.
    @MainActor private func measureBoardPitch(_ app: XCUIApplication,
                                              file: StaticString = #filePath,
                                              line: UInt = #line) -> CGFloat {
        let a1 = app.buttons["A 1"]
        let t19 = app.buttons["T 19"]
        XCTAssertTrue(a1.waitForExistence(timeout: 15), "A 1 not exposed", file: file, line: line)
        XCTAssertTrue(t19.exists, "T 19 not exposed", file: file, line: line)
        Thread.sleep(forTimeInterval: 5)

        let a1c = CGPoint(x: a1.frame.midX, y: a1.frame.midY)
        let t19c = CGPoint(x: t19.frame.midX, y: t19.frame.midY)
        let pitchX = abs(t19c.x - a1c.x) / 18
        let pitchY = abs(t19c.y - a1c.y) / 18
        XCTAssertEqual(pitchX, pitchY, accuracy: 0.5,
                       "Board is not square: the two axes disagree on the pitch",
                       file: file, line: line)

        // Which axis BINDS decides what a wider board would do, and the pitch
        // alone cannot say. The detail column's navigation bar spans the same
        // horizontal extent as the board container, so its frame recovers the
        // container width; `Dimensions` then gives the height.
        //   boardLineStartX = (W - (n-1)s + s) / 2   =>   W = 2 * dx + (n-2) * s
        // where dx is "A 1"'s centre measured from the container's leading edge.
        let bars = app.navigationBars.allElementsBoundByIndex.map(\.frame)
        if let detail = bars.max(by: { $0.width < $1.width }) {
            let dx = a1c.x - detail.minX
            let impliedWidth = 2 * dx + 17 * min(pitchX, pitchY)
            print("MEASURED container — navBars=\(bars) A1=\(a1c) " +
                  "impliedContainerWidth=\(impliedWidth) " +
                  "widthBoundPitch19=\(impliedWidth / 21)")
        }
        return min(pitchX, pitchY)
    }

    /// The cell pitch a board of side `n` is guaranteed at least, given that a
    /// 19x19 measured `pitch19` in the same container. Knowing only `pitch19`
    /// pins the container from below (`W >= 21s`, `H - 20 >= 22.5s`), and for
    /// `n >= 19` the width ratio is the smaller of the two, so this is the
    /// conservative bound. Proved over a container sweep in
    /// `BoardCoordinateFitTests.aNineteenPitchOfSeventeenPointsGuaranteesTheWidestBoardFits`.
    private func guaranteedPitch(forBoardSide n: Int, given pitch19: CGFloat) -> CGFloat {
        pitch19 * min(21 / CGFloat(n + 2), 22.5 / (CGFloat(n) + 3.5))
    }

    /// The pitch a coordinate label needs to render intact, mirroring
    /// `WidgetCoordinateMetrics.requiredCell` (the source of truth, unit-tested
    /// against the real system font in `WidgetBoardViewTests`). Duplicated as
    /// three constants rather than linking KataGoGameStore into the UI test
    /// target for two numbers.
    private func requiredPitch(forBoardSide n: Int) -> CGFloat {
        if n > 25 { return 9.115 }   // "AA".."AM" two-letter column labels
        if n >= 10 { return 7.34 }   // two-digit row numbers
        return 5.97                  // label line height
    }

    /// Closes QA item 17: measures the live board container on whatever
    /// destination this runs on, in both orientations, without needing a 37x37
    /// game on screen (which would mean raising Max Board Size and restarting
    /// the engine).
    ///
    /// What it guards: **every board size the stock engine can open (up to
    /// 19x19) keeps intact coordinate labels, in both orientations**, and a
    /// 37x37 keeps them in portrait. It deliberately does NOT require a 37x37
    /// to survive landscape — on a short window it does not, which is a known
    /// accepted limitation recorded in the QA checklist and on
    /// `BoardLineView.drawCoordinate`. The printed lines are the measurement
    /// record; read them when adding a new destination.
    @MainActor func testCoordinatePitchClearsTheWidestBoardsFloor() throws {
        let app = launchToFreshBoard()

        // `frame` is passed in rather than read from `app` here: the landscape
        // pass restores portrait before it asserts (see below), so by the time
        // this runs `app.frame` would report the portrait window and the
        // printed record — the whole point of these lines — would be wrong.
        func check(_ orientationName: String, pitch19: CGFloat, frame: CGRect) {
            let largestIntact = (2...37).last {
                guaranteedPitch(forBoardSide: $0, given: pitch19) >= requiredPitch(forBoardSide: $0)
            } ?? 0
            print("MEASURED container — device=\(UIDevice.current.name) \(orientationName) " +
                  "app.frame=\(frame) pitch19=\(pitch19) " +
                  "largestBoardWithIntactLabels=\(largestIntact)")
            XCTAssertGreaterThanOrEqual(
                pitch19, requiredPitch(forBoardSide: 19),
                "\(orientationName): a 19x19 renders at \(pitch19) pt, below the " +
                "\(requiredPitch(forBoardSide: 19)) pt its row numbers need — the DEFAULT board " +
                "is truncating its coordinates")
            XCTAssertGreaterThanOrEqual(
                largestIntact, 19,
                "\(orientationName): only boards up to \(largestIntact)x\(largestIntact) keep " +
                "intact labels, so a board the stock engine can open is truncating")
        }

        let portrait = measureBoardPitch(app)
        check("portrait", pitch19: portrait, frame: app.frame)
        // Portrait is the orientation that must carry every board size: it is
        // the one the widest boards are usable in.
        XCTAssertGreaterThanOrEqual(
            guaranteedPitch(forBoardSide: 37, given: portrait), requiredPitch(forBoardSide: 37),
            "portrait: a 37x37 would truncate its column labels")

        // Landscape is where the height budget bites — the pass row, captured
        // strip, and info pane all come out of it. The simulator refused to
        // rotate iPhones when this was written; it now honours the request, so
        // the branch below really runs.
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 3)
        let landscapeFrame = app.frame
        let rotated = landscapeFrame.width > landscapeFrame.height
        let landscapePitch = rotated ? measureBoardPitch(app) : nil

        // Restore HERE, before asserting — the `setUpWithError` teardown block
        // is not enough on its own. A failed XCTAssert under
        // `continueAfterFailure = false` aborts the runner process outright
        // (this target builds with Swift exceptions disabled, so the unwind
        // ends in `abort()`), and teardown blocks do not run on that path.
        // Measured, not assumed: with the restore only in teardown, the six
        // downstream tests below still failed. The teardown block stays as the
        // net for ordinary `throws` exits, which unwind normally.
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 2)

        guard let landscapePitch else {
            print("MEASURED container — rotation REFUSED, landscape NOT measured " +
                  "(app.frame=\(landscapeFrame))")
            return
        }
        check("landscape", pitch19: landscapePitch, frame: landscapeFrame)
    }

    /// The goban exposes named accessibility targets ("K 10", "Pass") so Voice
    /// Control users can play by voice. XCUITest reads the same accessibility
    /// tree Voice Control does, so the existence/label/value assertions here
    /// verify what a voice user can address. Tapping the element exercises the
    /// shared `attemptHumanMove` gate via the board's tap gesture (the overlay
    /// is hit-test transparent); the `accessibilityAction` voice path itself
    /// cannot be driven by XCUITest and is covered by the manual Voice Control
    /// device pass.
    @MainActor func testBoardIntersectionsAreSpeakableAndPlayable() throws {
        let app = launchToFreshBoard()

        // Voice Control's speakable targets: corners, the center, and the pass
        // tile must all be addressable by name.
        let a1 = app.buttons["A 1"]
        let t19 = app.buttons["T 19"]
        let k10 = app.buttons["K 10"]
        let pass = app.buttons["Pass"]
        XCTAssertTrue(a1.waitForExistence(timeout: 15), "A 1 not exposed")
        XCTAssertTrue(t19.exists, "T 19 not exposed")
        XCTAssertTrue(k10.exists, "K 10 not exposed")
        XCTAssertTrue(pass.exists, "Pass not exposed")
        XCTAssertEqual(k10.value as? String, "Empty",
                       "Fresh board should report K 10 as Empty")

        // Play K 10 (Black to move on a fresh Human-vs-Human game) and wait
        // for the element's value to reflect the placed stone.
        k10.tap()
        let placed = NSPredicate(format: "value == %@", "Black stone")
        wait(for: [expectation(for: placed, evaluatedWith: k10)], timeout: 60)
    }
}
