//
//  GobanStateContinuousAnalysisIntervalTests.swift
//  KataGo iOSTests
//
//  Pins the `continuousAnalysisUsesConfigInterval` flag: tvOS streams
//  continuous kata-analyze at the game's analysisInterval (the TV root never
//  re-arms at the config interval the way GameSplitView does), while the
//  default keeps the fast 0.1 s first-report command byte-identical for
//  iOS/macOS. The gen-move branch must ignore the flag entirely — it already
//  uses the config interval.
//

import Testing
@testable import KataGoUICore

@MainActor
struct GobanStateContinuousAnalysisIntervalTests {

    private func spectatorState(usesConfigInterval: Bool) -> GobanState {
        let state = GobanState()
        state.analysisStatus = .run
        state.suppressesGenMove = true
        state.continuousAnalysisUsesConfigInterval = usesConfigInterval
        return state
    }

    @Test("Default: continuous analysis keeps the fast 0.1 s interval (iOS pin)")
    func defaultKeepsFastInterval() {
        let state = spectatorState(usesConfigInterval: false)
        let config = Config()
        let commands = state.getRequestAnalysisCommands(config: config,
                                                        nextColorForPlayCommand: .black)
        #expect(commands.last == GtpCommandBuilder.fastAnalyzeCommand(maxMoves: config.maxAnalysisMoves))
        #expect(commands.last?.hasPrefix("kata-analyze interval 10 ") == true)
    }

    @Test("Flag set: continuous analysis streams at config.analysisInterval")
    func flagUsesConfigInterval() {
        let state = spectatorState(usesConfigInterval: true)
        let config = Config()
        let commands = state.getRequestAnalysisCommands(config: config,
                                                        nextColorForPlayCommand: .black)
        #expect(commands.last == GtpCommandBuilder.analyzeCommand(interval: config.analysisInterval,
                                                                  maxMoves: config.maxAnalysisMoves))
        #expect(commands.last?.hasPrefix("kata-analyze interval \(config.analysisInterval) ") == true)
        // The default per-game interval is 0.5 s — the whole point of the flag.
        #expect(config.analysisInterval == 50)
    }

    @Test("Flag set: the gen-move branch is unchanged")
    func flagDoesNotLeakIntoGenMove() {
        let state = spectatorState(usesConfigInterval: true)
        state.suppressesGenMove = false
        let config = Config(optionalBlackMaxTime: 1.0, optionalWhiteMaxTime: 1.0)
        let commands = state.getRequestAnalysisCommands(config: config,
                                                        nextColorForPlayCommand: .black)
        #expect(commands.last?.hasPrefix("kata-search_analyze_cancellable interval \(config.analysisInterval) ") == true)
    }

    @Test("A fresh GobanState keeps the fast interval (iOS/macOS default)")
    func defaultsToFalse() {
        #expect(GobanState().continuousAnalysisUsesConfigInterval == false)
    }
}
