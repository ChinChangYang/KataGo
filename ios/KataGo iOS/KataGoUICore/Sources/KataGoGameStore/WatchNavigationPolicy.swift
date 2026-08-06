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

/// What to do with a complication tap that named a game.
public enum WatchDeepLinkDisposition: Equatable, Sendable {
    /// Too early to decide — keep the latch and re-evaluate.
    case wait
    case live
    case stored(String)
    /// The game cannot be resolved and never will be; drop the latch.
    case giveUp
}

extension WatchNavigationPolicy {
    /// Precedence for a pending deep link, highest first:
    ///
    ///   1. the phone is playing this exact game -> `.live`
    ///   2. the library can produce a row for it -> `.stored`
    ///   3. neither, but the launch grace has not expired -> `.wait`
    ///   4. otherwise -> `.giveUp`
    ///
    /// `.wait` exists because a cold launch from a tap is the one moment when
    /// BOTH inputs are still missing: the library has not fetched, and
    /// WCSession has not replayed its persisted context. Deciding then is what
    /// dead-ends the tap on "Game not found".
    public static func deepLinkDisposition(pendingGameID: String,
                                           hostGameID: String?,
                                           hasSnapshot: Bool,
                                           libraryHasRow: Bool,
                                           graceExpired: Bool) -> WatchDeepLinkDisposition {
        if opensLiveMirror(rowID: pendingGameID, hostGameID: hostGameID,
                           hasSnapshot: hasSnapshot) {
            return .live
        }
        if libraryHasRow { return .stored(pendingGameID) }
        return graceExpired ? .giveUp : .wait
    }
}
