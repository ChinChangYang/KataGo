import Foundation

/// Persists the Saved Game widget's last successfully-resolved configured game id
/// in the shared App Group.
///
/// WHY: WidgetKit re-materializes the configured `GameEntity` (`SelectGameIntent.game`)
/// on every timeline pass via `GameEntityQuery.entities(for:)`. In the memory-
/// constrained widget process that resolution flakes to nil INTERMITTENTLY — when it
/// does, `SavedGameSnapshot.resolveSnapshot` would fall back to the most-recently-
/// modified game for BOTH the displayed board and the tap deep link, so a widget
/// configured to game A intermittently shows and opens the wrong (most-recent) game.
/// By caching the id whenever `configuration.game` DOES resolve and reusing it when it
/// doesn't, the widget stays pinned to the configured game instead of switching to
/// most-recent.
///
/// SINGLE-KEY (not per-widget): a timeline provider has no stable per-widget
/// identifier, so with multiple widgets configured to DIFFERENT games this is
/// best-effort — a nil pass reuses the most-recently-resolved configured id, which may
/// not be this widget's. The common single-widget case is exact, and even the
/// multi-widget degradation shows a *configured* game rather than the most-recent,
/// which is strictly better than the prior unconditional most-recent fallback.
public struct WidgetConfiguredGameStore {
    private let defaults: UserDefaults?
    private let key = "widget.lastConfiguredGameID"

    /// Test seam: inject a `UserDefaults` (e.g. a throwaway suite) directly.
    public init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    /// Production: the App-Group suite shared by the app and the widget extension.
    public init(suiteName: String = SharedModelContainer.appGroupID) {
        self.init(defaults: UserDefaults(suiteName: suiteName))
    }

    public func save(_ id: UUID) {
        defaults?.set(id.uuidString, forKey: key)
    }

    public func load() -> UUID? {
        guard let string = defaults?.string(forKey: key) else { return nil }
        return UUID(uuidString: string)
    }

    public func clear() {
        defaults?.removeObject(forKey: key)
    }
}
