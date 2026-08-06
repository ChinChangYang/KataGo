//
//  WatchNavigationPolicy.swift
//  KataGoGameStore
//
//  Where the watch lands, decided in one testable place because the watch
//  target has no test bundle.
//

import Foundation

/// What to do with a complication tap that named a game.
public enum WatchDeepLinkDisposition: Equatable, Sendable {
    /// Too early to decide — keep the latch and re-evaluate.
    case wait
    case game(String)
    /// The game cannot be resolved and never will be; drop the latch.
    case giveUp
}

public enum WatchNavigationPolicy {
    /// Precedence for a pending deep link, highest first:
    ///
    ///   1. the library can produce a row for it -> `.game`
    ///   2. it cannot, but the launch grace has not expired -> `.wait`
    ///   3. otherwise -> `.giveUp`
    ///
    /// `.wait` exists because a cold launch from a tap is the one moment when
    /// the store may not yet have imported the game the tile names. Deciding
    /// then is what dead-ends the tap on "Game not found". The grace is
    /// deliberately short (see `WatchRootView.deepLinkResolutionGrace`): during
    /// `.wait` the user is already sitting on a fully interactive library, so a
    /// long window mostly buys opportunities to yank them out of a list they
    /// have started browsing.
    public static func deepLinkDisposition(pendingGameID: String,
                                           libraryHasRow: Bool,
                                           graceExpired: Bool) -> WatchDeepLinkDisposition {
        if libraryHasRow { return .game(pendingGameID) }
        return graceExpired ? .giveUp : .wait
    }
}
