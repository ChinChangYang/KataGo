//
//  AnalysisPowerSavingTests.swift
//  KataGo AnytimeTests
//

import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

/// Power-saving pauses continuous analysis only when a human is playing the AI
/// (exactly one side has a positive per-move thinking time), the analysis
/// overlay is hidden (eye `.book`/`.closed`), and it is the human's turn. Every
/// other combination keeps analysis running.
struct AnalysisPowerSavingTests {

    /// Black human (0s) vs White AI (2s).
    private func mixedHumanBlackVsAIWhite() -> Config {
        Config(optionalBlackMaxTime: 0.0, optionalWhiteMaxTime: 2.0)
    }

    // MARK: - Pauses (the only cases that return true)

    @Test func pausesWhenHumanToMoveAndEyeClosed() {
        let state = GobanState()
        state.eyeStatus = .closed
        #expect(state.isAnalysisHiddenForPowerSaving(
            config: mixedHumanBlackVsAIWhite(),
            nextColorForPlayCommand: .black) == true)
    }

    @Test func pausesWhenHumanToMoveAndEyeBook() {
        let state = GobanState()
        state.eyeStatus = .book
        #expect(state.isAnalysisHiddenForPowerSaving(
            config: mixedHumanBlackVsAIWhite(),
            nextColorForPlayCommand: .black) == true)
    }

    @Test func pausesWhenHumanIsWhiteToMove() {
        // White human (0s) vs Black AI (1s), white to move, eye closed.
        let config = Config(optionalBlackMaxTime: 1.0, optionalWhiteMaxTime: 0.0)
        let state = GobanState()
        state.eyeStatus = .closed
        #expect(state.isAnalysisHiddenForPowerSaving(
            config: config, nextColorForPlayCommand: .white) == true)
    }

    // MARK: - Keeps running

    @Test func runsWhenEyeOpened() {
        let state = GobanState()
        state.eyeStatus = .opened
        #expect(state.isAnalysisHiddenForPowerSaving(
            config: mixedHumanBlackVsAIWhite(),
            nextColorForPlayCommand: .black) == false)
    }

    @Test func runsOnAITurnEvenWhenHidden() {
        // Mixed game, but it's the AI's (white's) turn — keep running so the
        // engine can generate the AI move.
        let state = GobanState()
        state.eyeStatus = .closed
        #expect(state.isAnalysisHiddenForPowerSaving(
            config: mixedHumanBlackVsAIWhite(),
            nextColorForPlayCommand: .white) == false)
    }

    @Test func runsForBothHumanGame() {
        let config = Config(optionalBlackMaxTime: 0.0, optionalWhiteMaxTime: 0.0)
        let state = GobanState()
        state.eyeStatus = .closed
        #expect(state.isAnalysisHiddenForPowerSaving(
            config: config, nextColorForPlayCommand: .black) == false)
        #expect(state.isAnalysisHiddenForPowerSaving(
            config: config, nextColorForPlayCommand: .white) == false)
    }

    @Test func runsForBothAIGame() {
        let config = Config(optionalBlackMaxTime: 1.0, optionalWhiteMaxTime: 2.0)
        let state = GobanState()
        state.eyeStatus = .closed
        #expect(state.isAnalysisHiddenForPowerSaving(
            config: config, nextColorForPlayCommand: .black) == false)
        #expect(state.isAnalysisHiddenForPowerSaving(
            config: config, nextColorForPlayCommand: .white) == false)
    }

    @Test func runsWhenNextColorIsNilOrUnknown() {
        let state = GobanState()
        state.eyeStatus = .closed
        #expect(state.isAnalysisHiddenForPowerSaving(
            config: mixedHumanBlackVsAIWhite(),
            nextColorForPlayCommand: nil) == false)
        #expect(state.isAnalysisHiddenForPowerSaving(
            config: mixedHumanBlackVsAIWhite(),
            nextColorForPlayCommand: .unknown) == false)
    }

    // MARK: - shouldRequestAnalysis integration

    @Test func shouldRequestAnalysisFalseWhenPowerSaving() {
        let state = GobanState()            // analysisStatus defaults to .run
        state.eyeStatus = .closed
        #expect(state.shouldRequestAnalysis(
            config: mixedHumanBlackVsAIWhite(),
            nextColorForPlayCommand: .black) == false)
    }

    @Test func shouldRequestAnalysisTrueOnAITurnWhenHidden() {
        let state = GobanState()
        state.eyeStatus = .closed
        #expect(state.shouldRequestAnalysis(
            config: mixedHumanBlackVsAIWhite(),
            nextColorForPlayCommand: .white) == true)
    }

    @Test func shouldRequestAnalysisTrueWhenEyeOpened() {
        let state = GobanState()
        state.eyeStatus = .opened
        #expect(state.shouldRequestAnalysis(
            config: mixedHumanBlackVsAIWhite(),
            nextColorForPlayCommand: .black) == true)
    }
}
