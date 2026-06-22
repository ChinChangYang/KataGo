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

/// F14: a deep link arriving before the engine is ready (macOS cold launch from
/// the widget, where the engine subprocess handshakes asynchronously) must be
/// deferred — not applied straight through to GTP — then drained once ready.
struct DeepLinkSelectionGateTests {
    @Test func request_whileEngineReady_appliesImmediatelyAndStashesNothing() {
        var gate = DeepLinkSelectionGate()
        let id = UUID()
        #expect(gate.request(gameID: id, isEngineReady: true) == id)
        #expect(gate.pendingGameID == nil)
    }

    @Test func request_whileEngineNotReady_defersAndStashes() {
        var gate = DeepLinkSelectionGate()
        let id = UUID()
        #expect(gate.request(gameID: id, isEngineReady: false) == nil)
        #expect(gate.pendingGameID == id)
    }

    @Test func drainOnEngineReady_returnsStashedThenClears() {
        var gate = DeepLinkSelectionGate()
        let id = UUID()
        _ = gate.request(gameID: id, isEngineReady: false)
        #expect(gate.drainOnEngineReady() == id)
        #expect(gate.pendingGameID == nil)
        #expect(gate.drainOnEngineReady() == nil)   // idempotent: no replay
    }

    @Test func drainOnEngineReady_returnsNilWhenNothingPending() {
        var gate = DeepLinkSelectionGate()
        #expect(gate.drainOnEngineReady() == nil)
    }

    @Test func request_lastWriteWins_whenMultipleDeferred() {
        var gate = DeepLinkSelectionGate()
        let first = UUID(), second = UUID()
        _ = gate.request(gameID: first, isEngineReady: false)
        _ = gate.request(gameID: second, isEngineReady: false)
        #expect(gate.pendingGameID == second)
        #expect(gate.drainOnEngineReady() == second)
    }

    @Test func request_whileReady_dropsStalePending() {
        var gate = DeepLinkSelectionGate()
        let stale = UUID(), fresh = UUID()
        _ = gate.request(gameID: stale, isEngineReady: false)  // deferred
        #expect(gate.request(gameID: fresh, isEngineReady: true) == fresh)
        #expect(gate.pendingGameID == nil)                     // stale dropped
        #expect(gate.drainOnEngineReady() == nil)              // no replay of stale
    }
}
