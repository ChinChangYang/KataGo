//
//  ConfigModel.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/7/1.
//

import Foundation
import SwiftData

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
    var optionalAnalysisForWhom: Int? = 0
    var optionalShowOwnership: Bool? = true

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
         optionalAnalysisForWhom: Int? = 0,
         optionalShowOwnership: Bool? = true) {
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
            optionalShowOwnership: config.optionalShowOwnership
        )
    }
}

extension Config {
    func getKataAnalyzeCommand(analysisInterval: Int) -> String {
        return "kata-analyze interval \(analysisInterval) maxmoves \(maxAnalysisMoves) rootInfo true ownership true ownershipStdev true"
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
        return "kata-set-rules \(Config.rules[rule])"
    }
}

extension Config {
    static let defaultAnalysisInformation = 0
    static let analysisInformationAll = "All"
    static let analysisInformationWinrate = "Winrate"
    static let analysisInformationScore = "Score"

    static let analysisInformations = [analysisInformationWinrate,
                                       analysisInformationScore,
                                       analysisInformationAll]

    func isAnalysisInformationWinrate() -> Bool {
        return Config.analysisInformations[analysisInformation] == Config.analysisInformationWinrate
    }

    func isAnalysisInformationScore() -> Bool {
        return Config.analysisInformations[analysisInformation] == Config.analysisInformationScore
    }
}

extension Config {
    static let fastStoneStyle = "Fast"
    static let classicStoneStyle = "Classic"
    static let stoneStyles = [fastStoneStyle, classicStoneStyle]
    static let defaultStoneStyle = 0

    func isFastStoneStyle() -> Bool {
        return Config.stoneStyles[stoneStyle] == Config.fastStoneStyle
    }

    func isClassicStoneStyle() -> Bool {
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

    func isAnalysisForBlack() -> Bool {
        return Config.analysisForWhoms[analysisForWhom] == Config.analysisForBlack
    }

    func isAnalysisForWhite() -> Bool {
        return Config.analysisForWhoms[analysisForWhom] == Config.analysisForWhite
    }

    func isAnalysisForCurrentPlayer(nextColorForPlayCommand: PlayerColor) -> Bool {
        return (isAnalysisForBlack() && nextColorForPlayCommand == .black) ||
        (isAnalysisForWhite() && nextColorForPlayCommand == .white) ||
        (!isAnalysisForBlack() && !isAnalysisForWhite())
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
