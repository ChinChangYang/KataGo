//
//  GlobalSettingsMenuUITests.swift
//  KataGo AnytimeUITests
//
//  The dots ("More") menu must offer Settings > Global Settings even when no
//  game is selected. Regression test for the gap where Global Settings was
//  only reachable via the game-gated Settings sheet.
//

import XCTest

final class GlobalSettingsMenuUITests: PortraitUITestCase {

    /// Launches the engine, pops back from the board to the game list
    /// (clearing the selection on compact width), opens the dots menu, and
    /// drills into the Global Settings sheet.
    @MainActor func testGlobalSettingsAvailableWithoutSelectedGame() throws {
        let app = makeApp()
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

        // The board draws before the engine is ready, so wait for the ENGINE
        // to be in sync with it rather than for a toolbar button to exist.
        waitForBoardInSync(app)

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

        // The dots menu must contain Settings > Global Settings with no game
        // selected.
        let more = app.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 15), "More menu not found")
        more.tap()
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10),
                      "Settings menu item not found")
        settings.tap()
        let globalSettings = app.buttons["Global Settings"].firstMatch
        XCTAssertTrue(globalSettings.waitForExistence(timeout: 10),
                      "Global Settings menu item not found")
        globalSettings.tap()

        // The Global Settings sheet opens.
        XCTAssertTrue(app.navigationBars["Global Settings"].waitForExistence(timeout: 15),
                      "Global Settings sheet not shown")

        // Accessibility ▸ Voice Control must be reachable from here: the whole
        // point of the screen is that a user who does not know what to say can
        // find out, so a broken link is the one failure mode that matters.
        // The section sits below Sound & Haptics, and List rows are lazy, so
        // scroll until it materializes.
        let voiceControl = app.buttons["Voice Control"].firstMatch
        for _ in 0..<6 where !voiceControl.exists {
            app.swipeUp()
        }
        XCTAssertTrue(voiceControl.waitForExistence(timeout: 10),
                      "Accessibility ▸ Voice Control row not found in Global Settings")
        voiceControl.tap()
        XCTAssertTrue(app.navigationBars["Voice Control"].waitForExistence(timeout: 10),
                      "Voice Control help screen did not open")

        // The wording must be the running platform's, and the board example must
        // name a real point — Mac phrasing here would tell an iPhone user to say
        // something that does nothing. Rows are combined accessibility elements,
        // so match any descendant whose label contains the phrase.
        assertVisible(in: app, containing: "Show me what to say",
                      "Help screen does not name the phrase that lists the available commands")
        assertVisible(in: app, containing: "Tap K 10",
                      "Help screen does not show the iOS phrasing for a real intersection")
    }

    /// Scrolls the current screen until some element's label contains `phrase`.
    @MainActor private func assertVisible(in app: XCUIApplication,
                                         containing phrase: String,
                                         _ message: String,
                                         file: StaticString = #filePath,
                                         line: UInt = #line) {
        let match = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", phrase))
            .firstMatch
        for _ in 0..<6 where !match.exists {
            app.swipeUp()
        }
        XCTAssertTrue(match.waitForExistence(timeout: 10), message, file: file, line: line)
    }
}
