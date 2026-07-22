//
//  GlobalSettingsMenuUITests.swift
//  KataGo AnytimeUITests
//
//  The dots ("More") menu must offer "Settings" (which opens Global Settings)
//  even when no game is selected. Regression test for the gap where Global
//  Settings was only reachable via the game-gated Settings sheet.
//

import XCTest

final class GlobalSettingsMenuUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launches the engine, pops back from the board to the game list
    /// (clearing the selection on compact width), opens the dots menu, and
    /// drills into the Global Settings sheet.
    @MainActor func testGlobalSettingsAvailableWithoutSelectedGame() throws {
        let app = XCUIApplication()
        app.launch()

        // Get past the model picker if it is up (Debug always shows it).
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

        // Pop back to the game list so no game is selected (compact width).
        // The back button carries the previous screen's title when it fits.
        let boardBar = app.navigationBars.firstMatch
        let namedBack = boardBar.buttons["Games"]
        if namedBack.waitForExistence(timeout: 5) {
            namedBack.tap()
        } else {
            boardBar.buttons.element(boundBy: 0).tap()  // leading = Back
        }
        XCTAssertTrue(app.navigationBars["Games"].waitForExistence(timeout: 10),
                      "Game list did not appear")

        // The dots menu must contain Settings with no game selected; it opens
        // Global Settings directly.
        let more = app.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 15), "More menu not found")
        more.tap()
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10),
                      "Settings menu item not found")
        settings.tap()

        // The Global Settings sheet opens directly.
        XCTAssertTrue(app.navigationBars["Global Settings"].waitForExistence(timeout: 15),
                      "Global Settings sheet not shown")
    }
}
