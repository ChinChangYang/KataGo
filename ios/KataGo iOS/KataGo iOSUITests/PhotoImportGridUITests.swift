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
        // Every size assertion below measures a live frame, so the orientation
        // has to be known rather than inherited. The simulator remembers it
        // across processes and this class runs after two rotators — the board
        // accessibility test and the launch-configuration sweep — so pin it
        // here rather than trusting them to clean up. In landscape the sheet
        // reaches its 560 pt cap and the photo goes height-bound, which these
        // assertions would otherwise report as a `maxWidth` cap or a
        // `layoutPriority(-1)` regression that does not exist.
        XCUIDevice.shared.orientation = .portrait
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
        let sizePicker = app.segmentedControls["PhotoImportSheet.boardSizePicker"]
        XCTAssertTrue(sizePicker.exists,
                      "Board size picker not found in the grid phase")

        // Bring the quad in to ~[0.22,0.78]² around the central board. The quad
        // starts inset at 0.1/0.9, so the drags begin there.
        let gridArea = app.descendants(matching: .any)["BoardQuadView.gridArea"].firstMatch
        XCTAssertTrue(gridArea.waitForExistence(timeout: 10), "Grid area not found")

        // The photo must bleed past the chrome's margins: the picker sits in
        // the padded lane, the photo reaches the sheet's edges, so the photo is
        // ~48 pt (2 × 24) wider. Comparing the two elements rather than the
        // window keeps this device- and orientation-independent.
        //
        // This holds only because the composed test image is 4:3 landscape, so
        // WIDTH is what binds the aspect fit. A portrait fixture would be
        // height-bound and this assertion would not apply.
        XCTAssertGreaterThan(gridArea.frame.width, sizePicker.frame.width + 40,
                             "The grid photo is not using the full sheet width — a maxWidth/maxHeight cap on BoardQuadView has come back")
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
                      "Camera-sourced grid phase should offer Retake")

        back.tap()
        XCTAssertTrue(board.waitForExistence(timeout: 10),
                      "Preview did not return after Back from the grid phase")
    }

    /// Regression guard for the grid photo collapsing at large accessibility
    /// text sizes. `BoardQuadView`'s `.frame(maxWidth: .infinity, maxHeight:
    /// .infinity)` in `adjustingGrid` once carried a `.layoutPriority(-1)`
    /// that looked harmless at default text size but, at Accessibility XXXL
    /// on an iPhone 17, made the photo yield first and completely: measured
    /// 54.67x41 pt (vs. 288x216 pt without it) — the corner-drag editor was
    /// unusable. That regression passed 8 task reviews, a whole-branch
    /// review, 1317 unit tests, and 3 UI suites; only hand-measurement caught
    /// it. This test pins the height so a reappearing `.layoutPriority(-1)`
    /// (or an equivalent regression) fails automatically.
    ///
    /// Reaches the grid phase via the fast `.fromPreview` route (like
    /// `testAdjustGridFromPreviewAndBackPreservesPreview`), not the slow
    /// full-frame-failure route, so it costs seconds, not ~100 s.
    @MainActor
    func testGridPhotoStaysReadableAtAccessibilityXXXL() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--uitest-camera-import", // recognizable board → preview
                                "-UIPreferredContentSizeCategoryName",
                                "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        launchBuiltInEngine(app)

        let board = app.descendants(matching: .any)["PhotoImportSheet.board"].firstMatch
        XCTAssertTrue(board.waitForExistence(timeout: 360), "Preview board never appeared")

        let adjust = app.buttons["PhotoImportSheet.adjustGrid"].firstMatch
        XCTAssertTrue(adjust.waitForExistence(timeout: 10), "'Adjust Grid' button not found in preview")
        adjust.tap()

        let gridArea = app.descendants(matching: .any)["BoardQuadView.gridArea"].firstMatch
        XCTAssertTrue(gridArea.waitForExistence(timeout: 10), "Grid area not found")

        // Healthy (HEAD, no .layoutPriority(-1)): measured 288.0x216.0 pt on
        // this route, at this text size, on an iPhone 17. 150 pt is ~69% of
        // that 216 pt height — far above the regressed 41 pt (measured with
        // .layoutPriority(-1) restored) and comfortably below the healthy
        // value, so it catches the regression without flaking on small
        // layout drift.
        XCTAssertGreaterThan(gridArea.frame.height, 150,
                             "Grid photo height \(gridArea.frame.height) pt is at/near the regressed " +
                             "54.67x41 pt collapse — check for a reintroduced .layoutPriority(-1) on " +
                             "BoardQuadView in PhotoImportSheet.adjustingGrid")
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
