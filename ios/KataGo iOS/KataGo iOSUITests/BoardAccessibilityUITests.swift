//
//  BoardAccessibilityUITests.swift
//  KataGo iOSUITests
//
//  Created by Chin-Chang Yang on 2026/7/19.
//

import XCTest

final class BoardAccessibilityUITests: PortraitUITestCase {

    override func setUpWithError() throws {
        // Pins portrait and sets `continueAfterFailure`. This class is the
        // suite's only deliberate rotator, so it is also the one most in need
        // of a known starting orientation.
        try super.setUpWithError()

        // The net for ordinary `throws` exits only. It does NOT cover a failed
        // assertion: `continueAfterFailure = false` aborts the runner process
        // outright and teardown blocks do not run on that path. The rotating
        // test below therefore restores portrait inline and, more importantly,
        // keeps its rotated window free of anything that can abort at all.
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
    }

    /// Launches the app, gets past the model picker, and lands on a fresh
    /// Human-vs-Human 19x19 so the caller sees a deterministic board.
    ///
    /// Orientation is already pinned by `PortraitUITestCase.setUpWithError`,
    /// which runs before this and before the app exists — rotating SpringBoard
    /// with no app under test is cheaper than rotating a launched one.
    @MainActor private func launchToFreshBoard() -> XCUIApplication {
        let app = makeApp()
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

        // The board draws before the engine is ready, so wait for the ENGINE
        // to be in sync with it rather than for a toolbar button to exist.
        waitForBoardInSync(app)

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

    /// Raw geometry from one orientation pass, with no judgement applied.
    ///
    /// Judging is deliberately the caller's job. The landscape pass runs with
    /// the device rotated and must put it back BEFORE it reports anything, so
    /// this type exists to carry measurements across that restore.
    private struct BoardSample {
        let a1Centre: CGPoint
        let t19Centre: CGPoint
        let navBarFrames: [CGRect]

        /// "A 1" and "T 19" are opposite corners of a 19x19 (columns skip I, so
        /// A..T is 19 columns) — 18 gaps in each axis.
        var pitchX: CGFloat { abs(t19Centre.x - a1Centre.x) / 18 }
        var pitchY: CGFloat { abs(t19Centre.y - a1Centre.y) / 18 }
        var pitch: CGFloat { min(pitchX, pitchY) }

        /// The predicate `XCTAssertEqual(_:_:accuracy: 0.5)` applies, spelled
        /// out because this check has to answer with a value rather than assert.
        var isSquare: Bool { abs(pitchX - pitchY) <= 0.5 }
    }

    /// A check inside `sampleBoard` that did not hold, carried back as a VALUE
    /// rather than asserted on the spot.
    ///
    /// `line` is the failing check's OWN line. The previous shape forwarded
    /// `file:`/`line:` down from the caller, so all three checks reported at the
    /// same call site and a red log said no more than "something in
    /// measureBoardPitch failed".
    private struct SampleFailure: Error {
        let reason: String
        let line: UInt

        // `#line` in a default argument expands at the CALL site, so each
        // construction records its own line without a literal that drifts.
        init(_ reason: String, line: UInt = #line) {
            self.reason = reason
            self.line = line
        }
    }

    /// Reads the live board's corner geometry off the accessibility grid.
    ///
    /// The sleep is load-bearing: XCUIElement frames read before SwiftUI has
    /// settled come back collapsed, which once produced a nonsense 2.37 pt pitch.
    ///
    /// **Nothing in here may abort the runner**, because one of the two call
    /// sites runs rotated. That rules out assertions — see `SampleFailure` — and
    /// it equally rules out reading geometry off an element that may have
    /// stopped matching: XCUIElement property access on a vanished element
    /// RAISES "Failed to get matching snapshot", which aborts every bit as
    /// loudly as a failed assertion and is just as invisible to `defer`.
    ///
    /// Note the guards must EARLY-RETURN rather than record and continue. The
    /// old assertions were what stopped execution reaching the `frame` reads;
    /// collecting failures and running on would feed a missing element straight
    /// into `frame` and convert a covered abort into an uncovered one.
    @MainActor private func sampleBoard(_ app: XCUIApplication) -> Result<BoardSample, SampleFailure> {
        let a1 = app.buttons["A 1"]
        let t19 = app.buttons["T 19"]
        guard a1.waitForExistence(timeout: 15) else {
            return .failure(SampleFailure("A 1 not exposed — the board's accessibility grid " +
                                          "never appeared"))
        }
        guard t19.exists else {
            return .failure(SampleFailure("T 19 not exposed — A 1 is there but the opposite " +
                                          "corner is not, so there is no diagonal to measure"))
        }
        Thread.sleep(forTimeInterval: 5)

        // Ask again AFTER the settle wait and immediately before the geometry
        // reads. `exists` re-queries and answers with a Bool; `frame` on an
        // element that has stopped matching raises instead. Five seconds is a
        // long time to carry a snapshot across — a rotation animation, a sheet,
        // or a plain re-render all invalidate it. This narrows the window to two
        // property accesses. It cannot close it: an ObjC raise is not catchable
        // from Swift, so the race is shrunk, not removed.
        guard a1.exists, t19.exists else {
            return .failure(SampleFailure("the board vanished while settling — A 1/T 19 stopped " +
                                          "matching during the 5 s wait, so their frames are " +
                                          "unreadable"))
        }

        // One `frame` read per element, not one per axis. Each property access
        // re-resolves the query, so reading `frame` twice could pair midX from
        // one snapshot with midY from another — and it doubles the number of
        // raise-capable accesses inside the rotated window for nothing.
        let a1Frame = a1.frame
        let t19Frame = t19.frame

        // `allElementsBoundByIndex` hands back proxies that re-resolve on every
        // property access, so `frame` on one whose snapshot has gone raises —
        // the same hazard, on a line that also runs rotated. Filtering on
        // `exists` first narrows it; on a healthy run the filter removes
        // nothing, so the printed record is unchanged.
        let bars = app.navigationBars.allElementsBoundByIndex.filter(\.exists).map(\.frame)

        return .success(BoardSample(a1Centre: CGPoint(x: a1Frame.midX, y: a1Frame.midY),
                                    t19Centre: CGPoint(x: t19Frame.midX, y: t19Frame.midY),
                                    navBarFrames: bars))
    }

    /// Turns a `sampleBoard` outcome into either a pitch or a reported failure,
    /// printing the measurement record on the way through.
    ///
    /// Both orientations go through here so their reports cannot drift apart —
    /// and, the point of the exercise, so the landscape site can call it AFTER
    /// the restore rather than in the middle of the rotated window.
    ///
    /// The `nil` return is dead in practice: `continueAfterFailure = false`
    /// means `XCTFail` aborts before it. The callers honour it anyway, so that
    /// flipping that flag degrades to "skip the rest of this orientation"
    /// rather than carrying on with an unmeasured value.
    private func pitch(from result: Result<BoardSample, SampleFailure>,
                       orientation: String) -> CGFloat? {
        switch result {
        case .failure(let failure):
            XCTFail("\(orientation): \(failure.reason)", line: failure.line)
            return nil

        case .success(let sample):
            // Which axis BINDS decides what a wider board would do, and the
            // pitch alone cannot say. The detail column's navigation bar spans
            // the same horizontal extent as the board container, so its frame
            // recovers the container width; `Dimensions` then gives the height.
            //   boardLineStartX = (W - (n-1)s + s) / 2   =>   W = 2 * dx + (n-2) * s
            // where dx is "A 1"'s centre measured from the container's leading edge.
            if let detail = sample.navBarFrames.max(by: { $0.width < $1.width }) {
                let dx = sample.a1Centre.x - detail.minX
                let impliedWidth = 2 * dx + 17 * sample.pitch
                print("MEASURED container — navBars=\(sample.navBarFrames) A1=\(sample.a1Centre) " +
                      "impliedContainerWidth=\(impliedWidth) " +
                      "widthBoundPitch19=\(impliedWidth / 21)")
            }
            guard sample.isSquare else {
                XCTFail("\(orientation): board is not square — the two axes disagree on the " +
                        "pitch (pitchX=\(sample.pitchX) pitchY=\(sample.pitchY), tolerance 0.5)")
                return nil
            }
            return sample.pitch
        }
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
        // pass restores portrait before it reports (see below), so by the time
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

        // Portrait may report on the spot: nothing has rotated yet, so an abort
        // here leaves the device exactly as it was found.
        guard let portrait = pitch(from: sampleBoard(app), orientation: "portrait") else { return }
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
        //
        // From the rotation below down to the restore is a NO-ABORT ZONE: no
        // assertion, and no call that can raise. That is what `sampleBoard`
        // returning a `Result` buys — its checks used to fire in here, and an
        // abort in here is what left the simulator landscape for the nine
        // classes ordered after this one. `app.state` is a plain enum read that
        // cannot raise; `app.frame` can, but only once the app is gone, so the
        // state read gates it rather than the other way round.
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 3)
        let alive = app.state == .runningForeground
        let landscapeFrame = alive ? app.frame : .zero
        let rotated = landscapeFrame.width > landscapeFrame.height
        let landscapeSample = rotated ? sampleBoard(app) : nil

        // Restore HERE, before reporting — the `setUpWithError` teardown block
        // is not enough on its own. A failed XCTAssert under
        // `continueAfterFailure = false` aborts the runner process outright
        // (this target builds with Swift exceptions disabled, so the unwind
        // ends in `abort()`), and teardown blocks do not run on that path.
        // Measured, not assumed: with the restore only in teardown, the six
        // downstream tests still failed. The teardown block stays as the net
        // for ordinary `throws` exits, which unwind normally.
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 2)

        // Verify the restore rather than trust it, and verify it against the
        // app's own frame rather than `XCUIDevice.shared.orientation` — that
        // getter reports whatever was last REQUESTED, so it agrees with you even
        // when the simulator ignored the request. Silence is the expensive
        // option here: a restore that quietly did not take leaves THIS test
        // green and fails nine other classes instead, which is precisely the
        // 2026-08-03 confusion this file exists to prevent.
        var restoredAlive = app.state == .runningForeground
        var restoredFrame = restoredAlive ? app.frame : .zero
        if restoredAlive, restoredFrame.width > restoredFrame.height {
            // One retry: the simulator occasionally swallows a rotation request
            // that arrives while the previous animation is still in flight.
            print("MEASURED container — portrait restore did NOT take " +
                  "(app.frame=\(restoredFrame)); retrying once")
            XCUIDevice.shared.orientation = .portrait
            Thread.sleep(forTimeInterval: 3)
            restoredAlive = app.state == .runningForeground
            restoredFrame = restoredAlive ? app.frame : .zero
        }

        // Portrait is back — only now is it safe to report.
        if let landscapeSample {
            if let landscapePitch = pitch(from: landscapeSample, orientation: "landscape") {
                check("landscape", pitch19: landscapePitch, frame: landscapeFrame)
            }
        } else if alive {
            print("MEASURED container — rotation REFUSED, landscape NOT measured " +
                  "(app.frame=\(landscapeFrame))")
        } else {
            print("MEASURED container — the app was not running while rotated, " +
                  "landscape NOT measured")
        }

        // Reported last so the pitch measurement above — this test's actual
        // subject — wins the single abort that `continueAfterFailure = false`
        // allows; the retry print has already put this anomaly in the log
        // either way. If the app itself has gone there is no frame to judge.
        if restoredAlive {
            XCTAssertGreaterThan(
                restoredFrame.height, restoredFrame.width,
                "portrait was not restored after the landscape pass " +
                "(app.frame=\(restoredFrame)) — the simulator is still landscape and will " +
                "poison every class ordered after this one, as on 2026-08-03")
        }
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

