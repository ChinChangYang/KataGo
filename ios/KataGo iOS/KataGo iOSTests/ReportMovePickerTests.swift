//
//  ReportMovePickerTests.swift
//  KataGo AnytimeTests
//
//  Pure logic of the report's alternative-move picker: which vertices are
//  rejectable and how the quick-pick marks compose.
//

import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

@MainActor
struct ReportMovePickerTests {
    /// 9×9 report: best A1, alternative B2, engine top-4 cached, game move D4,
    /// stones on C3 (black) and G7 (white).
    private func makeModel() -> DeepReportModel {
        let model = DeepReportModel()
        model.boardWidth = 9
        model.boardHeight = 9
        model.blackVertices = ["C3"]
        model.whiteVertices = ["G7"]
        model.position = PositionSummary(winrate: 0.5, scoreLead: 0, visits: 100)
        model.candidates = [
            CandidateReport(vertex: "A1", visits: 100, winrate: 0.5, scoreLead: 0,
                            winrateDelta: 0, scoreLeadDelta: 0, pv: [],
                            ownershipDelta: [:], tenuki: nil),
            CandidateReport(vertex: "B2", visits: 50, winrate: 0.48, scoreLead: -0.5,
                            winrateDelta: -0.02, scoreLeadDelta: -0.5, pv: [],
                            ownershipDelta: [:], tenuki: nil),
        ]
        let info = AnalysisInfo(visits: 10, winrate: 0.5, scoreLead: 0,
                                utilityLcb: 0, pv: [], movesOwnership: nil)
        model.snapshotEntries = [
            SnapshotEntry(vertex: "A1", info: info),
            SnapshotEntry(vertex: "B2", info: info),
            SnapshotEntry(vertex: "B1", info: info),
            SnapshotEntry(vertex: "A2", info: info),
        ]
        model.gameMoveVertex = "D4"
        model.stage = .complete
        return model
    }

    @Test func rejectionCoversOccupiedAndBest() {
        let model = makeModel()
        // Occupied points (either color) are not pickable.
        #expect(ReportMovePickerView.pickRejection(vertex: "C3", model: model) != nil)
        #expect(ReportMovePickerView.pickRejection(vertex: "G7", model: model) != nil)
        // The best move can't be its own alternative.
        #expect(ReportMovePickerView.pickRejection(vertex: "A1", model: model)?.contains("Best") == true)
        // Empty points — including the current alternative — are fine.
        #expect(ReportMovePickerView.pickRejection(vertex: "D5", model: model) == nil)
        #expect(ReportMovePickerView.pickRejection(vertex: "B2", model: model) == nil)
    }

    @Test func quickPicksComposeWithOneMarkPerVertex() {
        let marks = ReportMovePickerView.quickPicks(model: makeModel())
        // One mark per vertex; precedence best > current alternative >
        // game move > engine rank; remaining engine entries keep their true
        // rank numbers; the unranked game move comes last.
        #expect(marks.map(\.vertex) == ["A1", "B2", "B1", "A2", "D4"])
        #expect(marks.map(\.kind) == [.bestDisallowed, .currentAlternative,
                                      .engineRank(3), .engineRank(4), .gameMove])
    }

    @Test func quickPicksDeduplicateGameMoveInsideEngineRanks() {
        let model = makeModel()
        model.gameMoveVertex = "B1"     // also engine rank 3
        let marks = ReportMovePickerView.quickPicks(model: model)
        #expect(marks.map(\.vertex) == ["A1", "B2", "B1", "A2"])
        // The game-move mark beats the rank badge, in place.
        #expect(marks.map(\.kind) == [.bestDisallowed, .currentAlternative,
                                      .gameMove, .engineRank(4)])
    }

    @Test func quickPicksSkipPassEntriesAndMissingGameMove() {
        let model = makeModel()
        model.gameMoveVertex = nil
        let info = AnalysisInfo(visits: 10, winrate: 0.5, scoreLead: 0,
                                utilityLcb: 0, pv: [], movesOwnership: nil)
        model.snapshotEntries.append(SnapshotEntry(vertex: "pass", info: info))
        let marks = ReportMovePickerView.quickPicks(model: model)
        #expect(marks.map(\.vertex) == ["A1", "B2", "B1", "A2"])
    }
}
