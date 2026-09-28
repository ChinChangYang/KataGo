//
//  PhotoImportUITests.swift
//  KataGo iOSUITests
//
//  End-to-end UI test for the photo-import feature (recognition → preview →
//  Import → created game). XCUITest cannot drive the system PhotosPicker (it
//  runs out-of-process), so the app auto-presents the shared `PhotoImportSheet`
//  with a bundled, wide-margin clear-board image (img_00009, a deterministic
//  synthetic 9x9 board) via the DEBUG "--uitest-photo-import" launch argument
//  (see PhotoImportUITestSupport). This drives the REAL in-app recognition
//  pipeline, the preview render, and the existing import seam — the same code
//  the "Photo Library…" completion would.
//
//  Assertions:
//    * the sheet appears (proved by its Cancel, which every phase renders;
//      the title does not survive the grid phase) and recognition succeeds
//      (the preview's Import button + board-size + confidence + next-to-play
//      picker all render);
//    * tap-to-correct edits and Reset move the stone counts; the
//      next-to-play default follows an edit, and the picker moves what
//      Import will send (read off Import's accessibility value; the PL[]
//      text itself is pinned by RecognizedBoardSgfTests);
//    * tapping Import puts the imported game on the board: the title turns
//      from the seeded game's name to "UITest Photo Board", E 9, the
//      correction left in place in the preview, is a black stone, and the
//      first stone played is White, the side picked, which the mixed setup
//      alone would not give.
//
//  Import de-dups by exact SGF, and this SGF is the same on every run, so
//  after the first run Import selects the record an earlier run created,
//  which is a correct import too. What proves THIS run's Import is the board
//  switching away from a known game, the one `--uitest-seed-gif-game` makes
//  the launch select. The flip side: whether Import names and inserts a NEW
//  record is checked only on a simulator that has never run this test.
//

import XCTest

final class PhotoImportUITests: PortraitUITestCase {

    private let photoImportArg = "--uitest-photo-import"
    /// The sheet's Cancel: every phase renders it, unlike the title, which
    /// the grid phase drops.
    private let sheetCancelID = "PhotoImportSheet.cancel"
    private let importedGameName = "UITest Photo Board"
    /// Makes the Export GIF test's game the newest record, so the launch
    /// selects it and the board behind the sheet is known (see UITestSeed).
    private let seedLaunchArg = "--uitest-seed-gif-game"
    private let seededGameName = "UITest GIF Game"

    @MainActor
    func testPhotoImportRecognizesAndCreatesGame() throws {
        let app = makeApp(photoImportArg, seedLaunchArg)
        app.launch()

        // DEBUG forces the model picker — launch the built-in network. Once the
        // picker has closed, the DEBUG hook auto-presents the photo-import
        // sheet with the bundled board; it does not wait for the engine.
        launchModel(app)

        // --- Sheet appears. The hook presents it about 600 ms after the picker
        // closes, without waiting for the engine; the long timeout is headroom
        // for a simulator busy with the engine's launch and Core ML
        // conversion, which run at the same time. ---
        let sheetCancel = app.buttons[sheetCancelID].firstMatch
        XCTAssertTrue(sheetCancel.waitForExistence(timeout: 360),
                      "PhotoImportSheet ('\(sheetCancelID)') never appeared — the launch-arg hook did not reach the sheet")

        // --- Recognition succeeds and the preview renders. The Import button is
        // preview-only (absent during the 'Reading the board…' spinner and the
        // failure state), so its appearance proves recognition produced a board. ---
        let importButton = app.buttons["Import"].firstMatch
        XCTAssertTrue(importButton.waitForExistence(timeout: 60),
                      "Preview 'Import' button never appeared — recognition did not reach the preview state")

        // Board size label (img_00009 is a 9x9 board). The Label renders "9 × 9".
        let sizeLabel = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "9 × 9")).firstMatch
        XCTAssertTrue(sizeLabel.waitForExistence(timeout: 10),
                      "Board-size label ('9 × 9') not shown in the preview")

        // Confidence readout is preview-only.
        let confidence = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Confidence")).firstMatch
        XCTAssertTrue(confidence.waitForExistence(timeout: 10),
                      "Confidence readout not shown in the preview")

        // --- Tap-to-correct: the board preview is one a11y element; intersections
        // are tapped via normalized offsets. For an n×n board with coordinates and
        // no pass row, squareLength = side/(n+2) and both board-line margins are
        // 2·squareLength, so intersection (col c, gridRow r) sits at
        // ((c+2)/(n+2), (r+2)/(n+2)). img_00009's top row (gridRow 0) is all
        // empty, so (col 4, row 0) = E9 is a safe empty target: cycle it
        // empty → black → white, then Reset back to the recognized position. ---
        let board = app.descendants(matching: .any)["PhotoImportSheet.board"].firstMatch
        XCTAssertTrue(board.waitForExistence(timeout: 10),
                      "Board preview element ('PhotoImportSheet.board') not found")
        XCTAssertEqual(board.frame.width, board.frame.height, accuracy: 2.0,
                       "Board preview element should be square (aspect-fit 1:1)")

        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Tap a point to correct")).firstMatch.exists,
                      "Editing hint caption not shown in the preview")

        // Recognized counts (img_00009 is 12 B + 12 W) before any edit; the Reset
        // button only exists while edits are pending.
        XCTAssertTrue(countLabel(app, "12 black stones").waitForExistence(timeout: 10),
                      "Recognized black-stone count not shown")
        XCTAssertTrue(countLabel(app, "12 white stones").exists,
                      "Recognized white-stone count not shown")
        let reset = app.buttons["PhotoImportSheet.reset"].firstMatch
        XCTAssertFalse(reset.exists, "Reset button must be hidden before any edit")

        // Empty → black.
        tapIntersection(board, col: 4, row: 0, size: 9)
        XCTAssertTrue(countLabel(app, "13 black stones").waitForExistence(timeout: 10),
                      "Tapping an empty intersection did not add a black stone")
        XCTAssertTrue(reset.waitForExistence(timeout: 10),
                      "Reset button did not appear after an edit")

        // Black → white (same intersection cycles).
        tapIntersection(board, col: 4, row: 0, size: 9)
        XCTAssertTrue(countLabel(app, "13 white stones").waitForExistence(timeout: 10),
                      "Tapping a black stone did not cycle it to white")
        XCTAssertTrue(countLabel(app, "12 black stones").exists,
                      "Black count did not return to 12 after cycling the edit to white")

        // Reset restores the recognized position and hides itself. Waited on
        // what Reset CHANGES: the edit is white now (12 B + 13 W), so black
        // already reads 12 and a wait on it would pass before Reset did
        // anything. Black is read once white has moved, since both counts
        // come from the same render.
        reset.tap()
        XCTAssertTrue(countLabel(app, "12 white stones").waitForExistence(timeout: 10),
                      "Reset did not restore the recognized white count")
        XCTAssertTrue(countLabel(app, "12 black stones").exists,
                      "Reset did not restore the recognized black count")
        XCTAssertTrue(waitForGone(reset, timeout: 10),
                      "Reset button should hide once edits are reverted")

        // Leave one edit in place so Import exercises the edited grid.
        tapIntersection(board, col: 4, row: 0, size: 9)
        XCTAssertTrue(countLabel(app, "13 black stones").waitForExistence(timeout: 10),
                      "Re-applied edit did not register before Import")

        // Next-to-play segmented picker: its caption (segmented style drops the
        // Picker's own label, so the sheet renders it explicitly) and Black /
        // White segments are present.
        XCTAssertTrue(app.staticTexts["Next to play"].waitForExistence(timeout: 10),
                      "'Next to play' caption not shown above the picker")
        // Scoped to the segmented control: the board behind the sheet stays
        // in the tree, and a tap must land on the picker.
        let blackSegment = app.segmentedControls.buttons["Black"].firstMatch
        XCTAssertTrue(blackSegment.waitForExistence(timeout: 10),
                      "'Black' segment of the next-to-play picker not found")
        let whiteSegment = app.segmentedControls.buttons["White"].firstMatch
        XCTAssertTrue(whiteSegment.exists,
                      "'White' segment of the next-to-play picker not found")

        // Import's value names the side it will put to move (PL[]). Until
        // the user picks, it is the default for the position as edited: the
        // edit made it 13 B / 12 W, Black one ahead, so White.
        let whiteToPlay = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "White to play"), object: importButton)
        XCTAssertEqual(XCTWaiter().wait(for: [whiteToPlay], timeout: 5), .completed,
                       "Next to play did not follow the edit to White for 13 B / 12 W")

        // The picker takes both ways. Proven on Import, not on the segment: a
        // tap moves the segmented control by itself, whether or not the side
        // Import sends follows. White last, so the import below exercises the
        // side the setup alone would not give (a mixed board gives Black).
        XCTAssertTrue(tapWhenSteady(blackSegment, in: app, timeout: 10),
                      "'Black' segment never settled on screen")
        let blackToPlay = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Black to play"), object: importButton)
        XCTAssertEqual(XCTWaiter().wait(for: [blackToPlay], timeout: 5), .completed,
                       "Tapping 'Black' did not change what Import will send")
        XCTAssertTrue(tapWhenSteady(whiteSegment, in: app, timeout: 10),
                      "'White' segment never settled on screen")
        let whiteToPlayAgain = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "White to play"), object: importButton)
        XCTAssertEqual(XCTWaiter().wait(for: [whiteToPlayAgain], timeout: 5), .completed,
                       "Tapping 'White' did not change what Import will send")

        let previewShot = XCTAttachment(screenshot: app.screenshot())
        previewShot.name = "PhotoImportPreview"
        previewShot.lifetime = .keepAlways
        add(previewShot)

        // --- Before Import: the board behind the sheet is the seeded game,
        // read in the tree the sheet covers. Without this, the checks after
        // Import could all hold with Import doing nothing: a launch can
        // select the "UITest Photo Board" an earlier run left. The title
        // (a Button, see GobanView) names the game, and E 9 is empty on the
        // seed at every move. ---
        let seededTitle = app.navigationBars.buttons[seededGameName]
        let importedTitle = app.navigationBars.buttons[importedGameName]
        XCTAssertTrue(seededTitle.waitForExistence(timeout: 10),
                      "The board behind the sheet is not the seeded '\(seededGameName)': the launch selected another game")
        XCTAssertFalse(importedTitle.exists,
                       "'\(importedGameName)' was on the board before Import, so nothing below could prove the import")
        let e9 = app.buttons["E 9"].firstMatch
        XCTAssertEqual((try? e9.snapshot())?.value as? String, "Empty",
                       "E 9 should be empty on the seeded board before Import")

        // The dismissal check below needs the preview's Cancel here first:
        // the wait above saw the spinner's.
        XCTAssertTrue(sheetCancel.exists,
                      "Preview 'Cancel' ('\(sheetCancelID)') not found beside Import")

        // --- Import: the synthesized SGF flows through the existing import
        // seam, which selects the game: a new record, or the identical one
        // an earlier run imported. ---
        importButton.tap()

        // Sheet dismisses: its Cancel, present in every phase, is gone.
        XCTAssertTrue(waitForGone(sheetCancel, timeout: 10),
                      "PhotoImportSheet did not dismiss after tapping Import")

        // --- The board now shows the imported game: the title names it... ---
        XCTAssertTrue(waitForOnScreen(importedTitle, in: app, timeout: 30),
                      "The board did not switch to '\(importedGameName)' after Import")
        // ...and the EDITED position: E 9 is the correction left in place
        // above, which the raw recognition does not have.
        let editedStone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Black stone"), object: e9)
        XCTAssertEqual(XCTWaiter().wait(for: [editedStone], timeout: 15), .completed,
                       "E 9 is not black on the imported board: the preview's edit was not imported")

        // ...and it starts with the side picked above: the first stone played
        // is White, where the setup alone would give Black. C 9 is empty in
        // the recognized position. The import opens locked, so the stone
        // starts a branch, and the record keeps the SGF a later run's import
        // de-dups against. With an engine running, a tap is refused until
        // it has acknowledged the switch, so the tap waits for that; the
        // stone's colour still comes from the record, not the engine. Once
        // E 9 is black the switch has already cleared Board.sync, so a stale
        // "inSync" from the seeded game cannot pass this wait.
        waitForBoardInSync(app)
        let c9 = app.buttons["C 9"].firstMatch
        XCTAssertEqual((try? c9.snapshot())?.value as? String, "Empty",
                       "C 9 should be empty on the imported board")
        XCTAssertTrue(tapWhenSteady(c9, in: app, timeout: 10), "C 9 never settled on screen")
        let firstStone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "White stone"), object: c9)
        XCTAssertEqual(XCTWaiter().wait(for: [firstStone], timeout: 15), .completed,
                       "The first stone on the imported board is not White: the side picked did not reach the game")

        // --- The library lists it. Not the proof: earlier runs left rows
        // with this name. On screen so the screenshot below shows it. ---
        showGamesList(app)
        let cell = app.staticTexts[importedGameName].firstMatch
        XCTAssertTrue(reveal(cell, in: app, by: { app.swipeUp() }),
                      "Imported game '\(importedGameName)' never came on screen in the library")

        let libraryShot = XCTAttachment(screenshot: app.screenshot())
        libraryShot.name = "PhotoImportCreatedGame"
        libraryShot.lifetime = .keepAlways
        add(libraryShot)
    }

    // MARK: - Helpers

    /// The stone-count items are single a11y elements (not staticTexts) labeled
    /// "N black stones" / "N white stones", so match any element by label.
    @MainActor
    private func countLabel(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// Tap intersection (col, gridRow — row 0 = top) of the square board
    /// preview via a normalized offset: with coordinates shown and no pass row,
    /// squareLength = side/(size+2) and both board-line margins are
    /// 2·squareLength, so the point sits at ((col+2)/(size+2), (row+2)/(size+2)).
    @MainActor
    private func tapIntersection(_ board: XCUIElement, col: Int, row: Int, size: Int) {
        let denominator = CGFloat(size + 2)
        let offset = CGVector(dx: (CGFloat(col) + 2) / denominator,
                              dy: (CGFloat(row) + 2) / denominator)
        board.coordinate(withNormalizedOffset: offset).tap()
    }

    /// Poll until `element` leaves the accessibility tree, or the timeout.
    @MainActor
    private func waitForGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while element.exists && Date() < deadline { usleep(150_000) }
        return !element.exists
    }
}
