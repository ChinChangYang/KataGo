//
//  DraftSnapshotTests.swift
//  KataGo Anytime MacTests
//

import Testing
import Foundation
@testable import KataGoGameStore

@MainActor
struct DraftSnapshotTests {

    private func populated() -> GameRecord {
        let record = GameRecord(config: Config())
        record.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp])"
        record.currentIndex = 2
        record.name = "Populated"
        record.comments = [1: "note"]
        record.moves = [0: "D16", 1: "Q4"]
        record.winRates = [1: 0.42]
        record.scoreLeads = [1: -1.5]
        record.bestMoves = [1: "Q16"]
        record.blackStones = [1: "D16"]
        record.whiteStones = [1: "Q4"]
        record.ownershipWhiteness = [1: [0.1, 0.2]]
        record.ownershipScales = [1: [0.3, 0.4]]
        record.width = 19
        record.height = 19
        record.concreteConfig.komi = 6.5
        record.concreteConfig.boardWidth = 19
        record.concreteConfig.optionalBlackMaxTime = 3.0
        return record
    }

    @Test func snapshotCapturesGameAndConfigFields() {
        let snapshot = DraftSnapshot(record: populated(), originUUID: nil)
        #expect(snapshot.game.sgf == "(;FF[4]GM[1]SZ[19];B[dd];W[pp])")
        #expect(snapshot.game.name == "Populated")
        #expect(snapshot.game.comments?[1] == "note")
        #expect(snapshot.game.winRates?[1] == 0.42)
        #expect(snapshot.config.komi == 6.5)
        #expect(snapshot.config.optionalBlackMaxTime == 3.0)
    }

    @Test func applyCopiesEveryDraftedFieldOntoATarget() {
        let source = populated()
        let snapshot = DraftSnapshot(record: source, originUUID: nil)

        let target = GameRecord(config: Config())
        snapshot.apply(to: target)

        #expect(target.sgf == source.sgf)
        #expect(target.currentIndex == 2)
        #expect(target.name == "Populated")
        #expect(target.comments?[1] == "note")
        #expect(target.moves?[1] == "Q4")
        #expect(target.winRates?[1] == 0.42)
        #expect(target.scoreLeads?[1] == -1.5)
        #expect(target.bestMoves?[1] == "Q16")
        #expect(target.blackStones?[1] == "D16")
        #expect(target.whiteStones?[1] == "Q4")
        #expect(target.ownershipWhiteness?[1] == [0.1, 0.2])
        #expect(target.ownershipScales?[1] == [0.3, 0.4])
        #expect(target.width == 19)
        #expect(target.height == 19)
        #expect(target.concreteConfig.komi == 6.5)
        #expect(target.concreteConfig.optionalBlackMaxTime == 3.0)
    }

    @Test func applyLeavesTheTargetUuidAlone() {
        let source = populated()
        let target = GameRecord(config: Config())
        let targetUUID = target.uuid

        DraftSnapshot(record: source, originUUID: nil).apply(to: target)

        #expect(target.uuid == targetUUID)
        #expect(target.uuid != source.uuid)
    }

    @Test func snapshotRoundTripsThroughJSON() throws {
        let snapshot = DraftSnapshot(record: populated(), originUUID: UUID())
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(DraftSnapshot.self, from: data)
        #expect(decoded == snapshot)
    }

    @Test func snapshotCarriesTheCurrentVersion() {
        let snapshot = DraftSnapshot(record: populated(), originUUID: nil)
        #expect(snapshot.version == DraftSnapshot.currentVersion)
    }
}
