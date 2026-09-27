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

final class PlayerNameLabelUITests: PortraitUITestCase {

    private let humanLabel = "Human"

    @MainActor
    func testPlayerNameLabelsReflectThinkingTimeConfiguration() throws {
        let app = makeApp()
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
        let app = makeApp()
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

    /// Long-presses the WHITE capsule and picks a rank from its context menu:
    /// the side becomes the AI at that rank and the label reads the rank and
    /// its style year.
    /// Restores through the same menu (Full Strength keeps the side AI) and a
    /// tap (back to Human): once a rank is set the "Time per move" stepper is
    /// replaced by the "Engine plays this side" toggle, so the config path
    /// used by the other tests cannot restore the baseline here.
    @MainActor
    func testLongPressingWhiteLabelPicksARank() throws {
        let app = makeApp()
        launchToBoard(app)

        openAIConfig(app)
        adjustStepper(app, "blackTimePerMove", decrements: 4)
        adjustStepper(app, "whiteTimePerMove", decrements: 4)
        dismissConfig(app)
        waitForLabel(app, "whitePlayerName", equals: humanLabel)
        waitForLabel(app, "blackPlayerName", equals: humanLabel)

        let white = app.buttons["whitePlayerName"]
        XCTAssertTrue(white.waitForExistence(timeout: 10), "White capsule button not found")
        openRankMenu(app, white, showing: "Dan")
        tapMenuItem(app, "Dan")
        tapMenuItem(app, "5d")
        // The pick both sets the rank and hands White to the AI, in one step.
        // A side leaving Full Strength starts at the 2016 style year.
        waitForLabel(app, "whitePlayerName", equals: "5d 2016")
        waitForLabel(app, "blackPlayerName", equals: humanLabel)

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "WhiteRankPicked"
        shot.lifetime = .keepAlways
        add(shot)

        // Restore: Full Strength keeps White as the AI ("AI"), then a tap
        // makes it Human again, the baseline the other tests start from.
        openRankMenu(app, white, showing: "Full Strength (AI)")
        tapMenuItem(app, "Full Strength (AI)")
        waitForLabel(app, "whitePlayerName", equals: "AI")
        white.tap()
        waitForLabel(app, "whitePlayerName", equals: humanLabel)
    }

    /// Changes White's style year in the AI settings: the label follows the
    /// Year picker ("5k 2016" -> "5k 2019"), and a later rank pick from the
    /// capsule's menu keeps that year. White again, so no pick ever makes the
    /// side to move auto-play into a branch.
    @MainActor
    func testChangingWhiteYearRelabelsTheSide() throws {
        let app = makeApp()
        launchToBoard(app)

        openAIConfig(app)
        adjustStepper(app, "blackTimePerMove", decrements: 4)
        adjustStepper(app, "whiteTimePerMove", decrements: 4)
        dismissConfig(app)
        waitForLabel(app, "whitePlayerName", equals: humanLabel)
        waitForLabel(app, "blackPlayerName", equals: humanLabel)

        let white = app.buttons["whitePlayerName"]
        XCTAssertTrue(white.waitForExistence(timeout: 10), "White capsule button not found")
        openRankMenu(app, white, showing: "Kyu")
        tapMenuItem(app, "Kyu")
        tapMenuItem(app, "5k")
        waitForLabel(app, "whitePlayerName", equals: "5k 2016")

        openAIConfig(app)
        pickYear(app, "whiteStyleYear", "2019")
        dismissConfig(app)
        waitForLabel(app, "whitePlayerName", equals: "5k 2019")
        waitForLabel(app, "blackPlayerName", equals: humanLabel)

        // A rank pick keeps the side's style year.
        openRankMenu(app, white, showing: "Dan")
        tapMenuItem(app, "Dan")
        tapMenuItem(app, "3d")
        waitForLabel(app, "whitePlayerName", equals: "3d 2019")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "WhiteYearChanged"
        shot.lifetime = .keepAlways
        add(shot)

        // Restore, as in testLongPressingWhiteLabelPicksARank: Full Strength
        // drops the year, then a tap makes White Human again.
        openRankMenu(app, white, showing: "Full Strength (AI)")
        tapMenuItem(app, "Full Strength (AI)")
        waitForLabel(app, "whitePlayerName", equals: "AI")
        white.tap()
        waitForLabel(app, "whitePlayerName", equals: humanLabel)
    }

    // MARK: - Navigation helpers

    /// Opens the menu-style Year picker `identifier` on the AI screen and picks
    /// `year`, then waits for the picker to show it.
    @MainActor
    private func pickYear(_ app: XCUIApplication, _ identifier: String, _ year: String) {
        let picker = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(reveal(picker, in: app, by: { app.swipeUp() }, maxSwipes: 6),
                      "Year picker '\(identifier)' never came on screen")
        picker.tap()
        tapMenuItem(app, year)

        let shown = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", year, year)
        let expectation = XCTNSPredicateExpectation(predicate: shown, object: picker)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 10), .completed,
                       "Year picker '\(identifier)' did not show \(year)")
        // The value flips as the item is chosen, while the menu is still
        // closing; let it finish, so the next tap is not swallowed by it.
        _ = waitForOnScreen(picker, in: app, timeout: 5)
    }

    /// Long-presses `capsule` until its rank menu shows `firstItem`. On iOS 27
    /// a press occasionally opens nothing (the Year test's cleanup press, a
    /// few seconds after the previous menu closed, in one full run on
    /// 2026-09-25), so press again, a bounded number of times. The capsule
    /// must be on screen and settled first; that a sheet no longer covers it
    /// is `dismissConfig`'s job to prove.
    @MainActor
    private func openRankMenu(_ app: XCUIApplication, _ capsule: XCUIElement, showing firstItem: String) {
        XCTAssertTrue(waitForOnScreen(capsule, in: app, timeout: 10),
                      "The capsule is not on screen to long-press")
        let item = app.buttons[firstItem].firstMatch
        for _ in 0..<3 where !item.exists {
            capsule.press(forDuration: 1.0)
            _ = item.waitForExistence(timeout: 5)
        }
    }

    /// Taps a context-menu item once it is on screen and steady: an open
    /// SwiftUI menu collapses when an ancestor re-renders under engine
    /// churn, and a tap on an item that just left aborts the test.
    @MainActor
    private func tapMenuItem(_ app: XCUIApplication, _ title: String) {
        XCTAssertTrue(tapWhenSteady(app.buttons[title].firstMatch, in: app, timeout: 10),
                      "Menu item '\(title)' not found, or never held still")
    }

    @MainActor
    private func launchToBoard(_ app: XCUIApplication) {
        app.launch()

        // Launch the engine with the built-in network from the model picker,
        // then the engine-ready sentinel every class in this target shares.
        launchModel(app)
        waitForBoardInSync(app)

        // Start from a fresh New Game so the AI config is deterministic: the
        // default profile is "AI" (so the "Time per move" steppers exist, not the
        // "Engine plays this side" toggle) and both sides are Human (maxTime 0),
        // so the board never auto-plays into an uncommitted branch that would
        // hide the "More" menu. State persists across local runs, and a persisted
        // AI-vs-AI game breaks this test — the same recovery the retired
        // KataGo_iOSUITests.testCaptureReadmeScreens used, before
        // Screenshots/capture_screenshots.sh took over the README images.
        // From the Games list, where the new board is pushed and can be told
        // from the launch-selected one, which is usually a "New Game" too.
        showGamesList(app)
        openEmptyBoard(app)

        // Quiet the board before the test drives the toolbar menu: the new
        // game's engine setup rebuilds the toolbar host, which collapses an
        // open "Settings" submenu back to its parent. Analysis stays off for
        // the whole test; the config screens do not need it, and the
        // player-name labels are config-driven.
        quietBoard(app)
    }

    /// More ▸ Settings ▸ Game Settings ▸ AI.
    @MainActor
    private func openAIConfig(_ app: XCUIApplication) {
        openMoreMenuItem(app, path: ["Settings", "Game Settings"],
                         until: app.navigationBars["Game Settings"])

        // Tap the "AI" row scoped to the Settings LIST. A board player capsule
        // behind the sheet is itself a Button labeled "AI" once that side is set
        // to AI (whitePlayerName), so a bare app.buttons["AI"] can match the
        // capsule instead of the Game Settings navigation row — which is exactly
        // why the post-AI cleanup openAIConfig was failing.
        // On screen, not merely present: the sheet can still be sliding up.
        let aiRow = app.collectionViews.buttons["AI"].firstMatch
        XCTAssertTrue(waitForOnScreen(aiRow, in: app, timeout: 10),
                      "AI row not on screen in Game Settings")
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
            XCTAssertTrue(aiBar.waitForNonExistence(timeout: 5),
                          "The AI screen did not pop back to Game Settings")
        }
        // Proof is the sheet's own bar leaving. The board behind it stays in
        // the accessibility tree while covered, so "Forward to End" existing
        // proved nothing: a sheet that never left passed that check, and the
        // next capsule tap or press then went nowhere. The capsule check after
        // it only confirms the board has settled on screen; it cannot see
        // whether a sheet covers the capsule.
        dismissSheet(app, until: app.navigationBars["Game Settings"])
        XCTAssertTrue(waitForOnScreen(app.buttons["whitePlayerName"], in: app, timeout: 15),
                      "Did not return to the board after dismissing the config sheet")
    }

    // MARK: - Stepper helper

    @MainActor
    private func adjustStepper(_ app: XCUIApplication,
                               _ identifier: String,
                               decrements: Int = 0,
                               increments: Int = 0) {
        // The White "Time per move" stepper sits at the bottom of the AI
        // screen, below the fold.
        let stepper = app.steppers[identifier]
        XCTAssertTrue(reveal(stepper, in: app, by: { app.swipeUp() }, maxSwipes: 6),
                      "Stepper '\(identifier)' never came on screen")

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
