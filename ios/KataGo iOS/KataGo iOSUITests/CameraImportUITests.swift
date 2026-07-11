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
//      button (retry is a failure-state affordance);
//    * an unrecognizable camera image reaches the failure state, which offers
//      the camera-specific "Retake Photo" button; tapping it reopens the camera
//      cover (proven by the stable `BoardCamera.cancel` element, present in both
//      the Simulator's denied phase and its preview scaffold).
//

import XCTest

final class CameraImportUITests: XCTestCase {

    private let builtInTitle = "Built-in KataGo Network"
    private let cameraImportArg = "--uitest-camera-import"
    private let cameraImportFailingArg = "--uitest-camera-import-failing"
    private let sheetTitle = "Import from Photo"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCameraImportShowsPreviewWithRetakeAbsent() throws {
        let app = XCUIApplication()
        app.launchArguments += [cameraImportArg]
        app.launch()
        launchBuiltInEngine(app)

        // The sheet appears. Long timeout: engine launch + on-the-fly CoreML
        // conversion is slow on the simulator's software path.
        let title = app.staticTexts[sheetTitle]
        XCTAssertTrue(title.waitForExistence(timeout: 360),
                      "PhotoImportSheet ('\(sheetTitle)') never appeared — the camera launch-arg hook did not reach the sheet")

        // Recognition succeeds → preview. The board element is preview-only.
        let board = app.descendants(matching: .any)["PhotoImportSheet.board"].firstMatch
        XCTAssertTrue(board.waitForExistence(timeout: 120),
                      "Board preview element ('PhotoImportSheet.board') not found — recognition did not reach the preview state")

        // The preview state has no retry affordance: retry is a failure-state
        // button only. Assert both the identifier and the camera-specific label
        // are absent.
        XCTAssertFalse(app.buttons["PhotoImportSheet.retry"].exists,
                       "Retry button must not appear in the preview state")
        XCTAssertFalse(app.buttons["Retake Photo"].exists,
                       "'Retake Photo' button must not appear in the preview state")

        let cancel = app.buttons["PhotoImportSheet.cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "Preview 'Cancel' button not found")
        cancel.tap()
        XCTAssertTrue(waitForGone(title, timeout: 10),
                      "PhotoImportSheet did not dismiss after Cancel")
    }

    @MainActor
    func testCameraImportFailureOffersRetakeAndReopensCamera() throws {
        let app = XCUIApplication()
        app.launchArguments += [cameraImportFailingArg]
        app.launch()
        launchBuiltInEngine(app)

        // The sheet appears then lands in the failure state: the non-board image
        // cannot be recognized, so the retry button (camera title "Retake Photo",
        // identifier "PhotoImportSheet.retry") is shown.
        let title = app.staticTexts[sheetTitle]
        XCTAssertTrue(title.waitForExistence(timeout: 360),
                      "PhotoImportSheet ('\(sheetTitle)') never appeared — the failing camera launch-arg hook did not reach the sheet")

        let retry = app.buttons["PhotoImportSheet.retry"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 120),
                      "Failure-state retry button ('PhotoImportSheet.retry') never appeared — the unrecognizable image did not reach the failure state")
        XCTAssertEqual(retry.label, "Retake Photo",
                       "Camera failure retry button should be titled 'Retake Photo'")

        let failureShot = XCTAttachment(screenshot: app.screenshot())
        failureShot.name = "CameraImportFailure"
        failureShot.lifetime = .keepAlways
        add(failureShot)

        // Tapping Retake reopens the camera cover. On the Simulator (no camera)
        // BoardCameraView lands in either the denied phase or the preview
        // scaffold; both expose the stable "BoardCamera.cancel" element. A camera
        // permission prompt may appear on first access — answer it so the cover
        // leaves its transient checking phase.
        retry.tap()

        let cancel = app.buttons["BoardCamera.cancel"].firstMatch
        XCTAssertTrue(waitForCameraCover(app, cancel: cancel, timeout: 40),
                      "Camera cover ('BoardCamera.cancel') did not appear after tapping Retake Photo")

        let coverShot = XCTAttachment(screenshot: app.screenshot())
        coverShot.name = "CameraCoverReopened"
        coverShot.lifetime = .keepAlways
        add(coverShot)

        // Cancel dismisses the cover.
        cancel.tap()
        XCTAssertTrue(waitForGone(cancel, timeout: 10),
                      "Camera cover did not dismiss after tapping Cancel")
    }

    // MARK: - Helpers

    /// DEBUG forces the model picker — launch the built-in network. Once the
    /// engine is up, GameSplitView mounts and the DEBUG camera hook auto-presents
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

    /// Polls for the camera cover's stable Cancel element, answering a camera
    /// permission alert (springboard) if one is presented so the cover can leave
    /// its transient checking phase. Returns once the cover element is present
    /// (permission granted → preview scaffold, or denied → denied phase — both
    /// expose "BoardCamera.cancel"), or false on timeout.
    @MainActor
    private func waitForCameraCover(_ app: XCUIApplication,
                                    cancel: XCUIElement,
                                    timeout: TimeInterval) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // Any of these dismisses the alert; every outcome leaves the cover in a
        // state that shows "BoardCamera.cancel".
        let permissionButtons = ["OK", "Allow", "Don't Allow"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cancel.exists { return true }
            for label in permissionButtons {
                let button = springboard.buttons[label]
                if button.exists {
                    button.tap()
                    break
                }
            }
            usleep(300_000)
        }
        return cancel.exists
    }

    /// Poll until `element` leaves the accessibility tree, or the timeout.
    @MainActor
    private func waitForGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while element.exists && Date() < deadline { usleep(150_000) }
        return !element.exists
    }
}
