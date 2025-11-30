//
//  ConfigModel.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/7/1.
//

import Foundation
import SwiftData
import KataGoInterface

@Model
final class Config {
    // The iCloud servers don’t guarantee atomic processing of relationship changes,
    // so CloudKit requires all relationships to be optional.
    var gameRecord: GameRecord?
    var boardWidth: Int = defaultBoardWidth
    var boardHeight: Int = defaultBoardHeight
    var rule: Int = defaultRule
    var komi: Float = defaultKomi
    var playoutDoublingAdvantage: Float = defaultPlayoutDoublingAdvantage
    var analysisWideRootNoise: Float = defaultAnalysisWideRootNoise
    var maxAnalysisMoves: Int = defaultMaxAnalysisMoves
    var analysisInterval: Int = defaultAnalysisInterval
    var analysisInformation: Int = defaultAnalysisInformation
    var hiddenAnalysisVisitRatio: Float = defaultHiddenAnalysisVisitRatio
    var stoneStyle: Int = defaultStoneStyle
    var showCoordinate: Bool = defaultShowCoordinate
    var humanSLRootExploreProbWeightful: Float = defaultHumanRatio
    var humanSLProfile: String = defaultHumanSLProfile
    var optionalAnalysisForWhom: Int? = defaultAnalysisForWhom
    var optionalShowOwnership: Bool? = defaultShowOwnership
    var optionalHumanRatioForWhite: Float? = defaultHumanRatio
    var optionalHumanProfileForWhite: String? = defaultHumanSLProfile
    var optionalSoundEffect: Bool? = defaultSoundEffect
    var optionalShowComments: Bool? = defaultShowComments
    var optionalShowPass: Bool? = defaultShowPass
    var optionalVerticalFlip: Bool? = defaultVerticalFlip
    var optionalBlackMaxTime: Float? = defaultBlackMaxTime
    var optionalWhiteMaxTime: Float? = defaultWhiteMaxTime
    var optionalKoRule: Int? = defaultKoRule
    var optionalScoringRule: Int? = defaultScoringRule
    var optionalTaxRule: Int? = defaultTaxRule
    var optionalMultiStoneSuicideLegal: Bool? = defaultMultiStoneSuicideLegal
    var optionalHasButton: Bool? = defaultHasButton
    var optionalWhiteHandicapBonusRule: Int? = defaultWhiteHandicapBonusRule
    var optionalShowWinrateBar: Bool? = defaultShowWinrateBar
    var optionalAnalysisStyle: Int? = defaultAnalysisStyle
    var optionalShowCharts: Bool? = defaultShowCharts
    var optionalUseLLM: Bool? = defaultUseLLM
    var optionalTemperature: Float? = defaultTemperature

    init(gameRecord: GameRecord? = nil,
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
         optionalTemperature: Float? = defaultTemperature
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
    }

    convenience init(config: Config?) {
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
                optionalTemperature: config.optionalTemperature
            )
        } else {
            self.init()
        }
    }
}

extension Config {
    func getKataAnalyzeCommand(analysisInterval: Int) -> String {
        return "kata-analyze interval \(analysisInterval) maxmoves \(maxAnalysisMoves) ownership true ownershipStdev true"
    }

    func getKataAnalyzeCommand() -> String {
        return getKataAnalyzeCommand(analysisInterval: analysisInterval)
    }

    func getKataFastAnalyzeCommand() -> String {
        return getKataAnalyzeCommand(analysisInterval: 10);
    }

    func getKataGenMoveAnalyzeCommands(maxTime: Float) -> [String] {
        return [
            "kata-set-param maxTime \(max(maxTime, 0.5))",
            "kata-search_analyze_cancellable interval \(analysisInterval) maxmoves \(maxAnalysisMoves) ownership true ownershipStdev true"]
    }

    func getKataBoardSizeCommand() -> String {
        return "rectangular_boardsize \(boardWidth) \(boardHeight)"
    }

    func getKataKomiCommand() -> String {
        return "komi \(komi)"
    }

    func getKataPlayoutDoublingAdvantageCommand() -> String {
        return "kata-set-param playoutDoublingAdvantage \(playoutDoublingAdvantage)"
    }

    func getKataAnalysisWideRootNoiseCommand() -> String {
        return "kata-set-param analysisWideRootNoise \(analysisWideRootNoise)"
    }

    func getSymmetricHumanAnalysisCommands() -> [String] {
        if isEqualBlackWhiteHumanSettings,
           let humanSLModel = HumanSLModel(profile: humanSLProfile) {
            return humanSLModel.commands
        } else {
            return []
        }
    }
}

extension Config {
    static let defaultBoardWidth = 19
    static let defaultBoardHeight = 19
    static let defaultKomi: Float = 7.0
    static let defaultPlayoutDoublingAdvantage: Float = 0.0
    static let defaultAnalysisWideRootNoise: Float = 0.03125
    static let defaultMaxAnalysisMoves = 50
    static let defaultAnalysisInterval = 50
    static let defaultHiddenAnalysisVisitRatio: Float = 0.03125
}

extension Config {
    static let defaultRule = 0
    static let rules = ["chinese", "japanese", "korean", "aga", "bga", "new-zealand"]

    func getKataRuleCommand() -> String {
        guard (0..<Config.rules.count).contains(rule) else {
            return "kata-set-rules \(Config.rules[Config.defaultRule])"
        }

        return "kata-set-rules \(Config.rules[rule])"
    }
}

extension Config {
    static let defaultAnalysisInformation = 2
    static let analysisInformationWinrate = "Winrate"
    static let analysisInformationScore = "Score"
    static let analysisInformationAll = "All"
    static let analysisInformationNone = "None"

    static let analysisInformations = [analysisInformationWinrate,
                                       analysisInformationScore,
                                       analysisInformationAll,
                                       analysisInformationNone]

    static let defaultAnalysisInformationText = analysisInformations[defaultAnalysisInformation]

    var analysisInformationText: String {
        guard analysisInformation < Config.analysisInformations.count else {
            return Config.defaultAnalysisInformationText
        }

        return Config.analysisInformations[analysisInformation]
    }

    var isAnalysisInformationWinrate: Bool {
        guard (0..<Config.analysisInformations.count).contains(analysisInformation) else { return false }
        return Config.analysisInformations[analysisInformation] == Config.analysisInformationWinrate
    }

    var isAnalysisInformationScore: Bool {
        guard (0..<Config.analysisInformations.count).contains(analysisInformation) else { return false }
        return Config.analysisInformations[analysisInformation] == Config.analysisInformationScore
    }

    var isAnalysisInformationAll: Bool {
        guard (0..<Config.analysisInformations.count).contains(analysisInformation) else { return false }
        return Config.analysisInformations[analysisInformation] == Config.analysisInformationAll
    }

    var isAnalysisInformationNone: Bool {
        guard (0..<Config.analysisInformations.count).contains(analysisInformation) else { return false }
        return Config.analysisInformations[analysisInformation] == Config.analysisInformationNone
    }
}

extension Config {
    static let fastStoneStyle = "Fast"
    static let classicStoneStyle = "Classic"
    static let stoneStyles = [fastStoneStyle, classicStoneStyle]
    static let defaultStoneStyle = 0
    static let defaultStoneStyleText = stoneStyles[defaultStoneStyle]

    var stoneStyleText: String {
        guard stoneStyle < Config.stoneStyles.count else {
            return Config.defaultStoneStyleText
        }
        
        return Config.stoneStyles[stoneStyle]
    }

    var isFastStoneStyle: Bool {
        guard (0..<Config.stoneStyles.count).contains(stoneStyle) else { return false }
        return Config.stoneStyles[stoneStyle] == Config.fastStoneStyle
    }

    var isClassicStoneStyle: Bool {
        guard (0..<Config.stoneStyles.count).contains(stoneStyle) else { return false }
        return Config.stoneStyles[stoneStyle] == Config.classicStoneStyle
    }
}

extension Config {
    static let defaultShowCoordinate = true
}

extension Config {
    static let defaultHumanRatio: Float = 0
}

extension Config {
    static let defaultHumanSLProfile = "AI"
}

extension Config {
    static let defaultAnalysisForWhom = 0
    static let analysisForBoth = "Both"
    static let analysisForBlack = "Black"
    static let analysisForWhite = "White"

    static let analysisForWhoms = [analysisForBoth,
                                   analysisForBlack,
                                   analysisForWhite]

    static let defaultAnalysisForWhomText = analysisForWhoms[defaultAnalysisForWhom]

    var analysisForWhom: Int {
        get {
            return optionalAnalysisForWhom ?? Config.defaultAnalysisForWhom
        }

        set(newAnalysisForWhom) {
            optionalAnalysisForWhom = newAnalysisForWhom
        }
    }

    var analysisForWhomText: String {
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

    func isAnalysisForCurrentPlayer(nextColorForPlayCommand: PlayerColor) -> Bool {
        return (nextColorForPlayCommand != .unknown) &&
        ((isAnalysisForBlack && nextColorForPlayCommand == .black) ||
         (isAnalysisForWhite && nextColorForPlayCommand == .white) ||
         (!isAnalysisForBlack && !isAnalysisForWhite))
    }
}

extension Config {
    static let defaultShowOwnership = true

    var showOwnership: Bool {
        get {
            return optionalShowOwnership ?? Config.defaultShowOwnership
        }

        set(newShowOwnership) {
            optionalShowOwnership = newShowOwnership
        }
    }
}

extension Config {
    var humanProfileForBlack: String {
        get {
            return humanSLProfile
        }
        
        set(newValue) {
            humanSLProfile = newValue
        }
    }

    var humanRatioForBlack: Float {
        get {
            return humanSLRootExploreProbWeightful
        }
        
        set(newValue) {
            humanSLRootExploreProbWeightful = newValue
        }
    }
}

extension Config {
    var humanProfileForWhite: String {
        get {
            return optionalHumanProfileForWhite ?? Config.defaultHumanSLProfile
        }

        set(newHumanProfileForWhite) {
            optionalHumanProfileForWhite = newHumanProfileForWhite
        }
    }

    var humanRatioForWhite: Float {
        get {
            return optionalHumanRatioForWhite ?? Config.defaultHumanRatio
        }

        set(newHumanRatioForWhite) {
            optionalHumanRatioForWhite = newHumanRatioForWhite
        }
    }

    var isEqualBlackWhiteHumanSettings: Bool {
        return (humanSLProfile == humanProfileForWhite) && (humanRatioForBlack == humanRatioForWhite)
    }
}

extension Config {
    static let defaultSoundEffect = true

    var soundEffect: Bool {
        get {
            return optionalSoundEffect ?? Config.defaultSoundEffect
        }

        set(newSoundEffect) {
            optionalSoundEffect = newSoundEffect
        }
    }
}

extension Config {
    static let defaultShowComments = false

    var showComments: Bool {
        get {
            return optionalShowComments ?? Config.defaultShowComments
        }

        set(newShowComments) {
            optionalShowComments = newShowComments
        }
    }
}

extension Config {
    static let defaultShowPass = true

    var showPass: Bool {
        get {
            return optionalShowPass ?? Config.defaultShowPass
        }
        
        set(newShowPass) {
            optionalShowPass = newShowPass
        }
    }
}

extension Config {
    static let defaultVerticalFlip = false
    static let compatibleVerticalFlip = true

    var verticalFlip: Bool {
        get {
            return optionalVerticalFlip ?? Config.compatibleVerticalFlip
        }
        
        set(newVerticalFlip) {
            optionalVerticalFlip = newVerticalFlip
        }
    }
}

extension Config {
    static let defaultBlackMaxTime: Float = 0.0

    var blackMaxTime: Float {
        get {
            return optionalBlackMaxTime ?? Config.defaultBlackMaxTime
        }
        
        set(newValue) {
            optionalBlackMaxTime = newValue
        }
    }
}

extension Config {
    static let defaultWhiteMaxTime: Float = 0.0
    
    var whiteMaxTime: Float {
        get {
            return optionalWhiteMaxTime ?? Config.defaultBlackMaxTime
        }
        
        set(newValue) {
            optionalWhiteMaxTime = newValue
        }
    }
}

extension Config {
    static let defaultKoRule: Int = 0
    static let koRules = ["SIMPLE", "POSITIONAL", "SITUATIONAL"]
    static let defaultKoRuleText = koRules[defaultKoRule]

    var koRule: KoRule {
        get {
            return KoRule(rawValue: optionalKoRule ?? Config.defaultKoRule) ?? .simple
        }

        set(newValue) {
            optionalKoRule = newValue.rawValue
        }
    }

    var koRuleText: String {
        guard koRule.rawValue < Config.koRules.count else { return "" }
        return Config.koRules[koRule.rawValue]
    }

    var koRuleCommand: String {
        return "kata-set-rule ko \(koRuleText)"
    }

    static let defaultScoringRule: Int = 0
    static let scoringRules = ["AREA", "TERRITORY"]
    static let defaultScoringRuleText = scoringRules[defaultScoringRule]

    var scoringRule: ScoringRule {
        get {
            return ScoringRule(rawValue: optionalScoringRule ?? Config.defaultScoringRule) ?? .area
        }
        
        set(newValue) {
            optionalScoringRule = newValue.rawValue
        }
    }

    var scoringRuleText: String {
        guard scoringRule.rawValue < Config.scoringRules.count else { return "" }
        return Config.scoringRules[scoringRule.rawValue]
    }

    var scoringRuleCommand: String {
        return "kata-set-rule scoring \(scoringRuleText)"
    }

    static let defaultTaxRule: Int = 0
    static let taxRules = ["NONE", "SEKI", "ALL"]
    static let defaultTaxRuleText = taxRules[defaultTaxRule]

    var taxRule: TaxRule {
        get {
            return TaxRule(rawValue: optionalTaxRule ?? Config.defaultTaxRule) ?? .none
        }
        
        set(newValue) {
            optionalTaxRule = newValue.rawValue
        }
    }

    var taxRuleText: String {
        guard taxRule.rawValue < Config.taxRules.count else { return "" }
        return Config.taxRules[taxRule.rawValue]
    }

    var taxRuleCommand: String {
        return "kata-set-rule tax \(taxRuleText)"
    }

    static let defaultMultiStoneSuicideLegal: Bool = false

    var multiStoneSuicideLegal: Bool {
        get {
            return optionalMultiStoneSuicideLegal ?? Config.defaultMultiStoneSuicideLegal
        }
        
        set(newValue) {
            optionalMultiStoneSuicideLegal = newValue
        }
    }

    var multiStoneSuicideLegalCommand: String {
        return "kata-set-rule suicide \(multiStoneSuicideLegal)"
    }

    static let defaultHasButton: Bool = false

    var hasButton: Bool {
        get {
            return optionalHasButton ?? Config.defaultHasButton
        }
        
        set(newValue) {
            optionalHasButton = newValue
        }
    }

    var hasButtonCommand: String {
        return "kata-set-rule hasButton \(hasButton)"
    }

    static let defaultWhiteHandicapBonusRule: Int = 0
    static let whiteHandicapBonusRules = ["0", "N-1", "N"]
    static let defaultWhiteHandicapBonusRuleText = whiteHandicapBonusRules[defaultWhiteHandicapBonusRule]

    var whiteHandicapBonusRule: WhiteHandicapBonusRule {
        get {
            return WhiteHandicapBonusRule(rawValue: optionalWhiteHandicapBonusRule ?? Config.defaultWhiteHandicapBonusRule) ?? .zero
        }

        set(newValue) {
            optionalWhiteHandicapBonusRule = newValue.rawValue
        }
    }

    var whiteHandicapBonusRuleText: String {
        guard whiteHandicapBonusRule.rawValue < Config.whiteHandicapBonusRules.count else { return "" }
        return Config.whiteHandicapBonusRules[whiteHandicapBonusRule.rawValue]
    }

    var whiteHandicapBonusRuleCommand: String {
        return "kata-set-rule whiteHandicapBonus \(whiteHandicapBonusRuleText)"
    }

    var ruleCommands: [String] {
        return [koRuleCommand,
                scoringRuleCommand,
                taxRuleCommand,
                multiStoneSuicideLegalCommand,
                hasButtonCommand,
                whiteHandicapBonusRuleCommand]
    }
}

extension Config {
    static let defaultShowWinrateBar: Bool = true

    var showWinrateBar: Bool {
        get {
            return optionalShowWinrateBar ?? Config.defaultShowWinrateBar
        }

        set(newValue) {
            optionalShowWinrateBar = newValue
        }
    }
}

extension Config {
    static let fastAnalysisStyle = "Fast"
    static let classicAnalysisStyle = "Classic"
    static let analysisStyles = [fastAnalysisStyle, classicAnalysisStyle]
    static let defaultAnalysisStyle = 0
    static let defaultAnalysisStyleText = analysisStyles[defaultAnalysisStyle]

    var analysisStyle: Int {
        get {
            return optionalAnalysisStyle ?? Config.defaultAnalysisStyle
        }
        
        set(newValue) {
            optionalAnalysisStyle = newValue
        }
    }

    var analysisStyleText: String {
        guard analysisStyle < Config.analysisStyles.count else {
            return Config.defaultAnalysisStyleText
        }

        return Config.analysisStyles[analysisStyle]
    }

    var isFastAnalysisStyle: Bool {
        guard (0..<Config.analysisStyles.count).contains(analysisStyle) else { return false }
        return Config.analysisStyles[analysisStyle] == Config.fastAnalysisStyle
    }

    var isClassicAnalysisStyle: Bool {
        guard (0..<Config.analysisStyles.count).contains(analysisStyle) else { return false }
        return Config.analysisStyles[analysisStyle] == Config.classicAnalysisStyle
    }
}

extension Config {
    static let defaultShowCharts: Bool = true

    var showCharts: Bool {
        get {
            return optionalShowCharts ?? Config.defaultShowCharts
        }
        
        set(newValue) {
            optionalShowCharts = newValue
        }
    }
}

extension Config {
    static let defaultUseLLM: Bool = false

    var useLLM: Bool {
        get {
            return optionalUseLLM ?? Config.defaultUseLLM
        }
        
        set(newValue) {
            optionalUseLLM = newValue
        }
    }
}

extension Config {
    static let defaultTemperature: Float = 0.5

    var temperature: Float {
        get {
            return optionalTemperature ?? Config.defaultTemperature
        }

        set(newValue) {
            optionalTemperature = newValue
        }
    }
}
