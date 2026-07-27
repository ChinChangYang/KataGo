//
//  PhotoImportGridUITests.swift
//  KataGo iOSUITests
//
//  End-to-end grid-recovery flow. Was PhotoImportCropUITests; the crop rect it
//  drove was replaced by a draggable board-grid quad, so the identifiers and
//  the drag geometry both moved.
//
//  The DEBUG --uitest-crop-import seam feeds a composed image whose full frame
//  defeats detection but whose central [0.25,0.75]² is the bundled wide-margin
//  9x9 board. The sheet must land in the grid phase (not a dead-end failure),
//  corner drags must bring the quad onto the board, and Recognize must reach
//  the preview, from which Import creates the game. Also covers Adjust Grid →
//  Back from a successful preview (camera seam, which additionally shows
//  Retake in the grid phase).
//
//  Drag geometry: BoardQuadView constrains itself to the image's aspect ratio,
//  so the "BoardQuadView.gridArea" element frame ≡ the displayed image and
//  normalized offsets address image fractions directly. Unlike the old crop
//  rect, the quad starts INSET by 10%, so its corners sit at 0.1 and 0.9 of
//  the element rather than at its edges — a drag must start there to grab one.
//
//  The recognition this drives is the fallback path, not the user-quad fit:
//  dragging a quad to the board's outer edge by touch cannot land on the
//  actual corner intersections accurately enough to fit a lattice, so the
//  user-quad attempt fails and the sheet retries automatic detection inside
//  the quad's bounding box. That fallback is exactly what the crop phase used
//  to do, and pinning it here is the point — it is the behaviour that must not
//  regress when a user draws a rough box rather than placing corners.
//

import XCTest

final class PhotoImportGridUITests: XCTestCase {

    private let builtInTitle = "Built-in KataGo Network"
    private let sheetTitle = "Import from Photo"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testGridRecoveryImportsBoardAfterCornerDrags() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--uitest-crop-import"]
        app.launch()
        launchBuiltInEngine(app)

        let title = app.staticTexts[sheetTitle]
        XCTAssertTrue(title.waitForExistence(timeout: 360),
                      "PhotoImportSheet never appeared — the crop-import launch-arg hook did not fire")

        // Full-frame recognition fails on the composed image → grid phase.
        // Long timeout: full-frame abstention on the composed canvas takes
        // ~71 s under the Debug-built recognizer (measured headlessly with
        // gobanrecog-cli), plus simulator overhead.
        let recognize = app.buttons["PhotoImportSheet.recognize"].firstMatch
        XCTAssertTrue(recognize.waitForExistence(timeout: 300),
                      "Grid phase ('PhotoImportSheet.recognize') never appeared — full-frame recognition did not fail into the grid UI")
        // A file/library-sourced import offers no camera retry.
        XCTAssertFalse(app.buttons["PhotoImportSheet.retry"].exists,
                       "Retake/retry must not appear for a file-sourced import")
        // The size picker is part of the phase — the overlay needs a concrete
        // board size to draw, so there is no "Auto".
        XCTAssertTrue(app.segmentedControls["PhotoImportSheet.boardSizePicker"].exists,
                      "Board size picker not found in the grid phase")

        // Bring the quad in to ~[0.22,0.78]² around the central board. The quad
        // starts inset at 0.1/0.9, so the drags begin there.
        let gridArea = app.descendants(matching: .any)["BoardQuadView.gridArea"].firstMatch
        XCTAssertTrue(gridArea.waitForExistence(timeout: 10), "Grid area not found")
        drag(gridArea, from: CGVector(dx: 0.10, dy: 0.10), to: CGVector(dx: 0.22, dy: 0.22))
        drag(gridArea, from: CGVector(dx: 0.90, dy: 0.90), to: CGVector(dx: 0.78, dy: 0.78))
        drag(gridArea, from: CGVector(dx: 0.90, dy: 0.10), to: CGVector(dx: 0.78, dy: 0.22))
        drag(gridArea, from: CGVector(dx: 0.10, dy: 0.90), to: CGVector(dx: 0.22, dy: 0.78))

        recognize.tap()

        let board = app.descendants(matching: .any)["PhotoImportSheet.board"].firstMatch
        XCTAssertTrue(board.waitForExistence(timeout: 120),
                      "Preview never appeared after Recognize — neither the user quad nor the bounding-box fallback recognized the board")

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
    func testAdjustGridFromPreviewAndBackPreservesPreview() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--uitest-camera-import"] // recognizable board → preview
        app.launch()
        launchBuiltInEngine(app)

        let board = app.descendants(matching: .any)["PhotoImportSheet.board"].firstMatch
        XCTAssertTrue(board.waitForExistence(timeout: 360), "Preview board never appeared")

        let adjust = app.buttons["PhotoImportSheet.adjustGrid"].firstMatch
        XCTAssertTrue(adjust.waitForExistence(timeout: 10), "'Adjust Grid' button not found in preview")
        adjust.tap()

        // Grid phase from a successful preview offers Back and, for a camera
        // source, Retake.
        let back = app.buttons["PhotoImportSheet.gridBack"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "'Back' button not found in grid phase")
        XCTAssertTrue(app.buttons["PhotoImportSheet.retry"].exists,
                      "Camera-sourced grid phase should offer Retake Photo")

        back.tap()
        XCTAssertTrue(board.waitForExistence(timeout: 10),
                      "Preview did not return after Back from the grid phase")
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
