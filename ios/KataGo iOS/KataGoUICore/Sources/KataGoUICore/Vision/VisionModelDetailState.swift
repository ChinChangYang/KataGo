//
//  VisionModelDetailState.swift
//  KataGoUICore
//
//  Pure detail-page state behind the visionOS model detail view — the
//  Vision mirror of iOS ModelDetailView: the tri-state primary button
//  (activate / download / stop-with-progress) with the same icons, the
//  trash affordance for downloaded non-built-in nets, and the size line
//  (empty for the built-in). Unlike iOS, activate also waits for the
//  engine to be running: a Vision restart's teardown can take minutes,
//  and stacking a second restart on a stopping engine would wedge it.
//  humanFileSize is ported from the iOS Int extension (app-target-
//  private there), pinned by tests to the same output.
//

import Foundation

public struct VisionModelDetailState: Equatable, Sendable {
    public enum Primary: Equatable, Sendable {
        case activate
        case download
        case stopDownload
    }

    public let primary: Primary
    public let primarySystemImage: String
    public let primaryDisabled: Bool
    public let showsTrash: Bool
    public let sizeText: String

    public static func make(isBuiltIn: Bool,
                            fileSize: Int,
                            isDownloaded: Bool,
                            isDownloading: Bool,
                            isActive: Bool,
                            engineIsRunning: Bool) -> VisionModelDetailState {
        let onDisk = isBuiltIn || isDownloaded
        let primary: Primary
        let image: String
        let disabled: Bool
        if onDisk {
            primary = .activate
            image = "play.fill"
            disabled = isActive || !engineIsRunning
        } else if isDownloading {
            primary = .stopDownload
            image = "stop.circle"
            disabled = false
        } else {
            primary = .download
            image = "arrow.down"
            disabled = false
        }
        return VisionModelDetailState(
            primary: primary,
            primarySystemImage: image,
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
