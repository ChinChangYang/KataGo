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

final class BackendConfigSheetUITests: XCTestCase {

    private let builtInTitle = "Built-in KataGo Network"
    private let boardSizes = ["9x9", "13x13", "19x19", "37x37"]
    private let backends = ["MLX/GPU", "CoreML/NE", "GPU+ANE"]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testMaxBoardSizePickerDefaultsChangesAndPersists() throws {
        let app = XCUIApplication()
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

        // Default selection is 19x19.
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

        // Restore the 19x19 default so the test is idempotent: the choice is
        // persisted per-model in UserDefaults, which survives app reinstall in the
        // simulator's data container, so leaving it at 13x13 would make the
        // "defaults to 19x19" assertion fail on the next run.
        segment(in: app, "19x19").tap()
        XCTAssertTrue(segment(in: app, "19x19").isSelected,
                      "Failed to restore the 19x19 default at end of test")
    }

    @MainActor
    func testBackendPickerChangesAndPersists() throws {
        // NOTE: this does not assert an absolute "default" selection — the choice
        // is persisted per-model in UserDefaults (which survives in the simulator
        // data container), so a stale value from a prior run would poison such an
        // assertion. The default of `.mux` is covered by the BackendSettings unit
        // tests. Here we verify each choice is selectable and persists, and we
        // leave the model on the GPU+ANE default for idempotency.
        let app = XCUIApplication()
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

        // Select CoreML/NE; it must persist across a reopen (per-model UserDefaults).
        segment(in: app, "CoreML/NE").tap()
        XCTAssertTrue(segment(in: app, "CoreML/NE").isSelected,
                      "Tapping CoreML/NE did not select it")
        app.buttons["Done"].tap()
        openBackendSheet(in: app)
        let coreml = segment(in: app, "CoreML/NE")
        XCTAssertTrue(coreml.waitForExistence(timeout: 10) && coreml.isSelected,
                      "Backend did not persist as CoreML/NE across reopen, "
                      + "selected was: \(selectedBackend(in: app) ?? "none")")

        // Restore GPU+ANE (the intended default); it must persist too.
        segment(in: app, "GPU+ANE").tap()
        XCTAssertTrue(segment(in: app, "GPU+ANE").isSelected,
                      "Tapping GPU+ANE did not select it")
        app.buttons["Done"].tap()
        openBackendSheet(in: app)
        let mux = segment(in: app, "GPU+ANE")
        XCTAssertTrue(mux.waitForExistence(timeout: 10) && mux.isSelected,
                      "Backend did not persist as GPU+ANE across reopen, "
                      + "selected was: \(selectedBackend(in: app) ?? "none")")
    }

    @MainActor
    func testSearchThreadsStepperIsPresent() throws {
        let app = XCUIApplication()
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
