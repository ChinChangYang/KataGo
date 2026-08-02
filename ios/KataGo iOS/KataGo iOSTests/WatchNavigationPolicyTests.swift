//
//  WatchNavigationPolicyTests.swift
//  KataGo AnytimeTests
//
//  Where the watch lands on launch, and when a library row is really the
//  live game under another name.
//

import Testing
@testable import KataGoGameStore

struct WatchNavigationPolicyTests {
    @Test func aSnapshotSendsYouStraightToTheBoard() {
        // The glance case must stay zero-tap: the watch has always opened on
        // the mirrored board, including from WCSession's replayed context.
        #expect(WatchNavigationPolicy.launchRoute(hasSnapshot: true,
                                                  latchConsumed: false) == .liveGame)
    }

    @Test func noSnapshotLandsOnTheLibrary() {
        #expect(WatchNavigationPolicy.launchRoute(hasSnapshot: false,
                                                  latchConsumed: false) == .library)
    }

    @Test func theLatchStopsItPushingAgainThisSession() {
        // Without the latch, swiping back to the library would immediately
        // bounce you into the board again and the list would be unreachable.
        #expect(WatchNavigationPolicy.launchRoute(hasSnapshot: true,
                                                  latchConsumed: true) == .library)
    }

    @Test func theLiveGamesRowOpensTheMirrorNotAReplay() {
        #expect(WatchNavigationPolicy.opensLiveMirror(rowID: "abc",
                                                      hostGameID: "abc",
                                                      hasSnapshot: true))
    }

    @Test func anotherGamesRowOpensTheReplay() {
        #expect(!WatchNavigationPolicy.opensLiveMirror(rowID: "abc",
                                                       hostGameID: "xyz",
                                                       hasSnapshot: true))
    }

    @Test func withoutASnapshotEveryRowIsAReplay() {
        #expect(!WatchNavigationPolicy.opensLiveMirror(rowID: "abc",
                                                       hostGameID: "abc",
                                                       hasSnapshot: false))
        #expect(!WatchNavigationPolicy.opensLiveMirror(rowID: "abc",
                                                       hostGameID: nil,
                                                       hasSnapshot: true))
    }
}
