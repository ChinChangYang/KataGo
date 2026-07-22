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
//  real config screen (More ▸ This Game ▸ Game Settings ▸ AI) so it also
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

        // Quiet the board before the test drives the toolbar menu. The engine's
        // new-game setup churns the board, which rebuilds the toolbar host and
        // resets an open nested "This Game" submenu back to its parent level, so
        // the "Game Settings" item flickers and can't be tapped ("Game Settings
        // not found" / a tap that can't get a stable snapshot). Wait until
        // analysis is established (a winrate label = the setup transient is over)
        // and only THEN pause analysis (one tap on the sparkle: run -> pause, the
        // only iOS writer of analysisStatus) so no further updates re-render the
        // board. Pausing during the transient does NOT help — the setup churn
        // continues regardless. The pause holds for the whole test; the config
        // screens are analysis-independent and the player-name labels are
        // config-driven.
        let winrate = app.staticTexts.matching(identifier: "AnalysisView.winrate").firstMatch
        _ = winrate.waitForExistence(timeout: 120)
        let analysisToggle = app.buttons["Toggle Analysis"].firstMatch
        if analysisToggle.waitForExistence(timeout: 10) { analysisToggle.tap() }
        // Let the pause's "stop" ack drain and the cold engine's new-game setup
        // finish so the toolbar host stops re-rendering (that churn is what
        // collapses the nested submenu). openAIConfig additionally gates its tap
        // on the item being stably present, so residual flicker is tolerated.
        usleep(3_000_000)  // 3s settle
    }

    /// More ▸ This Game ▸ Game Settings ▸ AI.
    @MainActor
    private func openAIConfig(_ app: XCUIApplication) {
        // Drill More ▸ This Game ▸ Game Settings. The parent popover is stable,
        // but tapping "This Game" opens a nested submenu that a PlusMenuView
        // re-render (cold-engine new-game setup churn) can collapse back to the
        // parent, so the "Game Settings" item FLICKERS on/off. Resolving a
        // flickering element (`.tap()`/`.frame`) aborts the whole test, so gate
        // the tap: only tap "Game Settings" once it has been continuously present
        // for a short window (several safe `.exists` polls). Otherwise step the
        // menu forward (drill into This Game) or re-open "More" when the popover
        // has fully closed. Success is the Game Settings SHEET appearing.
        // (`.exists` and `waitForExistence` never abort — only element taps do —
        // and the parent items More/This Game are stable, so tapping them is safe.)
        let more = app.buttons["More"].firstMatch
        let thisGame = app.buttons["This Game"].firstMatch
        let gameSettings = app.buttons["Game Settings"].firstMatch
        let gameSettingsSheet = app.navigationBars["Game Settings"]
        for _ in 0..<25 {
            if gameSettingsSheet.exists { break }
            if gameSettings.exists {
                if isStablyPresent(gameSettings) {
                    gameSettings.tap()                          // stable: open the sheet
                    _ = gameSettingsSheet.waitForExistence(timeout: 3)
                }
                // else: flickering — loop and re-probe for a stable window.
            } else if thisGame.exists {
                thisGame.tap()                                  // parent menu open: drill in
                _ = gameSettings.waitForExistence(timeout: 3)
            } else {
                XCTAssertTrue(more.waitForExistence(timeout: 15), "More menu not found")
                more.tap()                                      // no menu open: reopen
                _ = thisGame.waitForExistence(timeout: 5)
            }
        }
        XCTAssertTrue(gameSettingsSheet.waitForExistence(timeout: 5),
                      "Game Settings sheet did not open from This Game")

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

    /// Pop back to the Game Settings root, then swipe the sheet away.
    @MainActor
    private func dismissConfig(_ app: XCUIApplication) {
        // "AI" pushes onto the Game Settings sheet; pop it. Game Settings is now
        // the sheet root itself, so it has no back button to tap.
        let aiBar = app.navigationBars["AI"]
        if aiBar.waitForExistence(timeout: 5) {
            aiBar.buttons.element(boundBy: 0).tap()  // leading = Back
        }
        // The Game Settings list is short (not scrollable), so a swipe down
        // dismisses the sheet (same approach as the screenshot test).
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(app.buttons["Forward to End"].waitForExistence(timeout: 15),
                      "Did not return to the board after dismissing the config sheet")
    }

    /// True only if `element` stays present across several rapid `.exists`
    /// polls — used to avoid resolving (tapping) an element that flickers in and
    /// out (which would abort the test). `.exists` never aborts.
    @MainActor
    private func isStablyPresent(_ element: XCUIElement,
                                 checks: Int = 5,
                                 gapMicros: UInt32 = 60_000) -> Bool {
        for _ in 0..<checks {
            if !element.exists { return false }
            usleep(gapMicros)
        }
        return element.exists
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
