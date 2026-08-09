//
//  KataGo_iOSUITests.swift
//  KataGo iOSUITests
//
//  Created by Chin-Chang Yang on 2023/7/2.
//

import XCTest

// `testCaptureReadmeScreens` below writes images that get committed to the
// repo, so a landscape simulator would silently produce landscape README
// screenshots. Inheriting the portrait pin makes that guarantee explicit
// instead of accidental.
final class KataGo_iOSUITests: PortraitUITestCase {

    @MainActor func testExample() throws {
        // UI tests must launch the application that they test.
        let app = makeApp()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    /// Captures README screenshots (board, Settings, Developer Mode) by
    /// driving the app on the iOS Simulator. Not a behavioral assertion test —
    /// it attaches full-frame screenshots that are extracted from the result
    /// bundle and committed as README images. On the simulator the backend is
    /// pinned to CoreML/NE, so launching the built-in net is supported.
    @MainActor func testCaptureReadmeScreens() throws {
        let app = makeApp()
        app.launch()

        func snap(_ name: String) {
            let att = XCTAttachment(screenshot: app.screenshot())
            att.name = name
            att.lifetime = .keepAlways
            add(att)
        }

        // Launch the engine with the built-in network if the model picker is up.
        // (If a model was already selected from a prior run, skip straight to
        // waiting for the board.)
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

        func openMore() {
            let more = app.buttons["More"].firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 15), "More menu not found")
            more.tap()
        }

        // The auto-selected game may persist an AI-vs-AI configuration (state
        // survives across local runs). An AI side auto-plays a move, which puts
        // the board in an uncommitted-branch state — TopToolbarView then shows a
        // "Deactivate Branch" button INSTEAD of the "More" menu, so "More" would
        // never be found on the board. Start from a fresh New Game (default
        // Human-vs-Human, so it never auto-plays into a branch), created from the
        // game-list toolbar menu, which the branch state does not affect.
        let back = app.navigationBars.buttons.element(boundBy: 0)  // leading = Back ("Games")
        if back.waitForExistence(timeout: 5) { back.tap() }
        openMore()
        let newGame = app.buttons["New Game"].firstMatch
        XCTAssertTrue(newGame.waitForExistence(timeout: 10), "New Game menu item not found")
        newGame.tap()

        // The fresh Human-vs-Human board reliably exposes "More" (no branch).
        XCTAssertTrue(app.buttons["More"].firstMatch.waitForExistence(timeout: 60),
                      "New game board did not appear (More button missing)")
        sleep(3)
        snap("GobanView")

        // Settings screen — "Settings" now opens Global Settings directly.
        openMore()
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "Settings menu item not found")
        settings.tap()
        XCTAssertTrue(app.navigationBars["Global Settings"].waitForExistence(timeout: 15),
                      "Global Settings screen not shown")
        sleep(2)
        snap("GlobalSettingsView")

        // Developer Mode (GTP console) — now nested in Global Settings ▸ Engine
        // rather than at the top level of the "More" menu. It sits below the
        // fold of the long Global Settings list (off-screen SwiftUI List cells
        // aren't in the a11y tree), so swipe it into view first.
        let dev = app.buttons["Developer Mode"].firstMatch
        var swipes = 0
        while !dev.exists && swipes < 8 { app.swipeUp(); swipes += 1 }
        XCTAssertTrue(dev.waitForExistence(timeout: 10), "Developer Mode row not found")
        dev.tap()
        let gtpField = app.textFields["Enter your GTP command (list_commands)"]
        XCTAssertTrue(gtpField.waitForExistence(timeout: 15), "GTP console not shown")
        sleep(2)
        snap("CommandView")
    }
}
