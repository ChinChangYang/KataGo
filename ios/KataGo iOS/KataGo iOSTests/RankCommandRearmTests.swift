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

// MARK: - set*HumanProfile (the settings forms' profile and Year pickers)

extension RankCommandRearmTests {
    private func profileLines(_ messageList: MessageList) -> [String] {
        messageList.messages.map(\.text).filter { $0.hasPrefix("> kata-set-param humanSLProfile ") }
    }

    /// Opening the AI settings seeds each picker with the canonical key, so a
    /// legacy "5k" arrives back as "5k 2016": the same profile, so nothing is
    /// written (a SwiftData write re-uploads the record) and nothing is sent.
    @MainActor
    @Test("an unchanged profile, in any spelling, writes and sends nothing")
    func unchangedProfileIsANoOp() {
        let config = Config()
        config.blackMaxTime = Config.toggleAIThinkingTime
        config.humanProfileForBlack = "5k"
        let gobanState = GobanState()
        gobanState.analysisStatus = .pause
        let player = Turn()   // Black to move, idle
        let messageList = MessageList.accepting()

        ConfigEngineSync.setBlackHumanProfile("5k 2016", config: config, gobanState: gobanState,
                                              player: player, messageList: messageList)

        #expect(config.humanProfileForBlack == "5k")
        #expect(messageList.messages.isEmpty)
    }

    /// A Year or profile picked for the side the engine is thinking for is
    /// only written: sending the bundle would cancel the search and the AI's
    /// move would never land. The next turn change owes the engine a re-send.
    @MainActor
    @Test("a profile picked mid-think only writes, and owes a re-send")
    func profileChangeWhileThinkingOnlyWrites() {
        let config = Config()
        config.blackMaxTime = Config.toggleAIThinkingTime
        config.humanProfileForBlack = "5k 2016"
        let gobanState = GobanState()
        let player = Turn()   // Black to move
        let messageList = MessageList.accepting()
        #expect(gobanState.shouldGenMove(config: config, player: player))

        ConfigEngineSync.setBlackHumanProfile("5k 2019", config: config, gobanState: gobanState,
                                              player: player, messageList: messageList)

        #expect(config.humanProfileForBlack == "5k 2019")
        #expect(messageList.messages.isEmpty)
        #expect(gobanState.humanSLResendOwed)
    }

    /// An idle AI side to move is re-stated now, and analysis re-arms: the
    /// bundle's first command stops any continuous `kata-analyze`.
    @MainActor
    @Test("a profile picked for an idle side to move is sent now and re-arms")
    func profileChangeForIdleSideToMoveSendsNow() {
        let config = Config()
        config.blackMaxTime = Config.toggleAIThinkingTime
        config.humanProfileForBlack = "5k 2016"
        let gobanState = GobanState()
        gobanState.analysisStatus = .pause
        let player = Turn()   // Black to move
        let messageList = MessageList.accepting()

        ConfigEngineSync.setBlackHumanProfile("5k 2019", config: config, gobanState: gobanState,
                                              player: player, messageList: messageList)

        #expect(profileLines(messageList) == ["> kata-set-param humanSLProfile rankyear_2019_5k"])
        #expect(messageList.messages.map(\.text).contains("> kata-set-param maxVisits 1000000000"))
        #expect(!gobanState.humanSLResendOwed)
    }

    /// The side not to move is only written: its bundle goes out at its turn.
    @MainActor
    @Test("a profile picked for the side not to move waits for its turn")
    func profileChangeForTheOtherSideWaits() {
        let config = Config()
        config.whiteMaxTime = Config.toggleAIThinkingTime
        config.humanProfileForWhite = "5k 2016"
        let gobanState = GobanState()
        let player = Turn()   // Black, a person, to move
        let messageList = MessageList.accepting()

        ConfigEngineSync.setWhiteHumanProfile("3d 2019", config: config, gobanState: gobanState,
                                              player: player, messageList: messageList)

        #expect(config.humanProfileForWhite == "3d 2019")
        #expect(messageList.messages.isEmpty)
        #expect(!gobanState.humanSLResendOwed)
    }

    /// A side a person plays is analysed by the best-AI bundle whatever its
    /// profile, so a profile change there changes nothing in the engine.
    @MainActor
    @Test("a profile picked for a side a person plays sends nothing")
    func profileChangeForAHumanSideSendsNothing() {
        let config = Config()
        config.humanProfileForBlack = "5k 2016"   // blackMaxTime 0: a person
        let gobanState = GobanState()
        let player = Turn()   // Black to move
        let messageList = MessageList.accepting()

        ConfigEngineSync.setBlackHumanProfile("3d 2019", config: config, gobanState: gobanState,
                                              player: player, messageList: messageList)

        #expect(config.humanProfileForBlack == "3d 2019")
        #expect(messageList.messages.isEmpty)
    }

    /// Auto-play owns the engine's human-SL state (it forces the best-AI
    /// bundle); its exit re-states both sides.
    @MainActor
    @Test("a profile picked during auto-play only writes")
    func profileChangeDuringAutoPlayOnlyWrites() {
        let config = Config()
        config.blackMaxTime = Config.toggleAIThinkingTime
        config.humanProfileForBlack = "5k 2016"
        let gobanState = GobanState()
        gobanState.isAutoPlaying = true
        let player = Turn()   // Black to move
        let messageList = MessageList.accepting()

        ConfigEngineSync.setBlackHumanProfile("5k 2019", config: config, gobanState: gobanState,
                                              player: player, messageList: messageList)

        #expect(config.humanProfileForBlack == "5k 2019")
        #expect(messageList.messages.isEmpty)
    }
}

// MARK: - The owed re-send (a profile change that waited for a search)

extension RankCommandRearmTests {
    private func profileLineCount(_ messageList: MessageList) -> Int {
        messageList.messages.filter { $0.text.hasPrefix("> kata-set-param humanSLProfile ") }.count
    }

    /// Black thinks as 3d; the pick makes both sides 5k 2019. The turn change
    /// alone skips a matched pair, so without the owed re-send the engine
    /// would keep playing both sides as 3d under a "5k 2019" label.
    @MainActor
    @Test("a rank deferred mid-think reaches the engine even when it makes the sides equal")
    func deferredRankThatEqualisesTheSidesIsSentAtTheTurnChange() {
        let config = Config()
        config.blackMaxTime = Config.toggleAIThinkingTime
        config.whiteMaxTime = Config.toggleAIThinkingTime
        config.humanProfileForBlack = "3d 2019"
        config.humanProfileForWhite = "5k 2019"
        let gobanState = GobanState()
        let player = Turn()   // Black to move, thinking
        let messageList = MessageList.accepting()

        ConfigEngineSync.chooseRank("5k 2019", for: .black, config: config,
                                    gobanState: gobanState, player: player, messageList: messageList)
        #expect(messageList.messages.isEmpty)
        #expect(gobanState.humanSLResendOwed)

        player.nextColorForPlayCommand = .white
        gobanState.handleTurnChange(to: .white, config: config, messageList: messageList)

        #expect(messageList.messages.map(\.text).contains("> kata-set-param humanSLProfile rankyear_2019_5k"))
        #expect(!gobanState.humanSLResendOwed)
    }

    /// The control: with nothing owed, a matched pair is not re-sent at each turn.
    @MainActor
    @Test("a turn change with nothing owed leaves a matched pair alone")
    func turnChangeWithNothingOwedSkipsAMatchedPair() {
        let config = Config()
        config.blackMaxTime = Config.toggleAIThinkingTime
        config.whiteMaxTime = Config.toggleAIThinkingTime
        config.humanProfileForBlack = "5k 2019"
        config.humanProfileForWhite = "5k 2019"
        let gobanState = GobanState()
        let messageList = MessageList.accepting()

        gobanState.handleTurnChange(to: .white, config: config, messageList: messageList)

        #expect(profileLineCount(messageList) == 0)
    }

    /// A search re-issued on the same turn — an analysis setting changed, a
    /// pause and run, a closed Deep Report — cancels the running one anyway, so
    /// the debt is paid first: the new search must not run on the old bundle
    /// at the new profile's visit budget.
    @MainActor
    @Test("a same-turn re-request pays a deferred profile change before its search")
    func sameTurnRerequestPaysTheDebtFirst() {
        let config = Config()
        config.blackMaxTime = Config.toggleAIThinkingTime
        config.humanProfileForBlack = "AI"
        let gobanState = GobanState()
        let player = Turn()   // Black to move, thinking
        let messageList = MessageList.accepting()

        ConfigEngineSync.setBlackHumanProfile("15k 2016", config: config, gobanState: gobanState,
                                              player: player, messageList: messageList)
        #expect(gobanState.humanSLResendOwed)
        ConfigEngineSync.setMaxAnalysisMoves(30, config: config, gobanState: gobanState,
                                             player: player, messageList: messageList)

        let texts = messageList.messages.map(\.text)
        let bundle = texts.firstIndex(of: "> kata-set-param humanSLProfile rankyear_2016_15k")
        let search = texts.firstIndex { $0.hasPrefix("> kata-search_analyze_cancellable") }
        #expect(bundle != nil && search != nil)
        if let bundle, let search { #expect(bundle < search) }
        #expect(!gobanState.humanSLResendOwed)
    }

    /// Leaving auto-play re-states both sides, the matched pair included:
    /// auto-play left the best-AI bundle in the engine. (The re-send the exit
    /// calls; the exit itself is view glue.)
    @MainActor
    @Test("the effective re-send restores a matched pair")
    func effectiveResendRestoresAMatchedPair() {
        let config = Config()
        config.blackMaxTime = Config.toggleAIThinkingTime
        config.whiteMaxTime = Config.toggleAIThinkingTime
        config.humanProfileForBlack = "5k 2019"
        config.humanProfileForWhite = "5k 2019"
        let gobanState = GobanState()
        gobanState.humanSLResendOwed = true
        let messageList = MessageList.accepting()

        gobanState.sendEffectiveHumanAnalysisCommands(nextColorForPlayCommand: .black,
                                                      config: config, messageList: messageList)

        #expect(messageList.messages.map(\.text).contains("> kata-set-param humanSLProfile rankyear_2019_5k"))
        #expect(profileLineCount(messageList) == 1)
        #expect(!gobanState.humanSLResendOwed)
    }

    /// While auto-play owns the engine nothing is re-stated, and the debt stays.
    @MainActor
    @Test("the effective re-send waits out auto-play")
    func effectiveResendWaitsOutAutoPlay() {
        let config = Config()
        let gobanState = GobanState()
        gobanState.isAutoPlaying = true
        gobanState.humanSLResendOwed = true
        let messageList = MessageList.accepting()

        gobanState.sendEffectiveHumanAnalysisCommands(nextColorForPlayCommand: .black,
                                                      config: config, messageList: messageList)

        #expect(messageList.messages.isEmpty)
        #expect(gobanState.humanSLResendOwed)
    }
}
