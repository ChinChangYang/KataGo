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
    var humanSLRootExploreProbWeightful: Float = defaultHumanSLRootExploreProbWeightful
    var humanSLProfile: String = defaultHumanSLProfile
    var optionalAnalysisForWhom: Int? = defaultAnalysisForWhom
    var optionalShowOwnership: Bool? = defaultShowOwnership
    var optionalHumanRatioForWhite: Float? = defaultHumanSLRootExploreProbWeightful
    var optionalHumanProfileForWhite: String? = defaultHumanSLProfile
    var optionalSoundEffect: Bool? = defaultSoundEffect
    var optionalShowComments: Bool? = defaultShowComments

    init(boardWidth: Int = defaultBoardWidth,
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
         humanSLRootExploreProbWeightful: Float = defaultHumanSLRootExploreProbWeightful,
         humanSLProfile: String = defaultHumanSLProfile,
         optionalAnalysisForWhom: Int? = defaultAnalysisForWhom,
         optionalShowOwnership: Bool? = defaultShowOwnership,
         optionalHumanRatioForWhite: Float? = defaultHumanSLRootExploreProbWeightful,
         optionalHumanProfileForWhite: String? = defaultHumanSLProfile,
         optionalSoundEffect: Bool? = defaultSoundEffect,
         optionalShowComments: Bool? = defaultShowComments) {
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
    }

    convenience init(config: Config) {
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
            optionalShowComments: config.optionalShowComments
        )
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
        if isEqualBlackWhiteHumanSettings {
            return ["kata-set-param humanSLProfile \(humanSLProfile)",
                    "kata-set-param humanSLRootExploreProbWeightful \(humanSLRootExploreProbWeightful)"]
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

    static let analysisInformations = [analysisInformationWinrate,
                                       analysisInformationScore,
                                       analysisInformationAll]

    var isAnalysisInformationWinrate: Bool {
        guard (0..<Config.analysisInformations.count).contains(analysisInformation) else { return false }
        return Config.analysisInformations[analysisInformation] == Config.analysisInformationWinrate
    }

    var isAnalysisInformationScore: Bool {
        guard (0..<Config.analysisInformations.count).contains(analysisInformation) else { return false }
        return Config.analysisInformations[analysisInformation] == Config.analysisInformationScore
    }
}

extension Config {
    static let fastStoneStyle = "Fast"
    static let classicStoneStyle = "Classic"
    static let stoneStyles = [fastStoneStyle, classicStoneStyle]
    static let defaultStoneStyle = 0

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
    static let defaultShowCoordinate = false
}

extension Config {
    static let defaultHumanSLRootExploreProbWeightful: Float = 0
}

extension Config {
    static let defaultHumanSLProfile = "preaz_9d"
}

extension Config {
    static let defaultAnalysisForWhom = 0
    static let analysisForBoth = "Both"
    static let analysisForBlack = "Black"
    static let analysisForWhite = "White"

    static let analysisForWhoms = [analysisForBoth,
                                   analysisForBlack,
                                   analysisForWhite]

    var analysisForWhom: Int {
        get {
            return optionalAnalysisForWhom ?? Config.defaultAnalysisForWhom
        }

        set(newAnalysisForWhom) {
            optionalAnalysisForWhom = newAnalysisForWhom
        }
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
            return optionalHumanRatioForWhite ?? Config.defaultHumanSLRootExploreProbWeightful
        }

        set(newHumanRatioForWhite) {
            optionalHumanRatioForWhite = newHumanRatioForWhite
        }
    }

    var isEqualBlackWhiteHumanSettings: Bool {
        return (humanSLProfile == humanProfileForWhite) && (humanSLRootExploreProbWeightful == humanRatioForWhite)
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
