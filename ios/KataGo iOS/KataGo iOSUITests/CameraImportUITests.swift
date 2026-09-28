//
//  CameraImportUITests.swift
//  KataGo iOSUITests
//
//  UI tests for the camera-import loop. The Simulator has no camera, so
//  XCUITest cannot drive `BoardCameraView`'s AVFoundation capture. The DEBUG
//  `CameraCaptureUITestSupport` seam instead injects a `.camera`-sourced
//  `TopUIState.pendingPhotoImport` on launch — the same state the real capture
//  completion sets — so `PhotoImportSheet` presents and runs the real
//  recognition path. Two launch arguments feed either a recognizable board
//  (preview state) or a deterministic non-board image (failure state).
//
//  Assertions:
//    * a recognizable camera board reaches the preview and shows NO retry
//      button (retry is a recovery affordance, not a preview one);
//    * an unrecognizable camera image reaches a recovery state offering the
//      camera-specific "Retake" button; tapping it reopens the camera cover.
//
//  On the recovery state: `PhotoImportSheet.phaseAfterFailure` sends a photo
//  that decodes but cannot be recognized to `.adjustingGrid(.firstFailure)` —
//  "point at the board yourself" — and only an undecodable one to the terminal
//  `.failure`. The gray JPEG below decodes, so this test lands in the grid
//  phase. Both states render `PhotoImportSheet.retry` titled "Retake", so the
//  assertions hold either way; the distinction matters only when reading a
//  failure log.
//
//  The sheet is proved by `PhotoImportSheet.cancel`, which every phase
//  renders, never by its "Import from Photo" title. The grid phase drops the
//  title, and the gray JPEG decodes but cannot be recognized, so it ends in
//  that phase; how soon is not measured. A title that came and went before
//  the first look would read as a sheet that never appeared.
//
//  Determinism: the camera cover is driven by `--uitest-camera-permission-denied`
//  (see `CameraCaptureUITestSupport`). Without it the cover's observability
//  depends on the Simulator's TCC history — a device that has never been asked
//  puts up a SpringBoard alert and parks the cover in a phase that renders no
//  identified element — which made the reopen assertion fail on some runs and
//  pass on the next with no code change.
//

import XCTest

final class CameraImportUITests: PortraitUITestCase {

    private let cameraImportArg = "--uitest-camera-import"
    private let cameraImportFailingArg = "--uitest-camera-import-failing"
    private let deniedPermissionArg = "--uitest-camera-permission-denied"
    /// The sheet's Cancel: every phase renders it, so it proves the sheet up
    /// (or gone) whatever phase recognition has reached. See the header.
    private let sheetCancelID = "PhotoImportSheet.cancel"

    @MainActor
    func testCameraImportShowsPreviewWithRetakeAbsent() throws {
        let app = makeApp(cameraImportArg)
        app.launch()
        launchModel(app)

        // The sheet appears. The hook presents it about 600 ms after the
        // picker closes, without waiting for the engine; the long timeout is
        // headroom for a simulator busy with the engine's launch and Core ML
        // conversion, which run at the same time.
        let cancel = app.buttons[sheetCancelID].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 360),
                      "PhotoImportSheet ('\(sheetCancelID)') never appeared — the camera launch-arg hook did not reach the sheet")

        // Recognition succeeds → preview. The board element is preview-only.
        let board = app.descendants(matching: .any)["PhotoImportSheet.board"].firstMatch
        XCTAssertTrue(board.waitForExistence(timeout: 120),
                      "Board preview element ('PhotoImportSheet.board') not found — recognition did not reach the preview state")

        // The preview state has no retry affordance: retry belongs to the
        // recovery states only. Assert both the identifier and the
        // camera-specific label are absent.
        XCTAssertFalse(app.buttons["PhotoImportSheet.retry"].exists,
                       "Retry button must not appear in the preview state")
        XCTAssertFalse(app.buttons["Retake"].exists,
                       "'Retake' button must not appear in the preview state")

        // Cancel leaving proves the sheet left: every phase renders it, so it
        // cannot go by a phase change. The title can, because the grid phase
        // drops it with the sheet still up.
        cancel.tap()
        XCTAssertTrue(waitForGone(cancel, timeout: 10),
                      "PhotoImportSheet did not dismiss after Cancel")
    }

    @MainActor
    func testCameraImportFailureOffersRetakeAndReopensCamera() throws {
        let app = makeApp(cameraImportFailingArg, deniedPermissionArg)
        app.launch()
        launchModel(app)

        // The sheet appears, then recognition of the non-board image fails, so
        // the retry button (camera title "Retake", identifier
        // "PhotoImportSheet.retry") is shown — see the note on the recovery
        // state in the file header. The sheet is proved by its Cancel: this
        // image ends in the grid phase, which has no title.
        let sheetCancel = app.buttons[sheetCancelID].firstMatch
        XCTAssertTrue(sheetCancel.waitForExistence(timeout: 360),
                      "PhotoImportSheet ('\(sheetCancelID)') never appeared — the failing camera launch-arg hook did not reach the sheet")

        let retry = app.buttons["PhotoImportSheet.retry"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 120),
                      "Retry button ('PhotoImportSheet.retry') never appeared — the unrecognizable image did not reach a recovery state")
        XCTAssertEqual(retry.label, "Retake",
                       "Camera retry button should be titled 'Retake'")

        // Tapping Retake reopens the camera cover, and that handoff is the point
        // of this test: `onRetry` only nils the sheet and flags intent, and
        // GameSplitView presents the cover from the sheet's `onDismiss`. Setting
        // both in one transaction instead races and the cover never presents, so
        // this assertion is the guard on that wiring.
        //
        // The permission phase is pinned to `denied`, which renders
        // "BoardCamera.cancel" on the cover's first frame — so a plain wait is
        // enough and a timeout here means the cover really did not present.
        //
        // Tapped once it holds still: the gray image can fail while the sheet
        // is still sliding up, and a tap during the slide is lost.
        XCTAssertTrue(tapWhenSteady(retry, in: app, timeout: 10),
                      "Retake never settled on screen")

        // The sheet leaves first: GameSplitView presents the cover from its
        // onDismiss, so a sheet that stays up is a different fault from a
        // cover that never comes.
        XCTAssertTrue(waitForGone(sheetCancel, timeout: 10),
                      "PhotoImportSheet did not dismiss after Retake")

        // On screen, not merely present: Cancel is in the tree from the
        // cover's first frame, while the cover is still sliding up.
        let cancel = app.buttons["BoardCamera.cancel"].firstMatch
        XCTAssertTrue(waitForOnScreen(cancel, in: app, timeout: 15),
                      coverFailureMessage(app))

        // Cancel dismisses the cover.
        cancel.tap()
        XCTAssertTrue(waitForGone(cancel, timeout: 10),
                      "Camera cover did not dismiss after tapping Cancel")
    }

    // MARK: - Helpers

    /// Failure text for the reopen assertion, naming the state the app is
    /// actually in. Built only when the assertion fails (the message is an
    /// autoclosure), so the accessibility-tree dump costs nothing on the happy
    /// path.
    ///
    /// The two ways this can go wrong look identical from the outside, and
    /// telling them apart used to require a rerun:
    ///   * the cover presented but its permission phase never resolved — the
    ///     launch-arg pin did not take, and "BoardCamera.checking" is on screen;
    ///   * the cover never presented — the sheet-dismiss → cover-present handoff
    ///     in `GameSplitView` dropped, which is a product bug.
    @MainActor
    private func coverFailureMessage(_ app: XCUIApplication) -> String {
        let stuckChecking = app.descendants(matching: .any)["BoardCamera.checking"].exists
        let diagnosis = stuckChecking
            ? "the cover IS presented but is stuck in its permission-checking phase — the '\(deniedPermissionArg)' pin did not take effect"
            : "the cover never presented — suspect the sheet-dismiss to cover-present handoff in GameSplitView"
        return """
        Camera cover ('BoardCamera.cancel') did not appear after tapping Retake: \(diagnosis).
        Accessibility tree follows.
        \(app.debugDescription)
        """
    }

    /// Poll until `element` leaves the accessibility tree, or the timeout.
    @MainActor
    private func waitForGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while element.exists && Date() < deadline { usleep(150_000) }
        return !element.exists
    }
}
