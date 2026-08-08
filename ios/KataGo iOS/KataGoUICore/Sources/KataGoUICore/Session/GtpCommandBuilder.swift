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
    /// Visit budget for a strong human-SL profile (9d and pros) — the legacy-strong
    /// 9d reference config's budget (#1209's `gtp_human9d.cfg`).
    public static let humanSLPlayMaxVisitsStrongRank = 400
    /// Visit budget for the ladder ranks (8d…25k) — the budget the #1209 ladder's
    /// ~100-ELO rungs were certified at.
    public static let humanSLPlayMaxVisitsWeakRank = 40
    /// Backstop wall-clock for a human-SL move so a slow device/large net cannot
    /// hang; on normal devices the visit budget binds first.
    public static let humanSLPlaySafetyMaxTime: Float = 60

    /// Visit budget for a human play move: 9d and pros keep the strong 400-visit
    /// budget; ladder ranks (8d…25k) play at the 40-visit calibration budget.
    /// Pro → strong is a product choice — change this one line to retune it.
    static func humanSLPlayVisitBudget(for effectiveProfile: String) -> Int {
        (effectiveProfile == "9d" || effectiveProfile.hasPrefix("Pro "))
            ? humanSLPlayMaxVisitsStrongRank : humanSLPlayMaxVisitsWeakRank
    }

    /// The `(maxVisits, maxTime)` search-budget commands for a side's move.
    /// The `AI` profile is time-bounded with unbounded visits (today's behavior);
    /// a human rank/pro profile is fixed at its per-rank visit budget (the
    /// "Time per move" magnitude is ignored), with a safety time cap.
    public static func searchBudgetCommands(effectiveProfile: String, maxTime: Float) -> [String] {
        if effectiveProfile == "AI" {
            return ["kata-set-param maxVisits \(unboundedMaxVisits)",
                    "kata-set-param maxTime \(max(maxTime, 0.5))"]
        } else {
            return ["kata-set-param maxVisits \(humanSLPlayVisitBudget(for: effectiveProfile))",
                    "kata-set-param maxTime \(humanSLPlaySafetyMaxTime)"]
        }
    }

    /// One continuous-analysis line. INTERNAL on purpose: a bare kata-analyze
    /// re-arm silently inherits a prior human-profile gen-move's sticky
    /// maxVisits=400 — app targets must use the bundles below, which embed the
    /// reset structurally instead of leaving it as a per-call-site convention.
    /// Delegates to the bridge-free tier so the literal exists exactly once.
    static func analyzeCommand(interval: Int, maxMoves: Int) -> String {
        return AnalysisCommand.analyze(interval: interval, maxMoves: maxMoves)
    }

    static func fastAnalyzeCommand(maxMoves: Int) -> String {
        return analyzeCommand(interval: 10, maxMoves: maxMoves)
    }

    /// Continuous-analysis re-arm bundle: ALWAYS precedes kata-analyze with a
    /// maxVisits reset. Every re-arm site (shared getRequestAnalysisCommands,
    /// iOS GameSplitView, macOS MainWindowController, and any future
    /// watch-driven re-arm) must use this or fastContinuousAnalyzeCommands.
    public static func continuousAnalyzeCommands(interval: Int, maxMoves: Int) -> [String] {
        return ["kata-set-param maxVisits \(unboundedMaxVisits)",
                analyzeCommand(interval: interval, maxMoves: maxMoves)]
    }

    /// The fast (0.1 s first report) variant of the bundle, for the initial
    /// arm after a position change on iOS/macOS.
    public static func fastContinuousAnalyzeCommands(maxMoves: Int) -> [String] {
        return ["kata-set-param maxVisits \(unboundedMaxVisits)",
                fastAnalyzeCommand(maxMoves: maxMoves)]
    }

    public static func genMoveAnalyzeCommands(effectiveProfile: String, maxTime: Float, interval: Int, maxMoves: Int) -> [String] {
        return searchBudgetCommands(effectiveProfile: effectiveProfile, maxTime: maxTime)
            + ["kata-search_analyze_cancellable interval \(interval) maxmoves \(maxMoves) ownership true ownershipStdev true rootInfo true"]
    }

    public static func boardSizeCommand(width: Int, height: Int) -> String {
        return AnalysisCommand.boardSize(width: width, height: height)
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
