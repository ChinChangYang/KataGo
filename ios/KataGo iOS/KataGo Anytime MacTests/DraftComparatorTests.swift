//
//  DraftComparatorTests.swift
//  KataGo Anytime MacTests
//

import Testing
import Foundation
@testable import KataGoGameStore

@MainActor
struct DraftComparatorTests {

    private func baseRecord() -> GameRecord {
        let record = GameRecord(config: Config())
        record.sgf = "(;FF[4]GM[1]SZ[19];B[dd])"
        record.name = "Base"
        record.comments = [0: "hi"]
        record.currentIndex = 1
        return record
    }

    private func snapshot(_ record: GameRecord) -> DraftSnapshot {
        DraftSnapshot(record: record, originUUID: nil)
    }

    @Test func identicalSnapshotsDoNotDiffer() {
        let record = baseRecord()
        #expect(!DraftComparator.differs(snapshot(record), snapshot(record)))
    }

    @Test func changingTheSgfDiffers() {
        let record = baseRecord()
        let before = snapshot(record)
        record.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp])"
        #expect(DraftComparator.differs(snapshot(record), before))
    }

    @Test func changingTheNameDiffers() {
        let record = baseRecord()
        let before = snapshot(record)
        record.name = "Renamed"
        #expect(DraftComparator.differs(snapshot(record), before))
    }

    @Test func changingACommentDiffers() {
        let record = baseRecord()
        let before = snapshot(record)
        record.comments = [0: "changed"]
        #expect(DraftComparator.differs(snapshot(record), before))
    }

    @Test func changingAConfigFieldDiffers() {
        let record = baseRecord()
        let before = snapshot(record)
        record.concreteConfig.komi = 0.5
        #expect(DraftComparator.differs(snapshot(record), before))
    }

    @Test func changingTheCursorDoesNotDiffer() {
        let record = baseRecord()
        let before = snapshot(record)
        record.currentIndex = 0
        #expect(!DraftComparator.differs(snapshot(record), before))
    }

    @Test func changingAnalysisDataDoesNotDiffer() {
        // The whole point: analysis rewrites these every few hundred
        // milliseconds, and must never light up the dirty marker.
        let record = baseRecord()
        let before = snapshot(record)
        record.winRates = [1: 0.7]
        record.scoreLeads = [1: 2.5]
        record.bestMoves = [1: "Q16"]
        record.ownershipWhiteness = [1: [0.5]]
        record.ownershipScales = [1: [0.5]]
        record.moves = [0: "D16"]
        record.blackStones = [1: "D16"]
        record.whiteStones = [1: ""]
        record.lastModificationDate = Date(timeIntervalSince1970: 999)
        #expect(!DraftComparator.differs(snapshot(record), before))
    }
}
