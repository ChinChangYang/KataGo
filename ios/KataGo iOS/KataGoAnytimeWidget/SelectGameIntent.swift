import WidgetKit
import AppIntents
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
}

/// Supplies the widget configuration picker with one option per saved game: the
/// value is the game's UUID string (what the widget reads), the title is the game's
/// name. Runs the same bounded, read-only store fetch the AppEntity query used — and,
/// crucially, only POPULATES the picker; the selected String value is restored to the
/// timeline provider directly, never via an entity round-trip.
struct GameOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> ItemCollection<String> {
        let items = try await MainActor.run { () -> [IntentItem<String>] in
            try GameEntityQuery.fetchRecords(container: SharedModelContainer.shared,
                                             limit: 50, repair: false)
                .compactMap { record -> IntentItem<String>? in
                    guard let uuid = record.uuid else { return nil }
                    let entity = GameEntity(gameRecord: record)
                    return IntentItem<String>(
                        uuid.uuidString,
                        title: "\(entity.name)",
                        subtitle: "\(entity.firstComment)"
                    )
                }
        }
        return ItemCollection(sections: [IntentItemSection(items: items)])
    }
}
