//
//  CameraCaptureUITestSupport.swift
//  KataGo iOS
//
//  DEBUG-only test support for the camera-import UI tests. The Simulator has no
//  camera, so XCUITest cannot drive `BoardCameraView`'s AVFoundation capture.
//  These hooks feed `TopUIState.pendingPhotoImport` with `source: .camera`
//  directly — the same state the real capture completion sets once the camera
//  cover dismisses — so `PhotoImportSheet` presents and runs the real
//  recognition path, exercising the camera-specific "Retake" retry wiring.
//
//  Three launch arguments:
//    --uitest-camera-import          a recognizable board (reuses the wide-margin
//                                    9x9 blob from PhotoImportUITestSupport) so
//                                    the sheet lands in the preview state.
//    --uitest-camera-import-failing  a deterministic non-board image (a 64x64
//                                    solid-gray JPEG rendered in code — no new
//                                    embedded blob) so recognition fails and the
//                                    sheet offers "Retake".
//    --uitest-camera-permission-denied
//                                    pins `BoardCameraView` to its denied phase
//                                    instead of asking AVFoundation. See
//                                    `forcesDeniedCameraPermission`.
//
//  The seam NEVER constructs an AVFoundation object: it only sets pending state,
//  keeping it Simulator-safe and away from the unconfigured-session capture
//  path. Mirrors `PhotoImportUITestSupport`; compiled out of Release entirely.
//

#if DEBUG
import Foundation
import KataGoUICore
import UIKit

enum CameraCaptureUITestSupport {
    /// Auto-present the photo-import sheet (source `.camera`) with a recognizable
    /// board, landing in the preview state.
    static let launchArg = "--uitest-camera-import"

    /// Auto-present the sheet (source `.camera`) with an unrecognizable image,
    /// so the sheet offers "Retake".
    static let failingLaunchArg = "--uitest-camera-import-failing"

    /// Pins `BoardCameraView` to its `denied` phase instead of consulting
    /// `AVCaptureDevice.authorizationStatus`.
    ///
    /// Without this the camera cover is only observable *eventually*, and on a
    /// schedule the test does not control. `authorizationStatus` is backed by the
    /// simulator's per-device TCC store, so it answers `.notDetermined` on a
    /// device that has never been asked — `requestAccess` then puts up a
    /// SpringBoard alert and the cover sits in its `checking` phase until
    /// something dismisses it — and `.authorized` on every device that has.
    /// Whether a given run pays that round trip is a property of the simulator's
    /// history, not of the code under test.
    ///
    /// `denied` is the right phase to pin: it is the only one that renders
    /// `BoardCamera.cancel` on its very first frame, and it constructs no
    /// AVFoundation object at all, which keeps this seam's "never touch the
    /// capture stack" invariant intact on a device that has no camera.
    static let deniedPermissionLaunchArg = "--uitest-camera-permission-denied"

    /// True when the camera cover should skip the AVFoundation permission query.
    static var forcesDeniedCameraPermission: Bool {
        ProcessInfo.processInfo.arguments.contains(deniedPermissionLaunchArg)
    }

    /// Fixed name so the UI tests can identify the pending camera import.
    static let importedGameName = "UITest Camera Board"

    /// True when either camera-import launch argument is present.
    static var isActive: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains(launchArg) || args.contains(failingLaunchArg)
    }

    /// Idempotently presents the photo-import sheet (source `.camera`) with the
    /// selected test image. No-op unless a camera launch argument is present and
    /// nothing is pending yet.
    @MainActor
    static func presentIfNeeded(into topUIState: TopUIState) {
        guard isActive else { return }
        guard topUIState.pendingPhotoImport == nil else { return }
        let args = ProcessInfo.processInfo.arguments
        let imageData: Data? = args.contains(failingLaunchArg)
            ? unrecognizableImageData()
            : PhotoImportUITestSupport.boardImageData
        guard let imageData else { return }
        topUIState.pendingPhotoImport = PendingPhotoImport(
            imageData: imageData,
            suggestedName: importedGameName,
            source: .camera
        )
    }

    /// A tiny deterministic non-board image (64x64 solid gray, JPEG) rendered at
    /// runtime — no board grid or stones, so the recognition pipeline fails
    /// cleanly and the sheet shows its failure state. Generated in code so no new
    /// blob ships in the binary.
    private static func unrecognizableImageData() -> Data? {
        let size = CGSize(width: 64, height: 64)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.9)
    }
}
#endif
