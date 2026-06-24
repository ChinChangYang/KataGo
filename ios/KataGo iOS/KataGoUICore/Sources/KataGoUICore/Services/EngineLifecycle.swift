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
public class EngineLifecycle {
    public var lastLoadedModelTitle: String? = nil

    public init() {}

    public func markFirstResponse(modelTitle: String) {
        lastLoadedModelTitle = modelTitle
    }

    public func reset() {
        lastLoadedModelTitle = nil
    }
}

/// What `ModelRunnerView` should do at launch based on persisted state.
public enum RecoveryAction: Equatable {
    case autoRestore(title: String)
    case showPicker
}

/// Pure decision logic for launch-time model-load recovery. Extracted so it
/// can be unit-tested without booting a SwiftUI view.
public enum RecoveryDecision {
    public static func decide(
        pendingLoadModelTitle: String,
        selectedModelTitle: String,
        isDebug: Bool
    ) -> RecoveryAction {
        if !pendingLoadModelTitle.isEmpty {
            // An incomplete prior load: the sentinel survived process death.
            // Force the picker rather than auto-restoring, so the user
            // re-chooses a model after a possible OOM. No banner is shown.
            return .showPicker
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
