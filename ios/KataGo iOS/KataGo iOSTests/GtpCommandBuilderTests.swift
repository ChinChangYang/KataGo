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
        // profiles equal but ratios differ — exercises the asymmetric branch
        let c = Config()
        c.humanRatioForBlack = 0.5
        c.humanRatioForWhite = 0.0
        return [a, b, c]
    }

    @Test func builderMatchesConfigForAllScalarCommands() {
        // config a — defaults
        let a = makeConfigs()[0]
        #expect(GtpCommandBuilder.analyzeCommand(interval: a.analysisInterval, maxMoves: a.maxAnalysisMoves)
                == "kata-analyze interval 50 maxmoves 50 ownership true ownershipStdev true rootInfo true")
        #expect(GtpCommandBuilder.fastAnalyzeCommand(maxMoves: a.maxAnalysisMoves)
                == "kata-analyze interval 10 maxmoves 50 ownership true ownershipStdev true rootInfo true")
        #expect(GtpCommandBuilder.boardSizeCommand(width: a.boardWidth, height: a.boardHeight)
                == "rectangular_boardsize 19 19")
        #expect(GtpCommandBuilder.komiCommand(a.komi) == "komi 7.0")
        #expect(GtpCommandBuilder.playoutDoublingAdvantageCommand(a.playoutDoublingAdvantage)
                == "kata-set-param playoutDoublingAdvantage 0.0")
        #expect(GtpCommandBuilder.analysisWideRootNoiseCommand(a.analysisWideRootNoise)
                == "kata-set-param analysisWideRootNoise 0.03125")
        #expect(GtpCommandBuilder.rulesetCommand(Config.rules[a.rule]) == "kata-set-rules chinese")
        #expect(GtpCommandBuilder.koRuleCommand(a.koRuleText) == "kata-set-rule ko SIMPLE")
        #expect(GtpCommandBuilder.scoringRuleCommand(a.scoringRuleText) == "kata-set-rule scoring AREA")
        #expect(GtpCommandBuilder.taxRuleCommand(a.taxRuleText) == "kata-set-rule tax NONE")
        #expect(GtpCommandBuilder.multiStoneSuicideCommand(a.multiStoneSuicideLegal) == "kata-set-rule suicide false")
        #expect(GtpCommandBuilder.hasButtonCommand(a.hasButton) == "kata-set-rule hasButton false")
        #expect(GtpCommandBuilder.whiteHandicapBonusCommand(a.whiteHandicapBonusRuleText) == "kata-set-rule whiteHandicapBonus 0")

        // config b — custom values
        let b = makeConfigs()[1]
        #expect(GtpCommandBuilder.analyzeCommand(interval: b.analysisInterval, maxMoves: b.maxAnalysisMoves)
                == "kata-analyze interval 25 maxmoves 30 ownership true ownershipStdev true rootInfo true")
        #expect(GtpCommandBuilder.fastAnalyzeCommand(maxMoves: b.maxAnalysisMoves)
                == "kata-analyze interval 10 maxmoves 30 ownership true ownershipStdev true rootInfo true")
        #expect(GtpCommandBuilder.boardSizeCommand(width: b.boardWidth, height: b.boardHeight)
                == "rectangular_boardsize 13 13")
        #expect(GtpCommandBuilder.komiCommand(b.komi) == "komi 0.5")
        #expect(GtpCommandBuilder.playoutDoublingAdvantageCommand(b.playoutDoublingAdvantage)
                == "kata-set-param playoutDoublingAdvantage 1.5")
        #expect(GtpCommandBuilder.analysisWideRootNoiseCommand(b.analysisWideRootNoise)
                == "kata-set-param analysisWideRootNoise 0.1")
        #expect(GtpCommandBuilder.rulesetCommand(Config.rules[b.rule]) == "kata-set-rules chinese")

        // config c — same rule defaults as a
        let c = makeConfigs()[2]
        #expect(GtpCommandBuilder.analyzeCommand(interval: c.analysisInterval, maxMoves: c.maxAnalysisMoves)
                == "kata-analyze interval 50 maxmoves 50 ownership true ownershipStdev true rootInfo true")
    }

    @Test func builderMatchesConfigForArrayCommands() {
        // config a — defaults: all default rule values
        let a = makeConfigs()[0]
        #expect(GtpCommandBuilder.ruleCommandsBundle(
            ko: a.koRuleText, scoring: a.scoringRuleText, tax: a.taxRuleText,
            multiStoneSuicide: a.multiStoneSuicideLegal, hasButton: a.hasButton,
            whiteHandicapBonus: a.whiteHandicapBonusRuleText)
            == ["kata-set-rule ko SIMPLE",
                "kata-set-rule scoring AREA",
                "kata-set-rule tax NONE",
                "kata-set-rule suicide false",
                "kata-set-rule hasButton false",
                "kata-set-rule whiteHandicapBonus 0"])
        // config a: blackMaxTime=0 → clamped to 0.5
        #expect(GtpCommandBuilder.genMoveAnalyzeCommands(maxTime: a.blackMaxTime, interval: a.analysisInterval, maxMoves: a.maxAnalysisMoves)
                == ["kata-set-param maxTime 0.5",
                    "kata-search_analyze_cancellable interval 50 maxmoves 50 ownership true ownershipStdev true rootInfo true"])
        // config a: profiles equal ("AI") and ratios equal (0) → symmetric → non-empty commands
        #expect(GtpCommandBuilder.symmetricHumanAnalysisCommands(
            humanSLProfile: a.humanSLProfile, humanProfileForWhite: a.humanProfileForWhite,
            humanRatioForBlack: a.humanRatioForBlack, humanRatioForWhite: a.humanRatioForWhite)
            == HumanSLModel(profile: a.humanSLProfile)?.commands ?? [])

        // config b: blackMaxTime=3 → max(3, 0.5) = 3.0
        let b = makeConfigs()[1]
        #expect(GtpCommandBuilder.genMoveAnalyzeCommands(maxTime: b.blackMaxTime, interval: b.analysisInterval, maxMoves: b.maxAnalysisMoves)
                == ["kata-set-param maxTime 3.0",
                    "kata-search_analyze_cancellable interval 25 maxmoves 30 ownership true ownershipStdev true rootInfo true"])

        // config c: profiles equal but ratios differ → asymmetric → []
        let c = makeConfigs()[2]
        #expect(GtpCommandBuilder.symmetricHumanAnalysisCommands(
            humanSLProfile: c.humanSLProfile, humanProfileForWhite: c.humanProfileForWhite,
            humanRatioForBlack: c.humanRatioForBlack, humanRatioForWhite: c.humanRatioForWhite)
            == [])
    }
}

// MARK: - ConfigEngineSync focused orchestrator test

@MainActor
struct ConfigEngineSyncTests {
    @Test func setKomiUpdatesConfigAndEnqueuesKomiCommand() {
        let config = Config()
        let messageList = MessageList()
        ConfigEngineSync.setKomi(6.5, config: config, messageList: messageList)
        #expect(config.komi == 6.5)
        #expect(messageList.messages.last?.text == "> \(GtpCommandBuilder.komiCommand(6.5))")
    }

    /// Toggling a side to Human (thinking time 0) must reconfigure analysis to use
    /// the strongest net — the unbiased "AI" human-SL bundle — even if that side
    /// still has a human-style profile configured. Regression test for analysis
    /// being generated by the human SL profile while the side reads "Human".
    @Test func togglingSideToHumanReconfiguresAnalysisToBestAI() {
        let config = Config()
        let gobanState = GobanState()
        let player = Turn()
        let messageList = MessageList()

        // White is an AI running a human-style profile, and it's White's turn.
        config.humanProfileForWhite = "rank_5k"
        config.whiteMaxTime = Config.toggleAIThinkingTime
        player.nextColorForPlayCommand = .white

        // Tap the White name label: AI -> Human.
        ConfigEngineSync.setWhiteMaxTime(0, config: config, gobanState: gobanState,
                                         player: player, messageList: messageList)

        let texts = messageList.messages.map(\.text)
        let unbiased = HumanSLModel(profile: "AI")!.commands
        #expect(texts.contains("> \(unbiased[0])"))   // kata-set-param humanSLProfile rank_9d
        #expect(texts.contains("> kata-set-param humanSLChosenMoveProp 0.0"))
        #expect(texts.contains("> kata-set-param humanSLRootExploreProbWeightless 0.0"))
        #expect(texts.contains("> kata-set-param winLossUtilityFactor 1.0"))
    }

    /// The inverse: toggling a side back to AI restores its human-style bias so the
    /// engine again analyzes/plays in that profile's style.
    @Test func togglingSideToAIRestoresHumanStyleProfile() {
        let config = Config()
        let gobanState = GobanState()
        let player = Turn()
        let messageList = MessageList()

        // White is currently Human but has a human-style profile configured; White to move.
        config.humanProfileForWhite = "rank_5k"
        config.whiteMaxTime = 0
        player.nextColorForPlayCommand = .white

        // Tap the White name label: Human -> AI.
        ConfigEngineSync.setWhiteMaxTime(Config.toggleAIThinkingTime, config: config,
                                         gobanState: gobanState, player: player, messageList: messageList)

        let texts = messageList.messages.map(\.text)
        #expect(texts.contains("> kata-set-param humanSLProfile rank_5k"))
        #expect(texts.contains("> kata-set-param humanSLChosenMoveProp 1.0"))
    }

    /// Re-opening the AI config view assigns the persisted per-move time to the
    /// view's `@State`, which fires `.onChange` with the SAME value. Routing that
    /// no-op change through `setBlackMaxTime` must NOT re-send GTP or re-arm
    /// analysis. Regression test for spurious engine traffic merely on view appear.
    @Test func setBlackMaxTimeWithUnchangedValueSendsNothing() {
        let config = Config()
        config.blackMaxTime = 2.0
        let gobanState = GobanState()
        let player = Turn()
        let messageList = MessageList()

        ConfigEngineSync.setBlackMaxTime(2.0, config: config, gobanState: gobanState,
                                         player: player, messageList: messageList)

        #expect(messageList.messages.isEmpty)
        #expect(config.blackMaxTime == 2.0)
    }

    /// The guard must only suppress genuine no-ops: a real change (e.g. the
    /// AI/Human toggle flipping 0.5 → 0) still reconfigures the engine.
    @Test func setBlackMaxTimeWithChangedValueStillReconfigures() {
        let config = Config()
        config.blackMaxTime = 2.0
        let gobanState = GobanState()
        let player = Turn()
        let messageList = MessageList()

        ConfigEngineSync.setBlackMaxTime(0, config: config, gobanState: gobanState,
                                         player: player, messageList: messageList)

        #expect(config.blackMaxTime == 0)
        #expect(!messageList.messages.isEmpty)
    }

    /// Toggling a side to Human while a continuous analysis is streaming and the
    /// overlay is hidden (the power-saving case) must STOP the in-flight analysis.
    /// The stop is driven by forcing `waitingForAnalysis` true so the next streamed
    /// line crosses the true→false edge the analysis loop watches; the toggle path
    /// (via `rearmAnalysis`) must trigger it, not just no-op `maybeRequestAnalysis`.
    @Test func togglingToHumanWhileHiddenStopsRunningAnalysis() {
        let config = Config()
        config.blackMaxTime = Config.toggleAIThinkingTime   // 0.5 (AI)
        config.whiteMaxTime = Config.toggleAIThinkingTime   // 0.5 (AI)
        let gobanState = GobanState()
        gobanState.eyeStatus = .closed         // analysis overlay hidden
        gobanState.analysisStatus = .run
        gobanState.waitingForAnalysis = false  // mid-stream
        let player = Turn()
        player.nextColorForPlayCommand = .black
        let messageList = MessageList()

        // Tap Black's label → Human (0.5 → 0): White stays AI, Black (human) to move, hidden.
        ConfigEngineSync.setBlackMaxTime(0, config: config, gobanState: gobanState,
                                         player: player, messageList: messageList)

        #expect(gobanState.waitingForAnalysis == true)
    }
}
