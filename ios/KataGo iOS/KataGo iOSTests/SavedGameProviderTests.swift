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
