import WidgetKit
import AppIntents
import Foundation
import KataGoGameStore

struct SelectGameIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Select Game"
    static let description = IntentDescription("Choose which saved game the widget shows, and how it looks.")

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
    /// SavedGameBackgroundOption(nil)" even after the user picked a
    /// non-default option and the Edit sheet redisplayed it), so the declared
    /// default silently won forever. A plain String decodes directly from the
    /// stored intent — the same fix as `gameID` above. nil (unconfigured or
    /// pre-upgrade) and retired raw values resolve to the designed default
    /// via `SavedGameBackground.resolve`.
    @Parameter(title: "Background", optionsProvider: BackgroundOptionsProvider())
    var background: String?

    /// The Edit Widget "Show Comment" switch. A plain, NON-optional `Bool` with
    /// a declared default — deliberately, and NOT a relapse into the AppEnum
    /// shape the two comments above warn against. `Bool` conforms to
    /// `AppIntents._IntentValue` DIRECTLY (`UnwrappedType == Bool`,
    /// `ValueType == Bool`), exactly as `String` does; `AppEnum`/`AppEntity`
    /// instead reach it through `AppValue: PersistentlyIdentifiable`, and it is
    /// that type-identity round-trip through the AppIntents registry — not
    /// parameters as such — that yields nil when linkd rejects the widget
    /// bundle. A Bool carries no persistent identifier to look up, so it decodes
    /// straight out of the stored intent like the two Strings above.
    ///
    /// `default: true` is load-bearing twice: it is the behavior the widget
    /// shipped with before this switch existed, AND it is what an ALREADY-PLACED
    /// widget resolves to — such a configuration simply has no entry for this
    /// new key, so the declared default fills it and no existing widget changes
    /// appearance. It must stay a LITERAL: the initializer takes the default as
    /// `_const`, so a named constant will not compile here. And the property
    /// name IS the stored key, so renaming it would reset every configured row.
    @Parameter(title: "Show Comment", default: true)
    var showsComment: Bool
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
    /// default rather than an empty row.
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
