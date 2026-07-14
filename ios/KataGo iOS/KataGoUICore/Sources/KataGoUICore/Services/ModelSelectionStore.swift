//
//  ModelSelectionStore.swift
//  KataGoUICore
//
//  Persisted model-selection store shared by the non-iOS targets (the Mac
//  window controller and the Vision root; promoted from the Mac target's
//  MacModelSelection). Stand-in for the two `@AppStorage` keys the iOS
//  `ModelRunnerView` owns (`ModelRunnerView.selectedModelTitle` +
//  `ModelRunnerView.pendingLoadModelTitle`).
//
//  It uses the SAME plain `UserDefaults.standard` keys iOS does (NOT the
//  iCloud key-value store), so the two values are read/written identically
//  across the shared `KataGoUICore` model layer:
//
//    • `selectedModelTitle` — the authoritative "user picked this" record,
//      i.e. the LAST model the user successfully chose. `currentModel`
//      resolves the model to launch from it (falling back to the built-in
//      net).
//    • `pendingLoadModelTitle` — the crash sentinel. The engine-launch seam
//      arms it BEFORE a launch and clears it once the engine's first GTP
//      response lands; if the process dies in between, the surviving value
//      drives crash recovery (RecoveryDecision). This store only exposes
//      typed get/set for it — it does NOT arm/clear it here.
//
//  Not a SwiftUI view, so it reads/writes `UserDefaults` directly rather
//  than via `@AppStorage`. `@MainActor` to match its owners (the Mac
//  MainWindowController and the Vision root view).
//

import Foundation

@MainActor
public final class ModelSelectionStore {
    /// The two `ModelRunnerView.*` UserDefaults keys, named exactly as iOS.
    private enum Key {
        /// Last-good model the user selected (authoritative selection record).
        static let selectedModelTitle = "ModelRunnerView.selectedModelTitle"
        /// Crash sentinel: the model whose launch is in flight.
        static let pendingLoadModelTitle = "ModelRunnerView.pendingLoadModelTitle"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - selectedModelTitle (last-good selection)

    /// The title of the last model the user successfully selected, or `""`
    /// when none has been recorded yet (mirrors the iOS `@AppStorage`
    /// default of `""`).
    public var selectedModelTitle: String {
        get { defaults.string(forKey: Key.selectedModelTitle) ?? "" }
        set { defaults.set(newValue, forKey: Key.selectedModelTitle) }
    }

    // MARK: - pendingLoadModelTitle (crash sentinel)

    /// The title of the model whose engine launch is currently in flight, or
    /// `""` when nothing is pending. Exposed for the engine-launch seam to
    /// arm (before a launch) and clear (on the first GTP response). This
    /// store never mutates it itself.
    public var pendingLoadModelTitle: String {
        get { defaults.string(forKey: Key.pendingLoadModelTitle) ?? "" }
        set { defaults.set(newValue, forKey: Key.pendingLoadModelTitle) }
    }

    // MARK: - Resolution + mutation

    /// The model to launch: the one matching `selectedModelTitle` if a model
    /// with that title exists, otherwise the built-in net. Force-unwrapping
    /// `builtInModel` mirrors iOS — the built-in net is always bundled, and
    /// the rest of the app already assumes its presence.
    public var currentModel: NeuralNetworkModel {
        if !selectedModelTitle.isEmpty,
           let match = NeuralNetworkModel.allCases.first(where: { $0.title == selectedModelTitle }) {
            return match
        }
        return NeuralNetworkModel.builtInModel!
    }

    /// Records `model` as the authoritative user selection by writing its
    /// title to `selectedModelTitle`. Does NOT arm the crash sentinel (the
    /// engine-launch seam owns that).
    public func setActiveModel(_ model: NeuralNetworkModel) {
        selectedModelTitle = model.title
    }
}
