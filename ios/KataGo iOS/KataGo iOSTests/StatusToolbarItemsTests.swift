//
//  StatusToolbarItemsTests.swift
//  KataGo AnytimeTests
//
//  The board's navigation row no longer waits for the engine.
//
//  `isFunctional` used to include `showBoardCount == 0` — "no showboard is
//  outstanding", i.e. "the engine has caught up". That was a reasonable gate
//  when the board could not be drawn until the engine answered; now the board
//  is record-owned and the cursor moves without asking anyone, so a pending
//  ack must not freeze Forward/Backward. The two things that still DO disable
//  them are the two that would corrupt the record: an AI move being generated,
//  and an auto-play replay already stepping the cursor.
//
//  The analysis toggle is the opposite case: it has nothing to toggle without
//  an engine, so it is disabled — not ignored — while one is unavailable.
//

import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

@MainActor
struct StatusToolbarItemsTests {

    private func aiToPlayConfig() -> Config {
        let config = Config()
        config.blackMaxTime = 5
        return config
    }

    @Test func navigationStaysFunctionalWhileAShowboardIsOutstanding() {
        let gobanState = GobanState()
        let player = Turn()
        // Three acks outstanding: the old gate would have greyed the row out
        // for the whole launch, because a launching engine acks nothing.
        gobanState.showBoardCount = 3

        #expect(StatusToolbarItems.isFunctional(gobanState: gobanState,
                                                config: Config(),
                                                player: player))
    }

    @Test func navigationIsRefusedWhileTheEngineIsGeneratingAMove() {
        let gobanState = GobanState()
        let player = Turn()
        player.nextColorForPlayCommand = .black

        #expect(!StatusToolbarItems.isFunctional(gobanState: gobanState,
                                                 config: aiToPlayConfig(),
                                                 player: player))
    }

    @Test func navigationIsRefusedWhileAutoPlayIsStepping() {
        let gobanState = GobanState()
        gobanState.isAutoPlaying = true

        #expect(!StatusToolbarItems.isFunctional(gobanState: gobanState,
                                                 config: Config(),
                                                 player: Turn()))
    }

    @Test func theAnalysisToggleIsDisabledUntilAnEngineCanAnswer() {
        let status = EngineStatus()

        status.availability = .launching
        #expect(!StatusToolbarItems.isAnalysisToggleEnabled(engineStatus: status))

        status.availability = .absent
        #expect(!StatusToolbarItems.isAnalysisToggleEnabled(engineStatus: status))

        status.availability = .failed(reason: "boom")
        #expect(!StatusToolbarItems.isAnalysisToggleEnabled(engineStatus: status))

        // Held: the engine is up, but it cannot take this board — so there is
        // still nothing for the toggle to start.
        status.availability = .held(maxBoardLength: 19)
        #expect(!StatusToolbarItems.isAnalysisToggleEnabled(engineStatus: status))

        status.availability = .ready
        #expect(StatusToolbarItems.isAnalysisToggleEnabled(engineStatus: status))
    }

    @Test func aHostThatInjectsNoStatusKeepsTheToggleEnabled() {
        // macOS injects none. "No status" must read as "carry on as before",
        // never as "disabled forever".
        #expect(StatusToolbarItems.isAnalysisToggleEnabled(engineStatus: nil))
    }
}
