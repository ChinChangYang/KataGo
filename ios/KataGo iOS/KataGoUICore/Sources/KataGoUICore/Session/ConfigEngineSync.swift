//
//  ConfigEngineSync.swift
//  KataGoUICore
//
//  Shared orchestrator: applies a Config edit and emits the matching GTP via
//  GtpCommandBuilder, re-arming analysis where required. Used by iOS ConfigView
//  and the macOS Inspector/Config-Editor controllers so both emit identical GTP.
//
import Foundation

/// Replays the GTP command(s) iOS's `ConfigView` sends for each editable
/// `Config` field. Callers mutate the `Config` property FIRST (or pass the new
/// value to the helper, which mutates it), then call the matching static func so
/// the engine receives the same command(s) the iOS `.onChange` handlers send.
///
/// All funcs are `@MainActor` (they touch `MessageList`/`GobanState`, both
/// main-actor-isolated through `GameSession`). Each func is a thin, named wrapper
/// over a single `Config` accessor + `appendAndSend`, so the macOS controllers
/// and the iOS ConfigView can reuse them.
@MainActor
public enum ConfigEngineSync {

    // MARK: Komi
    //
    // iOS `ConfigView.swift` lines 291-294 (`RuleConfigView`):
    //   config.komi = min(1_000, max(-1_000, ((Float(newValue) ?? defaultKomi) * 2).rounded() / 2))
    //   messageList.appendAndSend(command: GtpCommandBuilder.komiCommand(config.komi))
    // We clamp + half-point-round the same way, write `config.komi`, then send.

    /// Sets `config.komi` (clamped to ±1000, rounded to the nearest 0.5 exactly
    /// as iOS) and replays `komi <value>`.
    public static func setKomi(_ newValue: Float, config: Config, messageList: MessageList) {
        config.komi = min(1_000, max(-1_000, (newValue * 2).rounded() / 2))
        messageList.appendAndSend(command: GtpCommandBuilder.komiCommand(config.komi))
    }

    // MARK: Ko rule
    //
    // iOS `ConfigView.swift` lines 211-215:
    //   config.koRule = KoRule(rawValue: rawValue) ?? .simple
    //   messageList.appendAndSend(command: GtpCommandBuilder.koRuleCommand(config.koRuleText))

    /// Sets `config.koRule` and replays `kata-set-rule ko <TEXT>`.
    public static func setKoRule(_ koRule: KoRule, config: Config, messageList: MessageList) {
        config.koRule = koRule
        messageList.appendAndSend(command: GtpCommandBuilder.koRuleCommand(config.koRuleText))
    }

    // MARK: Scoring rule
    //
    // iOS `ConfigView.swift` lines 226-229:
    //   config.scoringRule = ScoringRule(rawValue: rawValue) ?? .area
    //   messageList.appendAndSend(command: GtpCommandBuilder.scoringRuleCommand(config.scoringRuleText))

    /// Sets `config.scoringRule` and replays `kata-set-rule scoring <TEXT>`.
    public static func setScoringRule(_ scoringRule: ScoringRule, config: Config, messageList: MessageList) {
        config.scoringRule = scoringRule
        messageList.appendAndSend(command: GtpCommandBuilder.scoringRuleCommand(config.scoringRuleText))
    }

    // MARK: Tax rule
    //
    // iOS `ConfigView.swift` lines 241-244:
    //   config.taxRule = TaxRule(rawValue: rawValue) ?? .none
    //   messageList.appendAndSend(command: GtpCommandBuilder.taxRuleCommand(config.taxRuleText))

    /// Sets `config.taxRule` and replays `kata-set-rule tax <TEXT>`.
    public static func setTaxRule(_ taxRule: TaxRule, config: Config, messageList: MessageList) {
        config.taxRule = taxRule
        messageList.appendAndSend(command: GtpCommandBuilder.taxRuleCommand(config.taxRuleText))
    }

    // MARK: Multi-stone suicide
    //
    // iOS `ConfigView.swift` lines 252-254 (`RuleConfigView`):
    //   config.multiStoneSuicideLegal = newValue
    //   messageList.appendAndSend(command: GtpCommandBuilder.multiStoneSuicideCommand(config.multiStoneSuicideLegal))

    /// Sets `config.multiStoneSuicideLegal` and replays
    /// `kata-set-rule suicide <bool>`.
    public static func setMultiStoneSuicideLegal(_ isOn: Bool, config: Config, messageList: MessageList) {
        config.multiStoneSuicideLegal = isOn
        messageList.appendAndSend(command: GtpCommandBuilder.multiStoneSuicideCommand(config.multiStoneSuicideLegal))
    }

    // MARK: Has button
    //
    // iOS `ConfigView.swift` lines 262-264 (`RuleConfigView`):
    //   config.hasButton = newValue
    //   messageList.appendAndSend(command: GtpCommandBuilder.hasButtonCommand(config.hasButton))

    /// Sets `config.hasButton` and replays `kata-set-rule hasButton <bool>`.
    public static func setHasButton(_ isOn: Bool, config: Config, messageList: MessageList) {
        config.hasButton = isOn
        messageList.appendAndSend(command: GtpCommandBuilder.hasButtonCommand(config.hasButton))
    }

    // MARK: White handicap bonus
    //
    // iOS `ConfigView.swift` lines 276-280 (`RuleConfigView`):
    //   config.whiteHandicapBonusRule = WhiteHandicapBonusRule(rawValue: rawValue) ?? .zero
    //   messageList.appendAndSend(command: GtpCommandBuilder.whiteHandicapBonusCommand(config.whiteHandicapBonusRuleText))
    // The picker index maps 1:1 onto `WhiteHandicapBonusRule.rawValue`
    // (both index `Config.whiteHandicapBonusRules`).

    /// Sets `config.whiteHandicapBonusRule` and replays
    /// `kata-set-rule whiteHandicapBonus <TEXT>`.
    public static func setWhiteHandicapBonusRule(_ rule: WhiteHandicapBonusRule,
                                                 config: Config,
                                                 messageList: MessageList) {
        config.whiteHandicapBonusRule = rule
        messageList.appendAndSend(command: GtpCommandBuilder.whiteHandicapBonusCommand(config.whiteHandicapBonusRuleText))
    }

    // MARK: Playout doubling advantage (White advantage)
    //
    // iOS `ConfigView.swift` lines 427-429 (`AIConfigView`):
    //   config.playoutDoublingAdvantage = newValue
    //   messageList.appendAndSend(command: GtpCommandBuilder.playoutDoublingAdvantageCommand(config.playoutDoublingAdvantage))

    /// Sets `config.playoutDoublingAdvantage` and replays
    /// `kata-set-param playoutDoublingAdvantage <value>`.
    public static func setPlayoutDoublingAdvantage(_ newValue: Float, config: Config, messageList: MessageList) {
        config.playoutDoublingAdvantage = newValue
        messageList.appendAndSend(command: GtpCommandBuilder.playoutDoublingAdvantageCommand(config.playoutDoublingAdvantage))
    }

    // MARK: Analysis wide root noise
    //
    // iOS `ConfigView.swift` lines 380-382 (`AnalysisConfigView`):
    //   config.analysisWideRootNoise = min(1, max(0, Float(newValue) ?? default))
    //   messageList.appendAndSend(command: GtpCommandBuilder.analysisWideRootNoiseCommand(config.analysisWideRootNoise))

    /// Sets `config.analysisWideRootNoise` (clamped 0...1 as iOS) and replays
    /// `kata-set-param analysisWideRootNoise <value>`.
    public static func setAnalysisWideRootNoise(_ newValue: Float, config: Config, messageList: MessageList) {
        config.analysisWideRootNoise = min(1, max(0, newValue))
        messageList.appendAndSend(command: GtpCommandBuilder.analysisWideRootNoiseCommand(config.analysisWideRootNoise))
    }

    // MARK: Human-SL profiles (per color)
    //
    // iOS `ConfigView.swift` lines 442-447 (Black) and 474-479 (White):
    //   Black: config.humanSLProfile = newValue; blackHumanSLModel.profile = newValue
    //          if player.nextColorForPlayCommand != .white {
    //              messageList.appendAndSend(commands: blackHumanSLModel.commands) }
    //   White: config.humanProfileForWhite = newValue; whiteHumanSLModel.profile = newValue
    //          if player.nextColorForPlayCommand != .black {
    //              messageList.appendAndSend(commands: whiteHumanSLModel.commands) }
    // The per-color GTP send is gated on whose turn is NOT next (so the running
    // engine isn't reconfigured mid-think for the color about to move), exactly
    // as iOS does.

    /// Sets Black's human-SL profile (`config.humanProfileForBlack`) and, when
    /// the next color to play is NOT white, replays that profile's
    /// `HumanSLModel.commands` (mirrors iOS `ConfigView` lines 442-447).
    public static func setBlackHumanProfile(_ profile: String,
                                            config: Config,
                                            player: Turn,
                                            messageList: MessageList) {
        config.humanProfileForBlack = profile
        if player.nextColorForPlayCommand != .white,
           let model = HumanSLModel(profile: profile) {
            messageList.appendAndSend(commands: model.commands)
        }
    }

    /// Sets White's human-SL profile (`config.humanProfileForWhite`) and, when
    /// the next color to play is NOT black, replays that profile's
    /// `HumanSLModel.commands` (mirrors iOS `ConfigView` lines 474-479).
    public static func setWhiteHumanProfile(_ profile: String,
                                            config: Config,
                                            player: Turn,
                                            messageList: MessageList) {
        config.humanProfileForWhite = profile
        if player.nextColorForPlayCommand != .black,
           let model = HumanSLModel(profile: profile) {
            messageList.appendAndSend(commands: model.commands)
        }
    }

    // MARK: Per-color max time
    //
    // iOS `ConfigView.swift` lines 460-461 (Black) / 492-493 (White): no GTP
    // command — the property alone is read when `getKataGenMoveAnalyzeCommands`
    // runs (`GobanState.getRequestAnalysisCommands`). So these only write the
    // `Config` prop.
    //
    // On iOS the change takes effect on the next color toggle (the hosted
    // `BoardView.onChange(of: player.nextColorForPlayCommand)` re-evaluates
    // `getRequestAnalysisCommands` → issues the gen-move). But ENABLING an AI
    // color MID-GAME (`maxTime` 0 → >0 with no color change) doesn't toggle the
    // color, so nothing re-evaluates and no gen-move is issued until the next
    // move. We therefore RE-ARM analysis after writing the value (same as
    // `setMaxAnalysisMoves`/`setAnalysisInterval`): if it's now that color's
    // turn, `getRequestAnalysisCommands` returns the gen-move set and the engine
    // generates immediately. `rearmAnalysis` no-ops when analysis is cleared /
    // not for the current player, so disabling (>0 → 0) is harmless.

    /// Sets Black's per-move max time (`config.blackMaxTime` →
    /// `optionalBlackMaxTime`) and re-arms analysis so enabling Black mid-game
    /// (0 → >0) issues the gen-move now when it's Black's turn.
    public static func setBlackMaxTime(_ seconds: Float,
                                       config: Config,
                                       gobanState: GobanState,
                                       player: Turn,
                                       messageList: MessageList) {
        config.blackMaxTime = seconds
        rearmAnalysis(config: config, gobanState: gobanState, player: player, messageList: messageList)
    }

    /// Sets White's per-move max time (`config.whiteMaxTime` →
    /// `optionalWhiteMaxTime`) and re-arms analysis so enabling White mid-game
    /// (0 → >0) issues the gen-move now when it's White's turn.
    public static func setWhiteMaxTime(_ seconds: Float,
                                       config: Config,
                                       gobanState: GobanState,
                                       player: Turn,
                                       messageList: MessageList) {
        config.whiteMaxTime = seconds
        rearmAnalysis(config: config, gobanState: gobanState, player: player, messageList: messageList)
    }

    // MARK: Analysis params (no dedicated GTP command)
    //
    // iOS `ConfigView.swift` lines 356-358 (`analysisForWhom`), 389-391
    // (`maxAnalysisMoves`), 397-399 (`analysisInterval`): each only sets the
    // `Config` property — there is NO dedicated GTP command; they are read when
    // analysis is next requested (`GtpCommandBuilder.analyzeCommand` /
    // `GtpCommandBuilder.fastAnalyzeCommand` embed `analysisInterval` +
    // `maxAnalysisMoves`). After changing `maxAnalysisMoves`/`analysisInterval`
    // we MAY re-arm so the change takes effect immediately, mirroring how iOS
    // re-requests analysis downstream.

    /// Sets `config.analysisForWhom`. No GTP command (gates which player's
    /// positions get analyzed on the next request).
    public static func setAnalysisForWhom(_ index: Int, config: Config) {
        config.analysisForWhom = index
    }

    /// Sets `config.maxAnalysisMoves` and re-arms analysis so the new `maxmoves`
    /// is sent immediately (the value is embedded in the next `kata-analyze`).
    public static func setMaxAnalysisMoves(_ value: Int,
                                           config: Config,
                                           gobanState: GobanState,
                                           player: Turn,
                                           messageList: MessageList) {
        config.maxAnalysisMoves = value
        rearmAnalysis(config: config, gobanState: gobanState, player: player, messageList: messageList)
    }

    /// Sets `config.analysisInterval` and re-arms analysis so the new `interval`
    /// is sent immediately (the value is embedded in the next `kata-analyze`).
    public static func setAnalysisInterval(_ value: Int,
                                           config: Config,
                                           gobanState: GobanState,
                                           player: Turn,
                                           messageList: MessageList) {
        config.analysisInterval = value
        rearmAnalysis(config: config, gobanState: gobanState, player: player, messageList: messageList)
    }

    /// Re-issues a continuous-analysis (or gen-move) request for the current
    /// position so a just-changed parameter (interval / maxmoves / per-color
    /// maxTime) is applied now. `getRequestAnalysisCommands` re-reads the config,
    /// so when a color was just enabled and it's that color's turn this issues
    /// the gen-move set (`kata-search_analyze_cancellable`); otherwise it
    /// re-issues `kata-analyze`. Uses the same gate iOS relies on downstream
    /// (`maybeRequestAnalysis`): it no-ops when analysis is cleared or not for
    /// the current player.
    private static func rearmAnalysis(config: Config,
                                      gobanState: GobanState,
                                      player: Turn,
                                      messageList: MessageList) {
        gobanState.maybeRequestAnalysis(
            config: config,
            nextColorForPlayCommand: player.nextColorForPlayCommand,
            messageList: messageList
        )
    }
}
