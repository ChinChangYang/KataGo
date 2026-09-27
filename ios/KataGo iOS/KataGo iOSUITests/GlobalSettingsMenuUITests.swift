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

        // Get past the model picker (every Debug launch shows it). The board
        // draws before the engine is ready, so wait for the ENGINE to be in
        // sync with it rather than for a toolbar button to exist.
        launchModel(app)
        waitForBoardInSync(app)

        // Pop back to the game list so no game is selected (compact width).
        showGamesList(app)

        // Check that premise before relying on it: the list's bar says the
        // list is showing, not that the selection is empty. This Game is on
        // the menu only while a game is selected.
        openMoreMenuItem(app, path: [], until: app.collectionViews.buttons["Settings"].firstMatch)
        XCTAssertFalse(app.collectionViews.buttons["This Game"].exists,
                       "A game is still selected on the Games list: its More offers This Game")

        // The dots menu must contain Settings > Global Settings with no game
        // selected. The drill carries on from the menu already open, and the
        // sheet's own bar is the proof it opened.
        openMoreMenuItem(app, path: ["Settings", "Global Settings"],
                         until: app.navigationBars["Global Settings"])

        // Accessibility ▸ Voice Control must be reachable from here: the whole
        // point of the screen is that a user who does not know what to say can
        // find out, so a broken link is the one failure mode that matters.
        // The section sits below Sound & Haptics, so scroll until the row is
        // on screen (on iOS 27 it is in the tree long before that).
        let voiceControl = app.buttons["Voice Control"].firstMatch
        XCTAssertTrue(reveal(voiceControl, in: app, by: { app.swipeUp() }, maxSwipes: 6),
                      "Accessibility ▸ Voice Control row never came on screen in Global Settings")
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
    ///
    /// A presence check, not an on-screen one: nothing taps the match, so the
    /// `exists`-gated loop is right here. It swipes on iOS 26, where List rows
    /// below the fold are not in the tree yet, and does nothing on iOS 27,
    /// where they already are. Anything that TAPS a row must use `reveal`.
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
