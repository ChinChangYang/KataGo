//
//  ScreenWakePolicy.swift
//  KataGoUICore
//
//  The keep-awake window as a pure rule: from the moment the engine owes the
//  person a move until a few seconds after its stone lands, and the whole of
//  an auto-play. The only time the app holds the screen on.
//
//  Pure so the iOS holder (`ScreenWakeHold`, the one thing that touches
//  `UIApplication.isIdleTimerDisabled`) stays a thin adapter and the
//  boundaries are pinned by tests: the tail is 5 s exactly, the ceiling 65 s
//  exactly.
//

import Foundation

public enum ScreenWakePolicy {
    /// The setting's default: on. The hold is bounded by the AI's own think,
    /// so it costs nothing a game against the engine was not already paying.
    public static let defaultEnabled = true

    /// How long the screen stays held after the AI's stone lands.
    public static let tailSeconds: TimeInterval = 5

    /// The longest one hold may last without a fresh activity event. The
    /// owes-a-move predicate is a pure function of turn and settings, not of
    /// a search in flight: it stays true after a reply the session dropped
    /// and while an overwrite confirmation waits for the person. Without a
    /// ceiling either would hold the screen forever.
    public static let ceilingSeconds: TimeInterval = 65

    /// Whether the idle timer should be disabled right now.
    ///
    /// - Parameters:
    ///   - enabled: the user's setting.
    ///   - engineOwesMove: the AI side is to move, the engine is in sync and
    ///     no confirmation is pending; the app is waiting on a stone.
    ///   - secondsSinceAIMove: time since the AI's last stone landed, or nil
    ///     when none has landed in this game.
    ///   - isAutoPlaying: the wand replay is running.
    ///   - isActive: the scene is in the foreground and active.
    ///   - holdAge: seconds since the most recent activity event (a rising
    ///     edge of owes-a-move or of auto-play, a landing, an auto-play
    ///     step), or nil when nothing has happened yet.
    public static func shouldHold(enabled: Bool,
                                  engineOwesMove: Bool,
                                  secondsSinceAIMove: TimeInterval?,
                                  isAutoPlaying: Bool,
                                  isActive: Bool,
                                  holdAge: TimeInterval?) -> Bool {
        guard enabled, isActive else { return false }
        if let holdAge, holdAge >= ceilingSeconds { return false }
        if engineOwesMove || isAutoPlaying { return true }
        if let secondsSinceAIMove, secondsSinceAIMove < tailSeconds { return true }
        return false
    }
}
