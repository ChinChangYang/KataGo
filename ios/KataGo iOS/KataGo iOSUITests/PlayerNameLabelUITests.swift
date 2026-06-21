//
//  PlayerNameLabelUITests.swift
//  KataGo iOSUITests
//
//  Verifies the per-color player-name label shown beside each captured-stone
//  count on the board:
//    * a side with a positive "Time per move" (AI) shows its profile name
//      (e.g. "AI" or a human-SL profile like "proyear_1817"),
//    * a side with zero "Time per move" shows "Human".
//
//  The labels are SwiftUI Buttons (tappable AI/Human capsules) carrying the
//  accessibility identifiers "blackPlayerName" / "whitePlayerName" (see
//  StoneView.drawCapturedStones); tapping one flips that side Human<->AI.
//  Their accessibility `label` is the displayed string. The test drives the
//  real config screen (More ▸ Configurations ▸ Game Settings ▸ AI) so it also
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
    }

    /// More ▸ Configurations ▸ Game Settings ▸ AI.
    @MainActor
    private func openAIConfig(_ app: XCUIApplication) {
        let more = app.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 15), "More menu not found")
        more.tap()

        tapRow(app, "Configurations")
        tapRow(app, "Game Settings")
        tapRow(app, "AI")

        XCTAssertTrue(app.steppers["blackTimePerMove"].waitForExistence(timeout: 10),
                      "AI configuration screen not shown")
    }

    /// Pop back to the Configurations root, then swipe the sheet away.
    @MainActor
    private func dismissConfig(_ app: XCUIApplication) {
        for navTitle in ["AI", "Game Settings"] {
            let bar = app.navigationBars[navTitle]
            if bar.waitForExistence(timeout: 5) {
                bar.buttons.element(boundBy: 0).tap()  // leading = Back
            }
        }
        // At the Configurations root the short list isn't scrollable, so a swipe
        // down dismisses the sheet (same approach as the screenshot test).
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(app.buttons["Forward to End"].waitForExistence(timeout: 15),
                      "Did not return to the board after dismissing the config sheet")
    }

    @MainActor
    private func tapRow(_ app: XCUIApplication, _ label: String) {
        let button = app.buttons[label].firstMatch
        if button.waitForExistence(timeout: 10) {
            button.tap()
            return
        }
        let text = app.staticTexts[label].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5), "Row '\(label)' not found")
        text.tap()
    }

    // MARK: - Stepper helper

    @MainActor
    private func adjustStepper(_ app: XCUIApplication,
                               _ identifier: String,
                               decrements: Int = 0,
                               increments: Int = 0) {
        let stepper = app.steppers[identifier]
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
