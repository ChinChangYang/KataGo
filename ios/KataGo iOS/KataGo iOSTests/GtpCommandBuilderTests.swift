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
        // config a: blackMaxTime=0, profile "AI" → unbounded visits, maxTime floored to 0.5
        #expect(GtpCommandBuilder.genMoveAnalyzeCommands(effectiveProfile: a.effectiveHumanProfileForBlack, maxTime: a.blackMaxTime, interval: a.analysisInterval, maxMoves: a.maxAnalysisMoves)
                == ["kata-set-param maxVisits 1000000000",
                    "kata-set-param maxTime 0.5",
                    "kata-search_analyze_cancellable interval 50 maxmoves 50 ownership true ownershipStdev true rootInfo true"])
        // config a: profiles equal ("AI") and ratios equal (0) → symmetric → non-empty commands
        #expect(GtpCommandBuilder.symmetricHumanAnalysisCommands(
            humanSLProfile: a.humanSLProfile, humanProfileForWhite: a.humanProfileForWhite,
            humanRatioForBlack: a.humanRatioForBlack, humanRatioForWhite: a.humanRatioForWhite)
            == HumanSLModel(profile: a.humanSLProfile)?.commands ?? [])

        // config b: blackMaxTime=3, profile "AI" → unbounded visits, maxTime 3.0
        let b = makeConfigs()[1]
        #expect(GtpCommandBuilder.genMoveAnalyzeCommands(effectiveProfile: b.effectiveHumanProfileForBlack, maxTime: b.blackMaxTime, interval: b.analysisInterval, maxMoves: b.maxAnalysisMoves)
                == ["kata-set-param maxVisits 1000000000",
                    "kata-set-param maxTime 3.0",
                    "kata-search_analyze_cancellable interval 25 maxmoves 30 ownership true ownershipStdev true rootInfo true"])

        // config c: profiles equal but ratios differ → asymmetric → []
        let c = makeConfigs()[2]
        #expect(GtpCommandBuilder.symmetricHumanAnalysisCommands(
            humanSLProfile: c.humanSLProfile, humanProfileForWhite: c.humanProfileForWhite,
            humanRatioForBlack: c.humanRatioForBlack, humanRatioForWhite: c.humanRatioForWhite)
            == [])
    }

    @Test func searchBudgetForAIProfileIsTimeBoundedUnboundedVisits() {
        #expect(GtpCommandBuilder.searchBudgetCommands(effectiveProfile: "AI", maxTime: 2.0)
                == ["kata-set-param maxVisits 1000000000",
                    "kata-set-param maxTime 2.0"])
        // maxTime is floored at 0.5 for the AI profile.
        #expect(GtpCommandBuilder.searchBudgetCommands(effectiveProfile: "AI", maxTime: 0.0)
                == ["kata-set-param maxVisits 1000000000",
                    "kata-set-param maxTime 0.5"])
    }

    @Test func searchBudgetForHumanProfileIsFixed400VisitsIgnoringTime() {
        let expected = ["kata-set-param maxVisits 400",
                        "kata-set-param maxTime 60.0"]
        // The time magnitude is irrelevant for a human profile.
        #expect(GtpCommandBuilder.searchBudgetCommands(effectiveProfile: "9d", maxTime: 0.5) == expected)
        #expect(GtpCommandBuilder.searchBudgetCommands(effectiveProfile: "9d", maxTime: 30.0) == expected)
        #expect(GtpCommandBuilder.searchBudgetCommands(effectiveProfile: "Pro 1800", maxTime: 0.5) == expected)
    }

    @Test func genMoveAnalyzeCommandsPrependsBudget() {
        #expect(GtpCommandBuilder.genMoveAnalyzeCommands(effectiveProfile: "AI", maxTime: 0.5, interval: 50, maxMoves: 50)
                == ["kata-set-param maxVisits 1000000000",
                    "kata-set-param maxTime 0.5",
                    "kata-search_analyze_cancellable interval 50 maxmoves 50 ownership true ownershipStdev true rootInfo true"])
        #expect(GtpCommandBuilder.genMoveAnalyzeCommands(effectiveProfile: "5k", maxTime: 3.0, interval: 25, maxMoves: 30)
                == ["kata-set-param maxVisits 400",
                    "kata-set-param maxTime 60.0",
                    "kata-search_analyze_cancellable interval 25 maxmoves 30 ownership true ownershipStdev true rootInfo true"])
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
        config.humanProfileForWhite = "5k"
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
        config.humanProfileForWhite = "5k"
        config.whiteMaxTime = 0
        player.nextColorForPlayCommand = .white

        // Tap the White name label: Human -> AI.
        ConfigEngineSync.setWhiteMaxTime(Config.toggleAIThinkingTime, config: config,
                                         gobanState: gobanState, player: player, messageList: messageList)

        let texts = messageList.messages.map(\.text)
        #expect(texts.contains("> kata-set-param humanSLProfile preaz_5k"))
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

// MARK: - HumanSLModel: keys, key→engine mapping, #1209 λ ladder, legacy normalization

struct HumanSLModelTests {

    private func lambdaValue(in commands: [String]) -> Float? {
        let prefix = "kata-set-param humanSLChosenMovePiklLambda "
        guard let line = commands.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return Float(line.dropFirst(prefix.count))
    }

    @Test func allProfilesAreCleanUnifiedKeys() {
        let all = HumanSLModel.allProfiles
        #expect(all.first == "AI")
        #expect(all.contains("9d"))
        #expect(all.contains("20k"))
        #expect(all.contains("Pro 1800"))
        #expect(all.contains("Pro 2023"))
        // The old duplicated/raw engine strings are gone from the menu.
        #expect(!all.contains("rank_9d"))
        #expect(!all.contains("preaz_9d"))
        #expect(!all.contains("proyear_2023"))
        // 1 (AI) + 29 ranks (9d…1d, 1k…20k) + 224 pros (1800…2023) = 254.
        #expect(all.count == 254)
    }

    @Test func defaultProfileIsAI() {
        #expect(HumanSLModel().profile == "AI")
    }

    @Test func rankKeyMapsToPreazEngineProfile() {
        #expect(HumanSLModel(profile: "9d")?.commands.contains("kata-set-param humanSLProfile preaz_9d") == true)
        #expect(HumanSLModel(profile: "5k")?.commands.contains("kata-set-param humanSLProfile preaz_5k") == true)
        #expect(HumanSLModel(profile: "20k")?.commands.contains("kata-set-param humanSLProfile preaz_20k") == true)
    }

    @Test func proKeyMapsToProyearEngineProfile() {
        #expect(HumanSLModel(profile: "Pro 2023")?.commands.contains("kata-set-param humanSLProfile proyear_2023") == true)
        #expect(HumanSLModel(profile: "Pro 1800")?.commands.contains("kata-set-param humanSLProfile proyear_1800") == true)
    }

    @Test func aiMapsToRank9dEngineProfile() {
        #expect(HumanSLModel(profile: "AI")?.commands.contains("kata-set-param humanSLProfile rank_9d") == true)
    }

    @Test func humanProfilesUse1209Constants() {
        let cmds = HumanSLModel(profile: "5k")!.commands
        #expect(cmds.contains("kata-set-param humanSLChosenMoveProp 1.0"))
        #expect(cmds.contains("kata-set-param humanSLRootExploreProbWeightless 0.8"))
        #expect(cmds.contains("kata-set-param chosenMoveTemperatureEarly 0.7"))
        #expect(cmds.contains("kata-set-param chosenMoveTemperature 0.25"))
        #expect(cmds.contains("kata-set-param chosenMoveTemperatureHalflife 30"))
        #expect(cmds.contains("kata-set-param chosenMoveTemperatureOnlyBelowProb 1.0"))
        #expect(cmds.contains("kata-set-param winLossUtilityFactor 1.0"))
        #expect(cmds.contains("kata-set-param staticScoreUtilityFactor 0.5"))
        #expect(cmds.contains("kata-set-param dynamicScoreUtilityFactor 0.5"))
    }

    @Test func aiProfileEmittedCommandsArePreserved() {
        // AI keeps the same param VALUES as today's level-9 emission (the new
        // literals just format cleaner than the old float arithmetic, e.g.
        // 0.66999996 → 0.67). This pins the canonical AI command list.
        #expect(HumanSLModel(profile: "AI")!.commands == [
            "kata-set-param humanSLProfile rank_9d",
            "kata-set-param humanSLChosenMoveProp 0.0",
            "kata-set-param humanSLRootExploreProbWeightless 0.0",
            "kata-set-param chosenMoveTemperatureEarly 0.67",
            "kata-set-param chosenMoveTemperature 0.16",
            "kata-set-param chosenMoveTemperatureHalflife 26",
            "kata-set-param chosenMoveTemperatureOnlyBelowProb 1.0",
            "kata-set-param humanSLChosenMovePiklLambda 0.06",
            "kata-set-param winLossUtilityFactor 1.0",
            "kata-set-param staticScoreUtilityFactor 0.1",
            "kata-set-param dynamicScoreUtilityFactor 0.3",
        ])
    }

    @Test func proProfileDerivesFrom9dWithLambda006() {
        let pro = HumanSLModel(profile: "Pro 1950")!.commands
        let nineDan = HumanSLModel(profile: "9d")!.commands
        // Same constant set as 9d except the profile line and λ.
        #expect(pro.contains("kata-set-param humanSLProfile proyear_1950"))
        #expect(lambdaValue(in: pro)! == 0.06)
        #expect(pro.contains("kata-set-param humanSLRootExploreProbWeightless 0.8"))
        #expect(pro.contains("kata-set-param winLossUtilityFactor 1.0"))
        #expect(pro.contains("kata-set-param chosenMoveTemperature 0.25"))
        // 9d differs only by profile (preaz_9d) and λ (0.045).
        #expect(nineDan.contains("kata-set-param humanSLProfile preaz_9d"))
        #expect(lambdaValue(in: nineDan)! != 0.06)
    }

    @Test func rankLambdaLadderMatches1209() {
        let expected: [String: Float] = [
            "9d": 0.045, "8d": 0.0868, "7d": 0.1267, "6d": 0.1983, "5d": 0.28064,
            "4d": 0.373, "3d": 0.45556, "2d": 0.5133, "1d": 0.5093,
            "1k": 0.48988, "2k": 0.46755, "3k": 0.49173, "4k": 0.4713, "5k": 0.5072,
            "6k": 0.48925, "7k": 0.5337, "8k": 0.5064, "9k": 0.5388, "10k": 0.59036,
            "11k": 0.56458, "12k": 0.54297, "13k": 0.58977, "14k": 0.61625, "15k": 0.61839,
            "16k": 0.6705, "17k": 0.7413, "18k": 0.7821, "19k": 0.8982, "20k": 1.2227,
        ]
        for (key, lam) in expected {
            let cmds = HumanSLModel(profile: key)!.commands
            let value = lambdaValue(in: cmds)
            #expect(value != nil)
            #expect(abs((value ?? 0) - lam) < 1e-4)
        }
    }

    @Test func legacyEngineStringsNormalizeToUnifiedKeys() {
        #expect(HumanSLModel(profile: "rank_9d")?.profile == "9d")
        #expect(HumanSLModel(profile: "preaz_9d")?.profile == "9d")   // both collapse
        #expect(HumanSLModel(profile: "preaz_5k")?.profile == "5k")
        #expect(HumanSLModel(profile: "proyear_2000")?.profile == "Pro 2000")
        #expect(HumanSLModel(profile: "AI")?.profile == "AI")
        // A normalized legacy rank still drives the preaz engine profile.
        #expect(HumanSLModel(profile: "rank_5k")?.commands.contains("kata-set-param humanSLProfile preaz_5k") == true)
    }

    @Test func unrecognizedProfileIsRejectedAndCanonicalizesToAI() {
        #expect(HumanSLModel(profile: "garbage_profile") == nil)
        #expect(HumanSLModel.canonicalProfile("garbage_profile") == "AI")
        #expect(HumanSLModel.canonicalProfile("rank_3d") == "3d")
        #expect(HumanSLModel.canonicalProfile("Pro 1999") == "Pro 1999")
        #expect(HumanSLModel.canonicalProfile("7k") == "7k")
    }
}

// MARK: - GobanState search-budget routing (gen-move vs continuous analysis)

@MainActor
struct AnalysisBudgetRoutingTests {

    private func runningState() -> GobanState {
        let s = GobanState()
        s.analysisStatus = .run
        return s
    }

    @Test func aiSideGenMoveIsTimeBoundedUnboundedVisits() {
        let config = Config()                 // default profile "AI"
        config.blackMaxTime = 2.0             // engine plays Black
        let cmds = runningState().getRequestAnalysisCommands(config: config, nextColorForPlayCommand: .black)
        #expect(cmds == ["kata-set-param maxVisits 1000000000",
                         "kata-set-param maxTime 2.0",
                         "kata-search_analyze_cancellable interval 50 maxmoves 50 ownership true ownershipStdev true rootInfo true"])
    }

    @Test func humanSideGenMoveIsFixed400VisitsIgnoringTime() {
        let config = Config()
        config.humanProfileForBlack = "9d"
        config.blackMaxTime = 0.5            // engine plays Black as 9d; magnitude ignored
        let cmds = runningState().getRequestAnalysisCommands(config: config, nextColorForPlayCommand: .black)
        #expect(cmds == ["kata-set-param maxVisits 400",
                         "kata-set-param maxTime 60.0",
                         "kata-search_analyze_cancellable interval 50 maxmoves 50 ownership true ownershipStdev true rootInfo true"])
    }

    @Test func continuousAnalysisResetsVisitsToUnbounded() {
        let config = Config()                 // blackMaxTime 0 → human plays → analysis branch
        let cmds = runningState().getRequestAnalysisCommands(config: config, nextColorForPlayCommand: .black)
        #expect(cmds == ["kata-set-param maxVisits 1000000000",
                         "kata-analyze interval 10 maxmoves 50 ownership true ownershipStdev true rootInfo true"])
    }
}
