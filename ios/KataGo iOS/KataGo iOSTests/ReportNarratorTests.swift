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

    /// Commentator register: the best move and the ranked alternative each
    /// open with their own spoken-first sentence, and the tenuki fact names
    /// the opponent's color.
    @Test func factsLabelBestMoveAndNameTenukiSides() {
        let model = makeModel()
        model.candidates.append(
            CandidateReport(vertex: "C3", visits: 20, winrate: 0.30, scoreLead: -8.0,
                            winrateDelta: -0.10, scoreLeadDelta: -3.0, pv: [],
                            ownershipDelta: [:], tenuki: nil)
        )
        let joined = ReportNarrator.facts(from: model).joined(separator: "\n")
        #expect(joined.contains("KataGo's favorite is A1."))
        #expect(joined.contains("There's also C3."))
        #expect(!joined.contains("Candidate "))
        // Black to play → White is the side that might ignore A1.
        #expect(joined.contains("If White ignores A1 and plays somewhere else, Black follows up at B2"))
        // The pass facts name the punishing side's color, name the best move
        // ("Playing A1"), and condition the punishment on it.
        #expect(joined.contains("Playing A1 is worth"))
        #expect(joined.contains("And if Black doesn't take A1, White punishes at B2."))
        #expect(!joined.contains("the opponent would punish"))
    }

    /// The alternative fact keeps the plain "Alternative" label whatever the
    /// slot's source — the game-move/user-pick provenance is picker-only
    /// detail, not title text (user simplification request).
    @Test func factsKeepPlainAlternativeLabelForEverySource() {
        let model = makeModel()
        model.candidates.append(
            CandidateReport(vertex: "C3", visits: 20, winrate: 0.30, scoreLead: -8.0,
                            winrateDelta: -0.10, scoreLeadDelta: -3.0, pv: [],
                            ownershipDelta: [:], tenuki: nil)
        )
        for source: AlternativeSource in [.engine, .gameMove, .userPick] {
            model.alternativeSource = source
            let joined = ReportNarrator.facts(from: model).joined(separator: "\n")
            #expect(joined.contains("There's also C3."))
            #expect(!joined.contains("game move"))
            #expect(!joined.contains("your pick"))
        }
    }

    /// With no candidates there is no best vertex to name — the pass fact
    /// keeps the generic phrasing and no conditional clause dangles.
    @Test func passFactFallsBackWhenNoCandidates() {
        let model = makeModel()
        model.candidates = []
        let joined = ReportNarrator.facts(from: model).joined(separator: "\n")
        #expect(joined.contains("Playing the best move instead is worth"))
        #expect(joined.contains("White would punish at B2."))
        #expect(!joined.contains("doesn't take"))
    }

    /// Round 5: the UI's Playing-vs-Passing sentence names the best move and
    /// conditions the punishment on it (full clause kept even when the
    /// punishment vertex equals the best move — user decision).
    @Test func passSentenceNamesBestMoveAndConditionsPunishment() {
        let pass = PassComparison(punishmentVertex: "B2", winrate: 0.28, scoreLead: -7.0,
                                  winrateDeltaVsBest: 0.12, scoreLeadDeltaVsBest: 2.0,
                                  ownershipDelta: [:], contestedPoints: [])
        let sentence = DeepReportView.passSentence(pass: pass, bestVertex: "A1",
                                                   sideName: "Black", opponentName: "White")
        #expect(sentence == "If Black just passes here, that leaves Black at a 28% win rate. Playing A1 is worth 12% and 2 points. And if Black doesn't take A1, White punishes at B2.")
    }

    /// A "pass" best candidate is not a nameable point — the fact keeps the
    /// generic phrasing rather than "Playing pass … doesn't take pass".
    @Test func passFactTreatsPassBestCandidateAsUnnamed() {
        let model = makeModel()
        model.candidates = [
            CandidateReport(vertex: "pass", visits: 100, winrate: 0.28, scoreLead: -7.0,
                            winrateDelta: 0, scoreLeadDelta: 0, pv: [],
                            ownershipDelta: [:], tenuki: nil),
        ]
        let joined = ReportNarrator.facts(from: model).joined(separator: "\n")
        #expect(joined.contains("Playing the best move instead is worth"))
        #expect(!joined.contains("doesn't take"))
    }

    /// Same for the UI sentence when the best candidate is "pass".
    @Test func passSentenceTreatsPassBestVertexAsUnnamed() {
        let pass = PassComparison(punishmentVertex: "B2", winrate: 0.28, scoreLead: -7.0,
                                  winrateDeltaVsBest: 0.12, scoreLeadDeltaVsBest: 2.0,
                                  ownershipDelta: [:], contestedPoints: [])
        let sentence = DeepReportView.passSentence(pass: pass, bestVertex: "pass",
                                                   sideName: "Black", opponentName: "White")
        #expect(sentence == "If Black just passes here, that leaves Black at a 28% win rate. Playing the best move instead is worth 12% and 2 points. White would punish at B2.")
    }

    /// Without a best vertex the sentence keeps the unconditioned shape.
    @Test func passSentenceFallsBackWithoutBestVertex() {
        let pass = PassComparison(punishmentVertex: "B2", winrate: 0.28, scoreLead: -7.0,
                                  winrateDeltaVsBest: 0.12, scoreLeadDeltaVsBest: 2.0,
                                  ownershipDelta: [:], contestedPoints: [])
        let sentence = DeepReportView.passSentence(pass: pass, bestVertex: nil,
                                                   sideName: "Black", opponentName: "White")
        #expect(sentence == "If Black just passes here, that leaves Black at a 28% win rate. Playing the best move instead is worth 12% and 2 points. White would punish at B2.")
    }

    @Test func lowVisitSmallDeltasAreMarkedWithinNoise() {
        let model = makeModel()   // candidate delta -0.02 at 100 visits (not low)
        var facts = ReportNarrator.facts(from: model)
        #expect(!facts.joined(separator: "\n").contains("within the noise"))

        // Re-build with a low-visit candidate: same delta now within noise.
        model.candidates = [
            CandidateReport(vertex: "A1", visits: 30, winrate: 0.41, scoreLead: -4.5,
                            winrateDelta: -0.01, scoreLeadDelta: -0.5, pv: [],
                            ownershipDelta: [:], tenuki: nil),
        ]
        facts = ReportNarrator.facts(from: model)
        #expect(facts.joined(separator: "\n").contains("within the noise"))
    }

    @Test func factsAreDeterministic() {
        let a = ReportNarrator.facts(from: makeModel())
        let b = ReportNarrator.facts(from: makeModel())
        #expect(a == b)
    }

    /// The broadcast consumes facts per section; facts(from:) must be exactly
    /// the concatenation so the two surfaces can never drift.
    @Test func factsAreTheConcatenationOfSectionFacts() {
        let model = makeModel()
        let composed = ReportNarrator.positionFacts(from: model)
            + model.candidates.indices.flatMap { ReportNarrator.candidateFacts(from: model, index: $0) }
            + ReportNarrator.passFacts(from: model)
        #expect(composed == ReportNarrator.facts(from: model))
    }

    @Test func sectionFactsAreEmptyForMissingSections() {
        let model = DeepReportModel()
        model.sideToMove = .black
        #expect(ReportNarrator.positionFacts(from: model).count == 1)   // opener only
        #expect(ReportNarrator.candidateFacts(from: model, index: 0).isEmpty)
        #expect(ReportNarrator.candidateFacts(from: model, index: 5).isEmpty)
        #expect(ReportNarrator.passFacts(from: model).isEmpty)
    }

    @Test func candidateFactsCarryTenukiWhenPresent() {
        let model = makeModel()
        let facts = ReportNarrator.candidateFacts(from: model, index: 0)
        #expect(facts.count == 2)                       // candidate line + tenuki line
        #expect(facts[0].hasPrefix("KataGo's favorite is A1."))
        #expect(facts[1].contains("ignores A1"))
    }

    /// Choreography round: the broadcast drops the PV coordinate list — the
    /// board plays it instead. Exact-suffix pin: default == variant + the
    /// appendage, so the two surfaces can never drift.
    @Test func candidateFactsWithoutContinuationDropOnlyTheAppendage() {
        let model = makeModel()
        let full = ReportNarrator.candidateFacts(from: model, index: 0)
        let broadcast = ReportNarrator.candidateFacts(from: model, index: 0,
                                                      includeContinuation: false)
        #expect(full.count == broadcast.count)
        #expect(full[0] == broadcast[0] + " The expected continuation runs A1, B2.")
        #expect(full[1] == broadcast[1])                 // tenuki line untouched
        #expect(!broadcast[0].contains("expected continuation"))
    }

    /// Choreography round 2: the broadcast splits the pass paragraph so the
    /// board can act each half out. Reconstruction pin: the report's joined
    /// form is exactly head + " " + punish, so the two surfaces can never
    /// drift.
    @Test func passFactsSplitFormReJoinsIntoTheReportSentence() {
        let model = makeModel()
        let full = ReportNarrator.passFacts(from: model)
        let split = ReportNarrator.passFacts(from: model, split: true)
        #expect(full.count == 2)
        #expect(split.count == 3)
        #expect(full[0] == split[0] + " " + split[1])
        // The broadcast's contested fact opens with the playing-payoff
        // hand-off; the report keeps the full wording.
        #expect(full[1] == "The most contested areas — where ownership swings hardest between playing and passing — are the upper left.")
        #expect(split[2] == "If Black plays A1 instead, the biggest fights are in the upper left.")

        // With no contested points both forms drop the third fact only.
        model.passComparison = PassComparison(punishmentVertex: "B2", winrate: 0.28,
                                              scoreLead: -7.0, winrateDeltaVsBest: 0.12,
                                              scoreLeadDeltaVsBest: 2.0,
                                              ownershipDelta: [:], contestedPoints: [])
        let bare = ReportNarrator.passFacts(from: model)
        let bareSplit = ReportNarrator.passFacts(from: model, split: true)
        #expect(bare.count == 1)
        #expect(bareSplit.count == 2)
        #expect(bare[0] == bareSplit[0] + " " + bareSplit[1])
    }

    /// With no named best move the hand-off has no vertex to name — the
    /// broadcast keeps the report's contested sentence unchanged.
    @Test func passFactsSplitFormDropsThePrefixWithoutABestMove() {
        let model = makeModel()
        model.candidates = []
        let split = ReportNarrator.passFacts(from: model, split: true)
        #expect(split.count == 3)
        #expect(split[2] == "The most contested areas — where ownership swings hardest between playing and passing — are the upper left.")
    }

    /// The defaults guard: the broadcast variants can never leak into
    /// facts(from:) — the iOS report sheet, narration prompt, and
    /// Copy-to-Comment keep the joined paragraph and both coordinate lists.
    @Test func factsFromStillIncludesContinuationAndContested() {
        let joined = ReportNarrator.facts(from: makeModel()).joined(separator: "\n")
        #expect(joined.contains("The expected continuation runs A1, B2."))
        #expect(joined.contains("The most contested areas"))
    }
}
