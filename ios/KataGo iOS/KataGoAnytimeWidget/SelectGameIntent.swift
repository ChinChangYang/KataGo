import WidgetKit
import AppIntents
import Foundation
import KataGoGameStore

struct SelectGameIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Select Game"
    static let description = IntentDescription("Choose which saved game the widget shows.")

    // The configured game is stored as its UUID STRING — a plain value that
    // round-trips through the intent WITHOUT the AppEntity re-materialization
    // (`GameEntityQuery.entities(for:)`) that AppIntents/linkd cannot perform in the
    // memory-/signing-constrained widget process (deterministic in the Simulator,
    // where linkd can't read the widget bundle's teamId; intermittent on device under
    // memory pressure). A `GameEntity?` parameter resolves to nil on those passes, so
    // the widget could not honor a configured game that isn't the most-recent. A plain
    // String is decoded directly from the stored intent, so the widget stays pinned to
    // the exact game the user picked. The picker still shows game names via
    // `GameOptionsProvider`.
    @Parameter(title: "Game", optionsProvider: GameOptionsProvider())
    var gameID: String?

    /// The widget backplate, stored as a `SavedGameBackground` RAW VALUE
    /// String. This started life as an AppEnum parameter, but an AppEnum goes
    /// through the same AppIntents resolver machinery as `GameEntity` — and in
    /// the widget process that resolution yields NIL (verified in the
    /// simulator log: every timeline request logged "Prepared background to
    /// SavedGameBackgroundOption(nil)" even after the user picked Glass and
    /// the Edit sheet redisplayed Glass), so the declared default silently won
    /// forever. A plain String decodes directly from the stored intent — the
    /// same fix as `gameID` above. nil (unconfigured or pre-upgrade) resolves
    /// to Wood via `SavedGameBackground.resolve`.
    @Parameter(title: "Background", optionsProvider: BackgroundOptionsProvider())
    var background: String?
}

/// Supplies the Background picker: one item per `SavedGameBackground` case,
/// value = the raw String the provider restores, title = the display name.
/// Static list, no store access — instant and memory-free in the appex.
struct BackgroundOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> ItemCollection<String> {
        let items = SavedGameBackground.allCases.map { background in
            IntentItem<String>(background.rawValue,
                               title: "\(background.displayName)")
        }
        return ItemCollection(sections: [IntentItemSection(items: items)])
    }

    /// Shown in the Edit sheet row before the user ever picks — the designed
    /// Wood default rather than an empty row.
    func defaultResult() async -> String? {
        SavedGameBackground.default.rawValue
    }
}

/// Supplies the widget configuration picker with one option per saved game: the
/// value is the game's UUID string (what the widget reads), the title is the game's
/// name. Delegates to `GameEntityQuery.pickerOptions`, a property-bounded fetch that
/// reads only name + first comment and never builds a `GameEntity` — the previous
/// version faulted in every game's heavy per-move board dictionaries for 50 records,
/// blowing the hard 30 MB widget memory limit so jetsam killed the appex
/// (JETSAM_REASON_MEMORY_PERPROCESSLIMIT) and the picker showed "Loading…" then closed
/// empty. The selected String is restored to the timeline provider directly, never via
/// an entity round-trip.
struct GameOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> ItemCollection<String> {
        do {
            let options = try await MainActor.run {
                try GameEntityQuery.pickerOptions(container: SharedModelContainer.shared, limit: 50)
            }
            let items = options.map {
                IntentItem<String>($0.id, title: "\($0.title)", subtitle: "\($0.subtitle)")
            }
            return ItemCollection(sections: [IntentItemSection(items: items)])
        } catch {
            // Property-bounding keeps the appex well under its memory limit, but still
            // degrade a transient SwiftData/CloudKit fault to an EMPTY picker rather
            // than letting it propagate and silently close the picker. The timeline
            // path swallows the same class of error with `try?`; this options
            // evaluation runs separately and must tolerate it on its own.
            NSLog("GameOptionsProvider.results failed: \(error)")
            return ItemCollection(sections: [IntentItemSection<String>(items: [])])
        }
    }
}
