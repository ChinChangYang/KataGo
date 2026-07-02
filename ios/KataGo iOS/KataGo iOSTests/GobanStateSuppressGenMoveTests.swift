//
//  GobanStateSuppressGenMoveTests.swift
//  KataGo iOSTests
//
//  Pins the `suppressesGenMove` spectator flag: with it set, a side whose
//  config says "engine plays" (maxTime > 0) still gets plain continuous
//  analysis instead of a gen-move (the tvOS review screen is a spectator);
//  with it clear, the gen-move path is byte-identical to before the flag
//  existed (the iOS/macOS regression pin).
//

import Testing
@testable import KataGoUICore

@MainActor
struct GobanStateSuppressGenMoveTests {

    /// Both sides engine-played — the AI-vs-AI (self-play) configuration.
    private func bothAIConfig() -> Config {
        Config(optionalBlackMaxTime: 1.0, optionalWhiteMaxTime: 1.0)
    }

    private func runningState(suppressed: Bool) -> GobanState {
        let state = GobanState()
        state.analysisStatus = .run
        state.suppressesGenMove = suppressed
        return state
    }

    @Test("Suppressed: maxTime > 0 still yields the continuous-analysis pair")
    func suppressedFallsBackToContinuousAnalysis() {
        let state = runningState(suppressed: true)
        let commands = state.getRequestAnalysisCommands(config: bothAIConfig(),
                                                        nextColorForPlayCommand: .black)
        #expect(commands.count == 2)
        #expect(commands.first == "kata-set-param maxVisits \(GtpCommandBuilder.unboundedMaxVisits)")
        #expect(commands.last?.hasPrefix("kata-analyze") == true)
        #expect(!commands.contains(where: { $0.contains("kata-search_analyze_cancellable") }))
    }

    @Test("Suppressed: shouldGenMove is false for both colors")
    func suppressedShouldGenMoveFalse() {
        let state = runningState(suppressed: true)
        let config = bothAIConfig()
        let player = Turn()
        player.nextColorForPlayCommand = .black
        #expect(state.shouldGenMove(config: config, player: player) == false)
        player.nextColorForPlayCommand = .white
        #expect(state.shouldGenMove(config: config, player: player) == false)
    }

    @Test("Clear (default): the gen-move path is unchanged")
    func clearFlagGenMovesAsBefore() {
        let state = runningState(suppressed: false)
        let config = bothAIConfig()
        let commands = state.getRequestAnalysisCommands(config: config,
                                                        nextColorForPlayCommand: .black)
        #expect(commands.contains(where: { $0.contains("kata-search_analyze_cancellable") }))

        let player = Turn()
        player.nextColorForPlayCommand = .black
        #expect(state.shouldGenMove(config: config, player: player) == true)
    }

    @Test("A fresh GobanState does not suppress (iOS/macOS default)")
    func defaultsToFalse() {
        #expect(GobanState().suppressesGenMove == false)
    }
}
