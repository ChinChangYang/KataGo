//
//  EngineLifecycleTests.swift
//  KataGo iOSTests
//
//  Created by Chin-Chang Yang on 2026/4/11.
//

import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

struct EngineLifecycleTests {

    // MARK: - EngineLifecycle

    @Test func markFirstResponseSetsTitle() {
        let lifecycle = EngineLifecycle()
        #expect(lifecycle.lastLoadedModelTitle == nil)

        lifecycle.markFirstResponse(modelTitle: "Built-in KataGo Network")

        #expect(lifecycle.lastLoadedModelTitle == "Built-in KataGo Network")
    }

    @Test func resetClearsTitle() {
        let lifecycle = EngineLifecycle()
        lifecycle.markFirstResponse(modelTitle: "Official KataGo Network")
        lifecycle.reset()

        #expect(lifecycle.lastLoadedModelTitle == nil)
    }

    // MARK: - RecoveryDecision

    @Test func pendingLoadForcesPicker() {
        // A surviving sentinel (an incomplete prior load) forces the picker
        // even when a last-good model exists — it must NOT auto-restore. This
        // input has a non-empty selectedModelTitle and isDebug == false, so
        // the ONLY branch that yields `.showPicker` is the sentinel branch;
        // remove that branch and this returns `.autoRestore`. (A debug variant
        // would not discriminate: debug yields `.showPicker` on its own.)
        let action = RecoveryDecision.decide(
            pendingLoadModelTitle: "Official KataGo Network",
            selectedModelTitle: "Built-in KataGo Network",
            isDebug: false
        )
        #expect(action == .showPicker)
    }

    @Test func noPendingAutoRestoresInRelease() {
        let action = RecoveryDecision.decide(
            pendingLoadModelTitle: "",
            selectedModelTitle: "Built-in KataGo Network",
            isDebug: false
        )
        #expect(action == .autoRestore(title: "Built-in KataGo Network"))
    }

    @Test func noPendingSuppressesAutoRestoreInDebug() {
        let action = RecoveryDecision.decide(
            pendingLoadModelTitle: "",
            selectedModelTitle: "Built-in KataGo Network",
            isDebug: true
        )
        #expect(action == .showPicker)
    }

    @Test func emptyStateShowsPicker() {
        let action = RecoveryDecision.decide(
            pendingLoadModelTitle: "",
            selectedModelTitle: "",
            isDebug: false
        )
        #expect(action == .showPicker)
    }

    @Test func emptyStateShowsPickerInDebug() {
        let action = RecoveryDecision.decide(
            pendingLoadModelTitle: "",
            selectedModelTitle: "",
            isDebug: true
        )
        #expect(action == .showPicker)
    }
}
