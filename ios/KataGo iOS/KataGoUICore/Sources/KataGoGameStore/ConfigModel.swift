//
//  ConfigModel.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/7/1.
//

import Foundation
import SwiftData

@Model
public final class Config {
    // The iCloud servers don’t guarantee atomic processing of relationship changes,
    // so CloudKit requires all relationships to be optional.
    public var gameRecord: GameRecord?
    public var boardWidth: Int = defaultBoardWidth
    public var boardHeight: Int = defaultBoardHeight
    public var rule: Int = defaultRule
    public var komi: Float = defaultKomi
    public var playoutDoublingAdvantage: Float = defaultPlayoutDoublingAdvantage
    public var analysisWideRootNoise: Float = defaultAnalysisWideRootNoise
    public var maxAnalysisMoves: Int = defaultMaxAnalysisMoves
    public var analysisInterval: Int = defaultAnalysisInterval
    public var analysisInformation: Int = defaultAnalysisInformation
    public var hiddenAnalysisVisitRatio: Float = defaultHiddenAnalysisVisitRatio
    public var stoneStyle: Int = defaultStoneStyle
    public var showCoordinate: Bool = defaultShowCoordinate
    public var humanSLRootExploreProbWeightful: Float = defaultHumanRatio
    public var humanSLProfile: String = defaultHumanSLProfile
    public var optionalAnalysisForWhom: Int? = defaultAnalysisForWhom
    public var optionalShowOwnership: Bool? = defaultShowOwnership
    public var optionalHumanRatioForWhite: Float? = defaultHumanRatio
    public var optionalHumanProfileForWhite: String? = defaultHumanSLProfile
    public var optionalSoundEffect: Bool? = defaultSoundEffect
    public var optionalShowComments: Bool? = defaultShowComments
    public var optionalShowPass: Bool? = defaultShowPass
    public var optionalVerticalFlip: Bool? = defaultVerticalFlip
    public var optionalBlackMaxTime: Float? = defaultBlackMaxTime
    public var optionalWhiteMaxTime: Float? = defaultWhiteMaxTime
    public var optionalKoRule: Int? = defaultKoRule
    public var optionalScoringRule: Int? = defaultScoringRule
    public var optionalTaxRule: Int? = defaultTaxRule
    public var optionalMultiStoneSuicideLegal: Bool? = defaultMultiStoneSuicideLegal
    public var optionalHasButton: Bool? = defaultHasButton
    public var optionalWhiteHandicapBonusRule: Int? = defaultWhiteHandicapBonusRule
    public var optionalShowWinrateBar: Bool? = defaultShowWinrateBar
    public var optionalAnalysisStyle: Int? = defaultAnalysisStyle
    public var optionalShowCharts: Bool? = defaultShowCharts
    public var optionalUseLLM: Bool? = defaultUseLLM
    public var optionalTemperature: Float? = defaultTemperature
    public var optionalTone: Int? = defaultTone

    public init(gameRecord: GameRecord? = nil,
         boardWidth: Int = defaultBoardWidth,
         boardHeight: Int = defaultBoardHeight,
         rule: Int = defaultRule,
         komi: Float = defaultKomi,
         playoutDoublingAdvantage: Float = defaultPlayoutDoublingAdvantage,
         analysisWideRootNoise: Float = defaultAnalysisWideRootNoise,
         maxAnalysisMoves: Int = defaultMaxAnalysisMoves,
         analysisInterval: Int = defaultAnalysisInterval,
         analysisInformation: Int = defaultAnalysisInformation,
         hiddenAnalysisVisitRatio: Float = defaultHiddenAnalysisVisitRatio,
         stoneStyle: Int = defaultStoneStyle,
         showCoordinate: Bool = defaultShowCoordinate,
         humanSLRootExploreProbWeightful: Float = defaultHumanRatio,
         humanSLProfile: String = defaultHumanSLProfile,
         optionalAnalysisForWhom: Int? = defaultAnalysisForWhom,
         optionalShowOwnership: Bool? = defaultShowOwnership,
         optionalHumanRatioForWhite: Float? = defaultHumanRatio,
         optionalHumanProfileForWhite: String? = defaultHumanSLProfile,
         optionalSoundEffect: Bool? = defaultSoundEffect,
         optionalShowComments: Bool? = defaultShowComments,
         optionalShowPass: Bool? = defaultShowPass,
         optionalVerticalFlip: Bool? = defaultVerticalFlip,
         optionalBlackMaxTime: Float? = defaultBlackMaxTime,
         optionalWhiteMaxTime: Float? = defaultWhiteMaxTime,
         optionalKoRule: Int? = defaultKoRule,
         optionalScoringRule: Int? = defaultScoringRule,
         optionalTaxRule: Int? = defaultTaxRule,
         optionalMultiStoneSuicideLegal: Bool? = defaultMultiStoneSuicideLegal,
         optionalHasButton: Bool? = defaultHasButton,
         optionalWhiteHandicapBonusRule: Int? = defaultWhiteHandicapBonusRule,
         optionalShowWinrateBar: Bool? = defaultShowWinrateBar,
         optionalAnalysisStyle: Int? = defaultAnalysisStyle,
         optionalShowCharts: Bool? = defaultShowCharts,
         optionalUseLLM: Bool? = defaultUseLLM,
         optionalTemperature: Float? = defaultTemperature,
         optionalTone: Int? = defaultTone
    ) {
        self.gameRecord = gameRecord
        self.boardWidth = boardWidth
        self.boardHeight = boardHeight
        self.rule = rule
        self.komi = komi
        self.playoutDoublingAdvantage = playoutDoublingAdvantage
        self.analysisWideRootNoise = analysisWideRootNoise
        self.maxAnalysisMoves = maxAnalysisMoves
        self.analysisInterval = analysisInterval
        self.analysisInformation = analysisInformation
        self.hiddenAnalysisVisitRatio = hiddenAnalysisVisitRatio
        self.stoneStyle = stoneStyle
        self.showCoordinate = showCoordinate
        self.humanSLRootExploreProbWeightful = humanSLRootExploreProbWeightful
        self.humanSLProfile = humanSLProfile
        self.optionalAnalysisForWhom = optionalAnalysisForWhom
        self.optionalShowOwnership = optionalShowOwnership
        self.optionalHumanRatioForWhite = optionalHumanRatioForWhite
        self.optionalHumanProfileForWhite = optionalHumanProfileForWhite
        self.optionalSoundEffect = optionalSoundEffect
        self.optionalShowComments = optionalShowComments
        self.optionalShowPass = optionalShowPass
        self.optionalVerticalFlip = optionalVerticalFlip
        self.optionalBlackMaxTime = optionalBlackMaxTime
        self.optionalWhiteMaxTime = optionalWhiteMaxTime
        self.optionalKoRule = optionalKoRule
        self.optionalScoringRule = optionalScoringRule
        self.optionalTaxRule = optionalTaxRule
        self.optionalMultiStoneSuicideLegal = optionalMultiStoneSuicideLegal
        self.optionalHasButton = optionalHasButton
        self.optionalWhiteHandicapBonusRule = optionalWhiteHandicapBonusRule
        self.optionalShowWinrateBar = optionalShowWinrateBar
        self.optionalAnalysisStyle = optionalAnalysisStyle
        self.optionalShowCharts = optionalShowCharts
        self.optionalUseLLM = optionalUseLLM
        self.optionalTemperature = optionalTemperature
        self.optionalTone = optionalTone
    }

    /// A field-by-field copy, detached from any game record — the caller owns
    /// wiring `gameRecord` up, which is why it is the one property not copied.
    ///
    /// EVERY other stored property must be forwarded here. Because the
    /// initializer above defaults each parameter, a field omitted from this
    /// call does not fail to compile: the copy silently takes that field's
    /// DEFAULT instead of the source's value. That is how the six rule fields
    /// (ko, scoring, tax, multi-stone suicide, button, white handicap bonus)
    /// were lost by every `GameRecord.clone()` until this was fixed —
    /// cloning a Japanese-rules game produced a Chinese-rules copy.
    /// `configPersistedPropertiesAreAllCopied` in `ConfigModelTests` fails
    /// when the model gains a property, as the reminder to extend this list.
    public convenience init(config: Config?) {
        assert(config != nil)
        if let config = config {
            self.init(
                boardWidth: config.boardWidth,
                boardHeight: config.boardHeight,
                rule: config.rule,
                komi: config.komi,
                playoutDoublingAdvantage: config.playoutDoublingAdvantage,
                analysisWideRootNoise: config.analysisWideRootNoise,
                maxAnalysisMoves: config.maxAnalysisMoves,
                analysisInterval: config.analysisInterval,
                analysisInformation: config.analysisInformation,
                hiddenAnalysisVisitRatio: config.hiddenAnalysisVisitRatio,
                stoneStyle: config.stoneStyle,
                showCoordinate: config.showCoordinate,
                humanSLRootExploreProbWeightful: config.humanSLRootExploreProbWeightful,
                humanSLProfile: config.humanSLProfile,
                optionalAnalysisForWhom: config.optionalAnalysisForWhom,
                optionalShowOwnership: config.optionalShowOwnership,
                optionalHumanRatioForWhite: config.optionalHumanRatioForWhite,
                optionalHumanProfileForWhite: config.optionalHumanProfileForWhite,
                optionalSoundEffect: config.optionalSoundEffect,
                optionalShowComments: config.optionalShowComments,
                optionalShowPass: config.optionalShowPass,
                optionalVerticalFlip: config.optionalVerticalFlip,
                optionalBlackMaxTime: config.optionalBlackMaxTime,
                optionalWhiteMaxTime: config.optionalWhiteMaxTime,
                optionalKoRule: config.optionalKoRule,
                optionalScoringRule: config.optionalScoringRule,
                optionalTaxRule: config.optionalTaxRule,
                optionalMultiStoneSuicideLegal: config.optionalMultiStoneSuicideLegal,
                optionalHasButton: config.optionalHasButton,
                optionalWhiteHandicapBonusRule: config.optionalWhiteHandicapBonusRule,
                optionalShowWinrateBar: config.optionalShowWinrateBar,
                optionalAnalysisStyle: config.optionalAnalysisStyle,
                optionalShowCharts: config.optionalShowCharts,
                optionalUseLLM: config.optionalUseLLM,
                optionalTemperature: config.optionalTemperature,
                optionalTone: config.optionalTone
            )
        } else {
            self.init()
        }
    }
}

extension Config {
    /// Whether an opening book *could* apply to this board (pure-config
    /// eligibility): a square board whose size has a published book (6...9).
    /// Whether such a book is actually downloaded/loaded is a runtime concern
    /// checked separately via `BookLookup.isAvailable(forBoardSize:)` /
    /// `isReady(forBoardSize:)`.
    public var isBookEligible: Bool {
        boardWidth == boardHeight && (6...9).contains(boardWidth)
    }
}

extension Config {
    /// Label shown beside the human-player icon when a side is played by a person.
    public static let humanPlayerLabel = "Human"

    /// The name shown beside a color's captured-stone count.
    ///
    /// A side with a positive per-move thinking time is generated by the engine,
    /// so we show its profile (e.g. "AI" by default, or a human-SL profile such
    /// as "9d"). A side with zero thinking time is played by a person and
    /// reads "Human". The `.unknown` color has no label.
    public func playerLabel(for color: PlayerColor) -> String {
        switch color {
        case .black:
            return blackMaxTime > 0 ? humanProfileForBlack : Config.humanPlayerLabel
        case .white:
            return whiteMaxTime > 0 ? humanProfileForWhite : Config.humanPlayerLabel
        case .unknown:
            return ""
        }
    }
}

extension Config {
    /// The per-move thinking time (seconds) a side is given when the user taps
    /// its AI/Human label to enable AI. The Config form can still set any other
    /// value; this is only the quick-toggle default.
    public static let toggleAIThinkingTime: Float = 0.5

    /// The new per-move max time for `color` when its AI/Human label is tapped:
    /// a side that is currently AI (time > 0) becomes `0` (human); a side that is
    /// currently human (`0`) becomes `toggleAIThinkingTime` (0.5s). `.unknown`
    /// returns `0` (no-op).
    public func toggledMaxTime(for color: PlayerColor) -> Float {
        switch color {
        case .black: return blackMaxTime > 0 ? 0 : Config.toggleAIThinkingTime
        case .white: return whiteMaxTime > 0 ? 0 : Config.toggleAIThinkingTime
        case .unknown: return 0
        }
    }
}

extension Config {
    public static let defaultBoardWidth = 19
    public static let defaultBoardHeight = 19
    public static let defaultKomi: Float = 7.0
    public static let defaultPlayoutDoublingAdvantage: Float = 0.0
    public static let defaultAnalysisWideRootNoise: Float = 0.03125
    public static let defaultMaxAnalysisMoves = 50
    public static let defaultAnalysisInterval = 50
    public static let defaultHiddenAnalysisVisitRatio: Float = 0.03125
}

extension Config {
    /// The SGF-canonical, locale-independent komi rendering: an integer when the
    /// value is whole (`7`), else `%g`-trimmed (`6.5`). The single source of truth
    /// shared by the SGF `KM[]` field (`GameRecord.komiSgfField`) and the macOS
    /// config / inspector / new-game komi labels. Keep it locale-independent so a
    /// display tweak can never corrupt the machine-parsed SGF field.
    public static func komiText(_ komi: Float) -> String {
        komi == komi.rounded() ? String(Int(komi)) : String(format: "%g", komi)
    }

    /// A compact seconds rendering: `"30s"` when whole, else `%g`-trimmed
    /// (`"1.5s"`). Shared by the macOS config editor and inspector time fields.
    public static func secondsText(_ seconds: Float) -> String {
        seconds == seconds.rounded() ? "\(Int(seconds))s" : String(format: "%gs", seconds)
    }
}

extension Config {
    public static let defaultRule = 0
    /// Sentinel stored in `rule` when the granular knobs match no named
    /// ruleset (a hand-edited "Custom" combination). Readers treat any
    /// out-of-range index the same way.
    public static let customRule = -1
    /// Named-ruleset tokens, indexed by the persisted `rule` field. Synced
    /// records store the index, so this array is APPEND-ONLY: the first six
    /// entries keep their historical positions.
    public static let rules = ["chinese", "japanese", "korean", "aga", "bga", "new-zealand",
                               "tromp-taylor", "chinese-ogs", "stone-scoring", "aga-button",
                               "ancient-territory"]
}

extension Config {
    public static let defaultAnalysisInformation = 2
    public static let analysisInformationWinrate = "Winrate"
    public static let analysisInformationScore = "Score"
    public static let analysisInformationAll = "All"
    public static let analysisInformationNone = "None"

    public static let analysisInformations = [analysisInformationWinrate,
                                       analysisInformationScore,
                                       analysisInformationAll,
                                       analysisInformationNone]

    public static let defaultAnalysisInformationText = analysisInformations[defaultAnalysisInformation]

    public var analysisInformationText: String {
        guard analysisInformation < Config.analysisInformations.count else {
            return Config.defaultAnalysisInformationText
        }

        return Config.analysisInformations[analysisInformation]
    }

    public var isAnalysisInformationWinrate: Bool {
        guard (0..<Config.analysisInformations.count).contains(analysisInformation) else { return false }
        return Config.analysisInformations[analysisInformation] == Config.analysisInformationWinrate
    }

    public var isAnalysisInformationScore: Bool {
        guard (0..<Config.analysisInformations.count).contains(analysisInformation) else { return false }
        return Config.analysisInformations[analysisInformation] == Config.analysisInformationScore
    }

    public var isAnalysisInformationAll: Bool {
        guard (0..<Config.analysisInformations.count).contains(analysisInformation) else { return false }
        return Config.analysisInformations[analysisInformation] == Config.analysisInformationAll
    }

    public var isAnalysisInformationNone: Bool {
        guard (0..<Config.analysisInformations.count).contains(analysisInformation) else { return false }
        return Config.analysisInformations[analysisInformation] == Config.analysisInformationNone
    }
}

extension Config {
    public static let fastStoneStyle = "Fast"
    public static let classicStoneStyle = "Classic"
    public static let stoneStyles = [fastStoneStyle, classicStoneStyle]
    /// Classic (index 1). Fast held this slot from 829a9dbd (2024-07-11) for
    /// render cost alone: the old per-stone view tree ran ~76 ms per frame on
    /// a dense 19x19. The `Canvas`-of-symbols renderer in `StoneView` brought
    /// that to ~0.9 ms — `StoneRenderPerfTests` guards it at 20 ms — so the
    /// default is no longer a performance choice.
    ///
    /// ⚠️ Do NOT change this by reordering `stoneStyles`. The INDEX is what
    /// persists, in both the `GlobalSettings.stoneStyle` UserDefaults key and
    /// the SwiftData `Config.stoneStyle` column, so a reorder silently
    /// reinterprets every value already stored on device and in CloudKit.
    public static let defaultStoneStyle = 1
    public static let defaultStoneStyleText = stoneStyles[defaultStoneStyle]

    public var stoneStyleText: String {
        // Full-range check, not just the upper bound: `stoneStyle` arrives from
        // UserDefaults and SwiftData, so a negative is reachable input and would
        // trap on the subscript below.
        guard Config.stoneStyles.indices.contains(stoneStyle) else {
            return Config.defaultStoneStyleText
        }

        return Config.stoneStyles[stoneStyle]
    }

    public var isFastStoneStyle: Bool {
        guard (0..<Config.stoneStyles.count).contains(stoneStyle) else { return false }
        return Config.stoneStyles[stoneStyle] == Config.fastStoneStyle
    }

    public var isClassicStoneStyle: Bool {
        Config.isClassicStoneStyle(atIndex: stoneStyle)
    }

    /// Index form of `isClassicStoneStyle`, for the surfaces that hold a raw
    /// `GlobalSettings.stoneStyle` index instead of a `Config` — the photo
    /// import preview and the GIF exporter both read the key directly. An
    /// out-of-range index reports `false` rather than trapping, matching the
    /// instance property.
    ///
    /// `GobanState.isClassicStoneStyle` also holds a raw index and deliberately
    /// does *not* delegate here. It is one of six sibling helpers there
    /// (`isClassicAnalysisStyle`, the four `isAnalysisInformation*`) that share
    /// a single bounds-checking idiom; routing one of the six through this
    /// function would trade a small duplication for an inconsistent block.
    public static func isClassicStoneStyle(atIndex index: Int) -> Bool {
        stoneStyles.indices.contains(index) && stoneStyles[index] == classicStoneStyle
    }
}

extension Config {
    // Display strings for the move-number picker. Order must match the
    // MoveNumberStyle raw values.
    public static let lastThreeMovesNumberStyle = "Last 3 moves"
    public static let lastMoveNumberStyle = "Last move"
    public static let allMovesNumberStyle = "All moves"
    public static let lastMoveMarkerNumberStyle = "Marker"
    public static let moveNumberStyles = [lastThreeMovesNumberStyle,
                                   lastMoveNumberStyle,
                                   allMovesNumberStyle,
                                   lastMoveMarkerNumberStyle]
    public static let defaultMoveNumberStyle = 0
    public static let defaultMoveNumberStyleText = moveNumberStyles[defaultMoveNumberStyle]
}

extension Config {
    public static let defaultShowCoordinate = true
}

extension Config {
    public static let defaultHumanRatio: Float = 0
}

extension Config {
    public static let defaultHumanSLProfile = "AI"
}

extension Config {
    public static let defaultAnalysisForWhom = 0
    public static let analysisForBoth = "Both"
    public static let analysisForBlack = "Black"
    public static let analysisForWhite = "White"

    public static let analysisForWhoms = [analysisForBoth,
                                   analysisForBlack,
                                   analysisForWhite]

    public static let defaultAnalysisForWhomText = analysisForWhoms[defaultAnalysisForWhom]

    public var analysisForWhom: Int {
        get {
            return optionalAnalysisForWhom ?? Config.defaultAnalysisForWhom
        }

        set(newAnalysisForWhom) {
            optionalAnalysisForWhom = newAnalysisForWhom
        }
    }

    public var analysisForWhomText: String {
        guard analysisForWhom < Config.analysisForWhoms.count else { return Config.defaultAnalysisForWhomText }
        return Config.analysisForWhoms[analysisForWhom]
    }

    private var isAnalysisForBlack: Bool {
        guard (0..<Config.analysisForWhoms.count).contains(analysisForWhom) else { return false }
        return Config.analysisForWhoms[analysisForWhom] == Config.analysisForBlack
    }

    private var isAnalysisForWhite: Bool {
        guard (0..<Config.analysisForWhoms.count).contains(analysisForWhom) else { return false }
        return Config.analysisForWhoms[analysisForWhom] == Config.analysisForWhite
    }

    public func isAnalysisForCurrentPlayer(nextColorForPlayCommand: PlayerColor) -> Bool {
        return (nextColorForPlayCommand != .unknown) &&
        ((isAnalysisForBlack && nextColorForPlayCommand == .black) ||
         (isAnalysisForWhite && nextColorForPlayCommand == .white) ||
         (!isAnalysisForBlack && !isAnalysisForWhite))
    }
}

extension Config {
    public static let defaultShowOwnership = true

    public var showOwnership: Bool {
        get {
            return optionalShowOwnership ?? Config.defaultShowOwnership
        }

        set(newShowOwnership) {
            optionalShowOwnership = newShowOwnership
        }
    }
}

extension Config {
    public var humanProfileForBlack: String {
        get {
            return humanSLProfile
        }
        
        set(newValue) {
            humanSLProfile = newValue
        }
    }

    public var humanRatioForBlack: Float {
        get {
            return humanSLRootExploreProbWeightful
        }
        
        set(newValue) {
            humanSLRootExploreProbWeightful = newValue
        }
    }
}

extension Config {
    public var humanProfileForWhite: String {
        get {
            return optionalHumanProfileForWhite ?? Config.defaultHumanSLProfile
        }

        set(newHumanProfileForWhite) {
            optionalHumanProfileForWhite = newHumanProfileForWhite
        }
    }

    public var humanRatioForWhite: Float {
        get {
            return optionalHumanRatioForWhite ?? Config.defaultHumanRatio
        }

        set(newHumanRatioForWhite) {
            optionalHumanRatioForWhite = newHumanRatioForWhite
        }
    }

    public var isEqualBlackWhiteHumanSettings: Bool {
        return (humanSLProfile == humanProfileForWhite) && (humanRatioForBlack == humanRatioForWhite)
    }
}

extension Config {
    /// The human-SL profile that should actually drive analysis and gen-move for a
    /// side, accounting for whether that side is currently played by a person.
    ///
    /// A side with zero per-move thinking time reads "Human" (see
    /// `playerLabel(for:)`); its analysis must be produced by the strongest net,
    /// i.e. the `"AI"` profile — `HumanSLModel(profile: "AI")` zeroes the
    /// human-style bias (`humanSLChosenMoveProp 0`,
    /// `humanSLRootExploreProbWeightless 0`, `winLossUtilityFactor 1`). A side with
    /// a positive thinking time is played by the engine and keeps its configured
    /// human-style profile. `"AI"` is the same sentinel the auto-play path already
    /// uses for best-AI analysis.
    public var effectiveHumanProfileForBlack: String {
        blackMaxTime > 0 ? humanProfileForBlack : "AI"
    }

    public var effectiveHumanProfileForWhite: String {
        whiteMaxTime > 0 ? humanProfileForWhite : "AI"
    }

    /// Like `isEqualBlackWhiteHumanSettings`, but over the *effective* profiles so a
    /// side toggled to Human (→ `"AI"`) is correctly treated as different from an AI
    /// side running a human-style profile. Drives symmetric-vs-asymmetric routing
    /// of the human-SL analysis commands.
    public var isEqualBlackWhiteEffectiveHumanSettings: Bool {
        return (effectiveHumanProfileForBlack == effectiveHumanProfileForWhite)
            && (humanRatioForBlack == humanRatioForWhite)
    }
}

extension Config {
    public static let defaultSoundEffect = true

    public var soundEffect: Bool {
        get {
            return optionalSoundEffect ?? Config.defaultSoundEffect
        }

        set(newSoundEffect) {
            optionalSoundEffect = newSoundEffect
        }
    }
}

extension Config {
    public static let defaultShowComments = false

    public var showComments: Bool {
        get {
            return optionalShowComments ?? Config.defaultShowComments
        }

        set(newShowComments) {
            optionalShowComments = newShowComments
        }
    }
}

extension Config {
    public static let defaultShowPass = true

    public var showPass: Bool {
        get {
            return optionalShowPass ?? Config.defaultShowPass
        }
        
        set(newShowPass) {
            optionalShowPass = newShowPass
        }
    }
}

extension Config {
    public static let defaultVerticalFlip = false
    public static let compatibleVerticalFlip = true

    public var verticalFlip: Bool {
        get {
            return optionalVerticalFlip ?? Config.compatibleVerticalFlip
        }
        
        set(newVerticalFlip) {
            optionalVerticalFlip = newVerticalFlip
        }
    }
}

extension Config {
    public static let defaultBlackMaxTime: Float = 0.0

    public var blackMaxTime: Float {
        get {
            return optionalBlackMaxTime ?? Config.defaultBlackMaxTime
        }
        
        set(newValue) {
            optionalBlackMaxTime = newValue
        }
    }
}

extension Config {
    public static let defaultWhiteMaxTime: Float = 0.0
    
    public var whiteMaxTime: Float {
        get {
            return optionalWhiteMaxTime ?? Config.defaultWhiteMaxTime
        }
        
        set(newValue) {
            optionalWhiteMaxTime = newValue
        }
    }
}

extension Config {
    public static let defaultKoRule: Int = 0
    public static let koRules = ["SIMPLE", "POSITIONAL", "SITUATIONAL"]
    public static let defaultKoRuleText = koRules[defaultKoRule]

    public var koRule: KoRule {
        get {
            return KoRule(rawValue: optionalKoRule ?? Config.defaultKoRule) ?? .simple
        }

        set(newValue) {
            optionalKoRule = newValue.rawValue
        }
    }

    public var koRuleText: String {
        guard koRule.rawValue < Config.koRules.count else { return "" }
        return Config.koRules[koRule.rawValue]
    }

    public static let defaultScoringRule: Int = 0
    public static let scoringRules = ["AREA", "TERRITORY"]
    public static let defaultScoringRuleText = scoringRules[defaultScoringRule]

    public var scoringRule: ScoringRule {
        get {
            return ScoringRule(rawValue: optionalScoringRule ?? Config.defaultScoringRule) ?? .area
        }
        
        set(newValue) {
            optionalScoringRule = newValue.rawValue
        }
    }

    public var scoringRuleText: String {
        guard scoringRule.rawValue < Config.scoringRules.count else { return "" }
        return Config.scoringRules[scoringRule.rawValue]
    }

    public static let defaultTaxRule: Int = 0
    public static let taxRules = ["NONE", "SEKI", "ALL"]
    public static let defaultTaxRuleText = taxRules[defaultTaxRule]

    public var taxRule: TaxRule {
        get {
            return TaxRule(rawValue: optionalTaxRule ?? Config.defaultTaxRule) ?? .none
        }
        
        set(newValue) {
            optionalTaxRule = newValue.rawValue
        }
    }

    public var taxRuleText: String {
        guard taxRule.rawValue < Config.taxRules.count else { return "" }
        return Config.taxRules[taxRule.rawValue]
    }

    public static let defaultMultiStoneSuicideLegal: Bool = false

    public var multiStoneSuicideLegal: Bool {
        get {
            return optionalMultiStoneSuicideLegal ?? Config.defaultMultiStoneSuicideLegal
        }

        set(newValue) {
            optionalMultiStoneSuicideLegal = newValue
        }
    }

    public static let defaultHasButton: Bool = false

    public var hasButton: Bool {
        get {
            return optionalHasButton ?? Config.defaultHasButton
        }

        set(newValue) {
            optionalHasButton = newValue
        }
    }

    public static let defaultWhiteHandicapBonusRule: Int = 0
    /// Ordered by `WhiteHandicapBonusRule.rawValue` (matching the C++
    /// `Rules::WHB_*` constants), so `whiteHandicapBonusRuleText` names the
    /// rule the bridge parsed. Historically this was `["0", "N-1", "N"]`,
    /// which made SGF-loaded games replay the wrong whb token.
    public static let whiteHandicapBonusRules = ["0", "N", "N-1"]
    public static let defaultWhiteHandicapBonusRuleText = whiteHandicapBonusRules[defaultWhiteHandicapBonusRule]

    public var whiteHandicapBonusRule: WhiteHandicapBonusRule {
        get {
            return WhiteHandicapBonusRule(rawValue: optionalWhiteHandicapBonusRule ?? Config.defaultWhiteHandicapBonusRule) ?? .zero
        }

        set(newValue) {
            optionalWhiteHandicapBonusRule = newValue.rawValue
        }
    }

    public var whiteHandicapBonusRuleText: String {
        guard whiteHandicapBonusRule.rawValue < Config.whiteHandicapBonusRules.count else { return "" }
        return Config.whiteHandicapBonusRules[whiteHandicapBonusRule.rawValue]
    }
}

extension Config {
    public static let defaultShowWinrateBar: Bool = true

    public var showWinrateBar: Bool {
        get {
            return optionalShowWinrateBar ?? Config.defaultShowWinrateBar
        }

        set(newValue) {
            optionalShowWinrateBar = newValue
        }
    }
}

extension Config {
    public static let fastAnalysisStyle = "Fast"
    public static let classicAnalysisStyle = "Classic"
    public static let analysisStyles = [fastAnalysisStyle, classicAnalysisStyle]
    public static let defaultAnalysisStyle = 0
    public static let defaultAnalysisStyleText = analysisStyles[defaultAnalysisStyle]

    public var analysisStyle: Int {
        get {
            return optionalAnalysisStyle ?? Config.defaultAnalysisStyle
        }
        
        set(newValue) {
            optionalAnalysisStyle = newValue
        }
    }

    public var analysisStyleText: String {
        guard analysisStyle < Config.analysisStyles.count else {
            return Config.defaultAnalysisStyleText
        }

        return Config.analysisStyles[analysisStyle]
    }

    public var isFastAnalysisStyle: Bool {
        guard (0..<Config.analysisStyles.count).contains(analysisStyle) else { return false }
        return Config.analysisStyles[analysisStyle] == Config.fastAnalysisStyle
    }

    public var isClassicAnalysisStyle: Bool {
        guard (0..<Config.analysisStyles.count).contains(analysisStyle) else { return false }
        return Config.analysisStyles[analysisStyle] == Config.classicAnalysisStyle
    }
}

extension Config {
    public static let defaultShowCharts: Bool = true

    public var showCharts: Bool {
        get {
            return optionalShowCharts ?? Config.defaultShowCharts
        }
        
        set(newValue) {
            optionalShowCharts = newValue
        }
    }
}

extension Config {
    public static let defaultUseLLM: Bool = false

    public var useLLM: Bool {
        get {
            return optionalUseLLM ?? Config.defaultUseLLM
        }
        
        set(newValue) {
            optionalUseLLM = newValue
        }
    }
}

extension Config {
    public static let defaultTemperature: Float = 0.5

    public var temperature: Float {
        get {
            return optionalTemperature ?? Config.defaultTemperature
        }

        set(newValue) {
            optionalTemperature = newValue
        }
    }
}

extension Config {
    public static let defaultTone: Int = 0
    public static let tones = ["Technical", "Educational", "Encouraging", "Enthusiastic", "Poetic"]
    public static let defaultToneText = tones[defaultTone]

    public var tone: CommentTone {
        get {
            return CommentTone(rawValue: optionalTone ?? Config.defaultTone) ?? .technical
        }

        set(newValue) {
            optionalTone = newValue.rawValue
        }
    }

    public var toneText: String {
        guard tone.rawValue < Config.tones.count else { return "" }
        return Config.tones[tone.rawValue]
    }
}
