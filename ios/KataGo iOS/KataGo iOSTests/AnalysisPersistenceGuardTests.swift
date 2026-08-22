//
//  AnalysisPersistenceGuardTests.swift
//  KataGo AnytimeTests
//
//  Per-index analysis may only be persisted for a position that is BOTH
//  acknowledged by the engine and the one the numbers were collected for. With
//  the board record-owned, navigation moves the record instantly while the
//  engine is still catching up — so without this guard a second step would
//  stamp the FIRST position's win rate, score and ownership onto the second
//  index.
//

import Testing
@testable import KataGoUICore

@MainActor
@Suite("Analysis persistence guard")
struct AnalysisPersistenceGuardTests {

    /// A 19×19 with three recorded moves, so indices 0…3 are all navigable.
    private static let sgf = "(;FF[4]GM[1]SZ[19]KM[7];B[dd];W[pp];B[dp])"

    private struct Fixture {
        let record: GameRecord
        let gobanState: GobanState
        let analysis: Analysis
        let board: BoardSize
        let stones: Stones
    }

    /// No `ModelContainer`: the guard compares a key built from THIS record
    /// against a stamp built from the same one, so a detached record's
    /// identifier is as good as a stored one — and there is no container
    /// lifetime to get wrong (`GobanStateBranchTests` works the same way).
    private func makeFixture() -> Fixture {
        let record = GameRecord.createGameRecord(sgf: Self.sgf)

        let gobanState = GobanState()
        gobanState.isEditing = true
        gobanState.analysisStatus = .run

        let analysis = Analysis()
        analysis.ownershipUnits = [OwnershipUnit(point: BoardPoint(x: 0, y: 0),
                                                 whiteness: 0.5, scale: 0.8, opacity: 1)]

        return Fixture(record: record, gobanState: gobanState, analysis: analysis,
                       board: BoardSize(), stones: Stones())
    }

    /// Marks the analysis as belonging to the record's CURRENT position and the
    /// engine as having acknowledged it — the state a genuinely analysed move
    /// is in.
    private func markInSync(_ fixture: Fixture) {
        fixture.stones.isReady = true
        fixture.analysis.collectedForKey =
            fixture.gobanState.recordPositionKey(gameRecord: fixture.record)
    }

    private func persist(_ fixture: Fixture) {
        fixture.gobanState.maybeUpdateAnalysisData(gameRecord: fixture.record,
                                                   analysis: fixture.analysis,
                                                   board: fixture.board,
                                                   stones: fixture.stones)
    }

    @Test("An in-sync, matching position is persisted as before")
    func inSyncPositionIsPersisted() {
        let fixture = makeFixture()
        fixture.record.currentIndex = 1
        markInSync(fixture)

        persist(fixture)

        #expect(fixture.record.ownershipWhiteness?[1] != nil)
    }

    @Test("Navigating twice with no acknowledgement writes nothing for either index")
    func navigatingTwiceWithNoAckWritesNothing() {
        let fixture = makeFixture()
        fixture.record.currentIndex = 1
        markInSync(fixture)
        persist(fixture)
        #expect(fixture.record.ownershipWhiteness?[1] != nil)

        // Step forward. The record moves at once (record-owned board); the
        // engine has not answered, so nothing may be written here.
        fixture.record.currentIndex = 2
        fixture.stones.isReady = false
        persist(fixture)

        // Step again before any answer arrives.
        fixture.record.currentIndex = 3
        persist(fixture)

        #expect(fixture.record.ownershipWhiteness?[2] == nil)
        #expect(fixture.record.ownershipWhiteness?[3] == nil)
    }

    @Test("An acknowledgement alone is not enough — the numbers must match the index")
    func acknowledgementWithStaleAnalysisWritesNothing() {
        let fixture = makeFixture()
        fixture.record.currentIndex = 1
        markInSync(fixture)

        // The engine catches up with index 2, but the analysis on screen is
        // still index 1's: the new position has not been searched yet.
        fixture.record.currentIndex = 2
        fixture.stones.isReady = true

        persist(fixture)

        #expect(fixture.record.ownershipWhiteness?[2] == nil)
    }

    @Test("Analysis collected for a different game is never written into this one")
    func analysisFromAnotherRecordIsRefused() {
        let fixture = makeFixture()
        fixture.record.currentIndex = 1
        fixture.stones.isReady = true
        // Same index, same branch state, a DIFFERENT record's SGF.
        fixture.analysis.collectedForKey = RecordPositionKey(
            recordID: nil,
            sgf: "(;FF[4]GM[1]SZ[19]KM[7];B[qq])",
            index: 1,
            isBranchActive: false)

        persist(fixture)

        #expect(fixture.record.ownershipWhiteness?[1] == nil)
    }
}
