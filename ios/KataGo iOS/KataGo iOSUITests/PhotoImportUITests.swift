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
//    * the sheet appears ("Import from Photo") and recognition succeeds
//      (the preview's Import button + board-size + confidence + next-to-play
//      picker all render);
//    * tapping Import creates and selects a new game — the library gains a
//      "UITest Photo Board" entry (proof the recognized position was imported).
//

import XCTest

final class PhotoImportUITests: XCTestCase {

    private let builtInTitle = "Built-in KataGo Network"
    private let photoImportArg = "--uitest-photo-import"
    private let sheetTitle = "Import from Photo"
    private let importedGameName = "UITest Photo Board"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPhotoImportRecognizesAndCreatesGame() throws {
        let app = XCUIApplication()
        app.launchArguments += [photoImportArg]
        app.launch()

        // DEBUG forces the model picker — launch the built-in network. Once the
        // engine is up GameSplitView mounts and the DEBUG hook auto-presents the
        // photo-import sheet with the bundled board.
        let row = app.staticTexts[builtInTitle]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "Model picker row '\(builtInTitle)' not found")
        row.tap()
        let play = app.buttons["ModelDetailView.downloadPlayButton"]
        XCTAssertTrue(play.waitForExistence(timeout: 15), "Play button not found")
        play.tap()

        // --- Sheet appears. Long timeout: engine launch + on-the-fly CoreML
        // conversion is slow on the simulator's software path. ---
        let title = app.staticTexts[sheetTitle]
        XCTAssertTrue(title.waitForExistence(timeout: 360),
                      "PhotoImportSheet ('\(sheetTitle)') never appeared — the launch-arg hook did not reach the sheet")

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

        // Next-to-play segmented picker: its caption (segmented style drops the
        // Picker's own label, so the sheet renders it explicitly) and Black /
        // White segments are present.
        XCTAssertTrue(app.staticTexts["Next to play"].waitForExistence(timeout: 10),
                      "'Next to play' caption not shown above the picker")
        XCTAssertTrue(app.buttons["Black"].firstMatch.waitForExistence(timeout: 10),
                      "'Black' segment of the next-to-play picker not found")
        let whiteSegment = app.buttons["White"].firstMatch
        XCTAssertTrue(whiteSegment.exists,
                      "'White' segment of the next-to-play picker not found")

        // Toggle to White before importing so the non-default next-to-play path
        // (PL[W] in the synthesized SGF) stays exercised by the suite.
        whiteSegment.tap()

        let previewShot = XCTAttachment(screenshot: app.screenshot())
        previewShot.name = "PhotoImportPreview"
        previewShot.lifetime = .keepAlways
        add(previewShot)

        // --- Import: the synthesized SGF flows through the existing import seam,
        // creating and selecting a new game named "UITest Photo Board". ---
        importButton.tap()

        // Sheet dismisses.
        XCTAssertTrue(waitForGone(title, timeout: 10),
                      "PhotoImportSheet did not dismiss after tapping Import")

        // --- A new game exists + is selected: reveal the Games list and find it.
        // Leading nav-bar button opens the sidebar (same as GifExportUITests). ---
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.waitForExistence(timeout: 10) { back.tap() }

        let cell = app.staticTexts[importedGameName].firstMatch
        reveal(app, cell, by: { app.swipeUp() })
        XCTAssertTrue(cell.waitForExistence(timeout: 15),
                      "Imported game '\(importedGameName)' not found in the library — the recognized board was not imported")

        let libraryShot = XCTAttachment(screenshot: app.screenshot())
        libraryShot.name = "PhotoImportCreatedGame"
        libraryShot.lifetime = .keepAlways
        add(libraryShot)
    }

    // MARK: - Helpers

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

    /// Poll until `element` leaves the accessibility tree, or the timeout.
    @MainActor
    private func waitForGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while element.exists && Date() < deadline { usleep(150_000) }
        return !element.exists
    }
}
