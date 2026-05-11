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

        // ----- Step 1: launch built-in, return, capture baseline count -----
        //
        // An engine launch may write more than one cache entry — the main
        // model plus auxiliaries like a HumanSL policy net — so this step
        // is treated as a baseline rather than a fixed "1 of 8" check.

        tapModelRow(in: app, title: builtInTitle)
        tapDownloadOrPlay(in: app)        // built-in is bundled → play.fill
        waitForEngineThenQuit(in: app, label: "built-in")
        waitForPicker(in: app, title: builtInTitle)

        let afterStep1 = readFooter(in: app)
        let countAfterStep1 = parseCompiledModelsCount(afterStep1)
        XCTAssertGreaterThanOrEqual(countAfterStep1, 1,
                                    "Step 1: expected at least one compiled model after " +
                                    "launching the built-in engine, footer was: '\(afterStep1)'")

        // ----- Step 2: launch the downloaded Lionffen model and verify the
        // footer's compiled-model count INCREASED — the bug was that no
        // cache write happened for downloaded models, so the count stayed
        // at the baseline.

        tapModelRow(in: app, title: lionffenTitle)
        ensureDownloadedThenPlay(in: app)
        waitForEngineThenQuit(in: app, label: "Lionffen")
        waitForPicker(in: app, title: lionffenTitle)

        let afterStep2 = readFooter(in: app)
        let countAfterStep2 = parseCompiledModelsCount(afterStep2)
        XCTAssertGreaterThan(countAfterStep2, countAfterStep1,
                             "Step 2 (bug repro): expected footer count to increase after " +
                             "launching a downloaded model. Step 1 footer: '\(afterStep1)'; " +
                             "Step 2 footer: '\(afterStep2)'")
    }

    /// Parses the "N of 8 compiled models" fragment that appears in the
    /// non-empty footer label. Returns 0 when the footer reads "empty".
    private func parseCompiledModelsCount(_ label: String) -> Int {
        if label.contains("empty") { return 0 }
        guard let range = label.range(of: #"(\d+) of 8 compiled models"#,
                                       options: .regularExpression) else {
            return -1
        }
        let match = String(label[range])
        let n = match.split(separator: " ").first.flatMap { Int($0) }
        return n ?? -1
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

    /// Handles both "needs to download" and "already downloaded" starting
    /// states for a non-built-in model on ModelDetailView. On entry the trash
    /// button's presence indicates whether the file is already on disk:
    /// - trash visible → tap play (single tap launches the engine)
    /// - trash absent  → tap download, wait for trash, tap play again
    private func ensureDownloadedThenPlay(in app: XCUIApplication,
                                          downloadTimeout: TimeInterval = 180) {
        let trash = app.buttons["ModelDetailView.trashButton"]
        if !trash.exists {
            tapDownloadOrPlay(in: app)
            XCTAssertTrue(trash.waitForExistence(timeout: downloadTimeout),
                          "Download did not complete within \(downloadTimeout)s")
        }
        tapDownloadOrPlay(in: app)
    }

    /// After tapping play, the engine launches and the goban (GameSplitView)
    /// appears. On iPhone (compact), NavigationSplitView collapses to a
    /// navigation stack with the sidebar as the root and the goban pushed
    /// on top. The Quit button lives in the sidebar's toolbar (GameListToolbar)
    /// — reach it by tapping the navigation-bar leading button to pop back
    /// to the sidebar, then tap Quit and confirm.
    private func waitForEngineThenQuit(in app: XCUIApplication, label: String) {
        // First: wait for the goban detail to appear. The "Lock" toolbar
        // button is the most reliable signal that GameSplitView is on screen.
        let lockButton = app.buttons["Lock"]
        XCTAssertTrue(lockButton.waitForExistence(timeout: 180),
                      "Goban (Lock button) did not appear after launching \(label) engine")

        // Tap leading navigation-bar button to return to the sidebar.
        let leadingNavButton = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(leadingNavButton.waitForExistence(timeout: 5),
                      "Navigation-bar leading button not found")
        leadingNavButton.tap()

        let toolbarQuit = app.buttons["Quit"]
        XCTAssertTrue(toolbarQuit.waitForExistence(timeout: 10),
                      "Quit button did not appear in sidebar after engine launch (\(label))")
        toolbarQuit.tap()

        // Confirmation dialog renders as a sheet on iPhone. Tap the
        // destructive "Quit" inside it.
        let dialogQuit = app.sheets.buttons["Quit"]
        if dialogQuit.waitForExistence(timeout: 5) {
            dialogQuit.tap()
        } else {
            // Fallback for compact rendering where the dialog hosts
            // both Quit buttons under the app root.
            let allQuit = app.buttons.matching(identifier: "Quit")
            XCTAssertGreaterThanOrEqual(allQuit.count, 2,
                                        "Quit confirmation button not found")
            allQuit.element(boundBy: 1).tap()
        }
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
