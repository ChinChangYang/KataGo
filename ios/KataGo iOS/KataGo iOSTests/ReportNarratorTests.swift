//
//  ReportNarratorTests.swift
//  KataGo AnytimeTests
//

import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

@MainActor
struct ReportNarratorTests {
    private func makeModel() -> DeepReportModel {
        let model = DeepReportModel()
        model.moveNumber = 42
        model.sideToMove = .black
        model.position = PositionSummary(winrate: 0.42, scoreLead: -4.0, visits: 150)
        model.candidates = [
            CandidateReport(vertex: "A1", visits: 100, winrate: 0.40, scoreLead: -5.0,
                            winrateDelta: -0.02, scoreLeadDelta: -1.0, pv: ["A1", "B2"],
                            ownershipDelta: [:],
                            tenuki: TenukiFollowUp(vertex: "B2", winrate: 0.56, scoreLead: 0.5,
                                                   visits: 45, pv: ["B2", "A2"])),
        ]
        model.passComparison = PassComparison(punishmentVertex: "B2", winrate: 0.28, scoreLead: -7.0,
                                              winrateDeltaVsBest: 0.12, scoreLeadDeltaVsBest: 2.0,
                                              ownershipDelta: [:],
                                              contestedPoints: [
                                                ContestedPoint(point: BoardPoint(x: 0, y: 1),
                                                               vertex: "A2", delta: -0.4,
                                                               regionName: "upper left"),
                                              ])
        return model
    }

    @Test func factsCoverEverySection() {
        let facts = ReportNarrator.facts(from: makeModel())
        let joined = facts.joined(separator: "\n")
        #expect(joined.contains("move 42"))
        #expect(joined.contains("Black"))
        #expect(joined.contains("42%"))            // position winrate
        #expect(joined.contains("A1"))             // candidate
        #expect(joined.contains("B2"))             // tenuki reply + punishment
        #expect(joined.contains("pass"))           // pass comparison present
        #expect(joined.contains("upper left"))     // contested region
    }

    /// Round 3: facts use the report UI's labels ("Best move …", ranked
    /// alternatives) and the tenuki fact names the opponent's color.
    @Test func factsLabelBestMoveAndNameTenukiSides() {
        let model = makeModel()
        model.candidates.append(
            CandidateReport(vertex: "C3", visits: 20, winrate: 0.30, scoreLead: -8.0,
                            winrateDelta: -0.10, scoreLeadDelta: -3.0, pv: [],
                            ownershipDelta: [:], tenuki: nil)
        )
        let joined = ReportNarrator.facts(from: model).joined(separator: "\n")
        #expect(joined.contains("Best move A1:"))
        #expect(joined.contains("Alternative C3:"))
        #expect(!joined.contains("Candidate "))
        // Black to play → White is the side that might ignore A1.
        #expect(joined.contains("If White ignores A1 (plays elsewhere), Black follows up with B2"))
        // Round 4: the pass fact names the punishing side's color too.
        #expect(joined.contains("White would punish at B2"))
        #expect(!joined.contains("the opponent would punish"))
    }

    @Test func lowVisitSmallDeltasAreMarkedWithinNoise() {
        let model = makeModel()   // candidate delta -0.02 at 100 visits (not low)
        var facts = ReportNarrator.facts(from: model)
        #expect(!facts.joined(separator: "\n").contains("within noise"))

        // Re-build with a low-visit candidate: same delta now within noise.
        model.candidates = [
            CandidateReport(vertex: "A1", visits: 30, winrate: 0.41, scoreLead: -4.5,
                            winrateDelta: -0.01, scoreLeadDelta: -0.5, pv: [],
                            ownershipDelta: [:], tenuki: nil),
        ]
        facts = ReportNarrator.facts(from: model)
        #expect(facts.joined(separator: "\n").contains("within noise"))
    }

    @Test func factsAreDeterministic() {
        let a = ReportNarrator.facts(from: makeModel())
        let b = ReportNarrator.facts(from: makeModel())
        #expect(a == b)
    }
}
