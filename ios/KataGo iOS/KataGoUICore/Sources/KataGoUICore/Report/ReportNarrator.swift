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
        var facts: [String] = []
        let side = model.sideToMove == .black ? "Black" : "White"
        let opponent = model.sideToMove == .black ? "White" : "Black"
        facts.append("Position: move \(model.moveNumber), \(side) to play.")

        if let position = model.position {
            facts.append("Current evaluation for \(side): \(percent(position.winrate)) win rate, \(points(position.scoreLead)) points, from \(position.visits) visits.")
        }

        // Same labels the report UI shows ("Best Move …" / "Alternative …")
        // so Copy-to-Comment output and LLM input match what the user reads.
        for (index, candidate) in model.candidates.enumerated() {
            let label = index == 0 ? "Best move" : "Alternative"
            var line = "\(label) \(candidate.vertex): \(percent(candidate.winrate)) win rate (\(signedPercent(candidate.winrateDelta)) vs the position\(noiseSuffix(candidate.winrateDelta, scoreDelta: candidate.scoreLeadDelta, visits: candidate.visits))), \(points(candidate.scoreLead)) points, \(candidate.visits) visits."
            if !candidate.pv.isEmpty {
                line += " Expected continuation: \(candidate.pv.joined(separator: " "))."
            }
            facts.append(line)
            if let tenuki = candidate.tenuki {
                facts.append("If \(opponent) ignores \(candidate.vertex) (plays elsewhere), \(side) follows up with \(tenuki.vertex): \(percent(tenuki.winrate)) win rate, \(points(tenuki.scoreLead)) points.")
            }
        }

        if let pass = model.passComparison {
            facts.append("If \(side) passes instead: \(percent(pass.winrate)) win rate — playing the best candidate is worth \(signedPercent(pass.winrateDeltaVsBest)) and \(points(pass.scoreLeadDeltaVsBest)) points; the opponent would punish at \(pass.punishmentVertex).")
            if !pass.contestedPoints.isEmpty {
                let regions = orderedUniqueRegions(pass.contestedPoints)
                facts.append("Most contested areas (largest ownership swings between playing and passing): \(regions.joined(separator: ", ")).")
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
