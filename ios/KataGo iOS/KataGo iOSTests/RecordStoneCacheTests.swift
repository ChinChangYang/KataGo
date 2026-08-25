//
//  RecordStoneCacheTests.swift
//  KataGo AnytimeTests
//
//  The per-index cache a `GameRecord` carries for readers that cannot replay an
//  SGF: the Saved Game widget (`blackStones`/`whiteStones`) and the Commentator
//  (`moves`). It is now driven by the record position rather than by a
//  `showboard` reply, so these pin the two things that made the old, duplicated
//  host code correct — `refillString` parity and assign-only-on-change — plus
//  the branch skip.
//  It parses nothing: the move vertices ride in on `RecordPosition`, filled by
//  the projector from the parse it already had.
//

import Testing
import Foundation
import SwiftData
@testable import KataGoUICore

@MainActor
struct RecordStoneCacheTests {
    private static let sgf = "(;FF[4]GM[1]SZ[9]KM[7];B[cc];W[dd])"

    /// Projects `Self.sgf` at `index` and hands back both halves the cache
    /// needs. No defaulted parameter: a default argument that reads a
    /// main-actor-isolated static is evaluated in its own isolation context.
    private func position(at index: Int) -> (RecordPosition, RecordPositionKey) {
        let key = RecordPositionKey(recordID: nil, sgf: Self.sgf, index: index, isBranchActive: false)
        let projector = RecordPositionProjector()
        let published = projector.project(key: key,
                                          into: Stones(),
                                          board: BoardSize(),
                                          analysis: Analysis(),
                                          gobanState: GobanState(),
                                          // Irrelevant here — this fixture
                                          // asserts on the published stones,
                                          // and the flag only decides how much
                                          // of a throwaway `Analysis` is cleared.
                                          engineIsAcceptingCommands: true)
        return (published, key)
    }

    @Test func stonesAreWrittenWithRefillStringParity() {
        let record = GameRecord.createGameRecord(sgf: Self.sgf)
        let (published, key) = position(at: 2)

        #expect(RecordStoneCache.write(position: published, key: key, into: record))

        #expect(record.blackStones?[2] == BoardPoint.refillString(published.blackPoints,
                                                                 width: 9, height: 9))
        #expect(record.whiteStones?[2] == BoardPoint.refillString(published.whitePoints,
                                                                 width: 9, height: 9))
        #expect(record.blackStones?[2] == "C7")
        #expect(record.whiteStones?[2] == "D6")
    }

    @Test func anEmptySideIsStoredAsAnEmptyStringNotAMissingKey() {
        // `dict[i] = nil` REMOVES the entry, which breaks the widget's
        // `lastIndex` / `getCapturedStones` logic — both distinguish "no entry"
        // from "empty entry".
        let record = GameRecord.createGameRecord(sgf: Self.sgf)
        let (published, key) = position(at: 1)

        RecordStoneCache.write(position: published, key: key, into: record)

        #expect(record.whiteStones?.keys.contains(1) == true)
        #expect(record.whiteStones?[1] == "")
    }

    @Test func rewritingTheSamePositionChangesNothing() {
        // SwiftData dirties a record on ANY set, and a dirtied record is
        // exported to CloudKit — so a re-projection of the same position (a
        // re-entry, a board reload) must cost nothing.
        let record = GameRecord.createGameRecord(sgf: Self.sgf)
        let (published, key) = position(at: 2)

        #expect(RecordStoneCache.write(position: published, key: key, into: record))
        #expect(!RecordStoneCache.write(position: published, key: key, into: record))
    }

    @Test func aBranchLineIsNeverCached() {
        // A branch is a scratch line that is never saved, and its indices are
        // numbered from the divergence — writing them would corrupt the
        // mainline's cache.
        let record = GameRecord.createGameRecord(sgf: Self.sgf)
        let (published, _) = position(at: 2)
        let branchKey = RecordPositionKey(recordID: nil, sgf: Self.sgf,
                                          index: 2, isBranchActive: true)

        #expect(!RecordStoneCache.write(position: published, key: branchKey, into: record))
        #expect(record.blackStones?[2] == nil)
        #expect(record.moves?[1] == nil)
    }

    @Test func theMoveVertexCacheTheCommentatorReadsIsFilled() {
        // Navigation sends no `printsgf`, so without this an index reached by
        // stepping would have no `moves` entry at all.
        let record = GameRecord.createGameRecord(sgf: Self.sgf)
        let (published, key) = position(at: 1)

        RecordStoneCache.write(position: published, key: key, into: record)

        #expect(record.moves?[0] == "C7")   // the move played INTO this position
        #expect(record.moves?[1] == "D6")   // the move that leaves it
    }

    @Test func aStaleMoveEntryIsCorrected() {
        // The vertices are free now (the projector supplies them), so a wrong
        // entry is rewritten rather than left alone — the earlier
        // fill-only-when-missing shortcut existed purely to dodge a parse.
        let record = GameRecord.createGameRecord(sgf: Self.sgf)
        record.moves?[1] = "Z1"
        let (published, key) = position(at: 2)

        #expect(RecordStoneCache.write(position: published, key: key, into: record))
        #expect(record.moves?[1] == "D6")
    }

    @Test func theMoveCacheStopsAtTheEndOfTheRecord() {
        let record = GameRecord.createGameRecord(sgf: Self.sgf)
        let (published, key) = position(at: 2)

        RecordStoneCache.write(position: published, key: key, into: record)

        #expect(record.moves?[1] == "D6")
        #expect(record.moves?[2] == nil)    // there is no third move to name
    }

    /// Every caller pairs a key from the PROJECTOR with a record from the
    /// HOST's selection, and a game switch moves those two one at a time. A
    /// write under a mismatched pair stamps the outgoing game's position into
    /// the incoming game's cache — at the outgoing game's index — and the
    /// widget then renders that as the incoming game's board. Refused.
    @Test func aKeyThatNamesAnotherRecordIsRefused() throws {
        let container = try ModelContainer(
            for: SharedModelContainer.schema,
            configurations: ModelConfiguration(schema: SharedModelContainer.schema,
                                               isStoredInMemoryOnly: true)
        )
        let mine = GameRecord.createGameRecord(sgf: Self.sgf)
        let other = GameRecord.createGameRecord(sgf: Self.sgf)
        container.mainContext.insert(mine)
        container.mainContext.insert(other)

        let (published, _) = position(at: 2)
        let foreignKey = RecordPositionKey(recordID: other.persistentModelID,
                                           sgf: Self.sgf, index: 2, isBranchActive: false)

        #expect(!RecordStoneCache.write(position: published, key: foreignKey, into: mine))
        #expect(mine.blackStones?[2] == nil)
        #expect(mine.moves?[1] == nil)

        // The same key against the record it actually names still writes.
        let ownKey = RecordPositionKey(recordID: mine.persistentModelID,
                                       sgf: Self.sgf, index: 2, isBranchActive: false)
        #expect(RecordStoneCache.write(position: published, key: ownKey, into: mine))
        #expect(mine.blackStones?[2] == "C7")
    }

    /// A nil id is not a mismatch: an unsaved record has no persistent identity
    /// yet, and every projector key built before one exists carries nil.
    @Test func aKeyWithNoRecordIDStillWrites() {
        let record = GameRecord.createGameRecord(sgf: Self.sgf)
        let (published, key) = position(at: 2)

        #expect(key.recordID == nil)
        #expect(RecordStoneCache.write(position: published, key: key, into: record))
    }
}
