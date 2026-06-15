//
//  CoreMLCacheFooterUITests.swift
//  KataGo iOSUITests
//
//  Tests for the Core ML cache footer in ModelPickerView:
//
//  1. testFooterCountIncrementsAfterDownloadedModelLaunch — regression
//     test for Step 2: after launching the built-in engine, returning to
//     the picker, downloading the smallest non-built-in model
//     (Lionffen b6c64, ~2.1 MB), and launching the engine with it, the
//     footer count should advance. Previously the count stayed at the
//     baseline because no cache write happened for downloaded models.
//
//  2. testFooterShowsZeroAfterClear — after tapping "Clear Cache" the
//     footer immediately shows "Main: 0 of 4 · 0 B" and
//     "Human SL: 0 of 4 · 0 B". No automatic repopulation occurs; the
//     cache refills only when the user explicitly loads a model.
//     The "Clear Cache" button hides once totalCount == 0.
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

    // MARK: - Tests

    @MainActor
    func testFooterCountIncrementsAfterDownloadedModelLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        // ----- Step 1: launch built-in, return, capture baseline count -----
        //
        // An engine launch may write more than one cache entry — the main
        // model plus auxiliaries like a HumanSL policy net — so this step
        // is treated as a baseline rather than a fixed "1 of 4" check.

        tapModelRow(in: app, title: builtInTitle)
        tapDownloadOrPlay(in: app)        // built-in is bundled → play.fill
        waitForEngineThenQuit(in: app, label: "built-in")
        waitForPicker(in: app, title: builtInTitle)

        let afterStep1 = readMainStats(in: app)
        let countAfterStep1 = parseCount(afterStep1)
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

        let afterStep2 = readMainStats(in: app)
        let countAfterStep2 = parseCount(afterStep2)
        XCTAssertGreaterThan(countAfterStep2, countAfterStep1,
                             "Step 2 (bug repro): expected footer count to increase after " +
                             "launching a downloaded model. Step 1 footer: '\(afterStep1)'; " +
                             "Step 2 footer: '\(afterStep2)'")
    }

    /// After dropping PrecompileScheduler, tapping "Clear Cache" wipes the
    /// cache and leaves the footer at "Main: 0 of 4" / "Human SL: 0 of 4".
    /// No automatic rewarm occurs. The "Clear Cache" button is hidden once
    /// totalCount drops to zero.
    @MainActor
    func testFooterShowsZeroAfterClear() throws {
        let app = XCUIApplication()
        app.launch()

        // Populate the cache by launching the built-in engine once.
        tapModelRow(in: app, title: builtInTitle)
        tapDownloadOrPlay(in: app)
        waitForEngineThenQuit(in: app, label: "built-in")
        waitForPicker(in: app, title: builtInTitle)

        // Verify the Clear Cache button exists (totalCount > 0).
        let clearButton = app.buttons["Clear Cache"]
        XCTAssertTrue(clearButton.waitForExistence(timeout: 15),
                      "Clear Cache button should be visible when cache has entries")

        // Tap Clear Cache and confirm the destructive action.
        clearButton.tap()
        let confirmClear = app.buttons["Clear"]
        XCTAssertTrue(confirmClear.waitForExistence(timeout: 5),
                      "Confirmation 'Clear' button did not appear")
        confirmClear.tap()

        // Footer must now read "Main: 0 of 4" with zero bytes.
        let mainStats = app.staticTexts["CoreMLCache.footerMainStats"]
        XCTAssertTrue(mainStats.waitForExistence(timeout: 30),
                      "CoreMLCache.footerMainStats not found after Clear")
        XCTAssertTrue(mainStats.label.contains("Main: 0 of 4"),
                      "Expected 'Main: 0 of 4' after Clear, got: '\(mainStats.label)'")
        XCTAssertTrue(mainStats.label.contains("0 B")
                      || mainStats.label.contains("Zero bytes"),
                      "Expected zero-byte size after Clear, got: '\(mainStats.label)'")

        // Human SL partition must also read "Human SL: 0 of 4" with zero bytes.
        let auxStats = app.staticTexts["CoreMLCache.footerAuxStats"]
        XCTAssertTrue(auxStats.waitForExistence(timeout: 30),
                      "CoreMLCache.footerAuxStats not found after Clear")
        XCTAssertTrue(auxStats.label.contains("Human SL: 0 of 4"),
                      "Expected 'Human SL: 0 of 4' after Clear, got: '\(auxStats.label)'")
        XCTAssertTrue(auxStats.label.contains("0 B")
                      || auxStats.label.contains("Zero bytes"),
                      "Expected zero-byte size for Human SL after Clear, got: '\(auxStats.label)'")

        // The Clear Cache button must disappear once totalCount == 0.
        XCTAssertFalse(clearButton.waitForExistence(timeout: 5),
                       "Clear Cache button should be hidden when cache is empty")
    }

    /// End-to-end runtime check that the MLX backend actually evaluates the
    /// neural net and the board renders its analysis: after launching the
    /// built-in model, AnalysisView's per-move winrate labels must appear on the
    /// goban. analysisStatus defaults to .run, so analysis starts automatically
    /// once the goban is on screen. Generous timeouts — the simulator's
    /// software-Metal path is slow to produce the first analysis.
    @MainActor
    func testAnalysisTextAppearsOnBoard() throws {
        let app = XCUIApplication()
        app.launch()

        tapModelRow(in: app, title: builtInTitle)
        tapDownloadOrPlay(in: app)        // built-in is bundled → play.fill

        // The goban (GameSplitView) is on screen once the "Lock" toolbar button exists.
        let lockButton = app.buttons["Lock"]
        XCTAssertTrue(lockButton.waitForExistence(timeout: 240),
                      "Goban (Lock button) did not appear after launching the built-in engine")

        // Analysis text: AnalysisView renders winrate % labels per candidate move
        // (default "All" mode shows winrate + visits + score).
        let winrate = app.staticTexts.matching(identifier: "AnalysisView.winrate").firstMatch
        let appeared = winrate.waitForExistence(timeout: 180)

        // Capture the board for visual confirmation regardless of the query result.
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "board-analysis"
        shot.lifetime = .keepAlways
        add(shot)

        XCTAssertTrue(appeared,
                      "No analysis winrate text appeared on the board — the engine did not produce analysis")
    }

    /// Verifies the settings migration: the display preferences that used to live
    /// in the per-game "View" config screen are now under Global Settings (and
    /// are interactive there, wired to GobanState), and the per-game "View" row
    /// has been removed while the other per-game tabs remain.
    @MainActor
    func testDisplayPreferencesMovedToGlobalSettings() throws {
        let app = XCUIApplication()
        app.launch()

        // A game must be selected for the "Configurations" menu item to appear,
        // so launch the built-in engine to reach the goban.
        tapModelRow(in: app, title: builtInTitle)
        tapDownloadOrPlay(in: app)        // built-in is bundled → play.fill

        let lockButton = app.buttons["Lock"]
        XCTAssertTrue(lockButton.waitForExistence(timeout: 240),
                      "Goban (Lock button) did not appear after launching the built-in engine")

        // Open the "More" menu → "Configurations" to present ConfigView.
        let moreButton = app.buttons["More"].firstMatch
        XCTAssertTrue(moreButton.waitForExistence(timeout: 10), "More menu button not found")
        moreButton.tap()

        let configurations = app.buttons["Configurations"].firstMatch
        XCTAssertTrue(configurations.waitForExistence(timeout: 10),
                      "Configurations menu item not found")
        configurations.tap()

        // ----- Global Settings now hosts the relocated display preferences -----
        let globalSettings = app.buttons["Global Settings"].firstMatch
        XCTAssertTrue(globalSettings.waitForExistence(timeout: 10), "Global Settings row not found")
        globalSettings.tap()

        // Every display toggle that used to be under the per-game "View" tab.
        let showCoordinate = app.switches["Show coordinate"].firstMatch
        XCTAssertTrue(showCoordinate.waitForExistence(timeout: 10),
                      "'Show coordinate' toggle missing from Global Settings")
        for title in ["Show pass", "Vertical flip", "Show chart/comments",
                      "Show ownership", "Show win rate bar"] {
            XCTAssertTrue(app.switches[title].firstMatch.waitForExistence(timeout: 5),
                          "'\(title)' toggle missing from Global Settings")
        }
        // The relocated "Stone style" picker title is present too.
        let stoneStylePicker = app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS %@", "Stone style")).firstMatch
        XCTAssertTrue(stoneStylePicker.waitForExistence(timeout: 5),
                      "'Stone style' picker missing from Global Settings")

        // The toggle is interactive and flips state (proves the GobanState wiring).
        // Tap the trailing edge where the switch control lives (a center tap can
        // land on the row label), then poll for the value to settle.
        let before = showCoordinate.value as? String
        showCoordinate.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let flipped = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", before ?? "1"),
            object: showCoordinate)
        XCTAssertEqual(XCTWaiter().wait(for: [flipped], timeout: 3), .completed,
                       "'Show coordinate' did not toggle from \(before ?? "nil")")
        showCoordinate.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()   // restore default

        // ----- The per-game "View" tab is gone; the others remain -----
        let backButton = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(backButton.waitForExistence(timeout: 5), "Back button not found")
        backButton.tap()

        let gameSettings = app.buttons["Game Settings"].firstMatch
        XCTAssertTrue(gameSettings.waitForExistence(timeout: 10), "Game Settings row not found")
        gameSettings.tap()

        XCTAssertTrue(app.buttons["Rule"].firstMatch.waitForExistence(timeout: 10),
                      "'Rule' row missing from Game Settings")
        XCTAssertTrue(app.buttons["Analysis"].firstMatch.exists,
                      "'Analysis' row missing from Game Settings")
        XCTAssertFalse(app.buttons["View"].firstMatch.exists,
                       "'View' row should have been removed from per-game Game Settings")
    }

    @MainActor
    func testOpenSourceLicensesScreen() throws {
        let app = XCUIApplication()
        app.launch()

        // A game must be selected for the "Configurations" menu item to appear.
        tapModelRow(in: app, title: builtInTitle)
        tapDownloadOrPlay(in: app)        // built-in is bundled → play.fill

        let lockButton = app.buttons["Lock"]
        XCTAssertTrue(lockButton.waitForExistence(timeout: 240),
                      "Goban (Lock button) did not appear after launching the built-in engine")

        // Open "More" → "Configurations".
        let moreButton = app.buttons["More"].firstMatch
        XCTAssertTrue(moreButton.waitForExistence(timeout: 10), "More menu button not found")
        moreButton.tap()

        let configurations = app.buttons["Configurations"].firstMatch
        XCTAssertTrue(configurations.waitForExistence(timeout: 10),
                      "Configurations menu item not found")
        configurations.tap()

        // The new third row opens the Open-Source Licenses list.
        let licensesRow = app.buttons["Open-Source Licenses"].firstMatch
        XCTAssertTrue(licensesRow.waitForExistence(timeout: 10),
                      "'Open-Source Licenses' row missing from Configurations")
        licensesRow.tap()

        // The list includes the MLX trigger and KataGo itself.
        let mlxRow = app.buttons["MLX"].firstMatch
        XCTAssertTrue(mlxRow.waitForExistence(timeout: 10),
                      "'MLX' row missing from Open-Source Licenses")
        XCTAssertTrue(app.buttons["KataGo"].firstMatch.waitForExistence(timeout: 10),
                      "'KataGo' row missing from Open-Source Licenses")

        // Opening a component shows its verbatim license text.
        mlxRow.tap()
        XCTAssertTrue(app.navigationBars["MLX"].waitForExistence(timeout: 10),
                      "MLX license detail did not open")
        let licenseBody = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "Permission is hereby granted")).firstMatch
        XCTAssertTrue(licenseBody.waitForExistence(timeout: 10),
                      "MLX license text not shown")
    }

    // MARK: - Helpers

    /// Parses the "<Label>: N of M" fragment from a footer line.
    private func parseCount(_ label: String) -> Int {
        guard let range = label.range(of: #":\s*(\d+)\s+of\s+\d+"#,
                                       options: .regularExpression) else {
            return -1
        }
        let match = String(label[range])
        let digits = match.drop { !$0.isNumber }
                          .prefix { $0.isNumber }
        return Int(digits) ?? -1
    }

    @MainActor
    private func tapModelRow(in app: XCUIApplication, title: String) {
        let row = app.staticTexts[title]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "Model row not found: \(title)")
        row.tap()
    }

    @MainActor
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
    @MainActor
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
    @MainActor
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
    @MainActor
    private func waitForPicker(in app: XCUIApplication, title: String) {
        let row = app.staticTexts[title]
        XCTAssertTrue(row.waitForExistence(timeout: 60),
                      "Picker did not reappear after Quit")
    }

    @MainActor
    private func readMainStats(in app: XCUIApplication) -> String {
        let footer = app.staticTexts["CoreMLCache.footerMainStats"]
        XCTAssertTrue(footer.waitForExistence(timeout: 15),
                      "CoreMLCache.footerMainStats not found")
        return footer.label
    }
}
