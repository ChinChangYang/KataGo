//
//  GtpCommandBuilderTests.swift
//  KataGo iOSTests
//

import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

struct GtpCommandBuilderTests {
    private func makeConfigs() -> [Config] {
        let a = Config()                          // defaults
        let b = Config()
        b.komi = 0.5
        b.boardWidth = 13; b.boardHeight = 13
        b.playoutDoublingAdvantage = 1.5
        b.analysisWideRootNoise = 0.1
        b.maxAnalysisMoves = 30
        b.analysisInterval = 25
        b.blackMaxTime = 3; b.whiteMaxTime = 0
        return [a, b]
    }

    @Test func builderMatchesConfigForAllScalarCommands() {
        for c in makeConfigs() {
            #expect(GtpCommandBuilder.analyzeCommand(interval: c.analysisInterval, maxMoves: c.maxAnalysisMoves) == c.getKataAnalyzeCommand())
            #expect(GtpCommandBuilder.fastAnalyzeCommand(maxMoves: c.maxAnalysisMoves) == c.getKataFastAnalyzeCommand())
            #expect(GtpCommandBuilder.boardSizeCommand(width: c.boardWidth, height: c.boardHeight) == c.getKataBoardSizeCommand())
            #expect(GtpCommandBuilder.komiCommand(c.komi) == c.getKataKomiCommand())
            #expect(GtpCommandBuilder.playoutDoublingAdvantageCommand(c.playoutDoublingAdvantage) == c.getKataPlayoutDoublingAdvantageCommand())
            #expect(GtpCommandBuilder.analysisWideRootNoiseCommand(c.analysisWideRootNoise) == c.getKataAnalysisWideRootNoiseCommand())
            #expect(GtpCommandBuilder.rulesetCommand(Config.rules[c.rule]) == c.getKataRuleCommand())
            #expect(GtpCommandBuilder.koRuleCommand(c.koRuleText) == c.koRuleCommand)
            #expect(GtpCommandBuilder.scoringRuleCommand(c.scoringRuleText) == c.scoringRuleCommand)
            #expect(GtpCommandBuilder.taxRuleCommand(c.taxRuleText) == c.taxRuleCommand)
            #expect(GtpCommandBuilder.multiStoneSuicideCommand(c.multiStoneSuicideLegal) == c.multiStoneSuicideLegalCommand)
            #expect(GtpCommandBuilder.hasButtonCommand(c.hasButton) == c.hasButtonCommand)
            #expect(GtpCommandBuilder.whiteHandicapBonusCommand(c.whiteHandicapBonusRuleText) == c.whiteHandicapBonusRuleCommand)
        }
    }

    @Test func builderMatchesConfigForArrayCommands() {
        for c in makeConfigs() {
            #expect(GtpCommandBuilder.ruleCommandsBundle(
                ko: c.koRuleText, scoring: c.scoringRuleText, tax: c.taxRuleText,
                multiStoneSuicide: c.multiStoneSuicideLegal, hasButton: c.hasButton,
                whiteHandicapBonus: c.whiteHandicapBonusRuleText) == c.ruleCommands)
            #expect(GtpCommandBuilder.genMoveAnalyzeCommands(maxTime: c.blackMaxTime, interval: c.analysisInterval, maxMoves: c.maxAnalysisMoves)
                    == c.getKataGenMoveAnalyzeCommands(maxTime: c.blackMaxTime))
            #expect(GtpCommandBuilder.symmetricHumanAnalysisCommands(blackProfile: c.humanProfileForBlack, whiteProfile: c.humanProfileForWhite)
                    == c.getSymmetricHumanAnalysisCommands())
        }
    }
}
