//
//  WatchDeepLinkDispositionTests.swift
//  KataGo AnytimeTests
//
//  Where a complication tap lands, and when it is still too early to decide.
//

import Testing
@testable import KataGoGameStore

struct WatchDeepLinkDispositionTests {
    @Test func aResolvableGameOpens() {
        #expect(WatchNavigationPolicy.deepLinkDisposition(
            pendingGameID: "GAME-A", libraryHasRow: true,
            graceExpired: true) == .game("GAME-A"))
    }

    @Test func aColdLaunchWaitsRatherThanSayingGameNotFound() {
        // The exact cold-launch case: the tap arrives before the store has
        // produced a row for the game. Deciding early is what dead-ends the
        // tap on "Game not found".
        #expect(WatchNavigationPolicy.deepLinkDisposition(
            pendingGameID: "GAME-A", libraryHasRow: false,
            graceExpired: false) == .wait)
    }

    @Test func onceTheGraceExpiresAMissingGameGivesUp() {
        // Giving up is not an error state: the latch clears and the user is
        // left on a fully interactive library.
        #expect(WatchNavigationPolicy.deepLinkDisposition(
            pendingGameID: "GAME-A", libraryHasRow: false,
            graceExpired: true) == .giveUp)
    }

    @Test func aResolvableGameWinsBeforeTheGraceExpires() {
        #expect(WatchNavigationPolicy.deepLinkDisposition(
            pendingGameID: "GAME-A", libraryHasRow: true,
            graceExpired: false) == .game("GAME-A"))
    }
}
