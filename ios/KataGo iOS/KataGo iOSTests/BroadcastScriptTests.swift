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
        #expect(best.facts.first?.hasPrefix("Here we are at move") == true)
        #expect(best.facts.contains { $0.hasPrefix("KataGo's favorite is Q16") })
    }

    @Test func passSlideNamesThePassComparison() {
        let pass = BroadcastScript.slides(from: fullModel())[2]
        #expect(pass.facts.first?.contains("just passes here") == true)
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

    // Guard tests for the kind-keyed cursor (new API — these pin the intended
    // behaviour; the regression they protect is exercised end-to-end by
    // BroadcastControllerTests.lateAlternativeNeverRebindsOrDuplicatesThePassCard).

    @Test("The cursor holds the pass card until the Alternative slot is decided")
    func cursorHoldsPassUntilAlternativeIsDecided() {
        let model = fullModel()
        model.candidates = [model.candidates[0]]     // snapshot ranked one move
        model.stage = .passProbe                     // parity probe still to come
        #expect(BroadcastScript.nextSlide(presented: [.best], model: model)
                == .waiting(.alternative))

        // Parity fills the slot: the Alternative is presented before the pass
        // card, in reading order, even though the pass section landed first.
        model.candidates.append(candidate("D4"))
        #expect(BroadcastScript.nextSlide(presented: [.best], model: model)
                == .ready(BroadcastScript.slide(of: .alternative, from: model)!))
    }

    @Test("A decided-absent Alternative releases the pass card instead of stalling")
    func decidedAbsentAlternativeDoesNotStallTheCursor() {
        let model = fullModel()
        model.candidates = [model.candidates[0]]
        model.stage = .tenuki(0)                     // past the section probes
        #expect(BroadcastScript.nextSlide(presented: [.best], model: model)
                == .ready(BroadcastScript.slide(of: .pass, from: model)!))
    }

    @Test("A position with no pass comparison finishes rather than waiting forever")
    func noPassComparisonFinishes() {
        let model = fullModel()
        model.passComparison = nil
        #expect(BroadcastScript.nextSlide(presented: [.best, .alternative], model: model)
                == .finished)
    }

    @Test("A tenuki probe that returns nothing still releases its card's grow-pin")
    func aSilentTenukiProbeReleasesTheGrowPin() {
        let model = fullModel()
        model.candidates[0] = candidate("Q16")       // probe landed nothing
        model.stage = .tenuki(0)
        #expect(BroadcastScript.factsMayGrow(kind: .best, model: model))
        model.stage = .tenuki(1)                     // candidate 0's probe is over
        #expect(!BroadcastScript.factsMayGrow(kind: .best, model: model))
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
            #expect(!joined.contains("expected continuation"))
            if slide.kind == .pass {
                // Round 2: the contested sentence returned — it types over
                // the punish-stone board; the Δ payoff follows it.
                #expect(joined.contains("biggest fights"))
            } else {
                #expect(!joined.contains("biggest fights"))
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
                                                 overlay: .none, caption: nil))
        #expect(frames[1] == BroadcastBoardFrame(
            anchor: .fact(2),
            placedStones: [],
            overlay: .pv(["Q16"], startingWith: .black),
            caption: nil))
        #expect(frames[2] == BroadcastBoardFrame(
            anchor: .afterPrevious(BroadcastConstants.pvStoneSeconds),
            placedStones: [],
            overlay: .pv(["Q16", "C3"], startingWith: .black),
            caption: nil))
    }

    @Test func bestSlideTenukiPhaseActsOutIgnoreAndFollowUp() {
        let model = fullModel()
        let best = BroadcastScript.slides(from: model)[0]
        let frames = BroadcastScript.frames(for: best, model: model)
        let beat = BroadcastConstants.choreographyBeatSeconds
        let q16 = PlacedStone(vertex: "Q16", color: .black)
        #expect(frames[3] == BroadcastBoardFrame(anchor: .fact(3), placedStones: [q16],
                                                 overlay: .none, caption: nil))
        #expect(frames[4] == BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                                 placedStones: [q16],
                                                 overlay: .none,
                                                 caption: .playsElsewhere(.white)))
        #expect(frames[5] == BroadcastBoardFrame(
            anchor: .afterPrevious(beat),
            placedStones: [q16, PlacedStone(vertex: "R14", color: .black)],
            overlay: .none,
            caption: .playsElsewhere(.white)))
        #expect(frames[5].lastMoveVertex == "R14")   // the punish stone gets the red dot
    }

    @Test func bestSlideWithoutTenukiEndsAfterPV() {
        let model = fullModel()
        model.candidates[0] = candidate("Q16")   // tenuki nil
        let best = BroadcastScript.slides(from: model)[0]
        let frames = BroadcastScript.frames(for: best, model: model)
        #expect(frames.count == 3)               // bare + pv1 + pv2, no tenuki phase
        #expect(frames.allSatisfy { $0.caption == nil })
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
                                overlay: .none, caption: nil),
            BroadcastBoardFrame(anchor: .afterPrevious(beat), placedStones: [],
                                overlay: .none, caption: nil),
            BroadcastBoardFrame(anchor: .afterPrevious(beat), placedStones: [d4],
                                overlay: .none, caption: nil),
            BroadcastBoardFrame(anchor: .afterPrevious(beat), placedStones: [d4],
                                overlay: .ownershipDelta([BoardPoint(x: 3, y: 3): -0.4]),
                                caption: nil),
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
                                                  overlay: .none, caption: nil))
        #expect(frames[5] == BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                                  placedStones: [d4],
                                                  overlay: .none,
                                                  caption: .playsElsewhere(.white)))
        #expect(frames[6] == BroadcastBoardFrame(
            anchor: .afterPrevious(beat),
            placedStones: [d4, PlacedStone(vertex: "F3", color: .black)],
            overlay: .none,
            caption: .playsElsewhere(.white)))
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
            caption: nil))
        #expect(frames[3].overlay == ReportBoardOverlay.pv(["D4", "C3"], startingWith: .black))
        #expect(frames[3].anchor == .afterPrevious(BroadcastConstants.pvStoneSeconds))
    }

    /// Round 2 (user feedback): the pass slide interleaves sentence-by-
    /// sentence — bare board while "If Black passes…" types, the chip beat,
    /// a barrier while "would punish at…" types, the punish stone, a barrier
    /// while the contested sentence types, then the payoff: bare board →
    /// best move → the Δ the static slide always showed.
    @Test func passSlideActsOutBothScenariosAndEndsCanonically() {
        let model = fullModel()
        let pass = BroadcastScript.slides(from: model)[2]
        let beat = BroadcastConstants.choreographyBeatSeconds
        #expect(BroadcastScript.frames(for: pass, model: model) == [
            BroadcastBoardFrame(anchor: .fact(0), placedStones: [],
                                overlay: .none, caption: nil),
            BroadcastBoardFrame(anchor: .afterPrevious(beat), placedStones: [],
                                overlay: .none, caption: .passes(.black)),
            BroadcastBoardFrame(anchor: .fact(1), placedStones: [],
                                overlay: .none, caption: .passes(.black)),
            BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                placedStones: [PlacedStone(vertex: "Q16", color: .white)],
                                overlay: .none, caption: .passes(.black)),
            BroadcastBoardFrame(anchor: .fact(2),
                                placedStones: [PlacedStone(vertex: "Q16", color: .white)],
                                overlay: .none, caption: .passes(.black)),
            BroadcastBoardFrame(anchor: .afterPrevious(beat), placedStones: [],
                                overlay: .none, caption: nil),
            BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                placedStones: [PlacedStone(vertex: "Q16", color: .black)],
                                overlay: .none, caption: nil),
            // Canonical end: the same board the static pass slide showed —
            // best stone marked over the Δ grid.
            BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                placedStones: [PlacedStone(vertex: "Q16", color: .black)],
                                overlay: .ownershipDelta([BoardPoint(x: 15, y: 15): 0.5]),
                                caption: nil),
        ])
    }

    /// punish == "pass" + contested non-empty: the punish frame is skipped
    /// and .fact(1)/.fact(2) become two consecutive barriers, both copies of
    /// the chip frame — a hardcoded punish barrier would place a "pass"
    /// stone (drawn off-grid).
    @Test func passSlideWithPassPunishmentUsesConsecutiveChipBarriers() {
        let model = fullModel()
        model.passComparison = PassComparison(punishmentVertex: "pass", winrate: 0.3,
                                              scoreLead: -5.0, winrateDeltaVsBest: 0.2,
                                              scoreLeadDeltaVsBest: 6.0,
                                              ownershipDelta: [BoardPoint(x: 15, y: 15): 0.5],
                                              contestedPoints: [
                                                ContestedPoint(point: BoardPoint(x: 15, y: 15),
                                                               vertex: "Q16", delta: 0.5,
                                                               regionName: "upper right"),
                                              ])
        let pass = BroadcastScript.slides(from: model)[2]
        let beat = BroadcastConstants.choreographyBeatSeconds
        #expect(BroadcastScript.frames(for: pass, model: model) == [
            BroadcastBoardFrame(anchor: .fact(0), placedStones: [],
                                overlay: .none, caption: nil),
            BroadcastBoardFrame(anchor: .afterPrevious(beat), placedStones: [],
                                overlay: .none, caption: .passes(.black)),
            BroadcastBoardFrame(anchor: .fact(1), placedStones: [],
                                overlay: .none, caption: .passes(.black)),
            BroadcastBoardFrame(anchor: .fact(2), placedStones: [],
                                overlay: .none, caption: .passes(.black)),
            BroadcastBoardFrame(anchor: .afterPrevious(beat), placedStones: [],
                                overlay: .none, caption: nil),
            BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                placedStones: [PlacedStone(vertex: "Q16", color: .black)],
                                overlay: .none, caption: nil),
            BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                placedStones: [PlacedStone(vertex: "Q16", color: .black)],
                                overlay: .ownershipDelta([BoardPoint(x: 15, y: 15): 0.5]),
                                caption: nil),
        ])
    }

    /// Contested-empty guard: no fact 2 exists, so there must be NO .fact(2)
    /// barrier — an unconditional barrier would anchor to a never-typing
    /// fact and strand the bare → best → Δ payoff.
    @Test func passSlideWithoutContestedOmitsTheSecondBarrier() {
        let model = fullModel()
        model.passComparison = PassComparison(punishmentVertex: "Q16", winrate: 0.3,
                                              scoreLead: -5.0, winrateDeltaVsBest: 0.2,
                                              scoreLeadDeltaVsBest: 6.0,
                                              ownershipDelta: [BoardPoint(x: 15, y: 15): 0.5],
                                              contestedPoints: [])
        let pass = BroadcastScript.slides(from: model)[2]
        let beat = BroadcastConstants.choreographyBeatSeconds
        #expect(BroadcastScript.frames(for: pass, model: model) == [
            BroadcastBoardFrame(anchor: .fact(0), placedStones: [],
                                overlay: .none, caption: nil),
            BroadcastBoardFrame(anchor: .afterPrevious(beat), placedStones: [],
                                overlay: .none, caption: .passes(.black)),
            BroadcastBoardFrame(anchor: .fact(1), placedStones: [],
                                overlay: .none, caption: .passes(.black)),
            BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                placedStones: [PlacedStone(vertex: "Q16", color: .white)],
                                overlay: .none, caption: .passes(.black)),
            BroadcastBoardFrame(anchor: .afterPrevious(beat), placedStones: [],
                                overlay: .none, caption: nil),
            BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                placedStones: [PlacedStone(vertex: "Q16", color: .black)],
                                overlay: .none, caption: nil),
            BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                placedStones: [PlacedStone(vertex: "Q16", color: .black)],
                                overlay: .ownershipDelta([BoardPoint(x: 15, y: 15): 0.5]),
                                caption: nil),
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
            overlay: .none, caption: nil)
        // A stone placed where one of its own color already stands is a no-op,
        // so the base order survives verbatim; "pass" places nothing.
        let stones = frame.stones(black: ["D4", "Q16"], white: ["D16"], width: 19, height: 19)
        #expect(stones.black == ["D4", "Q16"])
        #expect(stones.white == ["D16", "C3"])
        #expect(frame.lastMoveVertex == "C3")

        let empty = BroadcastBoardFrame(anchor: .fact(0), placedStones: [],
                                        overlay: .none, caption: nil)
        #expect(empty.lastMoveVertex == nil)

        let passLast = BroadcastBoardFrame(
            anchor: .fact(0),
            placedStones: [PlacedStone(vertex: "pass", color: .black)],
            overlay: .none, caption: nil)
        #expect(passLast.lastMoveVertex == nil)
    }

    @Test("A beat's placed stones capture, so a punish inside the cleared shape lands")
    func beatStonesResolveAsOneOrderedChain() {
        // 9x9 corner. White A9's only liberties are B9 and A8; Black already
        // holds B9, so Black A8 captures it. The punish then plays A9 itself —
        // a point the BASE shows as a WHITE stone, legal only once the capture
        // ahead of it has been applied. This is tenukiPhase's exact shape: the
        // capturing stone travels ahead of the punish in one placedStones list.
        let frame = BroadcastBoardFrame(
            anchor: .fact(0),
            placedStones: [PlacedStone(vertex: "A8", color: .black),
                           PlacedStone(vertex: "A9", color: .black)],
            overlay: .none, caption: nil)
        let stones = frame.stones(black: ["B9"], white: ["A9"], width: 9, height: 9)

        #expect(stones.white == [])                                 // captured
        #expect(stones.black.sorted() == ["A8", "A9", "B9"])        // punish landed
        #expect(frame.lastMoveVertex == "A9")
    }

    @Test("The real tenuki choreography resolves captures end to end")
    func tenukiChoreographyRendersACaptureCorrectly() throws {
        // Built through BroadcastScript.frames, not a hand-made frame, so this
        // covers the choreography the broadcast actually emits. 9x9: White A9's
        // last liberty is A8 (Black already holds B9), so the best move A8
        // captures it — and the tenuki punish is A9 itself, the point the
        // capture just cleared. The engine chose that punish on the board AFTER
        // the candidate was played, which is why the base still shows a white
        // stone there.
        let model = DeepReportModel()
        model.sideToMove = .black
        model.boardWidth = 9
        model.boardHeight = 9
        model.blackVertices = ["B9"]
        model.whiteVertices = ["A9"]
        model.position = PositionSummary(winrate: 0.55, scoreLead: 1.5, visits: 200)
        model.candidates = [
            CandidateReport(vertex: "A8", visits: 100, winrate: 0.6, scoreLead: 2,
                            winrateDelta: 0, scoreLeadDelta: 0, pv: ["A8"],
                            ownershipDelta: [:],
                            tenuki: TenukiFollowUp(vertex: "A9", winrate: 0.62,
                                                   scoreLead: 2.5, visits: 40, pv: ["A9"])),
        ]
        model.stage = .complete

        let best = BroadcastScript.slides(from: model).first { $0.kind == .best }
        let frames = BroadcastScript.frames(for: try #require(best), model: model)
        let final = try #require(frames.last)
        let stones = final.stones(black: model.blackVertices, white: model.whiteVertices,
                                  width: model.boardWidth, height: model.boardHeight)

        #expect(final.placedStones.map(\.vertex) == ["A8", "A9"])
        #expect(stones.white.isEmpty)                            // A9 was captured
        #expect(stones.black.sorted() == ["A8", "A9", "B9"])     // and the punish landed
    }

    @Test("A comment slide has no choreography and never grows")
    func commentSlideIsStaticAndFrameless() {
        let model = DeepReportModel()
        let slide = BroadcastSlide(kind: .comment, title: "Comment",
                                   facts: ["A synced note about this move."])
        #expect(BroadcastScript.frames(for: slide, model: model).isEmpty)
        #expect(!BroadcastScript.factsMayGrow(kind: .comment, model: model))
    }

    @Test("The standalone pass/game-over slides have no choreography and never grow")
    func standaloneSlidesAreStaticAndFrameless() {
        let model = fullModel()
        for slide in [BroadcastSlide(kind: .playedPass, title: "Black Passes",
                                     facts: ["Black passes."]),
                      BroadcastSlide(kind: .gameOver, title: "Game Over",
                                     facts: ["Both players have passed — that's the end of the game."])] {
            #expect(BroadcastScript.frames(for: slide, model: model).isEmpty)
            #expect(!BroadcastScript.factsMayGrow(kind: slide.kind, model: model))
        }
    }

    // MARK: - Beat captions (the pass/tenuki distinction)

    /// THE regression guard for commit 58155796, which collapsed the caption
    /// to a bare `PlayerColor?` and left the TV layer captioning every beat
    /// "plays elsewhere". A pass forfeits the move; a tenuki relocates it —
    /// the two beats must stay distinguishable in the frame model itself, not
    /// by convention.
    @Test("The pass beat captions .passes; a tenuki beat captions .playsElsewhere")
    func passBeatAndTenukiBeatCarryDifferentCaptions() {
        let model = fullModel()          // Black to move, so tenuki is White's
        let slides = BroadcastScript.slides(from: model)

        let passCaptions = BroadcastScript.frames(for: slides[2], model: model)
            .compactMap(\.caption)
        #expect(!passCaptions.isEmpty)
        #expect(passCaptions.allSatisfy { $0 == BeatCaption.passes(.black) })

        let tenukiCaptions = BroadcastScript.frames(for: slides[0], model: model)
            .compactMap(\.caption)
        #expect(!tenukiCaptions.isEmpty)
        #expect(tenukiCaptions.allSatisfy { $0 == BeatCaption.playsElsewhere(.white) })

        // Not merely different colors: different KINDS. Same player, same
        // case-payload, still not equal.
        #expect(BeatCaption.passes(.black) != BeatCaption.playsElsewhere(.black))
    }

    /// White to move flips both captions' colors: the pass beat is White's,
    /// the tenuki beat is Black's (the opponent of the side to move).
    @Test("Beat captions name the right player from either side")
    func beatCaptionsFollowTheSideToMove() {
        let model = fullModel()
        model.sideToMove = .white
        let slides = BroadcastScript.slides(from: model)
        #expect(BroadcastScript.frames(for: slides[2], model: model)
            .compactMap(\.caption) == [BeatCaption.passes(.white),
                                       BeatCaption.passes(.white),
                                       BeatCaption.passes(.white),
                                       BeatCaption.passes(.white)])
        #expect(BroadcastScript.frames(for: slides[0], model: model)
            .compactMap(\.caption) == [BeatCaption.playsElsewhere(.black),
                                       BeatCaption.playsElsewhere(.black)])
    }
}
