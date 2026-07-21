//
//  BroadcastScriptTests.swift
//  KataGo AnytimeTests
//
//  Pure slide-building for the tvOS Deep-Report Broadcast: which slides exist
//  for a partially/fully generated report model, their titles/facts/overlays,
//  the may-still-grow signal the typewriter waits on, and word chunking.
//

import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

@MainActor
struct BroadcastScriptTests {
    private func candidate(_ vertex: String, tenuki: TenukiFollowUp? = nil,
                           delta: [BoardPoint: Float] = [:]) -> CandidateReport {
        CandidateReport(vertex: vertex, visits: 100, winrate: 0.55, scoreLead: 1.5,
                        winrateDelta: -0.01, scoreLeadDelta: -0.5, pv: [vertex, "C3"],
                        ownershipDelta: delta, tenuki: tenuki)
    }

    private func fullModel() -> DeepReportModel {
        let model = DeepReportModel()
        model.sideToMove = .black
        model.candidates = [
            candidate("Q16", tenuki: TenukiFollowUp(vertex: "R14", winrate: 0.6,
                                                    scoreLead: 2.0, visits: 40, pv: ["R14"])),
            candidate("D4", delta: [BoardPoint(x: 3, y: 3): -0.4]),
        ]
        model.passComparison = PassComparison(punishmentVertex: "Q16", winrate: 0.3,
                                              scoreLead: -5.0, winrateDeltaVsBest: 0.2,
                                              scoreLeadDeltaVsBest: 6.0,
                                              ownershipDelta: [BoardPoint(x: 15, y: 15): 0.5],
                                              contestedPoints: [])
        model.stage = .complete
        return model
    }

    @Test func fullReportYieldsThreeSlidesInOrder() {
        let slides = BroadcastScript.slides(from: fullModel())
        #expect(slides.map(\.kind) == [.best, .alternative, .pass])
        #expect(slides[0].title == "Best Move Q16")
        #expect(slides[1].title == "Alternative D4")
        #expect(slides[2].title == "Playing vs. Passing")
    }

    @Test func bestSlideLeadsWithPositionFactsAndUsesPVOverlay() {
        let model = fullModel()
        let best = BroadcastScript.slides(from: model)[0]
        #expect(best.facts.first?.hasPrefix("Position: move") == true)
        #expect(best.facts.contains { $0.hasPrefix("Best move Q16") })
        guard case .pv(let vertices, let starting) = best.overlay else {
            Issue.record("expected PV overlay"); return
        }
        #expect(vertices == ["Q16", "C3"])
        #expect(starting == .black)
        #expect(best.markedMove == nil)
    }

    @Test func alternativeSlideUsesDeltaOverlayWithMarkedMove() {
        let alternative = BroadcastScript.slides(from: fullModel())[1]
        guard case .ownershipDelta = alternative.overlay else {
            Issue.record("expected delta overlay"); return
        }
        #expect(alternative.markedMove?.vertex == "D4")
        #expect(alternative.markedMove?.color == .black)
    }

    @Test func alternativeWithoutDeltaFallsBackToPVWithoutMark() {
        let model = fullModel()
        model.candidates[1] = candidate("D4")   // empty ownershipDelta
        let alternative = BroadcastScript.slides(from: model)[1]
        guard case .pv = alternative.overlay else {
            Issue.record("expected PV fallback"); return
        }
        #expect(alternative.markedMove == nil)
    }

    @Test func passSlideMarksTheBestMove() {
        let pass = BroadcastScript.slides(from: fullModel())[2]
        #expect(pass.markedMove?.vertex == "Q16")
        #expect(pass.facts.first?.contains("passes instead") == true)
    }

    @Test func partialModelYieldsOnlyLandedSlides() {
        let model = fullModel()
        model.passComparison = nil
        model.stage = .snapshot
        #expect(BroadcastScript.slides(from: model).map(\.kind) == [.best, .alternative])
        model.candidates = []
        #expect(BroadcastScript.slides(from: model).isEmpty)
    }

    @Test func factsMayGrowOnlyWhileACandidateAwaitsTenuki() {
        let model = fullModel()
        model.stage = .tenuki(1)
        #expect(!BroadcastScript.factsMayGrow(kind: .best, model: model))        // tenuki landed
        model.candidates[1] = candidate("D4")                                     // no tenuki yet
        #expect(BroadcastScript.factsMayGrow(kind: .alternative, model: model))
        #expect(!BroadcastScript.factsMayGrow(kind: .pass, model: model))         // never grows
        model.stage = .complete
        #expect(!BroadcastScript.factsMayGrow(kind: .alternative, model: model))  // settled
    }

    @Test func stageSettlement() {
        #expect(DeepReportModel.Stage.complete.isSettled)
        #expect(DeepReportModel.Stage.failed("x").isSettled)
        #expect(DeepReportModel.Stage.cancelled.isSettled)
        #expect(!DeepReportModel.Stage.snapshot.isSettled)
        #expect(!DeepReportModel.Stage.narrating.isSettled)
    }

    @Test func typewriterChunksRoundTrip() {
        let text = "Best move Q16: 55% win rate."
        let chunks = BroadcastScript.typewriterChunks(text)
        #expect(chunks.joined() == text)
        #expect(chunks.count == 6)                 // one chunk per word incl. its space
        #expect(BroadcastScript.typewriterChunks("").isEmpty)
    }
}
