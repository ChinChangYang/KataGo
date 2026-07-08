//
//  GobanStateFullScreenTests.swift
//  KataGo iOSTests
//
//  Pins the iPad full-screen board mode flag: `isInfoPaneVisible` is the
//  single gate PlayView uses for the chart/comments pane, so its
//  `isBoardFullScreen == false` rows prove every non-iPad platform (where
//  nothing ever sets the flag) behaves byte-identically to the old
//  `showCharts || showComments` condition, and its `true` rows prove
//  full screen hides the pane without touching the persisted settings.
//

import Testing
@testable import KataGoUICore

@MainActor
struct GobanStateFullScreenTests {

    private func state(showCharts: Bool,
                       showComments: Bool,
                       fullScreen: Bool) -> GobanState {
        let state = GobanState()
        state.showCharts = showCharts
        state.showComments = showComments
        state.isBoardFullScreen = fullScreen
        return state
    }

    @Test("Normal mode: pane visibility equals showCharts || showComments",
          arguments: [
            (charts: false, comments: false, visible: false),
            (charts: true, comments: false, visible: true),
            (charts: false, comments: true, visible: true),
            (charts: true, comments: true, visible: true),
          ])
    func normalModeMatchesLegacyCondition(charts: Bool, comments: Bool, visible: Bool) {
        let state = state(showCharts: charts, showComments: comments, fullScreen: false)
        #expect(state.isInfoPaneVisible == visible)
    }

    @Test("Full screen hides the pane regardless of the settings",
          arguments: [
            (charts: false, comments: false),
            (charts: true, comments: false),
            (charts: false, comments: true),
            (charts: true, comments: true),
          ])
    func fullScreenHidesPane(charts: Bool, comments: Bool) {
        let state = state(showCharts: charts, showComments: comments, fullScreen: true)
        #expect(state.isInfoPaneVisible == false)
    }

    @Test("Exiting full screen restores the pane; the settings were untouched")
    func exitRestoresPriorState() {
        let state = state(showCharts: true, showComments: true, fullScreen: true)
        state.isBoardFullScreen = false
        #expect(state.isInfoPaneVisible == true)
        #expect(state.showCharts == true)
        #expect(state.showComments == true)
    }

    @Test("A fresh GobanState is not in full screen (all platforms' default)")
    func defaultsToFalse() {
        #expect(GobanState().isBoardFullScreen == false)
    }
}
