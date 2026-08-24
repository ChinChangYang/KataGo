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
//  The analysis toggle (ADR 0010): its appearance reports analysis ACTIVITY
//  and its tap follows the engine — a usable engine cycles the preference, a
//  resting-down one (Absent/Failed/Held) opens the model picker instead, with
//  a badge saying so. Only the transient Launching wait disables it: the
//  control is the way INTO the remedy, so the down states must keep it live.
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

    @Test func theAnalysisToggleIsDisabledOnlyWhileLaunching() {
        // Launching is the one transient wait: the board's pill narrates it,
        // and a tap has nothing useful to do yet.
        let launching = AnalysisControlModel.make(analysisStatus: .run,
                                                  availability: .launching)
        #expect(!launching.isEnabled)
        #expect(!launching.isAnimating)
        #expect(!launching.showsWarningBadge)

        // The resting down states keep the control ENABLED — it is the way
        // into the remedy — and badge it so a bare red slash (user off) and
        // an engine-down slash stay distinguishable.
        for down in [EngineAvailability.absent,
                     .failed(reason: "boom"),
                     .held(maxBoardLength: 19)] {
            let control = AnalysisControlModel.make(analysisStatus: .run,
                                                    availability: down)
            #expect(control.isEnabled)
            #expect(control.tap == .openRemedy)
            #expect(control.showsWarningBadge)
            #expect(control.isRed)
            #expect(control.symbolName == AnalysisControlModel.slashSymbol)
            // Activity, not preference: a `.run` preference against a down
            // engine animates nothing, because nothing is running.
            #expect(!control.isAnimating)
        }

        let ready = AnalysisControlModel.make(analysisStatus: .run,
                                              availability: .ready)
        #expect(ready.isEnabled)
        #expect(ready.tap == .cycle)
        #expect(ready.isAnimating)
        #expect(!ready.showsWarningBadge)
    }

    @Test func theBadgeGrammarSeparatesUserOffFromEngineDown() {
        // Bare red slash: the USER turned analysis off, engine fine.
        let userOff = AnalysisControlModel.make(analysisStatus: .clear,
                                                availability: .ready)
        #expect(userOff.symbolName == AnalysisControlModel.slashSymbol)
        #expect(userOff.isRed)
        #expect(!userOff.showsWarningBadge)
        #expect(userOff.tap == .cycle)

        // Badged red slash: the ENGINE is down, whatever the preference says.
        let engineDown = AnalysisControlModel.make(analysisStatus: .clear,
                                                   availability: .absent)
        #expect(engineDown.showsWarningBadge)
        #expect(engineDown.tap == .openRemedy)

        // VoiceOver cannot see the badge, so the words must diverge too.
        #expect(userOff.accessibilityLabel != engineDown.accessibilityLabel)
    }

    @Test func aHostThatInjectsNoStatusKeepsTheToggleEnabled() {
        // macOS's shared row injects none. "No status" must read as "carry on
        // as before", never as "disabled forever".
        let control = AnalysisControlModel.make(analysisStatus: .pause,
                                                availability: nil)
        #expect(control.isEnabled)
        #expect(control.tap == .cycle)
        #expect(!control.showsWarningBadge)
        #expect(control.symbolName == AnalysisControlModel.sparkleSymbol)
    }
}
