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
//  the preview, from which Import puts the game on the board (proved against
//  a seeded game behind the sheet, since import de-dups by exact SGF; see
//  PhotoImportUITests). Also covers Adjust Grid →
//  Back from a successful preview (camera seam, which additionally shows
//  Retake in the grid phase).
//
//  Drag geometry: BoardQuadView constrains itself to the image's aspect ratio,
//  so the "BoardQuadView.gridArea" element frame ≡ the displayed image and
//  normalized offsets address image fractions directly. Unlike the old crop
//  rect, the quad starts INSET by 10%, so its corners sit at 0.1 and 0.9 of
//  the element rather than at its edges — a drag must start there to grab one.
//
//  The recognition this drives is the fallback path, not the user-quad fit.
//  The drags box the board roughly, around its edge rather than on its corner
//  intersections, and the size picker stays at its default 19. The recognizer
//  accepts a user's quad at any confidence, so that fit "succeeds" and reads
//  nonsense: a 19x19 at about 1% confidence. Below the automatic tier the
//  sheet also runs automatic detection inside the quad's bounding box, which
//  finds the 9x9 and wins. That fallback is exactly what the crop phase used
//  to do, and pinning it here is the point — it is the behaviour that must not
//  regress when a user draws a rough box rather than placing corners. The
//  preview's size and stone counts are what pin it: until 2026-09-28 the
//  sheet imported the fit's nonsense, and this test still passed, because it
//  only looked for a library row named "UITest Crop Board", which any import
//  supplies whatever it recognized.
//

import XCTest

// This class is where the portrait pin was first introduced (2026-08-03); it
// now inherits it from `PortraitUITestCase` along with everything else. The
// stake here is unchanged and worth restating: every size assertion below
// measures a live frame, and in landscape the import sheet reaches its 560 pt
// cap and the photo goes height-bound — which these assertions would report as
// a `maxWidth` cap or a `layoutPriority(-1)` regression that does not exist.
final class PhotoImportGridUITests: PortraitUITestCase {

    /// The sheet's Cancel: every phase renders it. The title is no proof of
    /// the sheet, because the grid phase this class drives drops it.
    private let sheetCancelID = "PhotoImportSheet.cancel"
    private let importedGameName = "UITest Crop Board"
    /// Makes the Export GIF test's 19x19 game the newest record, so the
    /// launch selects it and the board behind the sheet is known (see
    /// UITestSeed).
    private let seedLaunchArg = "--uitest-seed-gif-game"
    private let seededGameName = "UITest GIF Game"

    @MainActor
    func testGridRecoveryImportsBoardAfterCornerDrags() throws {
        let app = makeApp("--uitest-crop-import", seedLaunchArg)
        app.launch()
        launchModel(app)

        let sheetCancel = app.buttons[sheetCancelID].firstMatch
        XCTAssertTrue(sheetCancel.waitForExistence(timeout: 360),
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
        // The automatic look inside the quad read the bundled 9x9 (img_00009,
        // 12 B + 12 W). The quad's own fit at the picker's default size reads
        // a 19x19 of nonsense instead (see the header); imported, it would
        // also leave T 19 on the board below.
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "9 × 9")).firstMatch.waitForExistence(timeout: 10),
                      "The recognized board is not 9 × 9: the sheet kept the rough quad's own fit")
        for count in ["12 black stones", "12 white stones"] {
            XCTAssertTrue(app.descendants(matching: .any)
                            .matching(NSPredicate(format: "label == %@", count)).firstMatch.exists,
                          "The preview does not show \(count): the 9x9 was misread")
        }

        // Before Import: the board behind the sheet is the seeded 19x19 game.
        // Import de-dups by exact SGF, so the game it selects may be one an
        // earlier run left; the proof is the board switching to it.
        let seededTitle = app.navigationBars.buttons[seededGameName]
        let importedTitle = app.navigationBars.buttons[importedGameName]
        XCTAssertTrue(seededTitle.waitForExistence(timeout: 10),
                      "The board behind the sheet is not the seeded '\(seededGameName)': the launch selected another game")
        XCTAssertFalse(importedTitle.exists,
                       "'\(importedGameName)' was on the board before Import, so nothing below could prove the import")
        let t19 = app.buttons["T 19"]
        XCTAssertTrue(t19.exists, "The seeded 19x19 board does not expose T 19 before Import")
        // The dismissal check below needs the preview's Cancel here first:
        // the wait above saw the spinner's.
        XCTAssertTrue(sheetCancel.exists,
                      "Preview 'Cancel' ('\(sheetCancelID)') not found beside Import")

        importButton.tap()

        // Its Cancel is gone: every phase renders it, so unlike the title it
        // cannot leave by the sheet falling back to the grid phase.
        XCTAssertTrue(sheetCancel.waitForNonExistence(timeout: 10),
                      "PhotoImportSheet did not dismiss after tapping Import")
        // The board's title (a Button, see GobanView) now names the import...
        XCTAssertTrue(waitForOnScreen(importedTitle, in: app, timeout: 30),
                      "The board did not switch to '\(importedGameName)' after Import")
        // ...and the board itself reloaded as the recognized 9x9: the
        // seed's far corner is gone, and its intersections are still there.
        XCTAssertTrue(t19.waitForNonExistence(timeout: 10),
                      "T 19 is still on the board: the imported 9x9 position did not load")
        XCTAssertTrue(app.buttons["J 9"].exists,
                      "No J 9 on the board: its intersections left instead of shrinking to 9x9")

        // The library lists it. Not the proof: earlier runs left rows with
        // this name.
        showGamesList(app)
        let cell = app.staticTexts[importedGameName].firstMatch
        XCTAssertTrue(reveal(cell, in: app, by: { app.swipeUp() }),
                      "Imported game '\(importedGameName)' never came on screen in the library")
    }

    @MainActor
    func testAdjustGridFromPreviewAndBackPreservesPreview() throws {
        let app = makeApp("--uitest-camera-import") // recognizable board → preview
        app.launch()
        launchModel(app)

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
        let app = makeApp("--uitest-camera-import", // recognizable board → preview
                          "-UIPreferredContentSizeCategoryName",
                          "UICTContentSizeCategoryAccessibilityXXXL")
        app.launch()
        launchModel(app)

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

    @MainActor
    private func drag(_ element: XCUIElement, from: CGVector, to: CGVector) {
        let start = element.coordinate(withNormalizedOffset: from)
        let end = element.coordinate(withNormalizedOffset: to)
        start.press(forDuration: 0.15, thenDragTo: end)
    }
}
