//
//  BoardAccessibilityUITests.swift
//  KataGo iOSUITests
//
//  Created by Chin-Chang Yang on 2026/7/19.
//

import XCTest

final class BoardAccessibilityUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The goban exposes named accessibility targets ("K 10", "Pass") so Voice
    /// Control users can play by voice. XCUITest reads the same accessibility
    /// tree Voice Control does, so the existence/label/value assertions here
    /// verify what a voice user can address. Tapping the element exercises the
    /// shared `attemptHumanMove` gate via the board's tap gesture (the overlay
    /// is hit-test transparent); the `accessibilityAction` voice path itself
    /// cannot be driven by XCUITest and is covered by the manual Voice Control
    /// device pass.
    @MainActor func testBoardIntersectionsAreSpeakableAndPlayable() throws {
        let app = XCUIApplication()
        app.launch()

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

        // A fresh New Game gives a deterministic empty Human-vs-Human 19x19
        // board (the auto-selected game may persist an AI-vs-AI configuration
        // whose auto-played move locks the board into a branch state).
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

        // Voice Control's speakable targets: corners, the center, and the pass
        // tile must all be addressable by name.
        let a1 = app.buttons["A 1"]
        let t19 = app.buttons["T 19"]
        let k10 = app.buttons["K 10"]
        let pass = app.buttons["Pass"]
        XCTAssertTrue(a1.waitForExistence(timeout: 15), "A 1 not exposed")
        XCTAssertTrue(t19.exists, "T 19 not exposed")
        XCTAssertTrue(k10.exists, "K 10 not exposed")
        XCTAssertTrue(pass.exists, "Pass not exposed")
        XCTAssertEqual(k10.value as? String, "Empty",
                       "Fresh board should report K 10 as Empty")

        // Play K 10 (Black to move on a fresh Human-vs-Human game) and wait
        // for the element's value to reflect the placed stone.
        k10.tap()
        let placed = NSPredicate(format: "value == %@", "Black stone")
        wait(for: [expectation(for: placed, evaluatedWith: k10)], timeout: 60)
    }
}
