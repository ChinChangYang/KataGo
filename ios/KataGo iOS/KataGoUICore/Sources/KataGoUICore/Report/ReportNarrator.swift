//
//  ReportNarrator.swift
//  KataGoUICore
//
//  Deterministic fact sentences + streamed FoundationModels narration for the
//  Deep Analysis Report. The LLM NEVER computes: it rewords the facts built
//  here, under instructions forbidding invented moves or numbers. All facts
//  are in the reported side-to-move's perspective (DeepReportModel's
//  contract), and speak in the commentator register: spoken-first sentences —
//  the TV broadcast reads them aloud verbatim — where ahead/behind and its
//  qualifiers are judged by score lead, never win rate.
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

    /// The opener + the current-evaluation sentence (when the snapshot landed).
    @MainActor
    public static func positionFacts(from model: DeepReportModel) -> [String] {
        var facts: [String] = []
        let side = model.sideToMove == .black ? "Black" : "White"
        facts.append("Here we are at move \(model.moveNumber), and it's \(side)'s turn.")
        if let position = model.position {
            facts.append(evaluationSentence(side: side,
                                            winrate: position.winrate,
                                            scoreLead: position.scoreLead))
        }
        return facts
    }

    /// "Black is slightly behind — down 4 points, with a 42% win rate."
    /// Dead even under 1 point, slight under 5, plain under 15, far beyond —
    /// the win rate is reported, but never drives the stance.
    static func evaluationSentence(side: String, winrate: Float, scoreLead: Float) -> String {
        let rate = "a \(percent(winrate)) win rate"
        guard let points = pointsPhrase(scoreLead.magnitude) else {
            return "It's dead even — with \(rate) for \(side)."
        }
        let change = scoreLead > 0 ? "up \(points)" : "down \(points)"
        guard scoreLead.magnitude >= 1 else {
            return "It's dead even — \(side) is \(change), with \(rate)."
        }
        let stance = scoreLead > 0 ? "ahead" : "behind"
        let qualifier = scoreLead.magnitude < 5 ? "slightly "
            : scoreLead.magnitude < 15 ? "" : "far "
        return "\(side) is \(qualifier)\(stance) — \(change), with \(rate)."
    }

    /// One candidate's fact sentences (+ its tenuki sentence when present).
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
        let lead = candidateLeadClause(side: side, scoreLead: candidate.scoreLead)
        let noise = noiseSuffix(candidate.winrateDelta, scoreDelta: candidate.scoreLeadDelta,
                                visits: candidate.visits)
        var line: String
        if index == 0 {
            let opener = candidate.vertex == "pass"
                ? "KataGo's favorite here is simply to pass."
                : "KataGo's favorite is \(candidate.vertex)."
            line = "\(opener) \(bestEvaluationClause(side: side, winrate: candidate.winrate, winrateDelta: candidate.winrateDelta)), \(lead)\(noise)."
        } else {
            let opener = candidate.vertex == "pass"
                ? "There's also passing."
                : "There's also \(candidate.vertex)."
            line = "\(opener) That's worth a \(percent(candidate.winrate)) win rate, \(winrateChangeClause(candidate.winrateDelta)), \(lead)\(noise)."
        }
        if includeContinuation, !candidate.pv.isEmpty {
            line += " The expected continuation runs \(candidate.pv.joined(separator: ", "))."
        }
        facts.append(line)
        if let tenuki = candidate.tenuki {
            facts.append(tenukiSentence(opponentName: opponent, sideName: side,
                                        ignoredVertex: candidate.vertex,
                                        followUpVertex: tenuki.vertex,
                                        winrate: tenuki.winrate,
                                        scoreLead: tenuki.scoreLead))
        }
        return facts
    }

    /// "If White ignores Q16 and plays somewhere else, Black follows up at
    /// R10 — a 60% win rate, 2.5 points ahead." Shared by the broadcast facts
    /// and the report sheet's tenuki label.
    public static func tenukiSentence(opponentName: String, sideName: String,
                                      ignoredVertex: String, followUpVertex: String,
                                      winrate: Float, scoreLead: Float) -> String {
        let lead: String
        if scoreLead.magnitude >= 1, let points = pointsPhrase(scoreLead.magnitude) {
            lead = scoreLead > 0 ? "\(points) ahead" : "\(points) behind"
        } else {
            lead = "with the board dead even"
        }
        return "If \(opponentName) ignores \(ignoredVertex) and plays somewhere else, \(sideName) follows up at \(followUpVertex) — a \(percent(winrate)) win rate, \(lead)."
    }

    /// The pass-comparison facts (+ the contested-areas sentence when present).
    /// `split: true` (the TV broadcast) splits the head and the punishment into
    /// two facts — the pass evaluation, then the punishment — so the slide
    /// board can act each out as its sentence types. The split form also opens
    /// the contested fact with the payoff hand-off the board acts next when a
    /// best move is named. The default joins head and punishment into the
    /// report's single paragraph: head + " " + punish.
    @MainActor
    public static func passFacts(from model: DeepReportModel,
                                 split: Bool = false) -> [String] {
        guard let pass = model.passComparison else { return [] }
        let side = model.sideToMove == .black ? "Black" : "White"
        let opponent = model.sideToMove == .black ? "White" : "Black"
        let best = model.candidates.first.flatMap { $0.vertex == "pass" ? nil : $0.vertex }
        let (head, punish) = passHeadAndPunish(pass: pass, bestVertex: best,
                                               sideName: side, opponentName: opponent)
        var facts = split ? [head, punish] : [head + " " + punish]
        if !pass.contestedPoints.isEmpty {
            let regions = regionList(orderedUniqueRegions(pass.contestedPoints))
            if split, let best {
                // When this fact types, the board still shows the pass
                // scenario — the sentence announces the payoff it acts next
                // (bare → best stone → Δ).
                facts.append("If \(side) plays \(best) instead, the biggest fights are in \(regions).")
            } else {
                facts.append("The most contested areas — where ownership swings hardest between playing and passing — are \(regions).")
            }
        }
        return facts
    }

    /// The pass head-and-punishment sentence pair, shared by the report
    /// sheet's pass line and the broadcast's split pass facts. Pure over its
    /// values so the sheet's static text can call it off the model's actor.
    public static func passHeadAndPunish(pass: PassComparison, bestVertex: String?,
                                         sideName: String, opponentName: String)
        -> (head: String, punish: String) {
        // A "pass" best candidate is not a nameable point ("doesn't take
        // pass") — treat it like no best vertex.
        let named = bestVertex.flatMap { $0 == "pass" ? nil : $0 }
        let playing = named.map { "Playing \($0)" } ?? "Playing the best move instead"
        let head = "If \(sideName) just passes here, that leaves \(sideName) at a \(percent(pass.winrate)) win rate. \(worthSentence(playing: playing, winrateDelta: pass.winrateDeltaVsBest, scoreDelta: pass.scoreLeadDeltaVsBest))"
        let punish: String
        if pass.punishmentVertex == "pass" {
            punish = named.map { "And if \(sideName) doesn't take \($0), \(opponentName) simply passes in reply." }
                ?? "\(opponentName) would simply pass in reply."
        } else if let named {
            punish = "And if \(sideName) doesn't take \(named), \(opponentName) punishes at \(pass.punishmentVertex)."
        } else {
            punish = "\(opponentName) would punish at \(pass.punishmentVertex)."
        }
        return (head, punish)
    }

    // MARK: - Commentator clauses

    /// "It lifts Black to a 56% win rate, up 3% from here" — the verb agrees
    /// with the direction so a noisy down-delta never gets "lifts".
    private static func bestEvaluationClause(side: String, winrate: Float,
                                             winrateDelta: Float) -> String {
        let rate = "a \(percent(winrate)) win rate"
        guard let change = percentChange(winrateDelta) else {
            return "It keeps \(side) at \(rate), unchanged from here"
        }
        let verb = winrateDelta > 0 ? "lifts \(side) to" : "leaves \(side) at"
        return "It \(verb) \(rate), \(change) from here"
    }

    private static func winrateChangeClause(_ delta: Float) -> String {
        percentChange(delta).map { "\($0) from here" } ?? "unchanged from here"
    }

    /// "putting Black 1.8 points ahead" — stance from the score lead.
    private static func candidateLeadClause(side: String, scoreLead: Float) -> String {
        guard scoreLead.magnitude >= 1, let points = pointsPhrase(scoreLead.magnitude) else {
            return "leaving the board dead even"
        }
        return scoreLead > 0 ? "putting \(side) \(points) ahead"
            : "leaving \(side) \(points) behind"
    }

    /// "Playing A1 is worth 12% and 2 points." Sign-safe: a component that
    /// rounds away — or runs negative on probe noise — drops out rather than
    /// claiming a misleading direction; when neither survives, the move
    /// "barely changes things".
    private static func worthSentence(playing: String, winrateDelta: Float,
                                      scoreDelta: Float) -> String {
        let percentPart = winrateDelta > 0 ? wholePercent(winrateDelta) : nil
        let pointsPart = scoreDelta > 0 ? pointsPhrase(scoreDelta) : nil
        switch (percentPart, pointsPart) {
        case let (percent?, points?): return "\(playing) is worth \(percent) and \(points)."
        case let (percent?, nil): return "\(playing) is worth \(percent)."
        case let (nil, points?): return "\(playing) is worth \(points)."
        case (nil, nil): return "\(playing) barely changes things."
        }
    }

    // MARK: - Formatters

    private static func percent(_ value: Float) -> String {
        String(format: "%.0f%%", value * 100)
    }

    /// "12%"; nil when the whole percent rounds to zero.
    private static func wholePercent(_ magnitude: Float) -> String? {
        let text = String(format: "%.0f", magnitude.magnitude * 100)
        return text == "0" ? nil : "\(text)%"
    }

    /// "up 3%" / "down 1%"; nil when the whole percent rounds to zero.
    private static func percentChange(_ delta: Float) -> String? {
        wholePercent(delta).map { delta > 0 ? "up \($0)" : "down \($0)" }
    }

    /// "4 points" / "1.8 points" / "1 point"; nil when the tenths round to zero.
    private static func pointsPhrase(_ magnitude: Float) -> String? {
        let text = String(format: "%.1f", magnitude)
        let trimmed = text.hasSuffix(".0") ? String(text.dropLast(2)) : text
        guard trimmed != "0" else { return nil }
        return trimmed == "1" ? "1 point" : "\(trimmed) points"
    }

    private static func noiseSuffix(_ winrateDelta: Float, scoreDelta: Float, visits: Int) -> String {
        let small = winrateDelta.magnitude < ReportConstants.winrateNoise
            && scoreDelta.magnitude < ReportConstants.scoreNoise
        return (small && visits < ReportConstants.lowVisitThreshold) ? " — though that's within the noise" : ""
    }

    /// "the upper right, the lower left and the center" — locale-independent.
    private static func regionList(_ names: [String]) -> String {
        let articled = names.map { "the \($0)" }
        guard articled.count > 1, let last = articled.last else { return articled.first ?? "" }
        return articled.dropLast().joined(separator: ", ") + " and " + last
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
        Rules: Use ONLY the facts provided. Never invent moves, coordinates, or numbers. If a fact says an option is "within the noise", describe those options as about equally good. Write 2 to 4 short paragraphs of plain prose — no headings, no lists. Adopt \(tone.prompt).
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
