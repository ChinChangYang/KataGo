//
//  EngineLifecycle.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2026/4/11.
//

import Foundation

/// Signals "the engine responded to its first GTP command" (i.e. the model
/// finished loading) from `ContentView` up to `ModelRunnerView` so the
/// crash-loop sentinel can be cleared. `reset()` must be called before each
/// new load so the observer re-fires when the same model is picked twice.
@Observable
class EngineLifecycle {
    var lastLoadedModelTitle: String? = nil

    func markFirstResponse(modelTitle: String) {
        lastLoadedModelTitle = modelTitle
    }

    func reset() {
        lastLoadedModelTitle = nil
    }
}

/// What `ModelRunnerView` should do at launch based on persisted state.
enum RecoveryAction: Equatable {
    /// Previous launch died before the engine ever responded. `ModelRunnerView`
    /// leaves `selectedModel` nil so the picker renders; the picker reads
    /// `pendingLoadModelTitle` directly for the banner text.
    case showPickerWithBanner
    case autoRestore(title: String)
    case showPicker
}

/// Pure decision logic for launch-time model-load recovery. Extracted so it
/// can be unit-tested without booting a SwiftUI view.
enum RecoveryDecision {
    static func decide(
        pendingLoadModelTitle: String,
        selectedModelTitle: String,
        isDebug: Bool
    ) -> RecoveryAction {
        if !pendingLoadModelTitle.isEmpty {
            return .showPickerWithBanner
        }
        if isDebug {
            return .showPicker
        }
        if !selectedModelTitle.isEmpty {
            return .autoRestore(title: selectedModelTitle)
        }
        return .showPicker
    }
}
