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
    public var isBookCompatible: Bool {
        boardWidth == 9 && boardHeight == 9
    }
}

extension Config {
    public func getKataAnalyzeCommand(analysisInterval: Int) -> String {
        return "kata-analyze interval \(analysisInterval) maxmoves \(maxAnalysisMoves) ownership true ownershipStdev true rootInfo true"
    }

    public func getKataAnalyzeCommand() -> String {
        return getKataAnalyzeCommand(analysisInterval: analysisInterval)
    }

    public func getKataFastAnalyzeCommand() -> String {
        return getKataAnalyzeCommand(analysisInterval: 10);
    }

    public func getKataGenMoveAnalyzeCommands(maxTime: Float) -> [String] {
        return [
            "kata-set-param maxTime \(max(maxTime, 0.5))",
            "kata-search_analyze_cancellable interval \(analysisInterval) maxmoves \(maxAnalysisMoves) ownership true ownershipStdev true rootInfo true"]
    }

    public func getKataBoardSizeCommand() -> String {
        return "rectangular_boardsize \(boardWidth) \(boardHeight)"
    }

    public func getKataKomiCommand() -> String {
        return "komi \(komi)"
    }

    public func getKataPlayoutDoublingAdvantageCommand() -> String {
        return "kata-set-param playoutDoublingAdvantage \(playoutDoublingAdvantage)"
    }

    public func getKataAnalysisWideRootNoiseCommand() -> String {
        return "kata-set-param analysisWideRootNoise \(analysisWideRootNoise)"
    }

    public func getSymmetricHumanAnalysisCommands() -> [String] {
        if isEqualBlackWhiteHumanSettings,
           let humanSLModel = HumanSLModel(profile: humanSLProfile) {
            return humanSLModel.commands
        } else {
            return []
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
    public static let defaultRule = 0
    public static let rules = ["chinese", "japanese", "korean", "aga", "bga", "new-zealand"]

    public func getKataRuleCommand() -> String {
        guard (0..<Config.rules.count).contains(rule) else {
            return "kata-set-rules \(Config.rules[Config.defaultRule])"
        }

        return "kata-set-rules \(Config.rules[rule])"
    }
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
    public static let defaultStoneStyle = 0
    public static let defaultStoneStyleText = stoneStyles[defaultStoneStyle]

    public var stoneStyleText: String {
        guard stoneStyle < Config.stoneStyles.count else {
            return Config.defaultStoneStyleText
        }
        
        return Config.stoneStyles[stoneStyle]
    }

    public var isFastStoneStyle: Bool {
        guard (0..<Config.stoneStyles.count).contains(stoneStyle) else { return false }
        return Config.stoneStyles[stoneStyle] == Config.fastStoneStyle
    }

    public var isClassicStoneStyle: Bool {
        guard (0..<Config.stoneStyles.count).contains(stoneStyle) else { return false }
        return Config.stoneStyles[stoneStyle] == Config.classicStoneStyle
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
            return optionalWhiteMaxTime ?? Config.defaultBlackMaxTime
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

    public var koRuleCommand: String {
        return "kata-set-rule ko \(koRuleText)"
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

    public var scoringRuleCommand: String {
        return "kata-set-rule scoring \(scoringRuleText)"
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

    public var taxRuleCommand: String {
        return "kata-set-rule tax \(taxRuleText)"
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

    public var multiStoneSuicideLegalCommand: String {
        return "kata-set-rule suicide \(multiStoneSuicideLegal)"
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

    public var hasButtonCommand: String {
        return "kata-set-rule hasButton \(hasButton)"
    }

    public static let defaultWhiteHandicapBonusRule: Int = 0
    public static let whiteHandicapBonusRules = ["0", "N-1", "N"]
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

    public var whiteHandicapBonusRuleCommand: String {
        return "kata-set-rule whiteHandicapBonus \(whiteHandicapBonusRuleText)"
    }

    public var ruleCommands: [String] {
        return [koRuleCommand,
                scoringRuleCommand,
                taxRuleCommand,
                multiStoneSuicideLegalCommand,
                hasButtonCommand,
                whiteHandicapBonusRuleCommand]
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
