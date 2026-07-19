//
//  PhotoImportCropUITests.swift
//  KataGo iOSUITests
//
//  End-to-end crop-recovery flow. The DEBUG --uitest-crop-import seam feeds a
//  composed image whose full frame defeats detection but whose central
//  [0.25,0.75]² is the bundled wide-margin 9x9 board. The sheet must land in
//  the crop phase (not a dead-end failure), corner drags must tighten the
//  rect around the board, and Recognize must reach the preview, from which
//  Import creates the game. Also covers Adjust Crop → Back from a successful
//  preview (camera seam, which additionally shows Retake in the crop phase).
//
//  Drag geometry: BoardCropView constrains itself to the image's aspect
//  ratio, so the "BoardCropView.cropArea" element frame ≡ the displayed
//  image and normalized offsets address image fractions directly. The crop
//  rect starts full-frame, so its corners sit at the element's corners; a
//  drag from (0.02,0.02) to (0.22,0.22) grabs the top-left corner (7–8pt
//  from it on a ~340pt-wide sheet, inside the 24pt grab radius) and lands
//  the crop edge at ~0.20 — outside the board's 0.25 with margin.
//

import XCTest

final class PhotoImportCropUITests: XCTestCase {

    private let builtInTitle = "Built-in KataGo Network"
    private let sheetTitle = "Import from Photo"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCropRecoveryImportsBoardAfterCornerDrags() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--uitest-crop-import"]
        app.launch()
        launchBuiltInEngine(app)

        let title = app.staticTexts[sheetTitle]
        XCTAssertTrue(title.waitForExistence(timeout: 360),
                      "PhotoImportSheet never appeared — the crop-import launch-arg hook did not fire")

        // Full-frame recognition fails on the composed image → crop phase.
        // Long timeout: full-frame abstention on the composed canvas takes
        // ~71 s under the Debug-built recognizer (measured headlessly with
        // gobanrecog-cli), plus simulator overhead.
        let recognize = app.buttons["PhotoImportSheet.recognize"].firstMatch
        XCTAssertTrue(recognize.waitForExistence(timeout: 300),
                      "Crop phase ('PhotoImportSheet.recognize') never appeared — full-frame recognition did not fail into the crop UI")
        // A file/library-sourced import offers no camera retry.
        XCTAssertFalse(app.buttons["PhotoImportSheet.retry"].exists,
                       "Retake/retry must not appear for a file-sourced import")

        // Tighten the crop to ~[0.20,0.80]² around the central board.
        let cropArea = app.descendants(matching: .any)["BoardCropView.cropArea"].firstMatch
        XCTAssertTrue(cropArea.waitForExistence(timeout: 10), "Crop area not found")
        drag(cropArea, from: CGVector(dx: 0.02, dy: 0.02), to: CGVector(dx: 0.22, dy: 0.22))
        drag(cropArea, from: CGVector(dx: 0.98, dy: 0.98), to: CGVector(dx: 0.78, dy: 0.78))

        recognize.tap()

        let board = app.descendants(matching: .any)["PhotoImportSheet.board"].firstMatch
        XCTAssertTrue(board.waitForExistence(timeout: 120),
                      "Preview never appeared after Recognize — the cropped region did not recognize")

        let importButton = app.buttons["Import"].firstMatch
        XCTAssertTrue(importButton.waitForExistence(timeout: 10), "Import button not found")
        importButton.tap()

        // Import lands on the created game's board, whose toolbar title is a
        // Button (voice-actionable rename) — not a static text — so reveal the
        // Games list and assert the library cell, matching PhotoImportUITests'
        // post-import pattern.
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.waitForExistence(timeout: 10) { back.tap() }

        let cell = app.staticTexts["UITest Crop Board"].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 30),
                      "Imported game 'UITest Crop Board' not found in the library")
    }

    @MainActor
    func testAdjustCropFromPreviewAndBackPreservesPreview() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--uitest-camera-import"] // recognizable board → preview
        app.launch()
        launchBuiltInEngine(app)

        let board = app.descendants(matching: .any)["PhotoImportSheet.board"].firstMatch
        XCTAssertTrue(board.waitForExistence(timeout: 360), "Preview board never appeared")

        let adjust = app.buttons["PhotoImportSheet.adjustCrop"].firstMatch
        XCTAssertTrue(adjust.waitForExistence(timeout: 10), "'Adjust Crop' button not found in preview")
        adjust.tap()

        // Crop phase from a successful preview offers Back and, for a
        // camera source, Retake.
        let back = app.buttons["PhotoImportSheet.cropBack"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "'Back' button not found in crop phase")
        XCTAssertTrue(app.buttons["PhotoImportSheet.retry"].exists,
                      "Camera-sourced crop phase should offer Retake Photo")

        back.tap()
        XCTAssertTrue(board.waitForExistence(timeout: 10),
                      "Preview did not return after Back from the crop phase")
    }

    // MARK: - Helpers

    /// DEBUG forces the model picker — launch the built-in network. Once the
    /// engine is up, GameSplitView mounts and the DEBUG hook auto-presents
    /// the photo-import sheet.
    @MainActor
    private func launchBuiltInEngine(_ app: XCUIApplication) {
        let row = app.staticTexts[builtInTitle]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "Model picker row '\(builtInTitle)' not found")
        row.tap()
        let play = app.buttons["ModelDetailView.downloadPlayButton"]
        XCTAssertTrue(play.waitForExistence(timeout: 15), "Play button not found")
        play.tap()
    }

    @MainActor
    private func drag(_ element: XCUIElement, from: CGVector, to: CGVector) {
        let start = element.coordinate(withNormalizedOffset: from)
        let end = element.coordinate(withNormalizedOffset: to)
        start.press(forDuration: 0.15, thenDragTo: end)
    }
}
