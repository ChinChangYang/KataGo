//
//  WatchWidgetRecordTests.swift
//  KataGo AnytimeTests
//
//  The one record the complication renders, and when it is worth writing.
//

import Testing
import Foundation
import KataGoAnalysisKit

struct WatchWidgetRecordTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// A throwaway suite, removed when the block returns. Never the real App
    /// Group, which the simulator shares with anything else running.
    private func withSuite(_ body: (UserDefaults) -> Void) {
        let name = "test.watchwidgetrecord.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        body(defaults)
        UserDefaults().removePersistentDomain(forName: name)
    }

    private func snapshot(gameID: String = "GAME-A",
                          name: String = "Ladder Fight 3",
                          parkedIndex: Int = 10,
                          comment: String? = nil,
                          score: Double? = 1.5,
                          at offset: TimeInterval = 0) -> WatchWidgetSnapshot {
        WatchWidgetSnapshot(gameID: gameID, name: name, comment: comment,
                            parkedIndex: parkedIndex, mainlineMoveCount: 178,
                            scoreLeadBlack: score, isBranch: false,
                            capturedAt: t0.addingTimeInterval(offset))
    }

    @Test func anEmptyRecordHoldsNothing() {
        #expect(WatchWidgetRecord().library == nil)
    }

    @Test func anUnchangedCandidateIsRejectedSoNothingIsWritten() {
        // A CloudKit refresh burst must not rewrite an identical record once
        // per notification.
        let stored = WatchWidgetRecord(library: snapshot(at: 0))
        #expect(stored.accepting(snapshot(at: 600)) == nil)
    }

    @Test func aChangedCandidateIsAccepted() {
        let stored = WatchWidgetRecord(library: snapshot(comment: nil, at: 0))
        let updated = stored.accepting(snapshot(comment: "New note.", at: 600))
        #expect(updated?.library?.comment == "New note.")
    }

    @Test func theFirstRecordIsAlwaysAccepted() {
        #expect(WatchWidgetRecord().accepting(snapshot())?.library != nil)
    }

    @Test func thereIsNoMonotonicGuard() {
        // There is exactly one writer, serialized on the main actor, so an
        // out-of-order write cannot occur — and an older-clocked but DIFFERENT
        // record must still land, because a game edited on another device can
        // legitimately carry an earlier timestamp.
        let stored = WatchWidgetRecord(library: snapshot(at: 600))
        #expect(stored.accepting(snapshot(gameID: "GAME-B", at: 0))?.library?.gameID == "GAME-B")
    }

    /// The App-Group blob written by the previous two-mirror build must still
    /// yield its library half. `JSONDecoder` ignores the now-unknown "live"
    /// key, so this costs nothing at the process boundary — but it is the only
    /// thing standing between an update and a blank tile, so it is pinned.
    ///
    /// Goes through `WatchWidgetDefaults.read(from:)` — the production reader
    /// — rather than a locally-built `JSONDecoder`. A decoder built here would
    /// only pin this test's own decoding choices; a symmetric change to both
    /// the encoder and decoder inside `WatchWidgetDefaults` would keep such a
    /// test green while real legacy blobs silently decode with wrong
    /// instants, so it would not actually guard the cross-process contract it
    /// claims to.
    @Test func aTwoMirrorBlobStillDecodesItsLibraryHalf() {
        let legacy = """
        {"live":{"gameID":"OLD","name":"Old","parkedIndex":1,\
        "mainlineMoveCount":2,"isBranch":false,"capturedAt":0,"source":"live"},\
        "library":{"gameID":"GAME-A","name":"Ladder Fight 3","parkedIndex":10,\
        "mainlineMoveCount":178,"scoreLeadBlack":1.5,"isBranch":false,\
        "capturedAt":1000000,"source":"library"}}
        """
        withSuite { defaults in
            defaults.set(Data(legacy.utf8), forKey: WatchWidgetDefaults.recordsKey)
            let record = WatchWidgetDefaults.read(from: defaults)
            #expect(record.library?.gameID == "GAME-A")
            #expect(record.library?.parkedIndex == 10)
        }
    }
}
