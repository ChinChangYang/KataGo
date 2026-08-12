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
    /// and the review replay's per-slide pacing read.
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
    /// Slow IS the live broadcast; normal tightens the text; fast tightens it
    /// further. Speed is a pacing choice ONLY — every profile narrates every
    /// slide the report produced. Fast used to cap the cycle at the Best Move
    /// slide, which made a speed control silently delete the Alternative and
    /// Playing-vs-Passing analysis; that cap is gone.
    public var broadcastPacing: BroadcastPacing {
        switch self {
        case .slow:
            .live
        case .normal:
            BroadcastPacing(charactersPerSecond: 45, dwellSeconds: 1.5,
                            minimumSlideSeconds: 4.0)
        case .fast:
            BroadcastPacing(charactersPerSecond: 60, dwellSeconds: 1.0,
                            minimumSlideSeconds: 3.0)
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
}
