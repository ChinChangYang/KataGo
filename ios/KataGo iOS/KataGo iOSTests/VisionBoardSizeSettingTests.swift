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
}
