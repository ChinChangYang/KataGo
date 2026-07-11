//
//  CameraCaptureUITestSupport.swift
//  KataGo iOS
//
//  DEBUG-only test support for the camera-import UI tests. The Simulator has no
//  camera, so XCUITest cannot drive `BoardCameraView`'s AVFoundation capture.
//  These hooks feed `TopUIState.pendingPhotoImport` with `source: .camera`
//  directly — the same state the real capture completion sets once the camera
//  cover dismisses — so `PhotoImportSheet` presents and runs the real
//  recognition path, exercising the camera-specific "Retake Photo" retry wiring.
//
//  Two launch arguments:
//    --uitest-camera-import          a recognizable board (reuses the wide-margin
//                                    9x9 blob from PhotoImportUITestSupport) so
//                                    the sheet lands in the preview state.
//    --uitest-camera-import-failing  a deterministic non-board image (a 64x64
//                                    solid-gray JPEG rendered in code — no new
//                                    embedded blob) so the sheet lands in the
//                                    failure state, which offers "Retake Photo".
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
    /// landing in the failure state (which offers "Retake Photo").
    static let failingLaunchArg = "--uitest-camera-import-failing"

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
