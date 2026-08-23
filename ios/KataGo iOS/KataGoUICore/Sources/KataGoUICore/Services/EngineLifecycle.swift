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

/// What the host should do at launch based on persisted state.
///
/// Every case describes the board's FIRST FRAME, not a screen: the board is
/// mounted in all four, and they differ only in what the engine status says
/// over it.
public enum RecoveryAction: Equatable {
    /// Launch this net now. The board mounts in *Launching*.
    case autoRestore(title: String)
    /// Nothing is launching and the user has to pick. The board mounts in
    /// *Absent* and the model picker is presented over it (DEBUG only —
    /// Release always has a net to launch).
    case presentPicker
    /// The previous launch armed the crash sentinel and never cleared it: it
    /// died somewhere between "start loading `title`" and the engine's first
    /// GTP reply. The board mounts in *Failed* with a way out; nothing is
    /// relaunched, because relaunching it is how a crash loop is built.
    case failedLastLaunch(title: String)
}

/// Pure decision logic for launch-time model-load recovery. Extracted so it
/// can be unit-tested without booting a SwiftUI view.
public enum RecoveryDecision {
    /// - Parameters:
    ///   - pendingLoadModelTitle: the crash sentinel, as the PREVIOUS run left it.
    ///   - selectedModelTitle: the last net that finished loading successfully.
    ///   - isDebug: a debug build always asks; a release build never does.
    ///   - builtInTitle: the bundled net's title, so the "nothing persisted"
    ///     release path resolves to something launchable. Passed in rather than
    ///     read from the catalog here so the decision stays a pure function of
    ///     its arguments.
    public static func decide(
        pendingLoadModelTitle: String,
        selectedModelTitle: String,
        isDebug: Bool,
        builtInTitle: String
    ) -> RecoveryAction {
        // DEBUG is checked FIRST — before the sentinel. A debug build's rule is
        // simply "always ask", and the nine UI suites rely on the picker coming
        // up however the previous launch died. (Before the board was mounted
        // independently, the sentinel branch came first and produced the same
        // screen, so this reorder changes nothing a debug user can see.)
        if isDebug {
            return .presentPicker
        }
        if !pendingLoadModelTitle.isEmpty {
            return .failedLastLaunch(title: pendingLoadModelTitle)
        }
        if !selectedModelTitle.isEmpty {
            return .autoRestore(title: selectedModelTitle)
        }
        // A release build never shows Absent: with no recorded choice there is
        // still a bundled net, and a board with an engine beats a board with a
        // question.
        return .autoRestore(title: builtInTitle)
    }
}
