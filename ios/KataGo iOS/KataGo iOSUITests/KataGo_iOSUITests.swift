//
//  KataGo_iOSUITests.swift
//  KataGo iOSUITests
//
//  Created by Chin-Chang Yang on 2023/7/2.
//

import XCTest

final class KataGo_iOSUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    /// Captures README screenshots (board, Configurations, Developer Mode) by
    /// driving the app on the iOS Simulator. Not a behavioral assertion test —
    /// it attaches full-frame screenshots that are extracted from the result
    /// bundle and committed as README images. On the simulator the backend is
    /// pinned to CoreML/NE, so launching the built-in net is supported.
    @MainActor func testCaptureReadmeScreens() throws {
        let app = XCUIApplication()
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
        sleep(3)
        snap("GobanView")

        func openMore() {
            let more = app.buttons["More"].firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 15), "More menu not found")
            more.tap()
        }

        // Configurations screen.
        openMore()
        let config = app.buttons["Configurations"].firstMatch
        XCTAssertTrue(config.waitForExistence(timeout: 10), "Configurations menu item not found")
        config.tap()
        XCTAssertTrue(app.navigationBars["Configurations"].waitForExistence(timeout: 15)
                      || app.staticTexts["Global Settings"].waitForExistence(timeout: 5),
                      "Configurations screen not shown")
        sleep(2)
        snap("ConfigView")
        if app.buttons["Done"].firstMatch.exists {
            app.buttons["Done"].firstMatch.tap()
        } else {
            app.swipeDown(velocity: .fast)
        }

        // Developer Mode (GTP console).
        openMore()
        let dev = app.buttons["Developer Mode"].firstMatch
        XCTAssertTrue(dev.waitForExistence(timeout: 10), "Developer Mode menu item not found")
        dev.tap()
        let gtpField = app.textFields["Enter your GTP command (list_commands)"]
        XCTAssertTrue(gtpField.waitForExistence(timeout: 15), "GTP console not shown")
        sleep(2)
        snap("CommandView")
    }
}
