//
//  WatchNavigationPolicy.swift
//  KataGoGameStore
//
//  Where the watch lands, decided in one testable place because the watch
//  target has no test bundle.
//

import Foundation

public enum WatchLaunchRoute: Equatable, Sendable {
    case library
    case liveGame
}

public enum WatchNavigationPolicy {
    /// A snapshot — live or replayed from WCSession's persisted context —
    /// means the phone has something to show, so the watch opens on the board
    /// exactly as it always has. `latchConsumed` is set once the user has
    /// swiped back, so the library stays reachable for the rest of the session.
    public static func launchRoute(hasSnapshot: Bool,
                                   latchConsumed: Bool) -> WatchLaunchRoute {
        (hasSnapshot && !latchConsumed) ? .liveGame : .library
    }

    /// Whether tapping a library row should open the live mirror rather than
    /// the watch's own replay. There is never a stale second view of the game
    /// the phone is actually playing.
    public static func opensLiveMirror(rowID: String,
                                       hostGameID: String?,
                                       hasSnapshot: Bool) -> Bool {
        guard hasSnapshot, let hostGameID else { return false }
        return rowID == hostGameID
    }
}
