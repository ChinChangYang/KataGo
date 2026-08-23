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
        #expect(GtpCommandBuilder.komiCommand(a.komi) == "komi 7.5")
        #expect(GtpCommandBuilder.playoutDoublingAdvantageCommand(a.playoutDoublingAdvantage)
                == "kata-set-param playoutDoublingAdvantage 0.0")
        #expect(GtpCommandBuilder.analysisWideRootNoiseCommand(a.analysisWideRootNoise)
                == "kata-set-param analysisWideRootNoise 0.03125")
        #expect(GtpCommandBuilder.rulesetCommand(Config.rules[a.rule]) == "kata-set-rules tromp-taylor")
        #expect(GtpCommandBuilder.koRuleCommand(a.koRuleText) == "kata-set-rule ko POSITIONAL")
        #expect(GtpCommandBuilder.scoringRuleCommand(a.scoringRuleText) == "kata-set-rule scoring AREA")
        #expect(GtpCommandBuilder.taxRuleCommand(a.taxRuleText) == "kata-set-rule tax NONE")
        #expect(GtpCommandBuilder.multiStoneSuicideCommand(a.multiStoneSuicideLegal) == "kata-set-rule suicide true")
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
        #expect(GtpCommandBuilder.rulesetCommand(Config.rules[b.rule]) == "kata-set-rules tromp-taylor")

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
            == ["kata-set-rule ko POSITIONAL",
                "kata-set-rule scoring AREA",
                "kata-set-rule tax NONE",
                "kata-set-rule suicide true",
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

    @Test func searchBudgetIsPerRankVisitsIgnoringTime() {
        // 9d and pros keep the strong 400-visit budget; the time magnitude is ignored.
        let strong = ["kata-set-param maxVisits 400",
                      "kata-set-param maxTime 60.0"]
        #expect(GtpCommandBuilder.searchBudgetCommands(effectiveProfile: "9d", maxTime: 0.5) == strong)
        #expect(GtpCommandBuilder.searchBudgetCommands(effectiveProfile: "9d", maxTime: 30.0) == strong)
        #expect(GtpCommandBuilder.searchBudgetCommands(effectiveProfile: "Pro 1800", maxTime: 0.5) == strong)
        // Ladder rungs (8d…25k) play fast at 40 visits, also ignoring the time.
        let weak = ["kata-set-param maxVisits 40",
                    "kata-set-param maxTime 60.0"]
        #expect(GtpCommandBuilder.searchBudgetCommands(effectiveProfile: "8d", maxTime: 0.5) == weak)
        #expect(GtpCommandBuilder.searchBudgetCommands(effectiveProfile: "5k", maxTime: 30.0) == weak)
        #expect(GtpCommandBuilder.searchBudgetCommands(effectiveProfile: "20k", maxTime: 0.5) == weak)
        #expect(GtpCommandBuilder.searchBudgetCommands(effectiveProfile: "25k", maxTime: 0.5) == weak)
    }

    @Test func genMoveAnalyzeCommandsPrependsBudget() {
        #expect(GtpCommandBuilder.genMoveAnalyzeCommands(effectiveProfile: "AI", maxTime: 0.5, interval: 50, maxMoves: 50)
                == ["kata-set-param maxVisits 1000000000",
                    "kata-set-param maxTime 0.5",
                    "kata-search_analyze_cancellable interval 50 maxmoves 50 ownership true ownershipStdev true rootInfo true"])
        #expect(GtpCommandBuilder.genMoveAnalyzeCommands(effectiveProfile: "5k", maxTime: 3.0, interval: 25, maxMoves: 30)
                == ["kata-set-param maxVisits 40",
                    "kata-set-param maxTime 60.0",
                    "kata-search_analyze_cancellable interval 25 maxmoves 30 ownership true ownershipStdev true rootInfo true"])
    }

    @Test func continuousAnalyzeBundlesAlwaysResetMaxVisits() {
        // The reset is structural: every continuous-analysis re-arm goes through
        // these bundles, so a prior human-profile gen-move's sticky maxVisits=400
        // can never silently cap analysis (the load-bearing invariant behind the
        // rank-is-strength feature — and behind watch-driven navigation, which
        // multiplies re-arms).
        let cmds = GtpCommandBuilder.continuousAnalyzeCommands(interval: 25, maxMoves: 30)
        #expect(cmds.first == "kata-set-param maxVisits \(GtpCommandBuilder.unboundedMaxVisits)")
        #expect(cmds.last == "kata-analyze interval 25 maxmoves 30 ownership true ownershipStdev true rootInfo true")

        let fast = GtpCommandBuilder.fastContinuousAnalyzeCommands(maxMoves: 50)
        #expect(fast.first == "kata-set-param maxVisits \(GtpCommandBuilder.unboundedMaxVisits)")
        #expect(fast.last == "kata-analyze interval 10 maxmoves 50 ownership true ownershipStdev true rootInfo true")
    }
}

// MARK: - ConfigEngineSync focused orchestrator test

@MainActor
struct ConfigEngineSyncTests {
    @Test func setKomiUpdatesConfigAndEnqueuesKomiCommand() {
        let config = Config()
        let messageList = MessageList.accepting()
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
        let messageList = MessageList.accepting()

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
        let messageList = MessageList.accepting()

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
        let messageList = MessageList.accepting()

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
        let messageList = MessageList.accepting()

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
        let messageList = MessageList.accepting()

        // Tap Black's label → Human (0.5 → 0): White stays AI, Black (human) to move, hidden.
        ConfigEngineSync.setBlackMaxTime(0, config: config, gobanState: gobanState,
                                         player: player, messageList: messageList)

        #expect(gobanState.waitingForAnalysis == true)
    }
}

// MARK: - HumanSLModel: keys, key→engine mapping, #1209 ladder params, normalization

struct HumanSLModelTests {

    /// Parse the Float value emitted for a `kata-set-param <name>` line. The trailing
    /// space in the prefix keeps `chosenMoveTemperature` from matching
    /// `chosenMoveTemperatureEarly`/`…Halflife`/`…OnlyBelowProb`.
    private func paramValue(in commands: [String], _ name: String) -> Float? {
        let prefix = "kata-set-param \(name) "
        guard let line = commands.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return Float(line.dropFirst(prefix.count))
    }

    @Test func allProfilesAreCleanUnifiedKeys() {
        let all = HumanSLModel.allProfiles
        #expect(all.first == "AI")
        #expect(all.contains("9d"))
        #expect(all.contains("20k"))
        #expect(all.contains("25k"))
        #expect(all.contains("Pro 1800"))
        #expect(all.contains("Pro 2023"))
        // The old duplicated/raw engine strings are gone from the menu.
        #expect(!all.contains("rank_9d"))
        #expect(!all.contains("preaz_9d"))
        #expect(!all.contains("proyear_2023"))
        // 1 (AI) + 34 ranks (9d…1d, 1k…25k) + 224 pros (1800…2023) = 259.
        #expect(all.count == 259)
    }

    @Test func defaultProfileIsAI() {
        #expect(HumanSLModel().profile == "AI")
    }

    @Test func rankKeyMapsToPreazEngineProfile() {
        #expect(HumanSLModel(profile: "9d")?.commands.contains("kata-set-param humanSLProfile preaz_9d") == true)
        #expect(HumanSLModel(profile: "5k")?.commands.contains("kata-set-param humanSLProfile preaz_5k") == true)
        #expect(HumanSLModel(profile: "20k")?.commands.contains("kata-set-param humanSLProfile preaz_20k") == true)
        #expect(HumanSLModel(profile: "25k")?.commands.contains("kata-set-param humanSLProfile preaz_25k") == true)
    }

    @Test func proKeyMapsToProyearEngineProfile() {
        #expect(HumanSLModel(profile: "Pro 2023")?.commands.contains("kata-set-param humanSLProfile proyear_2023") == true)
        #expect(HumanSLModel(profile: "Pro 1800")?.commands.contains("kata-set-param humanSLProfile proyear_1800") == true)
    }

    @Test func aiMapsToRank9dEngineProfile() {
        #expect(HumanSLModel(profile: "AI")?.commands.contains("kata-set-param humanSLProfile rank_9d") == true)
    }

    @Test func humanRankProfilesUseCalibratedLadderConstants() {
        // #1209 ladder rungs share constant human params; only λ varies by rank.
        let cmds = HumanSLModel(profile: "5k")!.commands
        #expect(paramValue(in: cmds, "humanSLChosenMoveProp") == 1.0)
        #expect(paramValue(in: cmds, "humanSLRootExploreProbWeightless") == 0.8)
        #expect(paramValue(in: cmds, "chosenMoveTemperatureEarly") == 0.7)
        #expect(paramValue(in: cmds, "chosenMoveTemperature") == 0.25)
        #expect(paramValue(in: cmds, "chosenMoveTemperatureHalflife") == 30)
        #expect(paramValue(in: cmds, "chosenMoveTemperatureOnlyBelowProb") == 1.0)
        #expect(paramValue(in: cmds, "winLossUtilityFactor") == 0.0)              // human imitation
        #expect(paramValue(in: cmds, "staticScoreUtilityFactor") == 0.5)
        #expect(paramValue(in: cmds, "dynamicScoreUtilityFactor") == 0.5)
        // 5k's certified even-game λ.
        #expect(abs(paramValue(in: cmds, "humanSLChosenMovePiklLambda")! - 0.216) < 1e-4)
        // Calibration environment: the four search heuristics are OFF for human play.
        #expect(cmds.contains("kata-set-param useLcbForSelection false"))
        #expect(cmds.contains("kata-set-param useUncertainty false"))
        #expect(cmds.contains("kata-set-param useNoisePruning false"))
        #expect(cmds.contains("kata-set-param subtreeValueBiasFactor 0.0"))
    }

    @Test func aiProfileEmittedCommandsArePreserved() {
        // AI keeps its established values; the four search-heuristic RESTORES are
        // appended so a prior human-profile move's sticky overrides never leak into
        // full-strength play/analysis (engine GTP defaults: true/true/true/0.45).
        let cmds = HumanSLModel(profile: "AI")!.commands
        #expect(cmds.count == 15)
        #expect(cmds.first == "kata-set-param humanSLProfile rank_9d")
        #expect(paramValue(in: cmds, "humanSLChosenMoveProp") == 0.0)
        #expect(paramValue(in: cmds, "humanSLRootExploreProbWeightless") == 0.0)
        #expect(abs(paramValue(in: cmds, "chosenMoveTemperatureEarly")! - 0.67) < 1e-4)
        #expect(abs(paramValue(in: cmds, "chosenMoveTemperature")! - 0.16) < 1e-4)
        #expect(paramValue(in: cmds, "chosenMoveTemperatureHalflife") == 26)
        #expect(paramValue(in: cmds, "chosenMoveTemperatureOnlyBelowProb") == 1.0)
        #expect(abs(paramValue(in: cmds, "humanSLChosenMovePiklLambda")! - 0.06) < 1e-4)
        #expect(paramValue(in: cmds, "winLossUtilityFactor") == 1.0)
        #expect(abs(paramValue(in: cmds, "staticScoreUtilityFactor")! - 0.1) < 1e-4)
        #expect(abs(paramValue(in: cmds, "dynamicScoreUtilityFactor")! - 0.3) < 1e-4)
        #expect(cmds.contains("kata-set-param useLcbForSelection true"))
        #expect(cmds.contains("kata-set-param useUncertainty true"))
        #expect(cmds.contains("kata-set-param useNoisePruning true"))
        #expect(cmds.contains("kata-set-param subtreeValueBiasFactor 0.45"))
    }

    @Test func proProfilesUseFamilyConstants() {
        // Pros share the ladder's constant human params with the 8d-anchor λ 0.06:
        // imitation (winLoss 0), root-explore 0.8, temps 0.70/0.25.
        let pro = HumanSLModel(profile: "Pro 1950")!.commands
        #expect(pro.contains("kata-set-param humanSLProfile proyear_1950"))
        #expect(abs(paramValue(in: pro, "humanSLChosenMovePiklLambda")! - 0.06) < 1e-4)
        #expect(paramValue(in: pro, "humanSLRootExploreProbWeightless") == 0.8)
        #expect(paramValue(in: pro, "winLossUtilityFactor") == 0.0)
        #expect(paramValue(in: pro, "chosenMoveTemperature") == 0.25)
        #expect(pro.contains("kata-set-param useLcbForSelection false"))
    }

    @Test func nineDanIsTheLegacyStrongReference() {
        // 9d sits above the 40-visit ladder: preaz_9d @ 400 visits (budget asserted in
        // searchBudgetIsPerRankVisitsIgnoringTime), λ 0.045, and — uniquely among human
        // profiles — try-to-win (winLossUtilityFactor 1.0), per the PR docs' legacy 9d.
        let cmds = HumanSLModel(profile: "9d")!.commands
        #expect(cmds.contains("kata-set-param humanSLProfile preaz_9d"))
        #expect(abs(paramValue(in: cmds, "humanSLChosenMovePiklLambda")! - 0.045) < 1e-4)
        #expect(paramValue(in: cmds, "winLossUtilityFactor") == 1.0)
        #expect(paramValue(in: cmds, "humanSLRootExploreProbWeightless") == 0.8)
        #expect(paramValue(in: cmds, "staticScoreUtilityFactor") == 0.5)
        #expect(paramValue(in: cmds, "dynamicScoreUtilityFactor") == 0.5)
    }

    @Test func humanSLChosenMovePiklLambdaMatchesCalibratedLadder() {
        // The certified per-rank λ from PR #1209 (docs/HumanSL_Rank_Ladder.md): the
        // 7d…14k staircase values, the 15k…25k pure-human tail (1e8), the hand-set
        // 8d anchor, and the legacy-strong 9d.
        let expected: [String: Float] = [
            "9d": 0.045, "8d": 0.06, "7d": 0.0776, "6d": 0.0994, "5d": 0.1324,
            "4d": 0.1575, "3d": 0.1896, "2d": 0.213, "1d": 0.1917,
            "1k": 0.2015, "2k": 0.1995, "3k": 0.2076, "4k": 0.2118, "5k": 0.216,
            "6k": 0.2248, "7k": 0.2459, "8k": 0.2584, "9k": 0.3062, "10k": 0.3725,
            "11k": 0.4081, "12k": 0.463, "13k": 0.83, "14k": 3.4004,
            "15k": 1e8, "18k": 1e8, "20k": 1e8, "21k": 1e8, "25k": 1e8,
            "Pro 1950": 0.06, "AI": 0.06,
        ]
        for (key, lam) in expected {
            let cmds = HumanSLModel(profile: key)!.commands
            let value = paramValue(in: cmds, "humanSLChosenMovePiklLambda")
            #expect(value != nil)
            #expect(abs((value ?? 0) - lam) < max(1e-4, lam * 1e-6), "λ mismatch for \(key)")
        }
    }

    @Test func legacyEngineStringsNormalizeToUnifiedKeys() {
        #expect(HumanSLModel(profile: "rank_9d")?.profile == "9d")
        #expect(HumanSLModel(profile: "preaz_9d")?.profile == "9d")   // both collapse
        #expect(HumanSLModel(profile: "preaz_5k")?.profile == "5k")
        #expect(HumanSLModel(profile: "preaz_25k")?.profile == "25k")
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

    @Test func humanStrongRankSideGenMoveIsFixed400VisitsIgnoringTime() {
        let config = Config()
        config.humanProfileForBlack = "9d"
        config.blackMaxTime = 0.5            // engine plays Black as 9d; magnitude ignored
        let cmds = runningState().getRequestAnalysisCommands(config: config, nextColorForPlayCommand: .black)
        #expect(cmds == ["kata-set-param maxVisits 400",
                         "kata-set-param maxTime 60.0",
                         "kata-search_analyze_cancellable interval 50 maxmoves 50 ownership true ownershipStdev true rootInfo true"])
    }

    @Test func humanWeakRankSideGenMoveIsFast40Visits() {
        let config = Config()
        config.humanProfileForBlack = "5k"
        config.blackMaxTime = 0.5            // engine plays Black as 5k; magnitude ignored
        let cmds = runningState().getRequestAnalysisCommands(config: config, nextColorForPlayCommand: .black)
        #expect(cmds == ["kata-set-param maxVisits 40",
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
