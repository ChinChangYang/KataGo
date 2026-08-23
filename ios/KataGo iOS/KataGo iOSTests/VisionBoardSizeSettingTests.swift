//
//  VisionBoardSizeSettingTests.swift
//  KataGo AnytimeTests
//
//  Pins the pure row model behind the model-detail gear view's Max Board
//  Size picker: choices filtered to the displayed net's nnLen (omitted, not
//  clamp-displayed), the persisted selection clamped to the largest offered
//  segment, and the HYBRID apply rule — the ACTIVE model restarts the engine
//  on change (today's Vision behavior); any other model, and the pre-boot
//  chooser, persist only and apply at activation (iOS BackendConfigSheet
//  semantics).
//

import Testing
@testable import KataGoUICore

struct VisionBoardSizeSettingTests {
    private func make(persisted: BoardSizeChoice = .nineteen,
                      nnLen: Int = 37,
                      isActiveModel: Bool = false,
                      isBootChooser: Bool = false,
                      engineIsRunning: Bool = true) -> VisionBoardSizeSetting {
        VisionBoardSizeSetting.make(persisted: persisted,
                                    nnLen: nnLen,
                                    isActiveModel: isActiveModel,
                                    isBootChooser: isBootChooser,
                                    engineIsRunning: engineIsRunning)
    }

    @Test func choicesAreFilteredToTheNetsNNLen() {
        #expect(make(nnLen: 37).choices == [.nine, .thirteen, .nineteen, .thirtySevenMax])
        #expect(make(nnLen: 19).choices == [.nine, .thirteen, .nineteen])
        #expect(make(nnLen: 13).choices == [.nine, .thirteen])
        #expect(make(nnLen: 9).choices == [.nine])
    }

    @Test func selectionKeepsThePersistedChoiceWhenAllowed() {
        #expect(make(persisted: .thirteen, nnLen: 37).selection == .thirteen)
        #expect(make(persisted: .nineteen, nnLen: 19).selection == .nineteen)
    }

    @Test func selectionClampsToTheLargestAllowedChoice() {
        // A 37x37 persisted for a 19-capped net displays as 19x19 — which IS
        // the effective buffer (effectiveMaxBoardLength = min(choice, nnLen)).
        #expect(make(persisted: .thirtySevenMax, nnLen: 19).selection == .nineteen)
        #expect(make(persisted: .nineteen, nnLen: 13).selection == .thirteen)
    }

    @Test func activeRunningModelRestartsOnChange() {
        let setting = make(isActiveModel: true)
        #expect(setting.restartsEngineOnChange)
        #expect(!setting.pickerDisabled)
    }

    @Test func nonActiveModelPersistsOnly() {
        // A non-active net's buffer applies at activation — no restart, and
        // the picker stays usable even while the engine is down.
        let setting = make(isActiveModel: false, engineIsRunning: false)
        #expect(!setting.restartsEngineOnChange)
        #expect(!setting.pickerDisabled)
    }

    @Test func bootChooserPersistsOnlyAndNeverDisables() {
        // Pre-boot chooser: no engine runs, nothing is active — set the size,
        // then activate; the value rides the boot.
        let setting = make(isActiveModel: false,
                           isBootChooser: true,
                           engineIsRunning: false)
        #expect(!setting.restartsEngineOnChange)
        #expect(!setting.pickerDisabled)
        #expect(!setting.showsEngineStatusFooter)
    }

    @Test func pickerDisabledWhileActiveEngineIsNotRunning() {
        // A restart in flight serves the OLD buffer — same gating as the
        // retired Settings picker.
        let setting = make(isActiveModel: true, engineIsRunning: false)
        #expect(setting.pickerDisabled)
    }

    @Test func footerTextMatchesApplyTiming() {
        let base = "Sets the largest board the engine can play and the size "
            + "the performance tuner optimizes for."
        #expect(make(isActiveModel: true).footerText
                == base + " Changing it restarts the engine.")
        #expect(make(isActiveModel: false).footerText
                == base + " Takes effect when this net is activated.")
    }

    @Test func engineStatusFooterOnlyForTheActiveModel() {
        #expect(make(isActiveModel: true).showsEngineStatusFooter)
        #expect(!make(isActiveModel: false).showsEngineStatusFooter)
    }

    /// Changing the ACTIVE model's Max Board Size quits and respawns the engine
    /// — and the board does not go anywhere while that happens. It used to: the
    /// volume was gated on a `.booting` phase the restart set, so the user's
    /// game vanished for the minutes a teardown can take. Now the restart only
    /// moves the ENGINE's availability, and the goban keeps drawing (and keeps
    /// stepping) under a status line that says what is going on.
    @Test func restartKeepsBoardMountedAndFlagsLaunching() {
        #expect(make(isActiveModel: true).restartsEngineOnChange)

        let duringRestart = VisionEngineChrome.make(hasMountedGame: true,
                                                    isGeometryRenderable: true,
                                                    availability: .launching)
        #expect(duringRestart.showsBoard)
        #expect(duringRestart.allowsNavigation)
        // …but nothing may be SENT at an engine that is being replaced.
        #expect(!duringRestart.allowsEngineCommands)

        // And when it lands, everything comes back with no remount.
        let afterRestart = VisionEngineChrome.make(hasMountedGame: true,
                                                   isGeometryRenderable: true,
                                                   availability: .ready)
        #expect(afterRestart.showsBoard)
        #expect(afterRestart.allowsEngineCommands)
    }
}

//
//  The volume's own rule: what is drawn, and what may be driven, at each engine
//  availability. Pinned here because it is the whole point of the change — a
//  regression would put a loading screen back in front of the goban.
//
struct VisionEngineChromeTests {
    private func chrome(hasMountedGame: Bool = true,
                        isGeometryRenderable: Bool = true,
                        availability: EngineAvailability = .ready) -> VisionEngineChrome {
        VisionEngineChrome.make(hasMountedGame: hasMountedGame,
                                isGeometryRenderable: isGeometryRenderable,
                                availability: availability)
    }

    @Test func theBoardDrawsAtEveryEngineAvailability() {
        for availability: EngineAvailability in [.launching,
                                                 .ready,
                                                 .absent,
                                                 .failed(reason: "boom"),
                                                 .held(maxBoardLength: 19)] {
            #expect(chrome(availability: availability).showsBoard)
            #expect(chrome(availability: availability).allowsNavigation)
        }
    }

    @Test func onlyAReadyEngineTakesCommands() {
        #expect(chrome(availability: .ready).allowsEngineCommands)
        for availability: EngineAvailability in [.launching,
                                                 .absent,
                                                 .failed(reason: "boom"),
                                                 // Held is UP but refuses this
                                                 // board's size: there is
                                                 // nothing to start.
                                                 .held(maxBoardLength: 19)] {
            #expect(!chrome(availability: availability).allowsEngineCommands)
        }
    }

    @Test func newGameIsOfferedWhileHeldButNotWhileTheEngineIsAway() {
        // Held is the one command-sending exception: the engine is UP and can
        // take a smaller board, so starting one is the natural way out of a
        // hold. Greying out the control that rescues the user would have left
        // them stuck on the 37x37 record that caused it.
        #expect(chrome(availability: .held(maxBoardLength: 19)).allowsNewGame)
        #expect(chrome(availability: .ready).allowsNewGame)
        // Everything else still waits: there is no engine to take the new game.
        #expect(!chrome(availability: .launching).allowsNewGame)
        #expect(!chrome(availability: .absent).allowsNewGame)
        #expect(!chrome(availability: .failed(reason: "boom")).allowsNewGame)
        // …and the analysis/AI controls stay off even while Held.
        #expect(!chrome(availability: .held(maxBoardLength: 19)).allowsEngineCommands)
    }

    @Test func nothingIsDrawnWithoutAMountedGame() {
        let none = chrome(hasMountedGame: false)
        #expect(!none.showsBoard)
        #expect(!none.allowsNavigation)
        #expect(!none.allowsEngineCommands)
        #expect(!none.allowsNewGame)
    }

    @Test func unrenderableGeometryIsTheOneRealGate() {
        // Outside 2...37 there is no bundled board asset — the one thing a
        // ready engine cannot rescue.
        let unsupported = chrome(isGeometryRenderable: false)
        #expect(!unsupported.showsBoard)
        #expect(!unsupported.allowsEngineCommands)
    }
}
