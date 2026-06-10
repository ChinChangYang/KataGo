//
//  BackendConfigSheetUITests.swift
//  KataGo iOSUITests
//
//  UI test for the MLX/GPU "Max Board Size" picker (mirrors the CoreML/NE
//  "Compiled Board Size" picker).
//
//  NOTE: On the iOS Simulator the app force-pins the backend to CoreML/NE —
//  MLX's GPU path crashes the simulator's Metal layer (see BackendChoice.swift)
//  — so the MLX section is only reachable by tapping the Backend segmented
//  control over to "MLX/GPU" inside the config sheet. That is pure UI and never
//  launches the engine, so it is safe on the simulator. This verifies the
//  picker renders its options, defaults to 19x19, is changeable, and persists
//  across a sheet reopen. (Whether MLX actually tunes at the chosen size can
//  only be confirmed on a real device.)
//

import XCTest

final class BackendConfigSheetUITests: XCTestCase {

    private let builtInTitle = "Built-in KataGo Network"
    private let boardSizes = ["9x9", "13x13", "19x19", "37x37"]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testMLXMaxBoardSizePickerDefaultsChangesAndPersists() throws {
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
        selectMLXBackend(in: app)

        // All four "Max Board Size" segments must be present for MLX/GPU.
        for size in boardSizes {
            XCTAssertTrue(segment(in: app, size).waitForExistence(timeout: 10),
                          "Max Board Size option '\(size)' not found for MLX/GPU")
        }

        // Default selection is 19x19.
        XCTAssertTrue(segment(in: app, "19x19").isSelected,
                      "MLX/GPU max board size should default to 19x19, "
                      + "selected was: \(selectedBoardSize(in: app) ?? "none")")

        // Change to 13x13 and confirm the selection moves there.
        segment(in: app, "13x13").tap()
        XCTAssertTrue(segment(in: app, "13x13").isSelected,
                      "Tapping 13x13 did not select it")

        // Dismiss and reopen; the MLX choice must persist (per-model UserDefaults).
        app.buttons["Done"].tap()
        openBackendSheet(in: app)
        selectMLXBackend(in: app)
        let thirteen = segment(in: app, "13x13")
        XCTAssertTrue(thirteen.waitForExistence(timeout: 10) && thirteen.isSelected,
                      "MLX/GPU max board size did not persist as 13x13 across reopen, "
                      + "selected was: \(selectedBoardSize(in: app) ?? "none")")
    }

    // MARK: - Helpers

    /// From the model detail view, tap the gear button that presents
    /// BackendConfigSheet. (Navigation into the detail view happens once in the
    /// test body; the detail view persists across sheet dismissals.)
    private func openBackendSheet(in app: XCUIApplication) {
        let gear = app.buttons["Backend Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "Backend Settings gear button not found")
        gear.tap()
    }

    /// Tap the "MLX/GPU" segment of the Backend picker to reveal the MLX-only
    /// "Max Board Size" section. (UI only — no engine launch.)
    private func selectMLXBackend(in app: XCUIApplication) {
        let mlx = app.buttons["MLX/GPU"]
        XCTAssertTrue(mlx.waitForExistence(timeout: 10), "MLX/GPU backend segment not found")
        mlx.tap()
    }

    private func segment(in app: XCUIApplication, _ label: String) -> XCUIElement {
        app.buttons[label]
    }

    /// For diagnostics on failure: which board-size segment currently reads selected.
    private func selectedBoardSize(in app: XCUIApplication) -> String? {
        boardSizes.first { app.buttons[$0].exists && app.buttons[$0].isSelected }
    }
}
