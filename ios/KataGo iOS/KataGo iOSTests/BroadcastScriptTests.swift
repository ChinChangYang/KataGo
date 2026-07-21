//
//  BroadcastScriptTests.swift
//  KataGo AnytimeTests
//
//  Pure slide-building for the tvOS Deep-Report Broadcast: which slides exist
//  for a partially/fully generated report model, their titles/facts and board
//  choreography frames, the may-still-grow signal the typewriter waits on,
//  and word chunking.
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
        model.position = PositionSummary(winrate: 0.55, scoreLead: 1.5, visits: 200)
        model.candidates = [
            candidate("Q16", tenuki: TenukiFollowUp(vertex: "R14", winrate: 0.6,
                                                    scoreLead: 2.0, visits: 40, pv: ["R14"])),
            candidate("D4", delta: [BoardPoint(x: 3, y: 3): -0.4]),
        ]
        model.passComparison = PassComparison(punishmentVertex: "Q16", winrate: 0.3,
                                              scoreLead: -5.0, winrateDeltaVsBest: 0.2,
                                              scoreLeadDeltaVsBest: 6.0,
                                              ownershipDelta: [BoardPoint(x: 15, y: 15): 0.5],
                                              contestedPoints: [
                                                ContestedPoint(point: BoardPoint(x: 15, y: 15),
                                                               vertex: "Q16", delta: 0.5,
                                                               regionName: "upper right"),
                                              ])
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

    @Test func bestSlideLeadsWithPositionFacts() {
        let best = BroadcastScript.slides(from: fullModel())[0]
        #expect(best.facts.first?.hasPrefix("Position: move") == true)
        #expect(best.facts.contains { $0.hasPrefix("Best move Q16") })
    }

    @Test func passSlideNamesThePassComparison() {
        let pass = BroadcastScript.slides(from: fullModel())[2]
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

    // MARK: - Overlay equality (frame-model prerequisite)

    @Test func reportBoardOverlayIsEquatable() {
        #expect(ReportBoardOverlay.pv(["A1"], startingWith: .black)
                == ReportBoardOverlay.pv(["A1"], startingWith: .black))
        #expect(ReportBoardOverlay.pv(["A1"], startingWith: .black)
                != ReportBoardOverlay.pv(["A1"], startingWith: .white))
        #expect(ReportBoardOverlay.ownershipDelta([BoardPoint(x: 1, y: 1): 0.5])
                == ReportBoardOverlay.ownershipDelta([BoardPoint(x: 1, y: 1): 0.5]))
        #expect(ReportBoardOverlay.ownershipDelta([:]) != ReportBoardOverlay.none)
    }

    // MARK: - Removed coordinate-list sentences (broadcast only)

    @Test func broadcastFactsCarryNoCoordinateListSentences() {
        for slide in BroadcastScript.slides(from: fullModel()) {
            let joined = slide.facts.joined(separator: "\n")
            #expect(!joined.contains("Expected continuation"))
            if slide.kind == .pass {
                // Round 2: the contested sentence returned — it types while
                // the Δ overlay shows the swings on the board.
                #expect(joined.contains("Most contested areas"))
            } else {
                #expect(!joined.contains("Most contested areas"))
            }
        }
    }

    // MARK: - Board choreography frames

    @Test func bestSlideFramesPlayPVOneStonePerFrame() {
        let model = fullModel()
        let best = BroadcastScript.slides(from: model)[0]
        let frames = BroadcastScript.frames(for: best, model: model)
        // bare open, pv1, pv2, then the 3-frame tenuki phase
        #expect(frames.count == 6)
        #expect(frames[0] == BroadcastBoardFrame(anchor: .fact(0), placedStones: [],
                                                 overlay: .none, passChip: nil))
        #expect(frames[1] == BroadcastBoardFrame(
            anchor: .fact(2),
            placedStones: [],
            overlay: .pv(["Q16"], startingWith: .black),
            passChip: nil))
        #expect(frames[2] == BroadcastBoardFrame(
            anchor: .afterPrevious(BroadcastConstants.pvStoneSeconds),
            placedStones: [],
            overlay: .pv(["Q16", "C3"], startingWith: .black),
            passChip: nil))
    }

    @Test func bestSlideTenukiPhaseActsOutIgnoreAndFollowUp() {
        let model = fullModel()
        let best = BroadcastScript.slides(from: model)[0]
        let frames = BroadcastScript.frames(for: best, model: model)
        let beat = BroadcastConstants.choreographyBeatSeconds
        let q16 = PlacedStone(vertex: "Q16", color: .black)
        #expect(frames[3] == BroadcastBoardFrame(anchor: .fact(3), placedStones: [q16],
                                                 overlay: .none, passChip: nil))
        #expect(frames[4] == BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                                 placedStones: [q16],
                                                 overlay: .none,
                                                 passChip: .playsElsewhere(.white)))
        #expect(frames[5] == BroadcastBoardFrame(
            anchor: .afterPrevious(beat),
            placedStones: [q16, PlacedStone(vertex: "R14", color: .black)],
            overlay: .none,
            passChip: .playsElsewhere(.white)))
        #expect(frames[5].lastMoveVertex == "R14")   // the punish stone gets the red dot
    }

    @Test func bestSlideWithoutTenukiEndsAfterPV() {
        let model = fullModel()
        model.candidates[0] = candidate("Q16")   // tenuki nil
        let best = BroadcastScript.slides(from: model)[0]
        let frames = BroadcastScript.frames(for: best, model: model)
        #expect(frames.count == 3)               // bare + pv1 + pv2, no tenuki phase
        #expect(frames.allSatisfy { $0.passChip == nil })
    }

    @Test func factAnchorIndexTracksPositionFactCount() {
        let model = fullModel()                  // position set → positionFacts.count == 2
        var frames = BroadcastScript.frames(for: BroadcastScript.slides(from: model)[0],
                                            model: model)
        #expect(frames[1].anchor == .fact(2))
        #expect(frames[3].anchor == .fact(3))

        model.position = nil                     // test generators legally stage candidates alone
        frames = BroadcastScript.frames(for: BroadcastScript.slides(from: model)[0],
                                        model: model)
        #expect(frames[1].anchor == .fact(1))
        #expect(frames[3].anchor == .fact(2))
    }

    @Test func alternativeSlideEntersWithBestStoneThenAltDelta() {
        let model = fullModel()
        let alternative = BroadcastScript.slides(from: model)[1]
        let beat = BroadcastConstants.choreographyBeatSeconds
        let d4 = PlacedStone(vertex: "D4", color: .black)
        #expect(BroadcastScript.frames(for: alternative, model: model) == [
            BroadcastBoardFrame(anchor: .fact(0),
                                placedStones: [PlacedStone(vertex: "Q16", color: .black)],
                                overlay: .none, passChip: nil),
            BroadcastBoardFrame(anchor: .afterPrevious(beat), placedStones: [],
                                overlay: .none, passChip: nil),
            BroadcastBoardFrame(anchor: .afterPrevious(beat), placedStones: [d4],
                                overlay: .none, passChip: nil),
            BroadcastBoardFrame(anchor: .afterPrevious(beat), placedStones: [d4],
                                overlay: .ownershipDelta([BoardPoint(x: 3, y: 3): -0.4]),
                                passChip: nil),
        ])
    }

    @Test func alternativeSlideTenukiPhaseActsOutIgnoreAndFollowUp() {
        let model = fullModel()
        model.candidates[1] = candidate("D4",
                                        tenuki: TenukiFollowUp(vertex: "F3", winrate: 0.6,
                                                               scoreLead: 2.0, visits: 30,
                                                               pv: ["F3"]),
                                        delta: [BoardPoint(x: 3, y: 3): -0.4])
        let alternative = BroadcastScript.slides(from: model)[1]
        let frames = BroadcastScript.frames(for: alternative, model: model)
        let beat = BroadcastConstants.choreographyBeatSeconds
        let d4 = PlacedStone(vertex: "D4", color: .black)
        // entry: best-stone/bare/D4/D4+Δ occupy frames[0...3]; the tenuki
        // phase occupies frames[4...6].
        #expect(frames.count == 7)
        #expect(frames[4] == BroadcastBoardFrame(anchor: .fact(1), placedStones: [d4],
                                                  overlay: .none, passChip: nil))
        #expect(frames[5] == BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                                  placedStones: [d4],
                                                  overlay: .none,
                                                  passChip: .playsElsewhere(.white)))
        #expect(frames[6] == BroadcastBoardFrame(
            anchor: .afterPrevious(beat),
            placedStones: [d4, PlacedStone(vertex: "F3", color: .black)],
            overlay: .none,
            passChip: .playsElsewhere(.white)))
        #expect(frames[6].lastMoveVertex == "F3")   // the punish stone gets the red dot
    }

    @Test func alternativeWithoutDeltaPlaysItsPVInstead() {
        let model = fullModel()
        model.candidates[1] = candidate("D4")    // empty ownershipDelta, pv ["D4", "C3"]
        let alternative = BroadcastScript.slides(from: model)[1]
        let frames = BroadcastScript.frames(for: alternative, model: model)
        // entry: best stone, bare — then PV playback (prefix 1 IS the alt stone)
        #expect(frames.count == 4)
        #expect(frames[2] == BroadcastBoardFrame(
            anchor: .afterPrevious(BroadcastConstants.choreographyBeatSeconds),
            placedStones: [],
            overlay: .pv(["D4"], startingWith: .black),
            passChip: nil))
        #expect(frames[3].overlay == ReportBoardOverlay.pv(["D4", "C3"], startingWith: .black))
        #expect(frames[3].anchor == .afterPrevious(BroadcastConstants.pvStoneSeconds))
    }

    @Test func passSlideActsOutBothScenariosAndEndsCanonically() {
        let model = fullModel()
        let pass = BroadcastScript.slides(from: model)[2]
        let beat = BroadcastConstants.choreographyBeatSeconds
        #expect(BroadcastScript.frames(for: pass, model: model) == [
            BroadcastBoardFrame(anchor: .fact(0), placedStones: [],
                                overlay: .none, passChip: nil),
            BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                placedStones: [PlacedStone(vertex: "Q16", color: .black)],
                                overlay: .none, passChip: nil),
            BroadcastBoardFrame(anchor: .afterPrevious(beat), placedStones: [],
                                overlay: .none, passChip: .passes(.black)),
            BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                placedStones: [PlacedStone(vertex: "Q16", color: .white)],
                                overlay: .none, passChip: .passes(.black)),
            // Canonical end: the same board the static pass slide showed —
            // best stone marked over the Δ grid.
            BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                placedStones: [PlacedStone(vertex: "Q16", color: .black)],
                                overlay: .ownershipDelta([BoardPoint(x: 15, y: 15): 0.5]),
                                passChip: nil),
        ])
    }

    @Test func pvOverlayNeverCoexistsWithPlacedStones() {
        let model = fullModel()
        model.candidates[1] = candidate("D4")    // force the alt-PV fallback too
        for slide in BroadcastScript.slides(from: model) {
            for frame in BroadcastScript.frames(for: slide, model: model) {
                if case .pv = frame.overlay {
                    #expect(frame.placedStones.isEmpty)
                }
            }
        }
    }

    @Test func framesNeverPlacePassVerticesOrDuplicates() {
        let model = fullModel()
        model.candidates[0] = CandidateReport(
            vertex: "pass", visits: 100, winrate: 0.5, scoreLead: 0,
            winrateDelta: 0, scoreLeadDelta: 0, pv: [], ownershipDelta: [:],
            tenuki: TenukiFollowUp(vertex: "C3", winrate: 0.5, scoreLead: 0,
                                   visits: 10, pv: []))
        model.passComparison = PassComparison(punishmentVertex: "pass", winrate: 0.3,
                                              scoreLead: -5.0, winrateDeltaVsBest: 0.2,
                                              scoreLeadDeltaVsBest: 6.0,
                                              ownershipDelta: [:], contestedPoints: [])
        for slide in BroadcastScript.slides(from: model) {
            for frame in BroadcastScript.frames(for: slide, model: model) {
                #expect(!frame.placedStones.contains { $0.vertex == "pass" })
                let vertices = frame.placedStones.map(\.vertex)
                #expect(Set(vertices).count == vertices.count)
            }
        }
    }

    @Test func framesAreEquatableAndDeterministic() {
        let model = fullModel()
        for slide in BroadcastScript.slides(from: model) {
            #expect(BroadcastScript.frames(for: slide, model: model)
                    == BroadcastScript.frames(for: slide, model: model))
        }
    }

    @Test func mergedVertexHelpersFilterPassAndDedupe() {
        let frame = BroadcastBoardFrame(
            anchor: .fact(0),
            placedStones: [PlacedStone(vertex: "Q16", color: .black),
                           PlacedStone(vertex: "pass", color: .black),
                           PlacedStone(vertex: "Q16", color: .black),
                           PlacedStone(vertex: "C3", color: .white)],
            overlay: .none, passChip: nil)
        #expect(frame.blackVertices(base: ["D4", "Q16"]) == ["D4", "Q16"])
        #expect(frame.whiteVertices(base: ["D16"]) == ["D16", "C3"])
        #expect(frame.lastMoveVertex == "C3")

        let empty = BroadcastBoardFrame(anchor: .fact(0), placedStones: [],
                                        overlay: .none, passChip: nil)
        #expect(empty.lastMoveVertex == nil)

        let passLast = BroadcastBoardFrame(
            anchor: .fact(0),
            placedStones: [PlacedStone(vertex: "pass", color: .black)],
            overlay: .none, passChip: nil)
        #expect(passLast.lastMoveVertex == nil)
    }
}
