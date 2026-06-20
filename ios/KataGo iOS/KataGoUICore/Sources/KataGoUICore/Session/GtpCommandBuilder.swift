//
//  GtpCommandBuilder.swift
//  KataGoUICore
//
//  Pure Config -> GTP command-string mapping. Relocated from ConfigModel so the
//  frozen SwiftData @Model no longer generates GTP. No side effects.
//
import Foundation

public enum GtpCommandBuilder {
    public static func analyzeCommand(interval: Int, maxMoves: Int) -> String {
        return "kata-analyze interval \(interval) maxmoves \(maxMoves) ownership true ownershipStdev true rootInfo true"
    }

    public static func fastAnalyzeCommand(maxMoves: Int) -> String {
        return analyzeCommand(interval: 10, maxMoves: maxMoves)
    }

    public static func genMoveAnalyzeCommands(maxTime: Float, interval: Int, maxMoves: Int) -> [String] {
        return [
            "kata-set-param maxTime \(max(maxTime, 0.5))",
            "kata-search_analyze_cancellable interval \(interval) maxmoves \(maxMoves) ownership true ownershipStdev true rootInfo true"]
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
