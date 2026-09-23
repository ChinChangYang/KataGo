//
//  EngineStatusUITests.swift
//  KataGo iOSUITests
//
//  The board never waits for the engine — end to end, on a real simulator.
//
//  Everything else in this target waits for `Board.sync` and then drives a
//  board it knows is live. These three tests are about the window BEFORE that:
//  the state in which no engine exists at all, and the seconds (or, on a cold
//  simulator, minutes) while a model loads — which used to be a spinning launch
//  screen and is now a usable board with a status line over it.
//
//  **The assertions deliberately target *Absent*, not *Launching*.** A debug
//  launch presents the model picker over an already-mounted board, so dismissing
//  that sheet without choosing anything puts the app in a state that is both
//  stronger to assert (no engine at all, not merely one that is loading) and
//  perfectly deterministic. Asserting on *Launching* instead is a race the test
//  loses on a warm Core ML cache: the first full-suite run of these tests found
//  `Board.sync` already reading `inSync` while the launching-status wait was
//  still polling, because the engine had come up in under a second. Launching is
//  still checked where it can be, but never as a gate.
//
//  What they pin, and why each is a real regression risk (ADR 0010):
//    • the board exists with NO engine (a re-added `isInitialized` gate would
//      fail this on the first frame);
//    • Absent puts NO pill over the board — the resting states surface through
//      the sparkle, whose tap opens the model picker (the remedy);
//    • the sparkle's spoken label says the engine is down (VoiceOver cannot
//      see the badge, so the words must carry it);
//    • changing the model does not take the board down (the old flow unmounted
//      the entire tree when `runGtp` returned, which is what
//      `AppEngineController` replaces);
//    • the navigation buttons act with no engine (`isFunctional` used to include
//      `showBoardCount == 0`, and an absent engine acknowledges nothing);
//    • a stone can be PLAYED with no engine (ADR 0018): legality and the record
//      write are Swift's, and the stone survives the engine arriving later —
//      the tap gate used to require an in-sync engine.
//

import XCTest

final class EngineStatusUITests: PortraitUITestCase {

    private let builtInTitle = "Built-in KataGo Network"
    private let pickerTitle = "Select a Model"

    // MARK: - The board mounts before the engine

    @MainActor
    func testBoardMountsBeforeEngineAndStatusClears() throws {
        let app = makeApp()
        app.launch()

        dismissModelPicker(app)

        // The board is on screen with NO engine behind it. `Board.sync` is
        // published by `BoardView` itself, so its existence proves the board
        // tree mounted; its value proves nothing has acknowledged the position.
        let sync = app.otherElements["Board.sync"]
        XCTAssertTrue(sync.waitForExistence(timeout: 30),
                      "The board did not mount with no model chosen")
        XCTAssertEqual(sync.value as? String, "syncing",
                       "The board claimed to be in sync with an engine that does not exist")

        // NO pill over the board (ADR 0010): the resting Absent state is the
        // sparkle's to tell, not an overlay's.
        XCTAssertFalse(statusElement(app, "EngineStatus.absent").waitForExistence(timeout: 3),
                       "The removed 'No model chosen' pill reappeared over the board")

        // The sparkle IS the way out: enabled while the engine is down, spoken
        // label says why, and tapping it opens the model picker.
        let sparkle = app.buttons["Toggle Analysis"].firstMatch
        XCTAssertTrue(sparkle.waitForExistence(timeout: 15),
                      "The analysis sparkle was not on screen")
        XCTAssertTrue(sparkle.isEnabled,
                      "The sparkle was disabled with the engine Absent — it is the way into the remedy")
        XCTAssertTrue(sparkle.label.contains("engine unavailable"),
                      "The sparkle's label did not say the engine is down (was: \(sparkle.label))")
        sparkle.tap()
        XCTAssertTrue(app.navigationBars[pickerTitle].waitForExistence(timeout: 10),
                      "Tapping the sparkle with no engine did not open the model picker")

        launchBuiltInEngine(app)

        // Best-effort: on a cold cache this is on screen for minutes, on a warm
        // one it can be gone before the first poll. Never a gate — see the file
        // header.
        _ = statusElement(app, "EngineStatus.launching").waitForExistence(timeout: 5)

        // Then it resolves: the status vanishes (a ready engine renders nothing
        // at all) and the board reports in sync.
        waitForBoardInSync(app)
    }

    // MARK: - Change model keeps the board

    @MainActor
    func testChangeModelKeepsBoard() throws {
        let app = makeApp()
        app.launch()

        launchBuiltInEngine(app)

        // `Board.sync` rather than a toolbar button: it exists iff `BoardView`
        // is mounted, which is exactly the claim. (The "Lock" button is no use
        // here — the same button reads "Unlock" whenever the open record is a
        // pristine New Game.)
        let board = app.otherElements["Board.sync"]
        XCTAssertTrue(board.waitForExistence(timeout: 240),
                      "The board never appeared after launching the built-in engine")
        waitForBoardInSync(app)

        // More ▸ Settings ▸ Global Settings ▸ Engine ▸ Model. No confirmation
        // dialog: nothing is being destroyed, so there is nothing to confirm.
        let more = app.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 15), "More menu not found")
        more.tap()
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "Settings menu item not found")
        settings.tap()
        let globalSettingsItem = app.buttons["Global Settings"].firstMatch
        XCTAssertTrue(globalSettingsItem.waitForExistence(timeout: 10),
                      "Global Settings menu item not found")
        globalSettingsItem.tap()
        XCTAssertTrue(app.navigationBars["Global Settings"].waitForExistence(timeout: 15),
                      "Global Settings sheet not shown")

        let changeModelRow = app.descendants(matching: .any)
            .matching(identifier: "GlobalSettingsView.changeModelRow").firstMatch
        reveal(app, changeModelRow, by: { app.swipeUp() })
        XCTAssertTrue(changeModelRow.waitForExistence(timeout: 10),
                      "Change model row not found in Global Settings")
        changeModelRow.tap()

        // The picker is a sheet now, so it arrives without the board going
        // anywhere. Re-picking the SAME net must restart it (settled design,
        // decision 10) — this is also the regression test for that.
        XCTAssertTrue(app.staticTexts[builtInTitle].waitForExistence(timeout: 60),
                      "Model picker did not appear after Change model")
        launchBuiltInEngine(app)

        // THE assertion: the board is on screen the moment the sheet closes,
        // with the replacement engine still coming up behind it. A flow that
        // unmounted the tree would leave a launch screen here instead.
        XCTAssertTrue(board.waitForExistence(timeout: 20),
                      "The board was taken down by a model change")

        waitForBoardInSync(app)
        XCTAssertTrue(board.exists, "The board disappeared once the engine came back")
    }

    // MARK: - Navigation with no engine

    @MainActor
    func testNavigationWorksWithNoEngine() throws {
        let app = makeApp()
        app.launch()

        dismissModelPicker(app)

        // The resting state adds nothing to the board tree (ADR 0010).
        XCTAssertFalse(statusElement(app, "EngineStatus.absent").waitForExistence(timeout: 3),
                       "The removed 'No model chosen' pill reappeared over the board")

        // The navigation buttons are enabled and take taps with no engine in the
        // process at all — the strongest form of "navigation never waits". They
        // move the cursor over a record-owned board; anything they would send is
        // dropped by the command gate and replayed once an engine answers, so
        // nothing here can desync anything.
        let forward = app.buttons["Forward"].firstMatch
        let backward = app.buttons["Backward"].firstMatch
        XCTAssertTrue(forward.waitForExistence(timeout: 15), "Forward button not found")
        XCTAssertTrue(backward.exists, "Backward button not found")
        XCTAssertTrue(forward.isEnabled, "Forward was disabled with no engine running")
        XCTAssertTrue(backward.isEnabled, "Backward was disabled with no engine running")

        forward.tap()
        backward.tap()

        XCTAssertEqual(app.state, .runningForeground,
                       "The app did not survive navigation with no engine")

        // And the engine still arrives afterwards, onto the same board — via
        // the sparkle, the one control that leads to the remedy.
        let sparkle = app.buttons["Toggle Analysis"].firstMatch
        XCTAssertTrue(sparkle.waitForExistence(timeout: 10),
                      "The analysis sparkle was not on screen")
        sparkle.tap()
        XCTAssertTrue(app.navigationBars[pickerTitle].waitForExistence(timeout: 10),
                      "Tapping the sparkle with no engine did not open the model picker")
        launchBuiltInEngine(app)
        waitForBoardInSync(app)
    }

    // MARK: - Play with no engine

    @MainActor
    func testPlayWorksWithNoEngine() throws {
        let app = makeApp()
        app.launch()

        dismissModelPicker(app)
        startFreshGame(app)

        // Absent: the board is up, nothing has acknowledged it.
        let sync = app.otherElements["Board.sync"]
        XCTAssertTrue(sync.waitForExistence(timeout: 30),
                      "The board did not mount with no model chosen")
        XCTAssertEqual(sync.value as? String, "syncing")

        // Play K 10 through the same named target Voice Control uses. Black to
        // move on a fresh Human-vs-Human game; the record — not an engine —
        // decides that, and the record is what the stone is written to.
        let k10 = app.buttons["K 10"]
        XCTAssertTrue(k10.waitForExistence(timeout: 15), "K 10 not exposed")
        XCTAssertEqual(k10.value as? String, "Empty", "Fresh board should report K 10 as Empty")
        k10.tap()
        let placed = NSPredicate(format: "value == %@", "Black stone")
        wait(for: [expectation(for: placed, evaluatedWith: k10)], timeout: 15)
        XCTAssertEqual(sync.value as? String, "syncing",
                       "A stone played with no engine must not claim the engine is in sync")

        // Then the engine arrives, is fed the record it never saw being
        // written, and the stone is still there once it has caught up.
        let sparkle = app.buttons["Toggle Analysis"].firstMatch
        XCTAssertTrue(sparkle.waitForExistence(timeout: 10), "The analysis sparkle was not on screen")
        sparkle.tap()
        XCTAssertTrue(app.navigationBars[pickerTitle].waitForExistence(timeout: 10),
                      "Tapping the sparkle with no engine did not open the model picker")
        launchBuiltInEngine(app)
        waitForBoardInSync(app)
        XCTAssertEqual(k10.value as? String, "Black stone",
                       "The stone played before the engine arrived did not survive the resync")
    }

    // MARK: - The AI answers once the engine arrives

    @MainActor
    func testAIAnswersOnceTheEngineArrives() throws {
        let app = makeApp()
        app.launch()

        dismissModelPicker(app)
        startFreshGame(app)
        XCTAssertTrue(app.otherElements["Board.sync"].waitForExistence(timeout: 30),
                      "The board did not mount with no model chosen")

        // Hand White to the AI with no engine to play it: the capsule flip is a
        // config write, not an engine command, so it works in Absent too.
        let white = app.buttons["whitePlayerName"]
        XCTAssertTrue(white.waitForExistence(timeout: 15), "White capsule not found")
        white.tap()
        let deadline = Date().addingTimeInterval(10)
        while white.label == "Human" && Date() < deadline { usleep(200_000) }
        XCTAssertNotEqual(white.label, "Human", "White did not become the AI")

        // The human plays Black with no engine.
        let k10 = app.buttons["K 10"]
        XCTAssertTrue(k10.waitForExistence(timeout: 15), "K 10 not exposed")
        XCTAssertEqual(k10.value as? String, "Empty", "Fresh board should report K 10 as Empty")
        k10.tap()
        wait(for: [expectation(for: NSPredicate(format: "value == %@", "Black stone"),
                               evaluatedWith: k10)], timeout: 15)

        // (Whether a second human tap is refused on the AI's turn depends on
        // the analysis preference — paused, the AI does not move and either
        // colour may be played, and `startFreshGame`'s Back tap paused it via
        // `BoardView.onDisappear` — so that gate is pinned by
        // `GobanStateLocalPlayTests.aiSideBlocksTheGate`, not here.)

        // The engine arrives — picked from the sparkle, which arms analysis
        // back to run — is fed the record, and answers for White.
        let sparkle = app.buttons["Toggle Analysis"].firstMatch
        XCTAssertTrue(sparkle.waitForExistence(timeout: 10), "The analysis sparkle was not on screen")
        sparkle.tap()
        XCTAssertTrue(app.navigationBars[pickerTitle].waitForExistence(timeout: 10),
                      "Tapping the sparkle with no engine did not open the model picker")
        launchBuiltInEngine(app)
        waitForBoardInSync(app)

        let whiteStones = app.buttons.matching(NSPredicate(format: "value == %@", "White stone"))
        let answered = Date().addingTimeInterval(120)
        while whiteStones.count == 0 && Date() < answered { usleep(500_000) }
        XCTAssertGreaterThan(whiteStones.count, 0,
                             "The AI did not answer the move played before it arrived")
        XCTAssertEqual(k10.value as? String, "Black stone",
                       "The stone played before the engine arrived did not survive")

        // Restore the baseline for the suites that follow: White back to Human.
        white.tap()
        let restored = Date().addingTimeInterval(10)
        while white.label != "Human" && Date() < restored { usleep(200_000) }
        XCTAssertEqual(white.label, "Human", "White did not return to Human")
    }

    // MARK: - Helpers

    /// The status line renders as a container element, so match by identifier
    /// across every element type rather than betting on one.
    @MainActor
    private func statusElement(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Swipes the auto-presented model picker away WITHOUT choosing anything,
    /// leaving the app in *Absent* over its already-mounted board. Swiping the
    /// NAV BAR, not the list, because the list scrolls.
    @MainActor
    private func dismissModelPicker(_ app: XCUIApplication) {
        let pickerBar = app.navigationBars[pickerTitle]
        XCTAssertTrue(pickerBar.waitForExistence(timeout: 30),
                      "The model picker sheet did not appear on a debug launch")
        pickerBar.swipeDown(velocity: .fast)
        XCTAssertTrue(pickerBar.waitForNonExistence(timeout: 15),
                      "The model picker sheet did not dismiss")
    }

    /// More ▸ New Game ▸ Empty Board, with NO engine: a deterministic empty
    /// Human-vs-Human 19x19 board (the auto-selected game persists whatever the
    /// previous test left on it — a stone at K 10, an AI side). Creating a game
    /// is a record write, so it works in Absent.
    ///
    /// From the BOARD's own More menu, deliberately not via Back to the list
    /// as `BoardAccessibilityUITests.launchToFreshBoard` does: leaving the
    /// board runs `BoardView.onDisappear` → `maybePauseAnalysis`, and a paused
    /// preference is only ever un-paused by the sparkle — so the AI side of
    /// the game created afterwards would never gen-move, and
    /// `testAIAnswersOnceTheEngineArrives` would wait for a stone that cannot
    /// come.
    @MainActor
    private func startFreshGame(_ app: XCUIApplication) {
        let more = app.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 15), "More menu not found")
        more.tap()
        let newGame = app.buttons["New Game"].firstMatch
        XCTAssertTrue(newGame.waitForExistence(timeout: 10), "New Game menu item not found")
        newGame.tap()
        let emptyBoard = app.buttons["Empty Board"].firstMatch
        XCTAssertTrue(emptyBoard.waitForExistence(timeout: 10), "Empty Board menu item not found")
        emptyBoard.tap()
        XCTAssertTrue(app.buttons["More"].firstMatch.waitForExistence(timeout: 60),
                      "New game board did not appear (More button missing)")
    }

    /// Picks the built-in network in whatever model picker is currently up (the
    /// auto-presented one on a debug launch, or the one Change model raises) and
    /// starts the engine on it.
    @MainActor
    private func launchBuiltInEngine(_ app: XCUIApplication) {
        let row = app.staticTexts[builtInTitle]
        XCTAssertTrue(row.waitForExistence(timeout: 30),
                      "Model picker row '\(builtInTitle)' not found")
        row.tap()
        let play = app.buttons["ModelDetailView.downloadPlayButton"]
        XCTAssertTrue(play.waitForExistence(timeout: 15), "Play button not found")
        play.tap()
    }

    /// Scrolls until `element` exists, or gives up after a bounded number of
    /// swipes. Off-screen SwiftUI List cells are not in the accessibility tree,
    /// so a row near the bottom of Global Settings has to be revealed first.
    /// Same shape as the sibling suites' copies.
    @MainActor
    private func reveal(_ app: XCUIApplication,
                        _ element: XCUIElement,
                        by swipe: () -> Void,
                        maxSwipes: Int = 8) {
        var n = 0
        while !element.exists && n < maxSwipes {
            swipe()
            n += 1
        }
    }
}
