import Testing
import SwiftData
import Foundation
import KataGoUICore

struct SavedGameProviderTests {
    @MainActor
    private func container() throws -> ModelContainer {
        try ModelContainer(for: SharedModelContainer.schema,
                           configurations: ModelConfiguration(schema: SharedModelContainer.schema, isStoredInMemoryOnly: true))
    }

    @Test @MainActor func resolve_fallsBackToMostRecentWhenUnconfigured() throws {
        let c = try container()
        let older = GameRecord(config: Config()); older.name = "Older"; older.lastModificationDate = Date(timeIntervalSince1970: 1)
        let newer = GameRecord(config: Config()); newer.name = "Newer"; newer.lastModificationDate = Date(timeIntervalSince1970: 2)
        c.mainContext.insert(older); c.mainContext.insert(newer); try c.mainContext.save()

        let snap = SavedGameSnapshot.resolveSnapshot(for: nil, container: c)
        #expect(snap.name == "Newer")
    }

    @Test @MainActor func resolve_returnsPlaceholderWhenEmpty() throws {
        let c = try container()
        let snap = SavedGameSnapshot.resolveSnapshot(for: nil, container: c)
        #expect(snap.gameID == nil)
        #expect(snap.name == "No game selected")
    }

    /// A configured game must resolve to exactly that game via a bounded fetch,
    /// not by materializing the whole library in the memory-constrained widget
    /// process. Regression guard for the resolveSnapshot wiring.
    @Test @MainActor func resolve_returnsConfiguredGameWhenPresent() throws {
        let c = try container()
        let alpha = GameRecord(config: Config()); alpha.name = "Alpha"
        let bravo = GameRecord(config: Config()); bravo.name = "Bravo"
        c.mainContext.insert(alpha); c.mainContext.insert(bravo); try c.mainContext.save()

        let snap = SavedGameSnapshot.resolveSnapshot(for: GameEntity(gameRecord: bravo), container: c)
        #expect(snap.gameID == bravo.uuid)
        #expect(snap.name == "Bravo")
    }

    /// The bounded single-record fetch the widget uses to resolve its configured
    /// game: returns the matching record, or nil when no game has that UUID.
    @Test @MainActor func fetchGameRecord_returnsMatchingRecordOrNil() throws {
        let c = try container()
        let alpha = GameRecord(config: Config()); alpha.name = "Alpha"
        let bravo = GameRecord(config: Config()); bravo.name = "Bravo"
        c.mainContext.insert(alpha); c.mainContext.insert(bravo); try c.mainContext.save()

        let found = try GameRecord.fetchGameRecord(uuid: try #require(bravo.uuid), container: c)
        #expect(found?.name == "Bravo")
        #expect(try GameRecord.fetchGameRecord(uuid: UUID(), container: c) == nil)
    }

    /// F7: the timeline must NOT use `policy: .never` (which never self-refreshes
    /// on cross-device CloudKit edits). The reload date must be a bounded point
    /// in the future so the widget periodically re-resolves its snapshot.
    @Test func widgetReloadPolicy_schedulesBoundedFutureReload() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let next = WidgetReloadPolicy.nextReloadDate(after: base)
        #expect(next > base)                                    // not .never / not in the past
        #expect(next <= base.addingTimeInterval(24 * 60 * 60))  // refreshes at least daily
    }
}
