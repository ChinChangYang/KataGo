//
//  GtpCommandBuilder.swift
//  KataGoUICore
//
//  Pure Config -> GTP command-string mapping. Relocated from ConfigModel so the
//  frozen SwiftData @Model no longer generates GTP. No side effects.
//
import Foundation

public enum GtpCommandBuilder {
    // MARK: - Search budget

    /// Effectively-unbounded visit cap (the engine never reaches it within a move).
    public static let unboundedMaxVisits = 1_000_000_000
    /// Fixed visit budget for human-SL profile play — PR #1209's calibration point,
    /// at which the rank λ ladder is ~1 KGS stone apart.
    public static let humanSLPlayMaxVisits = 400
    /// Backstop wall-clock for a human-SL move so a slow device/large net cannot
    /// hang; on normal devices the 400 visits bind first.
    public static let humanSLPlaySafetyMaxTime: Float = 60

    /// The `(maxVisits, maxTime)` search-budget commands for a side's move.
    /// The `AI` profile is time-bounded with unbounded visits (today's behavior);
    /// a human rank/pro profile is fixed at `humanSLPlayMaxVisits` visits (the
    /// "Time per move" magnitude is ignored), with a safety time cap.
    public static func searchBudgetCommands(effectiveProfile: String, maxTime: Float) -> [String] {
        if effectiveProfile == "AI" {
            return ["kata-set-param maxVisits \(unboundedMaxVisits)",
                    "kata-set-param maxTime \(max(maxTime, 0.5))"]
        } else {
            return ["kata-set-param maxVisits \(humanSLPlayMaxVisits)",
                    "kata-set-param maxTime \(humanSLPlaySafetyMaxTime)"]
        }
    }

    public static func analyzeCommand(interval: Int, maxMoves: Int) -> String {
        return "kata-analyze interval \(interval) maxmoves \(maxMoves) ownership true ownershipStdev true rootInfo true"
    }

    public static func fastAnalyzeCommand(maxMoves: Int) -> String {
        return analyzeCommand(interval: 10, maxMoves: maxMoves)
    }

    public static func genMoveAnalyzeCommands(effectiveProfile: String, maxTime: Float, interval: Int, maxMoves: Int) -> [String] {
        return searchBudgetCommands(effectiveProfile: effectiveProfile, maxTime: maxTime)
            + ["kata-search_analyze_cancellable interval \(interval) maxmoves \(maxMoves) ownership true ownershipStdev true rootInfo true"]
    }

    public static func boardSizeCommand(width: Int, height: Int) -> String {
        return "rectangular_boardsize \(width) \(height)"
    }

    public static func komiCommand(_ komi: Float) -> String {
        return "komi \(komi)"
    }

    public static func playoutDoublingAdvantageCommand(_ value: Float) -> String {
        return "kata-set-param playoutDoublingAdvantage \(value)"
    }

    public static func analysisWideRootNoiseCommand(_ value: Float) -> String {
        return "kata-set-param analysisWideRootNoise \(value)"
    }

    public static func rulesetCommand(_ ruleName: String) -> String {
        return "kata-set-rules \(ruleName)"
    }

    public static func koRuleCommand(_ text: String) -> String {
        return "kata-set-rule ko \(text)"
    }

    public static func scoringRuleCommand(_ text: String) -> String {
        return "kata-set-rule scoring \(text)"
    }

    public static func taxRuleCommand(_ text: String) -> String {
        return "kata-set-rule tax \(text)"
    }

    public static func multiStoneSuicideCommand(_ legal: Bool) -> String {
        return "kata-set-rule suicide \(legal)"
    }

    public static func hasButtonCommand(_ enabled: Bool) -> String {
        return "kata-set-rule hasButton \(enabled)"
    }

    public static func whiteHandicapBonusCommand(_ text: String) -> String {
        return "kata-set-rule whiteHandicapBonus \(text)"
    }

    public static func ruleCommandsBundle(ko: String, scoring: String, tax: String,
                                          multiStoneSuicide: Bool, hasButton: Bool,
                                          whiteHandicapBonus: String) -> [String] {
        return [koRuleCommand(ko),
                scoringRuleCommand(scoring),
                taxRuleCommand(tax),
                multiStoneSuicideCommand(multiStoneSuicide),
                hasButtonCommand(hasButton),
                whiteHandicapBonusCommand(whiteHandicapBonus)]
    }

    public static func symmetricHumanAnalysisCommands(humanSLProfile: String,
                                                      humanProfileForWhite: String,
                                                      humanRatioForBlack: Float,
                                                      humanRatioForWhite: Float) -> [String] {
        let isEqual = (humanSLProfile == humanProfileForWhite) && (humanRatioForBlack == humanRatioForWhite)
        if isEqual, let model = HumanSLModel(profile: humanSLProfile) {
            return model.commands
        }
        return []
    }
}
