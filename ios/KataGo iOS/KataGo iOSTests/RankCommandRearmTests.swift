//
//  RankCommandRearmTests.swift
//  KataGo iOSTests
//
//  Checklist: every analyze/gen-move command path used on tvOS deliberately
//  arms maxVisits. With the human net loaded (Task 3), the sticky rank
//  budgets 400/40 really apply, so a path that forgets to re-arm would
//  silently cripple analysis.
//

import Testing
@testable import KataGoUICore

struct RankCommandRearmTests {
    @Test("rank gen-moves arm the certified visit budgets")
    func rankGenMoveArmsTheRankBudget() {
        let weak = GtpCommandBuilder.genMoveAnalyzeCommands(
            effectiveProfile: "3k", maxTime: 0.5, interval: 50, maxMoves: 50)
        #expect(weak.contains("kata-set-param maxVisits 40"))
        let strong = GtpCommandBuilder.genMoveAnalyzeCommands(
            effectiveProfile: "9d", maxTime: 0.5, interval: 50, maxMoves: 50)
        #expect(strong.contains("kata-set-param maxVisits 400"))
        let pro = GtpCommandBuilder.genMoveAnalyzeCommands(
            effectiveProfile: "Pro 2023", maxTime: 0.5, interval: 50, maxMoves: 50)
        #expect(pro.contains("kata-set-param maxVisits 400"))
    }

    @Test("every continuous-analyze bundle re-arms maxVisits to unbounded")
    func continuousBundlesRearmUnbounded() {
        let slow = GtpCommandBuilder.continuousAnalyzeCommands(interval: 50, maxMoves: 50)
        let fast = GtpCommandBuilder.fastContinuousAnalyzeCommands(maxMoves: 50)
        #expect(slow.first == "kata-set-param maxVisits 1000000000")
        #expect(fast.first == "kata-set-param maxVisits 1000000000")
    }

    @MainActor
    @Test("the request fork: gen-move arms the rank budget, spectator paths re-arm unbounded")
    func requestAnalysisFork() {
        let gobanState = GobanState()
        let config = Config()
        config.whiteMaxTime = 0.5
        config.humanProfileForWhite = "3k"
        gobanState.analysisStatus = .run
        let genMove = gobanState.getRequestAnalysisCommands(
            config: config, nextColorForPlayCommand: .white)
        #expect(genMove.contains("kata-set-param maxVisits 40"))
        gobanState.suppressesGenMove = true
        let spectate = gobanState.getRequestAnalysisCommands(
            config: config, nextColorForPlayCommand: .white)
        #expect(spectate.first == "kata-set-param maxVisits 1000000000")
    }
}

// MARK: - chooseRank (the player label's long press)

extension RankCommandRearmTests {
    /// A rank picked for a side a person plays hands that side to the AI at
    /// the quick-toggle time and brings the engine up to date now: the side
    /// to move (Black, still a person) is analysed with the best-AI bundle
    /// and analysis re-arms with the unbounded visit reset.
    @MainActor
    @Test("a rank picked for a Human side flips it to the AI and re-arms now")
    func chooseRankOnAHumanSideFlipsAndRearms() {
        let config = Config()
        let gobanState = GobanState()
        let player = Turn()
        let messageList = MessageList.accepting()

        ConfigEngineSync.chooseRank("5d", for: .white, config: config,
                                    gobanState: gobanState, player: player, messageList: messageList)

        #expect(config.humanProfileForWhite == "5d")
        #expect(config.whiteMaxTime == Config.toggleAIThinkingTime)
        let texts = messageList.messages.map(\.text)
        let unbiased = HumanSLModel(profile: "AI")!.commands
        #expect(texts.contains("> \(unbiased[0])"))
        #expect(texts.contains("> kata-set-param maxVisits 1000000000"))
    }

    /// A rank picked for the side the engine is thinking for is only written:
    /// nothing is sent, so the running search is neither cancelled nor
    /// restarted; the next turn change picks the new profile and budget up.
    @MainActor
    @Test("a rank picked mid-think only writes")
    func chooseRankWhileThinkingOnlyWrites() {
        let config = Config()
        config.whiteMaxTime = Config.toggleAIThinkingTime
        config.humanProfileForWhite = "5k"
        let gobanState = GobanState()
        let player = Turn()
        player.nextColorForPlayCommand = .white
        let messageList = MessageList.accepting()
        #expect(gobanState.shouldGenMove(config: config, player: player))

        ConfigEngineSync.chooseRank("3k", for: .white, config: config,
                                    gobanState: gobanState, player: player, messageList: messageList)

        #expect(config.humanProfileForWhite == "3k")
        #expect(config.whiteMaxTime == Config.toggleAIThinkingTime)
        #expect(messageList.messages.isEmpty)
    }

    /// A rank picked for an AI side while the person is to move keeps that
    /// side's time and re-states the engine's human-SL state at once — the
    /// case `set*MaxTime`'s no-op guard and `set*HumanProfile`'s side-to-move
    /// skip would both have swallowed.
    @MainActor
    @Test("a rank picked for an idle AI side re-states the engine now")
    func chooseRankOnAnIdleAISideRearms() {
        let config = Config()
        config.whiteMaxTime = Config.toggleAIThinkingTime
        config.humanProfileForWhite = "5k"
        let gobanState = GobanState()
        let player = Turn()   // Black, a person, to move
        let messageList = MessageList.accepting()

        ConfigEngineSync.chooseRank("2d", for: .white, config: config,
                                    gobanState: gobanState, player: player, messageList: messageList)

        #expect(config.humanProfileForWhite == "2d")
        #expect(config.whiteMaxTime == Config.toggleAIThinkingTime)
        let texts = messageList.messages.map(\.text)
        let unbiased = HumanSLModel(profile: "AI")!.commands
        #expect(texts.contains("> \(unbiased[0])"))
        #expect(texts.contains("> kata-set-param maxVisits 1000000000"))
    }
}
