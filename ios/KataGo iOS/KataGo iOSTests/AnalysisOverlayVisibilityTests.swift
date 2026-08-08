//
//  AnalysisOverlayVisibilityTests.swift
//  KataGo AnytimeTests
//

import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

/// `GobanState.isAnalysisOverlayVisible` is the single source of truth for "is the
/// analysis overlay showing on the board". `AnalysisView` gates its whole body on
/// it, and the macOS hover preview gates its win%/score capsule on it — so an
/// overlay layered on top of `BoardView` can never surface analysis the board
/// itself is hiding.
///
/// It is DISPLAY visibility, not engine state: the eye hides the overlay without
/// stopping analysis.
struct AnalysisOverlayVisibilityTests {

    /// Both sides human, so the power-saving branch never engages and these tests
    /// isolate the eye / auto-play / analysis-for-whom terms.
    private func bothHuman() -> Config {
        Config(optionalBlackMaxTime: 0.0, optionalWhiteMaxTime: 0.0)
    }

    // MARK: - Visible

    @Test func visibleInDefaultState() {
        // Fresh state: eye .opened, analysisStatus .run, not auto-playing.
        let state = GobanState()
        #expect(state.isAnalysisOverlayVisible(
            config: bothHuman(), nextColorForPlayCommand: .black) == true)
    }

    @Test func visibleWhileAnalysisPaused() {
        // `shouldRequestAnalysis` is `analysisStatus != .clear`, so a paused
        // analysis keeps its last frame on screen. The overlay stays visible.
        let state = GobanState()
        state.analysisStatus = .pause
        #expect(state.isAnalysisOverlayVisible(
            config: bothHuman(), nextColorForPlayCommand: .black) == true)
    }

    @Test func visibleWithNilNextColor() {
        // A nil next color skips the analysis-for-whom check entirely.
        let state = GobanState()
        #expect(state.isAnalysisOverlayVisible(
            config: bothHuman(), nextColorForPlayCommand: nil) == true)
    }

    // MARK: - Hidden

    @Test func hiddenWhenEyeClosed() {
        // The reported macOS bug: with the eye off the board draws no analysis,
        // so the hover capsule must not either.
        let state = GobanState()
        state.eyeStatus = .closed
        #expect(state.isAnalysisOverlayVisible(
            config: bothHuman(), nextColorForPlayCommand: .black) == false)
    }

    @Test func hiddenWhenEyeInBookView() {
        let state = GobanState()
        state.eyeStatus = .book
        #expect(state.isAnalysisOverlayVisible(
            config: bothHuman(), nextColorForPlayCommand: .black) == false)
    }

    @Test func hiddenWhileAutoPlaying() {
        let state = GobanState()
        state.isAutoPlaying = true
        #expect(state.isAnalysisOverlayVisible(
            config: bothHuman(), nextColorForPlayCommand: .black) == false)
    }

    @Test func hiddenWhenAnalysisCleared() {
        let state = GobanState()
        state.analysisStatus = .clear
        #expect(state.isAnalysisOverlayVisible(
            config: bothHuman(), nextColorForPlayCommand: .black) == false)
    }

    @Test func hiddenWhenAnalysisForWhomExcludesSideToMove() {
        let config = bothHuman()
        config.analysisForWhom = Config.analysisForWhoms.firstIndex(
            of: Config.analysisForBlack)!
        let state = GobanState()
        #expect(state.isAnalysisOverlayVisible(
            config: config, nextColorForPlayCommand: .white) == false)
        #expect(state.isAnalysisOverlayVisible(
            config: config, nextColorForPlayCommand: .black) == true)
    }

    @Test func hiddenWhenSideToMoveIsUnknown() {
        // `isAnalysisForCurrentPlayer` rejects `.unknown` outright.
        let state = GobanState()
        #expect(state.isAnalysisOverlayVisible(
            config: bothHuman(), nextColorForPlayCommand: .unknown) == false)
    }

    @Test func hiddenWhenPowerSaving() {
        // Integration with `shouldRequestAnalysis`: human black vs AI white, the
        // human's turn, overlay hidden. No-op on macOS; these tests run on iOS.
        let config = Config(optionalBlackMaxTime: 0.0, optionalWhiteMaxTime: 2.0)
        let state = GobanState()
        state.eyeStatus = .closed
        #expect(state.isAnalysisOverlayVisible(
            config: config, nextColorForPlayCommand: .black) == false)
    }

    // MARK: - Deliberately NOT part of this gate

    @Test func staysVisibleWhenAnalysisInformationIsNone() {
        // `AnalysisView` still draws the OWNERSHIP heatmap when the information
        // picker is None — only the per-move text is suppressed. So the helper
        // must stay true, and text-only callers (the macOS hover capsule) add
        // `!isAnalysisInformationNone` themselves.
        let state = GobanState()
        state.analysisInformation = Config.analysisInformations.firstIndex(
            of: Config.analysisInformationNone)!
        #expect(state.isAnalysisInformationNone == true)
        #expect(state.isAnalysisOverlayVisible(
            config: bothHuman(), nextColorForPlayCommand: .black) == true)
    }
}
