//
//  WatchDeepLinkDispositionTests.swift
//  KataGo AnytimeTests
//
//  Where a complication tap lands, and when it is still too early to decide.
//

import Testing
@testable import KataGoGameStore

struct WatchDeepLinkDispositionTests {
    @Test func tappingTheGameThePhoneIsPlayingOpensTheMirror() {
        // There is never a stale second view of the game the phone is on —
        // the same rule the library rows already follow.
        #expect(WatchNavigationPolicy.deepLinkDisposition(
            pendingGameID: "GAME-A", hostGameID: "GAME-A", hasSnapshot: true,
            libraryHasRow: true, graceExpired: true) == .live)
    }

    @Test func tappingAnotherGameOpensTheReplay() {
        #expect(WatchNavigationPolicy.deepLinkDisposition(
            pendingGameID: "GAME-A", hostGameID: "GAME-B", hasSnapshot: true,
            libraryHasRow: true, graceExpired: true) == .stored("GAME-A"))
    }

    @Test func aColdLaunchWaitsRatherThanSayingGameNotFound() {
        // The exact cold-launch case: the tap arrives before the library has
        // loaded and before WCSession has replayed its context, so neither
        // branch can be decided yet. Deciding early is what dead-ends the tap.
        #expect(WatchNavigationPolicy.deepLinkDisposition(
            pendingGameID: "GAME-A", hostGameID: nil, hasSnapshot: false,
            libraryHasRow: false, graceExpired: false) == .wait)
    }

    @Test func onceTheGraceExpiresAMissingGameGivesUp() {
        #expect(WatchNavigationPolicy.deepLinkDisposition(
            pendingGameID: "GAME-A", hostGameID: nil, hasSnapshot: false,
            libraryHasRow: false, graceExpired: true) == .giveUp)
    }

    @Test func theLiveMirrorWinsEvenBeforeTheLibraryLoads() {
        #expect(WatchNavigationPolicy.deepLinkDisposition(
            pendingGameID: "GAME-A", hostGameID: "GAME-A", hasSnapshot: true,
            libraryHasRow: false, graceExpired: false) == .live)
    }

    @Test func aStoredRowWinsBeforeTheGraceExpires() {
        #expect(WatchNavigationPolicy.deepLinkDisposition(
            pendingGameID: "GAME-A", hostGameID: nil, hasSnapshot: false,
            libraryHasRow: true, graceExpired: false) == .stored("GAME-A"))
    }

    @Test func aHostGameIdWithoutASnapshotIsNotTheLiveGame() {
        #expect(WatchNavigationPolicy.deepLinkDisposition(
            pendingGameID: "GAME-A", hostGameID: "GAME-A", hasSnapshot: false,
            libraryHasRow: true, graceExpired: true) == .stored("GAME-A"))
    }
}
