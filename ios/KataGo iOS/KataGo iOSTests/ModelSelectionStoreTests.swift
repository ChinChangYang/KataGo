//
//  ModelSelectionStoreTests.swift
//  KataGo AnytimeTests
//
//  Pins the shared model-selection store (promoted from the Mac target's
//  MacModelSelection so Vision can reuse it): the two ModelRunnerView.*
//  UserDefaults keys iOS owns via @AppStorage — selectedModelTitle (the
//  last-good selection) and pendingLoadModelTitle (the crash sentinel) —
//  plus currentModel resolution falling back to the built-in net.
//

import Foundation
import Testing
@testable import KataGoUICore

@MainActor
struct ModelSelectionStoreTests {
    /// A throwaway defaults suite so tests never touch the app's real
    /// UserDefaults (which also carry the simulator host's state).
    private func makeStore(_ name: String = #function) -> (ModelSelectionStore, UserDefaults) {
        let suiteName = "ModelSelectionStoreTests.\(name)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (ModelSelectionStore(defaults: defaults), defaults)
    }

    @Test func emptyDefaultsReadAsEmptyTitles() {
        let (store, _) = makeStore()
        #expect(store.selectedModelTitle == "")
        #expect(store.pendingLoadModelTitle == "")
    }

    @Test func titlesRoundTripThroughTheiOSKeys() {
        let (store, defaults) = makeStore()
        store.selectedModelTitle = "Official KataGo Network"
        store.pendingLoadModelTitle = "FD3 Network"
        #expect(defaults.string(forKey: "ModelRunnerView.selectedModelTitle")
                == "Official KataGo Network")
        #expect(defaults.string(forKey: "ModelRunnerView.pendingLoadModelTitle")
                == "FD3 Network")
        #expect(store.selectedModelTitle == "Official KataGo Network")
        #expect(store.pendingLoadModelTitle == "FD3 Network")
    }

    @Test func currentModelResolvesAnExactTitleMatch() {
        let (store, _) = makeStore()
        let official = NeuralNetworkModel.allCases.first { !$0.builtIn }!
        store.selectedModelTitle = official.title
        #expect(store.currentModel.title == official.title)
    }

    @Test func emptyOrUnknownTitleFallsBackToBuiltIn() {
        let (store, _) = makeStore()
        #expect(store.currentModel.builtIn)
        store.selectedModelTitle = "No Such Network"
        #expect(store.currentModel.builtIn)
    }

    @Test func setActiveModelWritesOnlyTheSelection() {
        let (store, _) = makeStore()
        store.pendingLoadModelTitle = "armed"
        let official = NeuralNetworkModel.allCases.first { !$0.builtIn }!
        store.setActiveModel(official)
        #expect(store.selectedModelTitle == official.title)
        // The crash sentinel is armed/cleared by the engine-launch seam,
        // never by selection bookkeeping.
        #expect(store.pendingLoadModelTitle == "armed")
    }
}
