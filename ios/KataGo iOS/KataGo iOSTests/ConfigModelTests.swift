//
//  ConfigModelTests.swift
//  KataGo iOSTests
//
//  Created by Chin-Chang Yang on 2024/8/18.
//

import Testing
@testable import KataGo_iOS

struct ConfigModelTests {

    @Test func initializeConfig() async throws {
        let config = Config()
        let clone = Config(config: config)
        #expect(config.boardWidth == clone.boardWidth)
        #expect(config.boardHeight == clone.boardHeight)
        #expect(config.rule == clone.rule)
        #expect(config.komi == clone.komi)
        #expect(config.playoutDoublingAdvantage == clone.playoutDoublingAdvantage)
        #expect(config.analysisWideRootNoise == clone.analysisWideRootNoise)
        #expect(config.maxAnalysisMoves == clone.maxAnalysisMoves)
        #expect(config.analysisInterval == clone.analysisInterval)
        #expect(config.analysisInformation == clone.analysisInformation)
        #expect(config.hiddenAnalysisVisitRatio == clone.hiddenAnalysisVisitRatio)
        #expect(config.stoneStyle == clone.stoneStyle)
        #expect(config.showCoordinate == clone.showCoordinate)
        #expect(config.humanSLRootExploreProbWeightful == clone.humanSLRootExploreProbWeightful)
        #expect(config.humanSLProfile == clone.humanSLProfile)
        #expect(config.optionalAnalysisForWhom == clone.optionalAnalysisForWhom)
        #expect(config.optionalShowOwnership == clone.optionalShowOwnership)
    }

    @Test func kataAnalyzeCommand() async throws {
        let config = Config()
        #expect(config.getKataAnalyzeCommand() == config.getKataAnalyzeCommand(analysisInterval: Config.defaultAnalysisInterval))
    }

    @Test func analysisInformation() async throws {
        let config = Config()
        #expect(config.isAnalysisInformationWinrate)
        #expect(!config.isAnalysisInformationScore)
        config.analysisInformation = 1
        #expect(!config.isAnalysisInformationWinrate)
        #expect(config.isAnalysisInformationScore)
    }

    @Test func stoneStyle() async throws {
        let config = Config()
        #expect(!config.isClassicStoneStyle)
        config.stoneStyle = 1
        #expect(config.isClassicStoneStyle)
    }

    @Test func analysisForWhom() async throws {
        let config = Config()
        #expect(config.analysisForWhom == 0)
        #expect(config.isAnalysisForCurrentPlayer(nextColorForPlayCommand: .black))
        #expect(config.isAnalysisForCurrentPlayer(nextColorForPlayCommand: .white))

        config.analysisForWhom = 1
        #expect(config.analysisForWhom == 1)
        #expect(config.isAnalysisForCurrentPlayer(nextColorForPlayCommand: .black))
        #expect(!config.isAnalysisForCurrentPlayer(nextColorForPlayCommand: .white))

        config.analysisForWhom = 2
        #expect(config.analysisForWhom == 2)
        #expect(!config.isAnalysisForCurrentPlayer(nextColorForPlayCommand: .black))
        #expect(config.isAnalysisForCurrentPlayer(nextColorForPlayCommand: .white))

        config.optionalAnalysisForWhom = nil
        #expect(config.analysisForWhom == Config.defaultAnalysisForWhom)
    }

    @Test func showOwnership() async throws {
        let config = Config()
        config.optionalShowOwnership = nil
        #expect(config.showOwnership == Config.defaultShowOwnership)
        config.showOwnership = false
        #expect(config.showOwnership == false)
    }
}
