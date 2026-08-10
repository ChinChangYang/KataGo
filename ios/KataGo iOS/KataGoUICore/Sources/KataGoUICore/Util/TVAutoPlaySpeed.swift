//
//  TVAutoPlaySpeed.swift
//  KataGoUICore
//
//  How fast TVReviewScreen's Auto-Play steps through a saved game's recorded
//  moves. Extracted into KataGoUICore (dependency-light, platform-agnostic) so
//  the cadence is unit-testable from the iOS test host: its consumers —
//  TVReviewScreen and TVSettingsScreen — are TV-target-only views that no test
//  target in this project can reach (the TimelineStepClassifier precedent).
//

import Foundation

public enum TVAutoPlaySpeed: String, CaseIterable, Identifiable, Sendable {
    case slow
    case normal
    case fast

    /// The one UserDefaults key, shared by the Settings picker's `@AppStorage`
    /// and the review screen's per-tick read.
    public static let defaultsKey = "TVSettings.autoPlaySpeed"

    /// One source of truth for the default so the picker's declared default and
    /// any non-View fallback can never drift (today's `soundEffects` default is
    /// duplicated across TVSettingsScreen and TVSettingsStore — don't repeat it).
    public static let defaultValue: TVAutoPlaySpeed = .normal

    /// The persisted speed right now. For escaping closures that must read
    /// the CURRENT value each cycle (a captured @AppStorage copy would not).
    public static var current: TVAutoPlaySpeed {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let speed = TVAutoPlaySpeed(rawValue: raw) else { return defaultValue }
        return speed
    }

    /// How this speed paces the commentated replay (see BroadcastPacing).
    /// Slow IS the live broadcast; normal tightens text; fast shows only the
    /// Best Move slide at the tightest text pacing.
    public var broadcastPacing: BroadcastPacing {
        switch self {
        case .slow:
            .live
        case .normal:
            BroadcastPacing(charactersPerSecond: 45, dwellSeconds: 1.5,
                            minimumSlideSeconds: 4.0, maxSlideCount: Int.max)
        case .fast:
            BroadcastPacing(charactersPerSecond: 60, dwellSeconds: 1.0,
                            minimumSlideSeconds: 3.0, maxSlideCount: 1)
        }
    }

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .slow: "Slow"
        case .normal: "Normal"
        case .fast: "Fast"
        }
    }

    /// Seconds between auto-advanced moves.
    public var seconds: Double {
        switch self {
        case .slow: 3.0
        case .normal: 1.5
        case .fast: 0.7
        }
    }

    /// The same cadence as a `Duration`, for `Task.sleep(for:)`.
    public var interval: Duration { .seconds(seconds) }
}
