//
//  CoreMLCacheFooterUITests.swift
//  KataGo iOSUITests
//
//  Reproduces the smoke-test Step 2 failure: after launching the
//  built-in engine, returning to the picker, downloading the smallest
//  non-built-in model (Lionffen b6c64, ~2.1 MB), and launching the
//  engine with it, the footer count should advance from "1 of 8" to
//  "2 of 8". On the current implementation the count stays at "1 of 8".
//
//  Run after `xcrun simctl uninstall booted chinchangyang.KataGo-iOS.tw`
//  for a clean cache state.
//

import XCTest

final class CoreMLCacheFooterUITests: XCTestCase {

    private let builtInTitle  = "Built-in KataGo Network"
    private let lionffenTitle = "Lionffen b6c64 Network"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFooterCountIncrementsAfterDownloadedModelLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        // ----- Step 1: launch built-in, return, expect footer "1 of 8" -----

        tapModelRow(in: app, title: builtInTitle)
        tapDownloadOrPlay(in: app)        // built-in is bundled → play.fill
        waitForEngineThenQuit(in: app, label: "built-in")
        waitForPicker(in: app, title: builtInTitle)

        let afterStep1 = readFooter(in: app)
        XCTAssertTrue(afterStep1.contains("1 of 8"),
                      "Step 1: expected footer to read '1 of 8', was: '\(afterStep1)'")

        // ----- Step 2: download Lionffen, launch it, return, expect "2 of 8" -----

        tapModelRow(in: app, title: lionffenTitle)
        // ModelDetailView's button starts as download (arrow.down).
        tapDownloadOrPlay(in: app)
        waitForDownloadComplete(in: app, timeout: 180)
        // Same button is now play.fill — tap again to launch.
        tapDownloadOrPlay(in: app)
        waitForEngineThenQuit(in: app, label: "Lionffen")
        waitForPicker(in: app, title: lionffenTitle)

        let afterStep2 = readFooter(in: app)
        XCTAssertTrue(afterStep2.contains("2 of 8"),
                      "Step 2 (bug repro): expected footer to read '2 of 8' after launching " +
                      "a downloaded model, but was: '\(afterStep2)'")
    }

    // MARK: - Helpers

    private func tapModelRow(in app: XCUIApplication, title: String) {
        let row = app.staticTexts[title]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "Model row not found: \(title)")
        row.tap()
    }

    private func tapDownloadOrPlay(in app: XCUIApplication) {
        let button = app.buttons["ModelDetailView.downloadPlayButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 10),
                      "ModelDetailView.downloadPlayButton not found")
        button.tap()
    }

    /// Waits for the download-in-progress button to revert to play.fill.
    /// The button's identifier is stable; SwiftUI's symbol changes from
    /// stop.circle → play.fill when downloading completes.
    private func waitForDownloadComplete(in app: XCUIApplication, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.images["play.fill"].exists { return }
            Thread.sleep(forTimeInterval: 1.0)
        }
        XCTFail("Download did not complete within \(timeout)s")
    }

    /// After tapping play, the engine launches and the Quit toolbar button
    /// appears once the goban view loads. Tap Quit + confirm to return.
    private func waitForEngineThenQuit(in app: XCUIApplication, label: String) {
        let quit = app.buttons["Quit"]
        XCTAssertTrue(quit.waitForExistence(timeout: 120),
                      "Quit button did not appear after launching \(label) engine")
        quit.tap()

        // Confirmation dialog: the destructive button has the same label.
        // It is the most-recently-presented "Quit" element.
        let confirm = app.buttons.matching(identifier: "Quit").element(boundBy: 1)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5),
                      "Quit confirmation button not found")
        confirm.tap()
    }

    /// The picker has reappeared once any model row is visible again.
    private func waitForPicker(in app: XCUIApplication, title: String) {
        let row = app.staticTexts[title]
        XCTAssertTrue(row.waitForExistence(timeout: 60),
                      "Picker did not reappear after Quit")
    }

    private func readFooter(in app: XCUIApplication) -> String {
        let footer = app.staticTexts["CoreMLCache.footerStats"]
        XCTAssertTrue(footer.waitForExistence(timeout: 15),
                      "CoreMLCache.footerStats not found")
        return footer.label
    }
}
