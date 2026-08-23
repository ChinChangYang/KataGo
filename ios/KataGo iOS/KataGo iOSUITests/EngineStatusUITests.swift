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
//  What they pin, and why each is a real regression risk:
//    • the board exists with NO engine (a re-added `isInitialized` gate would
//      fail this on the first frame);
//    • the status line's own "Choose model" button is wired;
//    • changing the model does not take the board down (the old flow unmounted
//      the entire tree when `runGtp` returned, which is what
//      `AppEngineController` replaces);
//    • the navigation buttons act with no engine (`isFunctional` used to include
//      `showBoardCount == 0`, and an absent engine acknowledges nothing).
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

        // And the state is explained rather than hidden.
        XCTAssertTrue(statusElement(app, "EngineStatus.absent").waitForExistence(timeout: 15),
                      "No 'no model chosen' engine status appeared over the board")

        // The status line's own way out — nothing else in this target covers it.
        let chooseModel = app.buttons["EngineStatus.chooseModel"]
        XCTAssertTrue(chooseModel.waitForExistence(timeout: 10),
                      "The Absent status offered no 'Choose model' button")
        chooseModel.tap()

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

        // More ▸ Settings ▸ Engine ▸ Model. No confirmation dialog: nothing is
        // being destroyed, so there is nothing to confirm.
        let more = app.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 15), "More menu not found")
        more.tap()
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "Settings menu item not found")
        settings.tap()
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

        XCTAssertTrue(statusElement(app, "EngineStatus.absent").waitForExistence(timeout: 30),
                      "No 'no model chosen' engine status appeared over the board")

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

        // And the engine still arrives afterwards, onto the same board.
        let chooseModel = app.buttons["EngineStatus.chooseModel"]
        XCTAssertTrue(chooseModel.waitForExistence(timeout: 10),
                      "The Absent status offered no 'Choose model' button")
        chooseModel.tap()
        launchBuiltInEngine(app)
        waitForBoardInSync(app)
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
