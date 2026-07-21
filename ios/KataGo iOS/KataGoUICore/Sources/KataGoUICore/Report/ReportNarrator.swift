//
//  ReportNarrator.swift
//  KataGoUICore
//
//  Deterministic fact list + streamed FoundationModels narration for the Deep
//  Analysis Report. The LLM NEVER computes: it rewords the facts built here,
//  under instructions forbidding invented moves or numbers. All facts are in
//  the reported side-to-move's perspective (DeepReportModel's contract).
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels   // Apple's on-device LLM — unavailable on tvOS
#endif

public enum ReportNarrator {
    // MARK: - Facts (pure, testable)

    @MainActor
    public static func facts(from model: DeepReportModel) -> [String] {
        positionFacts(from: model)
            + model.candidates.indices.flatMap { candidateFacts(from: model, index: $0) }
            + passFacts(from: model)
    }

    /// "Position: …" + the current-evaluation line (when the snapshot landed).
    @MainActor
    public static func positionFacts(from model: DeepReportModel) -> [String] {
        var facts: [String] = []
        let side = model.sideToMove == .black ? "Black" : "White"
        facts.append("Position: move \(model.moveNumber), \(side) to play.")
        if let position = model.position {
            facts.append("Current evaluation for \(side): \(percent(position.winrate)) win rate, \(points(position.scoreLead)) points, from \(position.visits) visits.")
        }
        return facts
    }

    /// One candidate's fact line (+ its tenuki line when present). Labels
    /// match the report UI ("Best move …" / "Alternative …").
    /// `includeContinuation: false` (the TV broadcast) drops the PV
    /// coordinate list — the slide board plays the continuation instead.
    @MainActor
    public static func candidateFacts(from model: DeepReportModel, index: Int,
                                      includeContinuation: Bool = true) -> [String] {
        guard model.candidates.indices.contains(index) else { return [] }
        let candidate = model.candidates[index]
        let side = model.sideToMove == .black ? "Black" : "White"
        let opponent = model.sideToMove == .black ? "White" : "Black"
        var facts: [String] = []
        let label = index == 0 ? "Best move" : "Alternative"
        var line = "\(label) \(candidate.vertex): \(percent(candidate.winrate)) win rate (\(signedPercent(candidate.winrateDelta)) vs the position\(noiseSuffix(candidate.winrateDelta, scoreDelta: candidate.scoreLeadDelta, visits: candidate.visits))), \(points(candidate.scoreLead)) points, \(candidate.visits) visits."
        if includeContinuation, !candidate.pv.isEmpty {
            line += " Expected continuation: \(candidate.pv.joined(separator: " "))."
        }
        facts.append(line)
        if let tenuki = candidate.tenuki {
            facts.append("If \(opponent) ignores \(candidate.vertex) (plays elsewhere), \(side) follows up with \(tenuki.vertex): \(percent(tenuki.winrate)) win rate, \(points(tenuki.scoreLead)) points.")
        }
        return facts
    }

    /// The pass-comparison facts (+ the contested-areas line when present).
    /// `split: true` (the TV broadcast) splits the sentence into two facts —
    /// the pass evaluation, then the punishment — so the slide board can act
    /// each out as its sentence types. The split form also prefixes the contested
    /// fact with "If X plays the best move at Y instead, " — the payoff hand-off
    /// the board acts out — when a best move is named. The default joins them
    /// into the single report sentence, byte-identical to the pre-split output.
    @MainActor
    public static func passFacts(from model: DeepReportModel,
                                 split: Bool = false) -> [String] {
        guard let pass = model.passComparison else { return [] }
        let side = model.sideToMove == .black ? "Black" : "White"
        let opponent = model.sideToMove == .black ? "White" : "Black"
        let best = model.candidates.first.flatMap { $0.vertex == "pass" ? nil : $0.vertex }
        let playing = best.map { "playing \($0)" } ?? "playing the best candidate"
        let head = "If \(side) passes instead: \(percent(pass.winrate)) win rate — \(playing) is worth \(signedPercent(pass.winrateDeltaVsBest)) and \(points(pass.scoreLeadDeltaVsBest)) points"
        var punish = "\(opponent) would punish at \(pass.punishmentVertex)"
        if let best {
            punish += " if \(side) doesn't play at \(best)"
        }
        var facts = split ? [head + ".", punish + "."]
                          : [head + "; " + punish + "."]
        if !pass.contestedPoints.isEmpty {
            let regions = orderedUniqueRegions(pass.contestedPoints).joined(separator: ", ")
            if split, let best {
                // When this fact types, the board still shows the pass
                // scenario — the prefix announces the payoff it acts next
                // (bare → best stone → Δ). "instead" carries the vs-passing
                // baseline, so the parenthetical trims.
                facts.append("If \(side) plays the best move at \(best) instead, the most contested areas (largest ownership swings): \(regions).")
            } else {
                facts.append("Most contested areas (largest ownership swings between playing and passing): \(regions).")
            }
        }
        return facts
    }

    private static func percent(_ value: Float) -> String {
        String(format: "%.0f%%", value * 100)
    }

    private static func signedPercent(_ value: Float) -> String {
        String(format: "%+.0f%%", value * 100)
    }

    private static func points(_ value: Float) -> String {
        String(format: "%+.1f", value)
    }

    private static func noiseSuffix(_ winrateDelta: Float, scoreDelta: Float, visits: Int) -> String {
        let small = winrateDelta.magnitude < ReportConstants.winrateNoise
            && scoreDelta.magnitude < ReportConstants.scoreNoise
        return (small && visits < ReportConstants.lowVisitThreshold) ? ", within noise" : ""
    }

    private static func orderedUniqueRegions(_ points: [ContestedPoint]) -> [String] {
        var seen = Set<String>()
        return points.compactMap { seen.insert($0.regionName).inserted ? $0.regionName : nil }
    }

    // MARK: - Narration (FoundationModels)

    /// Streams a short narrative over the facts into `model.narrative`.
    /// No-op (with a reason) when Apple Intelligence is unavailable; a thrown
    /// generation error leaves whatever partial text already streamed.
    @MainActor
    public static func narrate(model: DeepReportModel,
                               tone: CommentTone,
                               temperature: Double) async {
#if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else {
            model.narrativeUnavailableReason = "Apple Intelligence is not available on this device."
            return
        }
        let instructions = """
        You are a Go (baduk) teaching assistant. You summarize a game engine's findings for the player to move.
        Rules: Use ONLY the facts provided. Never invent moves, coordinates, or numbers. If a fact is marked "within noise", describe those options as about equally good. Write 2 to 4 short paragraphs of plain prose — no headings, no lists. Adopt \(tone.prompt).
        """
        let prompt = "Engine findings:\n" + facts(from: model).map { "- \($0)" }.joined(separator: "\n")
        do {
            let session = LanguageModelSession(instructions: instructions)
            let stream = session.streamResponse(to: prompt,
                                                options: GenerationOptions(temperature: temperature))
            for try await partial in stream {
                model.narrative = String(describing: partial.content)
            }
        } catch {
            // Keep any partial narrative; the data report stands on its own.
        }
#else
        model.narrativeUnavailableReason = "Apple Intelligence is not available on this platform."
#endif
    }
}
