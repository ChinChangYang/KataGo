//
//  NewGameSheetUITests.swift
//  KataGo iOSUITests
//
//  The "Play KataGo" New Game sheet, end to end:
//    * a fresh board offers the start card where its empty chart would be,
//    * the card opens the sheet, the sheet starts a game,
//    * the started game has KataGo on White at the rank the sheet showed, a
//      person on Black, and an UNLOCKED board — a 9x9 is not the default SGF,
//      so without the sheet's unlock every stone would go to a scratch branch,
//    * KataGo answers the person's first stone,
//    * the same sheet is reachable from More ▸ New Game.
//
//  The person plays Black on purpose: White (KataGo) then waits for a move,
//  so the test never races an engine move it did not ask for.
//

import XCTest

final class NewGameSheetUITests: PortraitUITestCase {

    private let humanLabel = "Human"

    @MainActor
    func testStartCardOpensTheSheetAndStartsARankedGame() throws {
        let app = makeApp()
        app.launch()
        launchModel(app)
        waitForBoardInSync(app)

        // A fresh game: no moves, a person on both sides.
        showGamesList(app)
        openEmptyBoard(app)

        let card = app.buttons["PlayKataGoCard"]
        XCTAssertTrue(waitForOnScreen(card, in: app, timeout: 30),
                      "A fresh board did not offer the start card")
        attachScreenshot(app, named: "StartCard")

        XCTAssertTrue(tapWhenSteady(card, in: app, timeout: 10))
        let sheetBar = app.navigationBars["Play KataGo"]
        XCTAssertTrue(sheetBar.waitForExistence(timeout: 10), "The New Game sheet did not open")

        // The sheet opens on the board it will start, at the full width the
        // sheet has: the board is never scaled down to fit the form on one
        // screen. The form scrolls instead.
        let start = app.buttons["NewGame.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "Start Game is not shown")

        // Move the strength slider, then read back the rung it landed on: a
        // slider drag is not exact, so the expectation follows the sheet.
        let slider = app.sliders["NewGame.strength"]
        XCTAssertTrue(waitForOnScreen(slider, in: app, timeout: 10),
                      "The strength slider is not on the sheet's first screen")
        slider.adjust(toNormalizedSliderPosition: 0.6)
        let title = app.staticTexts["NewGame.rankTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "The sheet shows no rank title")
        let expectedProfile = try XCTUnwrap(Self.profile(forRankTitle: title.label),
                                            "Unreadable rank title '\(title.label)'")
        attachScreenshot(app, named: "NewGameSheet")

        // The choices are below the board: scroll each clear of the Start
        // bar before tapping it. Black for the person, whatever an earlier
        // run stored.
        let black = app.buttons["Black"].firstMatch
        XCTAssertTrue(scroll(black, above: start, in: app), "The colour picker never cleared the Start bar")
        black.tap()

        let nine = app.buttons["9×9"].firstMatch
        XCTAssertTrue(scroll(nine, above: start, in: app), "The 9×9 choice never cleared the Start bar")
        nine.tap()
        attachScreenshot(app, named: "NewGameSheetScrolled")

        XCTAssertTrue(tapWhenSteady(start, in: app, timeout: 10), "Start Game is not on screen")
        XCTAssertTrue(sheetBar.waitForNonExistence(timeout: 10),
                      "The New Game sheet stayed up after Start Game")

        // The started game: KataGo on White at the chosen rank, a person on
        // Black, the board unlocked, and the fresh-board card gone.
        waitForLabel(app, "whitePlayerName", equals: expectedProfile)
        waitForLabel(app, "blackPlayerName", equals: humanLabel)
        XCTAssertTrue(app.buttons["Unlock"].waitForExistence(timeout: 10),
                      "The started game is locked: its stones would go to a branch")
        XCTAssertTrue(card.waitForNonExistence(timeout: 10),
                      "The start card is still offered on a game against KataGo")
        waitForBoardInSync(app)

        // And it plays: a stone from the person is answered by one from
        // KataGo, with the sparkle never touched — the sheet turned the
        // engine on, which is what lets the opponent move at all.
        let center = app.buttons["E 5"]
        XCTAssertTrue(center.waitForExistence(timeout: 15), "E 5 is not exposed on the 9×9 board")
        center.tap()
        let placed = NSPredicate(format: "value == %@", "Black stone")
        wait(for: [expectation(for: placed, evaluatedWith: center)], timeout: 60)
        let answer = app.buttons.matching(NSPredicate(format: "value == %@", "White stone")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 180),
                      "KataGo never answered the person's first move")
        attachScreenshot(app, named: "GameStarted")

        // Restore the all-human baseline other classes start from.
        let white = app.buttons["whitePlayerName"]
        XCTAssertTrue(tapWhenSteady(white, in: app, timeout: 10))
        waitForLabel(app, "whitePlayerName", equals: humanLabel)
    }

    @MainActor
    func testMoreMenuOpensTheSheetAndCancelLeavesTheGameAlone() throws {
        let app = makeApp()
        app.launch()
        launchModel(app)
        waitForBoardInSync(app)
        showGamesList(app)
        openEmptyBoard(app)
        quietBoard(app)

        let sheetBar = app.navigationBars["Play KataGo"]
        openMoreMenuItem(app, path: ["New Game", "Play KataGo…"], until: sheetBar)

        let cancel = app.buttons["NewGame.cancel"]
        XCTAssertTrue(tapWhenSteady(cancel, in: app, timeout: 10), "Cancel is not on screen")
        XCTAssertTrue(sheetBar.waitForNonExistence(timeout: 10), "Cancel did not close the sheet")

        // Nothing was created: the fresh board is still the one on screen.
        XCTAssertTrue(waitForOnScreen(app.navigationBars.buttons["New Game"], in: app, timeout: 10),
                      "Cancel left a different game on screen")
        waitForLabel(app, "whitePlayerName", equals: humanLabel)
        waitForLabel(app, "blackPlayerName", equals: humanLabel)
    }

    // MARK: - Helpers

    /// The player-label profile a rank title stands for: "15 kyu" is the
    /// profile "15k 2016" (a side leaving Full Strength starts at the 2016
    /// style year), "3 dan" is "3d 2016", "Full Strength" is "AI".
    private static func profile(forRankTitle title: String) -> String? {
        if title == "Full Strength" { return "AI" }
        let parts = title.split(separator: " ")
        guard parts.count == 2, Int(parts[0]) != nil else { return nil }
        switch parts[1] {
        case "kyu": return "\(parts[0])k 2016"
        case "dan": return "\(parts[0])d 2016"
        default: return nil
        }
    }

    /// Swipes the sheet up until `element` sits wholly above `bar`, the
    /// pinned Start button. "On screen" is not enough here: a row behind the
    /// bar is on screen, and a tap on it would land on Start Game.
    @MainActor
    private func scroll(_ element: XCUIElement,
                        above bar: XCUIElement,
                        in app: XCUIApplication,
                        maxSwipes: Int = 4) -> Bool {
        func isClear() -> Bool {
            waitForOnScreen(element, in: app, timeout: 3)
                && element.frame.maxY < bar.frame.minY
        }
        var swipes = 0
        while !isClear() && swipes < maxSwipes {
            app.swipeUp()
            swipes += 1
        }
        return isClear()
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    private func waitForLabel(_ app: XCUIApplication,
                              _ identifier: String,
                              equals expected: String,
                              timeout: TimeInterval = 15) {
        let element = app.buttons[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: timeout),
                      "Player-name label '\(identifier)' not found on the board")
        let deadline = Date().addingTimeInterval(timeout)
        while element.label != expected && Date() < deadline { usleep(200_000) }
        XCTAssertEqual(element.label, expected,
                       "Label '\(identifier)' expected '\(expected)' but was '\(element.label)'")
    }
}
