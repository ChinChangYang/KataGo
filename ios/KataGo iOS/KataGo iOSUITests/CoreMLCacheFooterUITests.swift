//
//  CoreMLCacheFooterUITests.swift
//  KataGo iOSUITests
//
//  Tests for the Core ML cache footer in ModelPickerView:
//
//  1. testFooterCountIncrementsAfterDownloadedModelLaunch — regression
//     test for Step 2: after launching the built-in engine, returning to
//     the picker, and launching the engine with a non-built-in model, the
//     footer count should advance. Previously the count stayed at the
//     baseline because no cache write happened for downloaded models.
//
//     ⚠️ This test must NOT reach the network, and no test in this target
//     may. It used to fetch Lionffen b6c64 (~2.1 MB) from
//     media.katagotraining.org inside a 180 s ceiling, which made an
//     offline machine, a captive portal, a DNS hiccup or a slow mirror
//     produce a red run for an assertion that is not about downloading.
//     It now runs against a model STAGED on disk before launch by
//     `ModelStagingUITestSupport` — the same Lionffen b24c64 network the
//     app already ships inside its Safari-extension appex, copied to the
//     catalog entry's own download location at its exact declared byte
//     count. The app cannot tell that apart from a real download, so the
//     "launch a downloaded model" path this test exists to guard is still
//     the path under test. If the staging does not happen the test fails
//     outright rather than falling back to the network.
//
//  2. testFooterShowsZeroAfterClear — after tapping "Clear Cache" the
//     footer immediately shows "Main: 0 of <cap> · 0 B" and
//     "Human SL: 0 of <cap> · 0 B". No automatic repopulation occurs; the
//     cache refills only when the user explicitly loads a model.
//     The "Clear Cache" button hides once totalCount == 0.
//     The caps come from CoreMLModelCache.shared and differ per partition,
//     so these tests never assert on the cap itself — only on the count.
//
//  Run after `xcrun simctl uninstall booted chinchangyang.KataGo-iOS.tw`
//  for a clean cache state.
//

import XCTest

final class CoreMLCacheFooterUITests: PortraitUITestCase {

    private let builtInTitle  = "Built-in KataGo Network"

    /// The staged non-built-in model. This is the b24c64 net rather than the
    /// b6c64 one the test used to download, because b24c64 is the network the
    /// app already carries inside its Safari-extension appex — so it can be put
    /// on disk offline, under its own catalog file name, with matching bytes.
    private let lionffenTitle = "Lionffen b24c64 Network"

    /// Stages that model before the first view renders. `ModelPickerView`
    /// decides "downloaded" by testing for the file as it appears, so the
    /// staging has to be in place before launch, not after.
    private let stageModelArg = "--uitest-stage-downloaded-model"

    // MARK: - Tests

    @MainActor
    func testFooterCountIncrementsAfterDownloadedModelLaunch() throws {
        let app = makeApp(stageModelArg)
        app.launch()

        // The Core ML cache persists across local runs and may already be at its
        // entry cap ("Main: N of N"), leaving no room for the count to grow —
        // launching another model would just evict+replace. Clear it first so the
        // increment is observable (mirrors the file-header note about starting
        // from a clean cache). "Clear Cache" is only present when non-empty.
        revealClearCacheButton(in: app)
        let initialClear = app.buttons["Clear Cache"]
        if initialClear.waitForExistence(timeout: 10) {
            initialClear.tap()
            let confirmClear = app.buttons["Clear"]
            if confirmClear.waitForExistence(timeout: 5) { confirmClear.tap() }
        }

        // ----- Step 1: launch built-in, return, capture baseline count -----
        //
        // An engine launch may write more than one cache entry — the main
        // model plus auxiliaries like a HumanSL policy net — so this step
        // is treated as a baseline rather than a fixed count.

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
        launchStagedModel(in: app)
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
    /// cache and leaves the footer at "Main: 0 of <cap>" / "Human SL: 0 of
    /// <cap>". No automatic rewarm occurs. The "Clear Cache" button is hidden
    /// once totalCount drops to zero.
    @MainActor
    func testFooterShowsZeroAfterClear() throws {
        let app = makeApp()
        app.launch()

        // Populate the cache by launching the built-in engine once.
        tapModelRow(in: app, title: builtInTitle)
        tapDownloadOrPlay(in: app)
        waitForEngineThenQuit(in: app, label: "built-in")
        waitForPicker(in: app, title: builtInTitle)

        // Verify the Clear Cache button exists (totalCount > 0).
        revealClearCacheButton(in: app)
        let clearButton = app.buttons["Clear Cache"]
        XCTAssertTrue(clearButton.waitForExistence(timeout: 15),
                      "Clear Cache button should be visible when cache has entries")

        // Tap Clear Cache and confirm the destructive action.
        clearButton.tap()
        let confirmClear = app.buttons["Clear"]
        XCTAssertTrue(confirmClear.waitForExistence(timeout: 5),
                      "Confirmation 'Clear' button did not appear")
        confirmClear.tap()

        // The footer formats sizes with `ByteCountFormatter`, whose output for
        // zero bytes is locale/OS-dependent ("0 B", "0 KB", "Zero KB", "Zero
        // bytes", …) AND differs between the app process and this test process,
        // so we cannot match the byte string directly. The deterministic,
        // process-independent signal that the partition is empty is the
        // cleared count in "<Label>: 0 of <cap> · <size>".
        //
        // Assert on the PARSED count, never on the cap: the caps now come from
        // CoreMLModelCache.shared (evictionCap / auxiliaryEvictionCap), they
        // differ between the two partitions, and either may be retuned. The
        // label prefix is checked separately so a mislabelled row still fails,
        // and `parseCount` returns -1 when the line does not match the
        // "<Label>: N of M" shape at all.
        revealCacheFooter(in: app)
        let mainStats = app.staticTexts["CoreMLCache.footerMainStats"]
        XCTAssertTrue(mainStats.waitForExistence(timeout: 30),
                      "CoreMLCache.footerMainStats not found after Clear")
        XCTAssertTrue(mainStats.label.hasPrefix("Main: "),
                      "Expected the main line to be labelled 'Main: ', got: '\(mainStats.label)'")
        XCTAssertEqual(parseCount(mainStats.label), 0,
                       "Expected 'Main: 0 of <cap>' after Clear, got: '\(mainStats.label)'")

        // Human SL partition must also read "Human SL: 0 of <cap>" after Clear.
        let auxStats = app.staticTexts["CoreMLCache.footerAuxStats"]
        XCTAssertTrue(auxStats.waitForExistence(timeout: 30),
                      "CoreMLCache.footerAuxStats not found after Clear")
        XCTAssertTrue(auxStats.label.hasPrefix("Human SL: "),
                      "Expected the aux line to be labelled 'Human SL: ', got: '\(auxStats.label)'")
        XCTAssertEqual(parseCount(auxStats.label), 0,
                       "Expected 'Human SL: 0 of <cap>' after Clear, got: '\(auxStats.label)'")

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
        let app = makeApp()
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
        let app = makeApp()
        app.launch()

        // A game must be selected for the "Settings" menu item to appear,
        // so launch the built-in engine to reach the goban.
        tapModelRow(in: app, title: builtInTitle)
        tapDownloadOrPlay(in: app)        // built-in is bundled → play.fill

        let lockButton = app.buttons["Lock"]
        XCTAssertTrue(lockButton.waitForExistence(timeout: 240),
                      "Goban (Lock button) did not appear after launching the built-in engine")

        // Quiet the board before opening the sheet and toggling a switch. Analysis
        // runs continuously after launch and keeps the app non-idle, so a
        // synthesized tap on the Global Settings toggle can land during a board
        // re-render and be dropped — the run-1/3/4 forensics showed taps landing
        // geometrically ON the switch control that still never flipped its value,
        // while an otherwise identical run that happened to tap between re-renders
        // passed. Wait until analysis is established (a winrate label), then pause
        // it (one tap on Toggle Analysis) so the board stops churning — the same
        // guard PlayerNameLabelUITests uses before driving its menus. Pausing is
        // irrelevant to what this test checks (the relocated display preferences).
        let winrate = app.staticTexts.matching(identifier: "AnalysisView.winrate").firstMatch
        _ = winrate.waitForExistence(timeout: 120)
        let analysisToggle = app.buttons["Toggle Analysis"].firstMatch
        if analysisToggle.waitForExistence(timeout: 10) { analysisToggle.tap() }
        usleep(3_000_000)  // 3s settle: let the stop ack drain and re-renders cease

        // Open the "More" menu → "Settings"; it opens Global Settings directly.
        let moreButton = app.buttons["More"].firstMatch
        XCTAssertTrue(moreButton.waitForExistence(timeout: 10), "More menu button not found")
        moreButton.tap()

        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10),
                      "Settings menu item not found")
        settings.tap()

        // ----- Global Settings now hosts the relocated display preferences -----
        XCTAssertTrue(app.navigationBars["Global Settings"].waitForExistence(timeout: 15),
                      "Global Settings sheet not shown")

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
        //
        // The old single dx:0.92 tap + 3s poll was flaky here (it was fine before
        // Task 3, when tapping a "Global Settings" hub row and waiting through its
        // push animation left the sheet settled and the board's churn had subsided).
        // Two effects combined:
        //   1. Dropped tap under board churn — the PRIMARY cause. The forensics
        //      showed taps landing geometrically ON the switch control that still
        //      never flipped the value, while a lucky run that tapped between
        //      re-renders passed; the quieting step above (pause analysis) removes
        //      this by stopping the re-renders.
        //   2. Moving frame — the Global Settings sheet presents with animation and
        //      `waitForExistence` returns mid-presentation, so an early tap can fire
        //      against a still-moving frame.
        // `flipSwitch` is the belt-and-suspenders: it settles the frame before each
        // tap, targets the toggle by a fixed inset from the row's right edge, and
        // re-taps until the value actually flips (recovering any tap still dropped).
        let before = showCoordinate.value as? String
        XCTAssertTrue(flipSwitch(showCoordinate, awayFrom: before ?? "1"),
                      "'Show coordinate' did not toggle from \(before ?? "nil")")
        // Restore the default by flipping it back (idempotent reruns). Same
        // self-healing re-tap on an already-settled screen; a stray miss here is
        // only cosmetic since the next run re-captures `before`.
        _ = flipSwitch(showCoordinate, awayFrom: showCoordinate.value as? String ?? "1")

        // ----- The per-game "View" tab is gone; the others remain. Game
        // Settings now lives under This Game, so dismiss the Global Settings
        // sheet (swipe down ON THE NAV BAR — the list is scrollable, so a bare
        // list swipeDown would scroll instead of dismiss) and reopen it via
        // More ▸ This Game ▸ Game Settings. -----
        app.navigationBars["Global Settings"].swipeDown(velocity: .fast)

        let moreAgain = app.buttons["More"].firstMatch
        XCTAssertTrue(moreAgain.waitForExistence(timeout: 15),
                      "More menu button not found after dismissing Global Settings")
        moreAgain.tap()
        let thisGame = app.buttons["This Game"].firstMatch
        XCTAssertTrue(thisGame.waitForExistence(timeout: 10), "This Game submenu not found")
        thisGame.tap()
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
        let app = makeApp()
        app.launch()

        // A game must be selected for the "Settings" menu item to appear.
        tapModelRow(in: app, title: builtInTitle)
        tapDownloadOrPlay(in: app)        // built-in is bundled → play.fill

        let lockButton = app.buttons["Lock"]
        XCTAssertTrue(lockButton.waitForExistence(timeout: 240),
                      "Goban (Lock button) did not appear after launching the built-in engine")

        // Open "More" → "Settings".
        let moreButton = app.buttons["More"].firstMatch
        XCTAssertTrue(moreButton.waitForExistence(timeout: 10), "More menu button not found")
        moreButton.tap()

        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10),
                      "Settings menu item not found")
        settings.tap()

        // Licenses now live under Global Settings ▸ About, which Settings opens
        // directly.
        XCTAssertTrue(app.navigationBars["Global Settings"].waitForExistence(timeout: 15),
                      "Global Settings sheet not shown")

        // The About section sits at the bottom of the (now longer) Global
        // Settings list, so scroll it into view first — off-screen SwiftUI List
        // cells aren't in the a11y tree.
        let licensesRow = app.buttons["Open-Source Licenses"].firstMatch
        reveal(app, licensesRow, by: { app.swipeUp() })
        XCTAssertTrue(licensesRow.waitForExistence(timeout: 10),
                      "'Open-Source Licenses' row missing from Global Settings")
        licensesRow.tap()

        // The list includes KataGo itself (near the top) and the MLX
        // trigger — which the three "KataGo …" content entries push below
        // the fold on an iPhone, so scroll it into view first (off-screen
        // SwiftUI List cells aren't in the a11y tree).
        XCTAssertTrue(app.buttons["KataGo"].firstMatch.waitForExistence(timeout: 10),
                      "'KataGo' row missing from Open-Source Licenses")
        let mlxRow = app.buttons["MLX"].firstMatch
        reveal(app, mlxRow, by: { app.swipeUp() })
        XCTAssertTrue(mlxRow.waitForExistence(timeout: 10),
                      "'MLX' row missing from Open-Source Licenses")

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

    /// Blocks until `element` is hittable AND its frame has stopped moving —
    /// unchanged across `stableChecks` consecutive polls. A presenting sheet
    /// animates its contents, and `waitForExistence` returns mid-animation, so a
    /// coordinate tap computed against a still-moving frame misses its target.
    /// Mirrors PlayerNameLabelUITests' `isStablyPresent` stability-polling idea,
    /// extended from bare `.exists` to frame + hittability. Returns early once
    /// settled; falls through after `timeout` so a genuinely stuck frame still
    /// lets the caller's own assertion report the failure.
    @MainActor
    private func waitUntilSettled(_ element: XCUIElement,
                                  stableChecks: Int = 4,
                                  gapMicros: UInt32 = 100_000,
                                  timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        var previous = element.frame
        var streak = 0
        while Date() < deadline && streak < stableChecks {
            usleep(gapMicros)
            let current = element.frame
            if element.isHittable && current == previous {
                streak += 1
            } else {
                streak = 0
            }
            previous = current
        }
    }

    /// Taps a Switch's trailing toggle control and confirms its value moves away
    /// from `current`, re-tapping up to `attempts` times. A single tap can be
    /// dropped (delivered during a board re-render) or fired against a still-moving
    /// frame, and a one-shot tap + poll cannot recover it; each attempt settles the
    /// frame first, then re-taps only while the value is still `current`. The
    /// per-attempt poll is generous (a registered tap flips via Observation in well
    /// under a second), so only a genuinely dropped tap — not a slow one — triggers
    /// a re-tap, avoiding a double-toggle race. Returns true once the value leaves
    /// `current`. (The board is also quieted before calling this, which removes the
    /// dominant dropped-tap cause; the retry loop is defensive insurance.)
    @MainActor
    private func flipSwitch(_ sw: XCUIElement,
                            awayFrom current: String,
                            attempts: Int = 5,
                            perAttempt: TimeInterval = 4) -> Bool {
        for _ in 0..<attempts {
            waitUntilSettled(sw)
            // Aim at the trailing toggle control by a fixed inset from the row's
            // RIGHT EDGE. The switch's a11y frame spans the whole row (a center tap
            // lands on the label and does not flip a SwiftUI Toggle), and the
            // forensics measured the control at ~40pt in from the row's right edge;
            // a right-edge-anchored offset hits it regardless of row width, unlike a
            // normalized dx:0.92 that drifts with the inset.
            sw.coordinate(withNormalizedOffset: CGVector(dx: 1.0, dy: 0.5))
              .withOffset(CGVector(dx: -40, dy: 0))
              .tap()
            let changed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value != %@", current),
                object: sw)
            if XCTWaiter().wait(for: [changed], timeout: perAttempt) == .completed {
                return true
            }
        }
        return false
    }

    /// Scrolls the picker until the Core ML cache footer is realized.
    ///
    /// The footer is the picker's LAST section — below the model catalog, the
    /// Custom Networks section and the Opening Books row — so it sits well off
    /// screen on an iPhone at launch. SwiftUI's List is lazy, so a row that far
    /// down is not in the accessibility tree at all and `waitForExistence`
    /// finds nothing however long it waits. These tests used to pass only
    /// because the footer happened to fall inside the realized window; adding a
    /// section above it pushed it out. Scroll for it explicitly instead of
    /// depending on where it lands.
    @MainActor
    private func revealCacheFooter(in app: XCUIApplication) {
        reveal(app, app.staticTexts["CoreMLCache.footerMainStats"], by: { app.swipeUp() })
    }

    /// Same, for the Clear Cache button, which lives in that footer.
    @MainActor
    private func revealClearCacheButton(in app: XCUIApplication) {
        reveal(app, app.buttons["Clear Cache"], by: { app.swipeUp() })
    }

    /// Swipe until `element` is present, up to `maxSwipes` (off-screen SwiftUI
    /// List/Form cells aren't in the a11y tree).
    @MainActor
    private func reveal(_ app: XCUIApplication,
                        _ element: XCUIElement,
                        by swipe: () -> Void,
                        maxSwipes: Int = 8) {
        var n = 0
        while !element.exists && n < maxSwipes {
            swipe()
            n += 1
        }
    }

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
        // Usually the picker is already at the top and this resolves at once.
        // If it does not, the list may be scrolled away from the top —
        // revealing the cache footer leaves it at the bottom, and when the
        // cache is already empty there is no Clear Cache button to stop that
        // scroll early. Only then scroll back up, so the common path keeps its
        // original settle-and-wait behaviour untouched.
        if !row.waitForExistence(timeout: 15) {
            reveal(app, row, by: { app.swipeDown() })
        }
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

    /// Launches the engine on a non-built-in model that is ALREADY on disk.
    ///
    /// The trash button is the app's own signal that the file is present: it
    /// renders only when `ModelDetailView` found the model at its
    /// `downloadedURL`. Requiring it here is what keeps this test offline —
    /// this helper used to tap download and wait 180 s when the trash button
    /// was absent, which is exactly the fallback that let a missing file turn
    /// into a network fetch. There is deliberately no such branch now: if the
    /// file is not staged, fail and say so, rather than quietly going online.
    @MainActor
    private func launchStagedModel(in app: XCUIApplication) {
        let trash = app.buttons["ModelDetailView.trashButton"]
        XCTAssertTrue(
            trash.waitForExistence(timeout: 15),
            "\(lionffenTitle) is not on disk, so the app would offer to DOWNLOAD it — " +
            "and UI tests must stay offline. The '\(stageModelArg)' launch argument " +
            "should have staged it before launch; check ModelStagingUITestSupport, " +
            "whose failures print a line beginning 'UITEST STAGING FAILED'.")
        tapDownloadOrPlay(in: app)
    }

    /// After tapping play, the engine launches and the goban (GameSplitView)
    /// appears. Quitting the engine (return to the model picker) now lives in
    /// Global Settings ▸ Engine: tapping the Model row raises a confirmation
    /// dialog whose destructive "Quit" tears down the engine — commit f9c85d85
    /// removed the old sidebar-toolbar Quit button. Reach it via the board
    /// "More" ▸ "Settings" menu, which opens Global Settings directly (the same
    /// path the passing display-preferences / licenses tests use).
    @MainActor
    private func waitForEngineThenQuit(in app: XCUIApplication, label: String) {
        // Wait for the goban detail. The "Lock" toolbar button is the most
        // reliable signal that GameSplitView is on screen.
        let lockButton = app.buttons["Lock"]
        XCTAssertTrue(lockButton.waitForExistence(timeout: 180),
                      "Goban (Lock button) did not appear after launching \(label) engine")

        // Board "More" → "Settings" (opens Global Settings directly).
        let more = app.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 15), "More menu not found (\(label))")
        more.tap()
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "Settings menu item not found (\(label))")
        settings.tap()
        XCTAssertTrue(app.navigationBars["Global Settings"].waitForExistence(timeout: 15),
                      "Global Settings sheet not shown (\(label))")

        // Engine ▸ Model row raises the quit confirmation. It sits near the
        // bottom of the (long) Global Settings list, so scroll it into view.
        let quitRow = app.descendants(matching: .any)
            .matching(identifier: "GlobalSettingsView.quitEngineRow").firstMatch
        reveal(app, quitRow, by: { app.swipeUp() })
        XCTAssertTrue(quitRow.waitForExistence(timeout: 10),
                      "Quit engine row not found in Global Settings (\(label))")
        quitRow.tap()

        // Confirmation dialog renders as a sheet on iPhone. Tap the
        // destructive "Quit" inside it.
        let dialogQuit = app.sheets.buttons["Quit"]
        if dialogQuit.waitForExistence(timeout: 5) {
            dialogQuit.tap()
        } else {
            // Fallback for compact rendering where the dialog hosts the
            // Quit button under the app root.
            let allQuit = app.buttons.matching(identifier: "Quit")
            XCTAssertGreaterThanOrEqual(allQuit.count, 1,
                                        "Quit confirmation button not found (\(label))")
            allQuit.element(boundBy: allQuit.count - 1).tap()
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
        revealCacheFooter(in: app)
        let footer = app.staticTexts["CoreMLCache.footerMainStats"]
        XCTAssertTrue(footer.waitForExistence(timeout: 15),
                      "CoreMLCache.footerMainStats not found")
        return footer.label
    }
}
