//
//  VisionModelDetailState.swift
//  KataGoUICore
//
//  Pure detail-page state behind the visionOS model detail view — the
//  Vision mirror of iOS ModelDetailView, now on the shared
//  DownloadButtonRole vocabulary (play / download / pause / resume)
//  instead of a private three-case copy: the trash affordance for
//  downloaded non-built-in nets, and the size line (empty for the
//  built-in). Unlike iOS, activate also waits for the engine to be
//  running: a Vision restart's teardown can take minutes, and stacking
//  a second restart on a stopping engine would wedge it.
//  humanFileSize is ported from the iOS Int extension (app-target-
//  private there), pinned by tests to the same output.
//

import Foundation

public struct VisionModelDetailState: Equatable, Sendable {
    /// The shared four-role button vocabulary. visionOS used to carry its own
    /// three-case copy; there is one now, so a paused download reads as
    /// "resume" here exactly as it does on iOS.
    public let primary: DownloadButtonRole
    public let primarySystemImage: String
    public let primaryDisabled: Bool
    public let showsTrash: Bool
    public let sizeText: String

    public static func make(isBuiltIn: Bool,
                            fileSize: Int,
                            isDownloaded: Bool,
                            downloadState: DownloadState,
                            hasPartial: Bool,
                            isActive: Bool,
                            engineIsRunning: Bool) -> VisionModelDetailState {
        let onDisk = isBuiltIn || isDownloaded
        let primary = DownloadButtonRole.role(isOnDisk: onDisk,
                                              state: downloadState,
                                              hasPartial: hasPartial)
        // Only activation waits for the engine. Downloading, pausing and
        // resuming are always allowed — a boot chooser has no engine yet and
        // must still be able to fetch the net it is about to boot.
        let disabled = primary == .play ? (isActive || !engineIsRunning) : false
        return VisionModelDetailState(
            primary: primary,
            primarySystemImage: primary.systemImageName,
            primaryDisabled: disabled,
            showsTrash: onDisk && !isBuiltIn,
            sizeText: isBuiltIn ? "" : humanFileSize(fileSize))
    }

    /// The iOS `Int.humanFileSize` formatter, verbatim.
    public static func humanFileSize(_ bytes: Int) -> String {
        let size = Double(bytes)
        guard size > 0 else { return "0 B" }
        let units = ["B", "kB", "MB", "GB", "TB"]
        let exponent = Int(floor(log(size) / log(1024)))
        let scaledSize = size / pow(1024, Double(exponent))
        let formattedSize = String(format: "%.2f", scaledSize)

        return "\(formattedSize) \(units[exponent])"
    }
}
