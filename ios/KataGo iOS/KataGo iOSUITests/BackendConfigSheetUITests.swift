//
//  BackendConfigSheetUITests.swift
//  KataGo iOSUITests
//
//  UI test for the "Max Board Size" picker in the per-model Backend Settings
//  sheet.
//
//  The app always runs a fixed GPU+ANE inference mux, so the sheet no longer
//  has a backend (MLX/GPU vs CoreML/NE) toggle — the Max Board Size picker is
//  shown immediately on opening the sheet. This is pure UI and never launches
//  the engine, so it is safe on the simulator. This verifies the picker renders
//  its options, defaults to 19x19, is changeable, and persists across a sheet
//  reopen. (Whether the engine actually tunes at the chosen size can only be
//  confirmed on a real device.)
//

import XCTest

final class BackendConfigSheetUITests: XCTestCase {

    private let builtInTitle = "Built-in KataGo Network"
    private let boardSizes = ["9x9", "13x13", "19x19", "37x37"]

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

        // All four "Max Board Size" segments must be present immediately (no
        // backend toggle to tap first).
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
}
