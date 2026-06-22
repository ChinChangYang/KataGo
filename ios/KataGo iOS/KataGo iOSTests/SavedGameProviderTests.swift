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
}
