//
//  EngineFeedInitialCommandsTests.swift
//  KataGo iOSTests
//
//  macOS launches its engine with the FEED and nothing else — it calls
//  `GameSession.handshake` rather than `initialize`, so `sendInitialCommands`
//  never runs there. It does that because `sendInitialCommands` states the
//  selected game's board size before anything has asked whether the engine can
//  hold that board: an iCloud-synced 37x37 record would be announced to a
//  19-buffer engine, which aborts the whole helper on its first analysis.
//
//  That is only safe while the feed really does say everything the initial
//  commands said. This pins that invariant. If someone adds a command to
//  `sendInitialCommands` and not to `EngineFeed.openingCommands`, macOS would
//  otherwise silently stop sending it, and the symptom (an engine quietly
//  running with the wrong rule or profile) is nearly untraceable.
//

import Testing
import GoRulesKit
@testable import KataGoUICore

@MainActor
struct EngineFeedInitialCommandsTests {

    private func initialCommands(config: Config) -> [String] {
        let session = GameSession.accepting()
        let engine = RecordingEngine()
        session.useEngine(engine)
        session.sendInitialCommands(config: config)
        return engine.sent
    }

    private func feedCommands(config: Config) -> [String] {
        var replay = SgfReplay(width: config.boardWidth,
                               height: config.boardHeight,
                               moves: [])
        return EngineFeed.openingCommands(replay: &replay, config: config, targetIndex: 0)
    }

    /// The superset claim, on the default config.
    @Test func theFeedStatesEverythingTheInitialCommandsDid() {
        let config = Config()
        let missing = initialCommands(config: config).filter {
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

        let missing = initialCommands(config: config).filter {
            !feedCommands(config: config).contains($0)
        }
        #expect(missing.isEmpty, "the feed never states: \(missing)")
    }

    /// The feed says two things the initial commands never did, and both matter
    /// to a relaunch: it re-states the board size from the RECORD (not from a
    /// `Config` that may disagree with the SGF) and it clears the board first,
    /// because `set_free_handicap` refuses a non-empty one.
    @Test func theFeedAlsoResetsTheBoard() {
        let commands = feedCommands(config: Config())
        #expect(commands.contains("clear_board"))
        #expect(commands.first?.hasPrefix("rectangular_boardsize") == true)
    }
}
