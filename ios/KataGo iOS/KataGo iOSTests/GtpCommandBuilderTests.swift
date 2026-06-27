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

    @Test func searchBudgetIsPerRankVisitsIgnoringTime() {
        // 9d and pros keep the strong 400-visit budget; the time magnitude is ignored.
        let strong = ["kata-set-param maxVisits 400",
                      "kata-set-param maxTime 60.0"]
        #expect(GtpCommandBuilder.searchBudgetCommands(effectiveProfile: "9d", maxTime: 0.5) == strong)
        #expect(GtpCommandBuilder.searchBudgetCommands(effectiveProfile: "9d", maxTime: 30.0) == strong)
        #expect(GtpCommandBuilder.searchBudgetCommands(effectiveProfile: "Pro 1800", maxTime: 0.5) == strong)
        // Weaker ranks (8d…20k) play fast at 40 visits, also ignoring the time.
        let weak = ["kata-set-param maxVisits 40",
                    "kata-set-param maxTime 60.0"]
        #expect(GtpCommandBuilder.searchBudgetCommands(effectiveProfile: "8d", maxTime: 0.5) == weak)
        #expect(GtpCommandBuilder.searchBudgetCommands(effectiveProfile: "5k", maxTime: 30.0) == weak)
        #expect(GtpCommandBuilder.searchBudgetCommands(effectiveProfile: "20k", maxTime: 0.5) == weak)
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

// MARK: - HumanSLModel: keys, key→engine mapping, legacy level-formula params, normalization

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

    @Test func humanProfilesUseLegacyLevelFormulas() {
        // 5k → level -5 in the restored level-based formulas.
        let cmds = HumanSLModel(profile: "5k")!.commands
        #expect(paramValue(in: cmds, "humanSLChosenMoveProp") == 1.0)
        #expect(paramValue(in: cmds, "humanSLRootExploreProbWeightless") == 0.5)
        #expect(paramValue(in: cmds, "chosenMoveTemperatureEarly") == 0.85)        // min-clamped
        #expect(paramValue(in: cmds, "chosenMoveTemperature") == 0.7)              // min-clamped
        #expect(paramValue(in: cmds, "chosenMoveTemperatureHalflife") == 82)       // 30 - (-5-8)*4
        #expect(paramValue(in: cmds, "chosenMoveTemperatureOnlyBelowProb") == 0.01) // max-clamped
        #expect(paramValue(in: cmds, "winLossUtilityFactor") == 0.0)              // human imitation
        #expect(paramValue(in: cmds, "staticScoreUtilityFactor") == 0.5)
        #expect(paramValue(in: cmds, "dynamicScoreUtilityFactor") == 0.5)
        // λ at level -5: 0.06 + (-5 - 9)^2 * 0.03 = 5.94.
        #expect(abs(paramValue(in: cmds, "humanSLChosenMovePiklLambda")! - 5.94) < 1e-3)
    }

    @Test func aiProfileEmittedCommandsArePreserved() {
        // AI keeps the level-9 legacy values (unchanged by the param revert). Asserted
        // by value (tolerance) so cosmetic Float formatting can't make this brittle.
        let cmds = HumanSLModel(profile: "AI")!.commands
        #expect(cmds.count == 11)
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
    }

    @Test func proProfilesUseLevel9LegacyConstants() {
        // A pro profile maps to level 9 (like AI): λ 0.06 and the level-9 temperatures,
        // but it is a HUMAN profile (root-explore 0.5, winLoss 0.0 — not AI's 0.0/1.0).
        let pro = HumanSLModel(profile: "Pro 1950")!.commands
        #expect(pro.contains("kata-set-param humanSLProfile proyear_1950"))
        #expect(abs(paramValue(in: pro, "humanSLChosenMovePiklLambda")! - 0.06) < 1e-4)
        #expect(paramValue(in: pro, "humanSLRootExploreProbWeightless") == 0.5)
        #expect(paramValue(in: pro, "winLossUtilityFactor") == 0.0)
        #expect(abs(paramValue(in: pro, "chosenMoveTemperature")! - 0.16) < 1e-4)   // level 9
        // 9d is a different (level-8) rank: preaz_9d engine profile, λ 0.09 (≠ 0.06).
        let nineDan = HumanSLModel(profile: "9d")!.commands
        #expect(nineDan.contains("kata-set-param humanSLProfile preaz_9d"))
        #expect(abs(paramValue(in: nineDan, "humanSLChosenMovePiklLambda")! - 0.09) < 1e-4)
    }

    @Test func humanSLChosenMovePiklLambdaMatchesLegacyFormula() {
        // Legacy λ = 0.06 + (level - 9)^2 * 0.03, with level derived from the rank key
        // (AI/pros → 9; "Nd" → N-1; "Nk" → -N).
        let expected: [String: Float] = [
            "9d": 0.09, "8d": 0.18, "1d": 2.49, "5k": 5.94, "20k": 25.29,
            "Pro 1950": 0.06, "AI": 0.06,
        ]
        for (key, lam) in expected {
            let cmds = HumanSLModel(profile: key)!.commands
            let value = paramValue(in: cmds, "humanSLChosenMovePiklLambda")
            #expect(value != nil)
            #expect(abs((value ?? 0) - lam) < 1e-3)
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
