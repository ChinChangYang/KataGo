//
//  DownloadState.swift
//  KataGo Anytime
//
//  The vocabulary of a download's life (CONTEXT.md § Downloads). Deliberately
//  free of transport: nothing here knows what HTTP is.
//

import Foundation

/// Where one download stands. `succeeded` is the only state the rest of the
/// app is entitled to infer anything from — it means a complete, *verified*
/// asset is at its destination.
public enum DownloadState: String, Equatable, Sendable, CaseIterable {
    /// Never asked for, or asked for and long since finished and forgotten.
    case idle
    /// Asked for, not yet started, because another download is transferring.
    /// Distinct from `paused`: nobody stopped it.
    case waiting
    /// Bytes are moving right now.
    case transferring
    /// Stopped by the user. Keeps its partial and never resumes itself.
    case paused
    /// Stopped by anything other than the user. Keeps its partial and is
    /// eligible to resume itself at launch and when connectivity returns.
    case interrupted
    /// Verified and moved to its destination.
    case succeeded
}

/// What the one download button in a detail view should do right now.
///
/// One button, four roles — never a button that appears and disappears. The
/// iOS UI suite taps `ModelDetailView.downloadPlayButton` in nine files and
/// would break the moment that identifier stopped being always present.
public enum DownloadButtonRole: String, Equatable, Sendable, CaseIterable {
    /// The asset is on disk; the button activates it.
    case play
    /// Nothing on disk, nothing in flight, no partial.
    case download
    /// A transfer is running or queued behind one.
    case pause
    /// Stopped with a partial kept — one tap away from continuing.
    case resume

    public var systemImageName: String {
        switch self {
        case .play: return "play.fill"
        case .download, .resume: return "arrow.down"
        case .pause: return "stop.circle"
        }
    }

    /// The button's spoken label. Icon-only labels use this as their
    /// accessibility text, so `download` and `resume` must read differently
    /// even though they share a glyph.
    public var actionTitle: String {
        switch self {
        case .play: return "Play"
        case .download: return "Download"
        case .pause: return "Stop Download"
        case .resume: return "Resume Download"
        }
    }

    /// A download stopped before it wrote anything has nothing to resume, so
    /// it reads as a fresh `download` rather than a `resume` that would
    /// promise progress it does not have.
    public static func role(isOnDisk: Bool,
                            state: DownloadState,
                            hasPartial: Bool) -> DownloadButtonRole {
        if isOnDisk { return .play }
        switch state {
        case .transferring, .waiting:
            return .pause
        case .paused, .interrupted:
            return hasPartial ? .resume : .download
        case .idle, .succeeded:
            return .download
        }
    }
}
