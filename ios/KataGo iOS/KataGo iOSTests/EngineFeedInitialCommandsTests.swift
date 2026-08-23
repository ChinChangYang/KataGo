//
//  EngineFeedInitialCommandsTests.swift
//  KataGo iOSTests
//
//  Every platform launches its engine with the FEED and nothing else. It used
//  to be launched with a fixed bundle of config commands as well
//  (`GameSession.sendInitialCommands`, now DELETED): board size, the rules,
//  komi, friendly-pass, playout doubling, wide root noise, and the symmetric
//  human-SL profile pair. That bundle had to go, because it stated the selected
//  game's board size before anything had asked whether the engine could hold
//  that board — an iCloud-synced 37x37 record announced to a 19-buffer engine
//  aborts the whole helper on its first analysis.
//
//  Deleting it is only safe while the feed really does say everything the
//  bundle said. `preFeedBundle` below is that bundle, transcribed verbatim from
//  the deleted method, and these tests pin `EngineFeed.openingCommands` as a
//  strict superset of it. If someone drops a command from the feed, the symptom
//  (an engine quietly running with the wrong rule or profile) is nearly
//  untraceable — this is what catches it instead.
//

import Testing
import GoRulesKit
@testable import KataGoUICore

@MainActor
struct EngineFeedInitialCommandsTests {

    /// The pre-feed bundle: exactly what `GameSession.sendInitialCommands`
    /// sent, in its order, before it was deleted. A reference list rather than
    /// a call, because the thing it is a reference to no longer exists — and a
    /// reference the feed is checked against is the whole point of the suite.
    private func preFeedBundle(config: Config) -> [String] {
        var commands = [
            GtpCommandBuilder.boardSizeCommand(width: config.boardWidth,
                                               height: config.boardHeight)
        ]
        commands.append(contentsOf: GtpCommandBuilder.ruleCommandsBundle(
            ko: config.koRuleText,
            scoring: config.scoringRuleText,
            tax: config.taxRuleText,
            multiStoneSuicide: config.multiStoneSuicideLegal,
            hasButton: config.hasButton,
            whiteHandicapBonus: config.whiteHandicapBonusRuleText))
        commands.append(GtpCommandBuilder.komiCommand(config.komi))
        // Disabled to avoid a memory shortage problem.
        commands.append("kata-set-rule friendlyPassOk false")
        commands.append(
            GtpCommandBuilder.playoutDoublingAdvantageCommand(config.playoutDoublingAdvantage))
        commands.append(
            GtpCommandBuilder.analysisWideRootNoiseCommand(config.analysisWideRootNoise))
        commands.append(contentsOf: GtpCommandBuilder.symmetricHumanAnalysisCommands(
            humanSLProfile: config.effectiveHumanProfileForBlack,
            humanProfileForWhite: config.effectiveHumanProfileForWhite,
            humanRatioForBlack: config.humanRatioForBlack,
            humanRatioForWhite: config.humanRatioForWhite))
        return commands
    }

    private func feedCommands(config: Config) -> [String] {
        var replay = SgfReplay(width: config.boardWidth,
                               height: config.boardHeight,
                               moves: [])
        return EngineFeed.openingCommands(replay: &replay, config: config, targetIndex: 0)
    }

    /// The superset claim, on the default config.
    @Test func theFeedStatesEverythingThePreFeedBundleDid() {
        let config = Config()
        let missing = preFeedBundle(config: config).filter {
            !feedCommands(config: config).contains($0)
        }
        #expect(missing.isEmpty, "the feed never states: \(missing)")
    }

    /// And on a config that moves every knob the initial commands touch, so a
    /// command that happens to be identical at the defaults cannot hide.
    @Test func theFeedStatesEverythingOnANonDefaultConfig() {
        let config = Config()
        config.boardWidth = 13
        config.boardHeight = 9
        config.komi = 0.5
        // Written through `rawValue` rather than by case name so this stays
        // compiling if a rule enum is ever re-spelled; each value is a
        // different one from the default (ko 1, scoring 0, tax 0, whb 0).
        config.koRule = KoRule(rawValue: 0) ?? config.koRule
        config.scoringRule = ScoringRule(rawValue: 1) ?? config.scoringRule
        config.taxRule = TaxRule(rawValue: 1) ?? config.taxRule
        config.whiteHandicapBonusRule =
            WhiteHandicapBonusRule(rawValue: 1) ?? config.whiteHandicapBonusRule
        config.multiStoneSuicideLegal = false
        config.hasButton = true
        config.playoutDoublingAdvantage = 1.5
        config.analysisWideRootNoise = 0.25

        let missing = preFeedBundle(config: config).filter {
            !feedCommands(config: config).contains($0)
        }
        #expect(missing.isEmpty, "the feed never states: \(missing)")
    }

    /// The feed says two things the pre-feed bundle never did, and both matter
    /// to a relaunch: it re-states the board size from the RECORD (not from a
    /// `Config` that may disagree with the SGF) and it clears the board first,
    /// because `set_free_handicap` refuses a non-empty one.
    @Test func theFeedAlsoResetsTheBoard() {
        let commands = feedCommands(config: Config())
        #expect(commands.contains("clear_board"))
        #expect(commands.first?.hasPrefix("rectangular_boardsize") == true)
    }
}
