//
//  PlayerNameLabelUITests.swift
//  KataGo iOSUITests
//
//  Verifies the per-color player-name label shown beside each captured-stone
//  count on the board:
//    * a side with a positive "Time per move" (AI) shows its profile name
//      (e.g. "AI" or a human-SL profile like "Pro 1817"),
//    * a side with zero "Time per move" shows "Human".
//
//  The labels are SwiftUI Buttons (tappable AI/Human capsules) carrying the
//  accessibility identifiers "blackPlayerName" / "whitePlayerName" (see
//  StoneView.drawCapturedStones); tapping one flips that side Human<->AI.
//  Their accessibility `label` is the displayed string. The test drives the
//  real config screen (More ▸ Settings ▸ Game Settings ▸ AI) so it also
//  proves the board reflects the configuration end-to-end.
//
//  On the iOS Simulator the backend is pinned to CoreML/NE, so launching the
//  built-in net is supported (engine init + on-the-fly CoreML conversion is
//  slow — hence the long board-ready timeout, mirroring the other UI tests).
//

import XCTest

final class PlayerNameLabelUITests: XCTestCase {

    private let builtInTitle = "Built-in KataGo Network"
    private let humanLabel = "Human"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPlayerNameLabelsReflectThinkingTimeConfiguration() throws {
        let app = XCUIApplication()
        launchToBoard(app)

        // Phase A — force a known all-human baseline (defends against config
        // persisted by a previous run), then confirm both sides read "Human".
        openAIConfig(app)
        adjustStepper(app, "blackTimePerMove", decrements: 4)  // clamps at 0s
        adjustStepper(app, "whiteTimePerMove", decrements: 4)  // clamps at 0s
        dismissConfig(app)
        waitForLabel(app, "blackPlayerName", equals: humanLabel)
        waitForLabel(app, "whitePlayerName", equals: humanLabel)

        // Phase B — give WHITE a positive thinking time (AI); leave Black at 0.
        // White is chosen deliberately: at the opening it is Black's turn, so an
        // AI White does NOT auto-generate a move. That keeps the board out of the
        // uncommitted-branch state (which would replace the "More" toolbar button
        // with "Deactivate Branch") and leaves the saved game untouched, so the
        // test stays idempotent across reruns. The label is config-driven, so
        // White still reads "AI" without any move being played. (The symmetric
        // Black-AI case is covered exhaustively by the PlayerLabelTests units.)
        openAIConfig(app)
        adjustStepper(app, "whiteTimePerMove", increments: 1)  // 0s -> 0.5s
        dismissConfig(app)
        // White label should now show the AI profile name (not "Human").
        // The exact profile name varies by simulator state, so check ≠ humanLabel.
        waitForAILabel(app, "whitePlayerName")
        waitForLabel(app, "blackPlayerName", equals: humanLabel)

        // Attach a board screenshot so the label layout can be eyeballed.
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "BoardWithPlayerLabels"
        shot.lifetime = .keepAlways
        add(shot)

        // Cleanup — restore the all-human baseline so reruns start clean.
        openAIConfig(app)
        adjustStepper(app, "whiteTimePerMove", decrements: 4)
        dismissConfig(app)
        waitForLabel(app, "whitePlayerName", equals: humanLabel)
    }

    /// Taps the WHITE capsule directly on the board and verifies it flips
    /// Human -> AI -> Human, with Black unaffected. White is used so the toggle
    /// never makes the side-to-move (Black, at the opening) auto-play into an
    /// uncommitted branch — keeping the board stable and the test idempotent.
    @MainActor
    func testTappingWhiteLabelTogglesAIAndHuman() throws {
        let app = XCUIApplication()
        launchToBoard(app)

        // Baseline: force both sides Human via the config steppers (robust against
        // state persisted by a previous run).
        openAIConfig(app)
        adjustStepper(app, "blackTimePerMove", decrements: 4)
        adjustStepper(app, "whiteTimePerMove", decrements: 4)
        dismissConfig(app)
        waitForLabel(app, "whitePlayerName", equals: humanLabel)
        waitForLabel(app, "blackPlayerName", equals: humanLabel)

        // Tap WHITE's capsule -> becomes AI (shows profile name, not necessarily "AI").
        let white = app.buttons["whitePlayerName"]
        XCTAssertTrue(white.waitForExistence(timeout: 10), "White capsule button not found")
        white.tap()
        // Verify: white label is no longer "Human" (AI is now active). The exact
        // profile name may vary by simulator state, so we check ≠ humanLabel.
        waitForAILabel(app, "whitePlayerName")
        waitForLabel(app, "blackPlayerName", equals: humanLabel)  // unaffected

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "WhiteToggledToAI"
        shot.lifetime = .keepAlways
        add(shot)

        // Tap again -> back to Human (restores the clean baseline for reruns).
        app.buttons["whitePlayerName"].tap()
        waitForLabel(app, "whitePlayerName", equals: humanLabel)
        waitForLabel(app, "blackPlayerName", equals: humanLabel)
    }

    // MARK: - Navigation helpers

    @MainActor
    private func launchToBoard(_ app: XCUIApplication) {
        app.launch()

        // Launch the engine with the built-in network if the model picker is up.
        let row = app.staticTexts[builtInTitle]
        if row.waitForExistence(timeout: 20) {
            row.tap()
            let play = app.buttons["ModelDetailView.downloadPlayButton"]
            if play.waitForExistence(timeout: 15) {
                play.tap()
            }
        }

        // "Forward to End" is the board-ready sentinel used by the other tests.
        XCTAssertTrue(app.buttons["Forward to End"].waitForExistence(timeout: 360),
                      "Board did not appear (engine never finished launching)")

        // Start from a fresh New Game so the AI config is deterministic: the
        // default profile is "AI" (so the "Time per move" steppers exist, not the
        // "Engine plays this side" toggle) and both sides are Human (maxTime 0),
        // so the board never auto-plays into an uncommitted branch that would
        // hide the "More" menu. State persists across local runs, and a persisted
        // AI-vs-AI game breaks this test — same recovery as
        // KataGo_iOSUITests.testCaptureReadmeScreens.
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
    }

    /// More ▸ Settings ▸ Game Settings ▸ AI.
    @MainActor
    private func openAIConfig(_ app: XCUIApplication) {
        let more = app.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 15), "More menu not found")
        more.tap()

        tapRow(app, "Settings")
        tapRow(app, "Game Settings")

        // Tap the "AI" row scoped to the Settings LIST. A board player capsule
        // behind the sheet is itself a Button labeled "AI" once that side is set
        // to AI (whitePlayerName), so a bare app.buttons["AI"] can match the
        // capsule instead of the Game Settings navigation row — which is exactly
        // why the post-AI cleanup openAIConfig was failing.
        let aiRow = app.collectionViews.buttons["AI"].firstMatch
        XCTAssertTrue(aiRow.waitForExistence(timeout: 10), "AI row not found in Game Settings")
        aiRow.tap()

        // The AI screen's nav bar is a scroll-independent "screen shown" signal;
        // the blackTimePerMove stepper can be below the fold (adjustStepper
        // scrolls to it), so it's not a reliable sentinel on its own.
        XCTAssertTrue(app.navigationBars["AI"].waitForExistence(timeout: 15),
                      "AI configuration screen not shown")
    }

    /// Pop back to the Settings root, then swipe the sheet away.
    @MainActor
    private func dismissConfig(_ app: XCUIApplication) {
        for navTitle in ["AI", "Game Settings"] {
            let bar = app.navigationBars[navTitle]
            if bar.waitForExistence(timeout: 5) {
                bar.buttons.element(boundBy: 0).tap()  // leading = Back
            }
        }
        // At the Settings root the short list isn't scrollable, so a swipe
        // down dismisses the sheet (same approach as the screenshot test).
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(app.buttons["Forward to End"].waitForExistence(timeout: 15),
                      "Did not return to the board after dismissing the config sheet")
    }

    @MainActor
    private func tapRow(_ app: XCUIApplication, _ label: String) {
        // Wait BEFORE scrolling: menu-popover items (e.g. "Settings") are in the
        // tree as soon as the menu opens, so they resolve here and never trigger
        // a swipe — swiping while a menu is open would dismiss it. Only genuinely
        // below-the-fold List rows fall through to the scroll path.
        let button = app.buttons[label].firstMatch
        if button.waitForExistence(timeout: 10) { button.tap(); return }
        scrollUntilExists(app, button)
        if button.exists { button.tap(); return }

        let text = app.staticTexts[label].firstMatch
        if text.waitForExistence(timeout: 5) { text.tap(); return }
        scrollUntilExists(app, text)
        XCTAssertTrue(text.exists, "Row '\(label)' not found")
        text.tap()
    }

    /// Swipe up on the config sheet until `element` enters the accessibility
    /// hierarchy. Off-screen SwiftUI `List` cells (e.g. the White "Time per
    /// move" stepper at the bottom of the AI screen) aren't queryable until
    /// scrolled into view — the dominant source of this suite's flakiness.
    /// No-ops when the element is already present.
    @MainActor
    private func scrollUntilExists(_ app: XCUIApplication,
                                   _ element: XCUIElement,
                                   maxSwipes: Int = 6) {
        var swipes = 0
        while !element.exists && swipes < maxSwipes {
            app.swipeUp()
            swipes += 1
        }
    }

    // MARK: - Stepper helper

    @MainActor
    private func adjustStepper(_ app: XCUIApplication,
                               _ identifier: String,
                               decrements: Int = 0,
                               increments: Int = 0) {
        let stepper = app.steppers[identifier]
        scrollUntilExists(app, stepper)
        XCTAssertTrue(stepper.waitForExistence(timeout: 10), "Stepper '\(identifier)' not found")

        let decrement = stepper.buttons["Decrement"].exists
            ? stepper.buttons["Decrement"]
            : stepper.buttons.element(boundBy: 0)
        let increment = stepper.buttons["Increment"].exists
            ? stepper.buttons["Increment"]
            : stepper.buttons.element(boundBy: max(0, stepper.buttons.count - 1))

        for _ in 0..<decrements { decrement.tap() }
        for _ in 0..<increments { increment.tap() }
    }

    // MARK: - Assertion helper

    /// Poll the label until it matches (Observation updates the board after the
    /// sheet dismisses, so the first read can briefly lag the config change).
    @MainActor
    private func waitForLabel(_ app: XCUIApplication,
                              _ identifier: String,
                              equals expected: String,
                              timeout: TimeInterval = 10) {
        let element = app.buttons[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: timeout),
                      "Player-name label '\(identifier)' not found on the board")

        let deadline = Date().addingTimeInterval(timeout)
        while element.label != expected && Date() < deadline {
            usleep(200_000)  // 0.2s
        }
        XCTAssertEqual(element.label, expected,
                       "Label '\(identifier)' expected '\(expected)' but was '\(element.label)'")
    }

    /// Poll until the label is NOT the human label (i.e. the side became AI —
    /// its profile name, whatever the persisted profile is). Mirrors
    /// `waitForLabel`'s single-timeout existence-then-poll.
    @MainActor
    private func waitForAILabel(_ app: XCUIApplication,
                               _ identifier: String,
                               timeout: TimeInterval = 10) {
        let element = app.buttons[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: timeout),
                      "Player-name button '\(identifier)' not found on the board")

        let deadline = Date().addingTimeInterval(timeout)
        while element.label == humanLabel && Date() < deadline {
            usleep(200_000)  // 0.2s
        }
        XCTAssertNotEqual(element.label, humanLabel,
                          "Label '\(identifier)' expected to leave 'Human' (became AI) but was 'Human'")
    }
}
