//
//  BackendConfigSheetUITests.swift
//  KataGo iOSUITests
//
//  UI tests for the per-model Backend Settings sheet: the Backend picker
//  (MLX/GPU, CoreML/NE, GPU+ANE), the Max Board Size picker, and the Search
//  Threads stepper. This is pure UI and never launches the engine, so it is
//  safe on the simulator. (Whether the engine actually runs the chosen backend
//  / tunes at the chosen size can only be confirmed on a real device.)
//

import XCTest

// `PortraitUITestCase` matters more here than anywhere else, on both of its
// axes.
//
// Orientation: this class sorts FIRST, so it inherits whatever the PREVIOUS run
// left behind. On 2026-08-03 that is exactly how it failed — `stepper.isHittable`
// below came back false in an inherited landscape window, before any rotator in
// its own run had executed.
//
// Per-model settings: this class is the suite's only writer of them, and
// `makeApp()` clears them on every launch. That is what makes the "defaults to"
// assertions below legitimate — they read a state this launch established,
// rather than betting on the previous run having restored it. Because a failed
// assertion `abort()`s (`continueAfterFailure = false`, exceptions disabled),
// no end-of-test restore can be relied on, and a leaked Max Board Size of 13
// would make every 19x19 board in every later class render as "Too large board
// size". Anything new added here may therefore leave a non-default value
// behind, but must not depend on one.
final class BackendConfigSheetUITests: PortraitUITestCase {

    private let builtInTitle = "Built-in KataGo Network"
    private let boardSizes = ["9x9", "13x13", "19x19", "37x37"]
    private let backends = ["MLX/GPU", "CoreML/NE", "GPU+ANE"]

    @MainActor
    func testMaxBoardSizePickerDefaultsChangesAndPersists() throws {
        let app = makeApp()
        app.launch()

        // Navigate from the model list into the built-in model's detail view.
        // Done once: dismissing the config sheet returns here, not to the list,
        // so the reopen below must NOT tap the row again (the title also shows
        // as the detail nav title → multiple matches).
        let row = app.staticTexts[builtInTitle]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "Model row not found: \(builtInTitle)")
        row.tap()

        openBackendSheet(in: app)

        // All four "Max Board Size" segments must be present.
        for size in boardSizes {
            XCTAssertTrue(segment(in: app, size).waitForExistence(timeout: 10),
                          "Max Board Size option '\(size)' not found")
        }

        // Default selection is 19x19. `makeApp()` cleared the persisted value
        // at launch, so this reads a genuine default rather than whatever the
        // previous run happened to leave.
        XCTAssertTrue(segment(in: app, "19x19").isSelected,
                      "Max board size should default to 19x19, "
                      + "selected was: \(selectedBoardSize(in: app) ?? "none")")

        // Change to 13x13 and confirm the selection moves there.
        segment(in: app, "13x13").tap()
        XCTAssertTrue(segment(in: app, "13x13").isSelected,
                      "Tapping 13x13 did not select it")

        // Dismiss and reopen; the choice must persist (per-model UserDefaults).
        app.buttons["Done"].tap()
        openBackendSheet(in: app)
        let thirteen = segment(in: app, "13x13")
        XCTAssertTrue(thirteen.waitForExistence(timeout: 10) && thirteen.isSelected,
                      "Max board size did not persist as 13x13 across reopen, "
                      + "selected was: \(selectedBoardSize(in: app) ?? "none")")

        // Put 19x19 back. This is a courtesy — it keeps a manual launch on the
        // same simulator from meeting a 13x13 engine — and one more round-trip
        // through the picker. It is NOT what makes the suite safe: an abort at
        // any assertion above skips it, which is why the reset lives in
        // `makeApp()` instead.
        segment(in: app, "19x19").tap()
        XCTAssertTrue(segment(in: app, "19x19").isSelected,
                      "Selecting 19x19 again did not select it")
    }

    @MainActor
    func testBackendPickerChangesAndPersists() throws {
        let app = makeApp()
        app.launch()

        let row = app.staticTexts[builtInTitle]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "Model row not found: \(builtInTitle)")
        row.tap()

        openBackendSheet(in: app)

        // All three backend segments must be present.
        for name in backends {
            XCTAssertTrue(segment(in: app, name).waitForExistence(timeout: 10),
                          "Backend option '\(name)' not found")
        }

        // Default selection is CoreML/NE. Assertable for the same reason as the
        // board-size default above: `makeApp()` cleared the persisted choice at
        // launch. (Before that reset existed this test could only say "each
        // choice is selectable", because a stale value from a prior run would
        // have poisoned an absolute claim.)
        XCTAssertTrue(segment(in: app, "CoreML/NE").isSelected,
                      "Backend should default to CoreML/NE, "
                      + "selected was: \(selectedBackend(in: app) ?? "none")")

        // Select GPU+ANE; it must persist across a reopen (per-model UserDefaults).
        segment(in: app, "GPU+ANE").tap()
        XCTAssertTrue(segment(in: app, "GPU+ANE").isSelected,
                      "Tapping GPU+ANE did not select it")
        app.buttons["Done"].tap()
        openBackendSheet(in: app)
        let mux = segment(in: app, "GPU+ANE")
        XCTAssertTrue(mux.waitForExistence(timeout: 10) && mux.isSelected,
                      "Backend did not persist as GPU+ANE across reopen, "
                      + "selected was: \(selectedBackend(in: app) ?? "none")")

        // Back to CoreML/NE; it must persist too. A second round-trip, and a
        // courtesy for a manual launch — not a safety net (see the board-size
        // test above).
        segment(in: app, "CoreML/NE").tap()
        XCTAssertTrue(segment(in: app, "CoreML/NE").isSelected,
                      "Tapping CoreML/NE did not select it")
        app.buttons["Done"].tap()
        openBackendSheet(in: app)
        let coreml = segment(in: app, "CoreML/NE")
        XCTAssertTrue(coreml.waitForExistence(timeout: 10) && coreml.isSelected,
                      "Backend did not persist as CoreML/NE across reopen, "
                      + "selected was: \(selectedBackend(in: app) ?? "none")")
    }

    @MainActor
    func testSearchThreadsStepperIsPresent() throws {
        let app = makeApp()
        app.launch()

        let row = app.staticTexts[builtInTitle]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "Model row not found: \(builtInTitle)")
        row.tap()

        openBackendSheet(in: app)

        // The Search Threads control lives lower in the form; reveal it if needed.
        // Value/clamping/persistence behaviour is covered by the BackendSettings
        // unit tests; here we just verify the stepper is wired into the sheet and
        // reachable.
        let stepper = app.steppers["SearchThreadsStepper"]
        if !stepper.waitForExistence(timeout: 5) {
            app.swipeUp()
        }
        XCTAssertTrue(stepper.waitForExistence(timeout: 10),
                      "Search Threads stepper not found")
        XCTAssertTrue(stepper.isHittable, "Search Threads stepper is not hittable")
    }

    /// The Core ML Routing control must be present and enabled for the
    /// built-in network, which always has a source file on disk.
    ///
    /// Presence only, on purpose: tapping it reads a compute plan and, on a
    /// cache miss, converts the network first — tens of seconds of real work
    /// that would make this suite slow and flaky. The state machine behind
    /// the button is covered by CoreMLRoutingProbeTests, and the routing
    /// numbers themselves are meaningless on the Simulator anyway (no Neural
    /// Engine), which is why the section renders a caveat there.
    @MainActor
    func testCoreMLRoutingControlIsPresentForTheBuiltInNetwork() throws {
        let app = makeApp()
        app.launch()

        let row = app.staticTexts[builtInTitle]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "Model row not found: \(builtInTitle)")
        row.tap()

        openBackendSheet(in: app)

        let check = app.buttons["CoreMLRouting.checkButton"]
        XCTAssertTrue(check.waitForExistence(timeout: 10),
                      "Core ML routing check button not found")
        XCTAssertTrue(check.isEnabled, "Core ML routing check button should be enabled")

        // The built-in network is bundled, so the "not downloaded" state must
        // never appear for it.
        XCTAssertFalse(app.staticTexts["CoreMLRouting.unavailable"].exists,
                       "Built-in network must not report a missing source file")
    }

    // MARK: - Helpers

    /// From the model detail view, tap the gear button that presents
    /// BackendConfigSheet. (Navigation into the detail view happens once in the
    /// test body; the detail view persists across sheet dismissals.)
    @MainActor
    private func openBackendSheet(in app: XCUIApplication) {
        let gear = app.buttons["Backend Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "Backend Settings gear button not found")
        gear.tap()
    }

    @MainActor
    private func segment(in app: XCUIApplication, _ label: String) -> XCUIElement {
        app.buttons[label]
    }

    /// For diagnostics on failure: which board-size segment currently reads selected.
    @MainActor
    private func selectedBoardSize(in app: XCUIApplication) -> String? {
        boardSizes.first { app.buttons[$0].exists && app.buttons[$0].isSelected }
    }

    /// For diagnostics on failure: which backend segment currently reads selected.
    @MainActor
    private func selectedBackend(in app: XCUIApplication) -> String? {
        backends.first { app.buttons[$0].exists && app.buttons[$0].isSelected }
    }
}
