//
//  WatchWidgetRecordsTests.swift
//  KataGo AnytimeTests
//
//  Which of the two mirrors the complication shows, and how they combine when
//  they describe the same game.
//

import Testing
import Foundation
import KataGoAnalysisKit

struct WatchWidgetRecordsTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func record(_ source: WatchWidgetSnapshot.Source,
                        gameID: String = "GAME-A",
                        name: String = "Ladder Fight 3",
                        parkedIndex: Int = 10,
                        comment: String? = nil,
                        score: Double? = 1.5,
                        at offset: TimeInterval = 0) -> WatchWidgetSnapshot {
        WatchWidgetSnapshot(gameID: gameID, name: name, comment: comment,
                            parkedIndex: parkedIndex, mainlineMoveCount: 178,
                            scoreLeadBlack: score, isBranch: false,
                            capturedAt: t0.addingTimeInterval(offset), source: source)
    }

    // MARK: resolution

    @Test func nothingStoredResolvesToNothing() {
        #expect(WatchWidgetRecords().resolved(now: t0) == nil)
    }

    @Test func aLoneRecordWins() {
        let live = WatchWidgetRecords(live: record(.live), library: nil)
        #expect(live.resolved(now: t0)?.source == .live)
        let library = WatchWidgetRecords(live: nil, library: record(.library))
        #expect(library.resolved(now: t0)?.source == .library)
    }

    @Test func differentGamesResolveToTheNewer() {
        let records = WatchWidgetRecords(
            live: record(.live, gameID: "GAME-A", at: 0),
            library: record(.library, gameID: "GAME-B", at: 60))
        #expect(records.resolved(now: t0.addingTimeInterval(60))?.gameID == "GAME-B")
    }

    @Test func aLiveRecordOlderThanADayLosesToTheLibrary() {
        // A phone left idling on last Tuesday's game must not pin the tile
        // forever once the user has been playing elsewhere.
        let records = WatchWidgetRecords(
            live: record(.live, gameID: "GAME-A", at: 0),
            library: record(.library, gameID: "GAME-B", at: -3_600))
        let now = t0.addingTimeInterval(WatchWidgetRecords.liveExpiry + 1)
        #expect(records.resolved(now: now)?.gameID == "GAME-B")
    }

    @Test func aFreshLiveRecordStillBeatsAnOlderLibraryOne() {
        let records = WatchWidgetRecords(
            live: record(.live, gameID: "GAME-A", at: 0),
            library: record(.library, gameID: "GAME-B", at: -3_600))
        #expect(records.resolved(now: t0)?.gameID == "GAME-A")
    }

    @Test func aLiveRecordExactlyAtTheExpiryBoundaryLosesToTheLibrary() {
        // This pins the exact boundary of the >= check in resolved(now:).
        // With elapsed time exactly equal to liveExpiry, the library must win.
        // A regression from >= to > would let the live record incorrectly survive.
        let records = WatchWidgetRecords(
            live: record(.live, gameID: "GAME-A", at: 0),
            library: record(.library, gameID: "GAME-B", at: -3_600))
        let now = t0.addingTimeInterval(WatchWidgetRecords.liveExpiry)
        #expect(records.resolved(now: now)?.gameID == "GAME-B")
    }

    @Test func whenTimestampsAreEqualDifferentGamesResolveToLive() {
        // This pins the deliberate >= tie-break in resolved(now:) when games
        // differ. A regression from >= to > would let the library win undetected.
        let records = WatchWidgetRecords(
            live: record(.live, gameID: "GAME-A", at: 0),
            library: record(.library, gameID: "GAME-B", at: 0))
        #expect(records.resolved(now: t0)?.source == .live)
    }

    // MARK: same-game merge

    @Test func theSameGameMergesRatherThanPicks() {
        // The common case: the phone is parked deep in the game while the
        // watch's CloudKit replica still sits where the comment was written.
        // Picking a record would throw that comment away.
        let records = WatchWidgetRecords(
            live: record(.live, parkedIndex: 158, comment: nil, at: 60),
            library: record(.library, parkedIndex: 158, comment: "White cuts.", at: 0))
        let resolved = records.resolved(now: t0.addingTimeInterval(60))
        #expect(resolved?.parkedIndex == 158)
        #expect(resolved?.comment == "White cuts.")
    }

    @Test func aCommentFromADifferentIndexIsNeverBorrowed() {
        // Labelling move 158 with move 30's comment is confidently wrong.
        let records = WatchWidgetRecords(
            live: record(.live, parkedIndex: 158, comment: nil, at: 60),
            library: record(.library, parkedIndex: 30, comment: "Joseki here.", at: 0))
        let resolved = records.resolved(now: t0.addingTimeInterval(60))
        #expect(resolved?.parkedIndex == 158)
        #expect(resolved?.comment == nil)
    }

    @Test func theNewerRecordsOwnCommentWins() {
        let records = WatchWidgetRecords(
            live: record(.live, parkedIndex: 40, comment: "Fresh.", at: 60),
            library: record(.library, parkedIndex: 40, comment: "Stale.", at: 0))
        #expect(records.resolved(now: t0.addingTimeInterval(60))?.comment == "Fresh.")
    }

    @Test func theLibraryCanBeTheNewerHalfOfAMerge() {
        let records = WatchWidgetRecords(
            live: record(.live, parkedIndex: 40, comment: nil, at: 0),
            library: record(.library, parkedIndex: 40, comment: "Written on iPad.", at: 60))
        let resolved = records.resolved(now: t0.addingTimeInterval(60))
        #expect(resolved?.source == .library)
        #expect(resolved?.comment == "Written on iPad.")
    }

    @Test func whenTimestampsAreEqualTheLiveRecordIsTheNewerHalfOfAMerge() {
        // This pins the deliberate >= tie-break in merged(live:library:).
        // A regression from >= to > would let the library win undetected.
        // Test uses different parkedIndex to verify which record contributes.
        let records = WatchWidgetRecords(
            live: record(.live, parkedIndex: 158, at: 0),
            library: record(.library, parkedIndex: 100, at: 0))
        let resolved = records.resolved(now: t0)
        #expect(resolved?.parkedIndex == 158)  // live's index, confirming live is the newer half
    }

    // MARK: accepting a live candidate

    @Test func anUnchangedCandidateIsRejectedSoNothingIsWritten() {
        let stored = WatchWidgetRecords(live: record(.live, at: 0), library: nil)
        let candidate = record(.live, at: 600)   // same content, later clock
        #expect(stored.acceptingLive(candidate) == nil)
    }

    @Test func aChangedCandidateIsAccepted() {
        let stored = WatchWidgetRecords(live: record(.live, parkedIndex: 10, at: 0), library: nil)
        let candidate = record(.live, parkedIndex: 11, at: 600)
        #expect(stored.acceptingLive(candidate)?.live?.parkedIndex == 11)
    }

    @Test func aLateOlderPayloadCannotMoveTheTileBackwards() {
        // transferCurrentComplicationUserInfo is FIFO, not latest-wins: a
        // previously-current payload stays queued and can arrive after a newer
        // one. Writing it unconditionally would jump the tile from move 88
        // back to move 71.
        let stored = WatchWidgetRecords(live: record(.live, parkedIndex: 88, at: 600), library: nil)
        let late = record(.live, parkedIndex: 71, at: 0)
        #expect(stored.acceptingLive(late) == nil)
    }

    @Test func aDifferentGameIsAcceptedEvenWithAnOlderClock() {
        // Monotonicity is per-game: switching games on the phone must not be
        // blocked by the previous game's newer timestamp.
        let stored = WatchWidgetRecords(live: record(.live, gameID: "GAME-A", at: 600), library: nil)
        let other = record(.live, gameID: "GAME-B", at: 0)
        #expect(stored.acceptingLive(other)?.live?.gameID == "GAME-B")
    }

    // MARK: accepting a library candidate

    @Test func anUnchangedLibraryCandidateIsRejected() {
        // Same content-key rule as the live side: a CloudKit refresh burst
        // must not rewrite an identical record once per notification.
        let stored = WatchWidgetRecords(live: nil, library: record(.library, at: 0))
        #expect(stored.acceptingLibrary(record(.library, at: 600)) == nil)
    }

    @Test func aChangedLibraryCandidateIsAccepted() {
        let stored = WatchWidgetRecords(live: nil,
                                        library: record(.library, comment: nil, at: 0))
        let updated = stored.acceptingLibrary(record(.library, comment: "New note.", at: 600))
        #expect(updated?.library?.comment == "New note.")
    }

    @Test func theLibraryWriterHasNoMonotonicGuard() {
        // Unlike the live side there is exactly one library writer, serialized
        // on the main actor, so an out-of-order write cannot occur and an
        // older-clocked but DIFFERENT record must still land (a game edited on
        // another device can legitimately carry an earlier timestamp).
        let stored = WatchWidgetRecords(live: nil, library: record(.library, at: 600))
        let older = record(.library, gameID: "GAME-B", at: 0)
        #expect(stored.acceptingLibrary(older)?.library?.gameID == "GAME-B")
    }

    @Test func theFirstLibraryRecordIsAlwaysAccepted() {
        #expect(WatchWidgetRecords().acceptingLibrary(record(.library))?.library != nil)
    }

    // MARK: eviction

    @Test func aLiveRecordForADeletedGameIsEvicted() {
        let records = WatchWidgetRecords(
            live: record(.live, gameID: "GONE"),
            library: record(.library, gameID: "GAME-B"))
        let swept = records.evictingStaleLive(libraryIDs: ["GAME-B"], libraryIsAuthoritative: true)
        #expect(swept.live == nil)
        #expect(swept.library?.gameID == "GAME-B")
    }

    @Test func anEmptyOrDegradedLibraryNeverEvicts() {
        // A degraded or still-syncing store must not mass-evict a good record.
        let records = WatchWidgetRecords(live: record(.live, gameID: "GONE"), library: nil)
        #expect(records.evictingStaleLive(libraryIDs: [], libraryIsAuthoritative: true).live != nil)
        #expect(records.evictingStaleLive(libraryIDs: ["GAME-B"],
                                          libraryIsAuthoritative: false).live != nil)
    }

    @Test func aLiveRecordStillInTheLibrarySurvives() {
        let records = WatchWidgetRecords(live: record(.live, gameID: "GAME-A"), library: nil)
        #expect(records.evictingStaleLive(libraryIDs: ["GAME-A", "GAME-B"],
                                          libraryIsAuthoritative: true).live != nil)
    }
}
