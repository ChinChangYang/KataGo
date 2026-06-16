import Foundation
import KataGoUICore

/// Persisted Mac model-selection store. AppKit stand-in for the two
/// `@AppStorage` keys the iOS `ModelRunnerView` owns
/// (`ModelRunnerView.selectedModelTitle` + `ModelRunnerView.pendingLoadModelTitle`).
///
/// It uses the SAME plain `UserDefaults.standard` keys iOS does (NOT the iCloud
/// key-value store), so the two values are read/written identically across the
/// shared `KataGoUICore` model layer:
///
///   • `selectedModelTitle` — the authoritative "user picked this" record, i.e.
///     the LAST model the user successfully chose. `currentModel` resolves the
///     model to launch from it (falling back to the built-in net).
///   • `pendingLoadModelTitle` — the crash sentinel. P5-T4/T5 arm it BEFORE a
///     launch and clear it once the engine's first GTP response lands; if the
///     process dies in between, the surviving value drives crash recovery. This
///     store only exposes typed get/set for it — it does NOT arm/clear it here
///     (that is P5-T4's responsibility).
///
/// Not a SwiftUI view, so it reads/writes `UserDefaults.standard` directly rather
/// than via `@AppStorage`. `@MainActor` to match `MainWindowController`, which
/// owns the single instance.
@MainActor
final class MacModelSelection {
    /// The two `ModelRunnerView.*` UserDefaults keys, named exactly as iOS.
    private enum Key {
        /// Last-good model the user selected (authoritative selection record).
        static let selectedModelTitle = "ModelRunnerView.selectedModelTitle"
        /// Crash sentinel: the model whose launch is in flight (armed/cleared by T4).
        static let pendingLoadModelTitle = "ModelRunnerView.pendingLoadModelTitle"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - selectedModelTitle (last-good selection)

    /// The title of the last model the user successfully selected, or `""` when
    /// none has been recorded yet (mirrors the iOS `@AppStorage` default of `""`).
    var selectedModelTitle: String {
        get { defaults.string(forKey: Key.selectedModelTitle) ?? "" }
        set { defaults.set(newValue, forKey: Key.selectedModelTitle) }
    }

    // MARK: - pendingLoadModelTitle (crash sentinel; armed/cleared by T4)

    /// The title of the model whose engine launch is currently in flight, or `""`
    /// when nothing is pending. Exposed for P5-T4/T5 to arm (before a launch) and
    /// clear (on the first GTP response). This store never mutates it itself.
    var pendingLoadModelTitle: String {
        get { defaults.string(forKey: Key.pendingLoadModelTitle) ?? "" }
        set { defaults.set(newValue, forKey: Key.pendingLoadModelTitle) }
    }

    // MARK: - Resolution + mutation

    /// The model to launch: the one matching `selectedModelTitle` if a model with
    /// that title exists, otherwise the built-in net. Force-unwrapping
    /// `builtInModel` mirrors iOS — the built-in net is always bundled, and the
    /// rest of the app already assumes its presence.
    var currentModel: NeuralNetworkModel {
        if !selectedModelTitle.isEmpty,
           let match = NeuralNetworkModel.allCases.first(where: { $0.title == selectedModelTitle }) {
            return match
        }
        return NeuralNetworkModel.builtInModel!
    }

    /// Records `model` as the authoritative user selection by writing its title to
    /// `selectedModelTitle`. Does NOT arm the crash sentinel (that is P5-T4's job).
    func setActiveModel(_ model: NeuralNetworkModel) {
        selectedModelTitle = model.title
    }
}
