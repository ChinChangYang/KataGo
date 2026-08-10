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
