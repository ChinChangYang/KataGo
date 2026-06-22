import Testing
import Foundation
import SwiftData
import KataGoUICore

struct GameDeepLinkTests {
    @Test func roundTrip_buildsAndParsesGameID() {
        let id = UUID()
        let url = GameDeepLink.url(for: id)
        #expect(url.scheme == "katago-anytime")
        #expect(GameDeepLink.gameID(from: url) == id)
    }

    @Test func gameID_rejectsForeignURLs() {
        #expect(GameDeepLink.gameID(from: URL(string: "file:///tmp/x.sgf")!) == nil)
        #expect(GameDeepLink.gameID(from: URL(string: "katago-anytime://open-game?id=not-a-uuid")!) == nil)
    }
}

/// F5: a deep link whose game was deleted (e.g. a widget lagging the store)
/// must fall back to the most-recent game instead of silently doing nothing —
/// mirroring `SavedGameSnapshot.resolveSnapshot`'s display fallback.
struct GameDeepLinkResolveTests {
    @MainActor
    private func container() throws -> ModelContainer {
        try ModelContainer(for: SharedModelContainer.schema,
                           configurations: ModelConfiguration(schema: SharedModelContainer.schema,
                                                              isStoredInMemoryOnly: true))
    }

    @MainActor
    private func seedTwo(_ c: ModelContainer) throws -> (older: GameRecord, newer: GameRecord) {
        let older = GameRecord(config: Config()); older.name = "Older"
        older.uuid = UUID(); older.lastModificationDate = Date(timeIntervalSince1970: 1)
        let newer = GameRecord(config: Config()); newer.name = "Newer"
        newer.uuid = UUID(); newer.lastModificationDate = Date(timeIntervalSince1970: 2)
        c.mainContext.insert(older); c.mainContext.insert(newer)
        try c.mainContext.save()
        return (older, newer)
    }

    @Test @MainActor func resolveDeepLinkTarget_returnsExactMatch() throws {
        let c = try container()
        let (older, newer) = try seedTwo(c)
        #expect(GameRecord.resolveDeepLinkTarget(id: older.uuid!, container: c)?.uuid == older.uuid)
        #expect(GameRecord.resolveDeepLinkTarget(id: newer.uuid!, container: c)?.uuid == newer.uuid)
    }

    @Test @MainActor func resolveDeepLinkTarget_fallsBackToMostRecentWhenMissing() throws {
        let c = try container()
        let (_, newer) = try seedTwo(c)
        let result = GameRecord.resolveDeepLinkTarget(id: UUID(), container: c)
        #expect(result?.uuid == newer.uuid)   // most-recently-modified
    }

    @Test @MainActor func resolveDeepLinkTarget_returnsNilWhenEmpty() throws {
        let c = try container()
        #expect(GameRecord.resolveDeepLinkTarget(id: UUID(), container: c) == nil)
    }
}
