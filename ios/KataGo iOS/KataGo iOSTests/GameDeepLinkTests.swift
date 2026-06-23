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

/// F14/F14b: a game selection arriving before the engine is ready (macOS cold
/// launch — a widget deep link OR an .sgf file-open, where the engine subprocess
/// handshakes asynchronously) must be deferred, not applied straight through to
/// GTP, then drained once ready. The shared `selectGame(_:)` chokepoint uses
/// this gate so both entry points are covered by one mechanism.
struct ReadinessGateTests {
    @Test func request_whenReady_appliesImmediatelyAndStashesNothing() {
        var gate = ReadinessGate<UUID>()
        let id = UUID()
        #expect(gate.request(id, isReady: true) == id)
        #expect(gate.pending == nil)
    }

    @Test func request_whenNotReady_defersAndStashes() {
        var gate = ReadinessGate<UUID>()
        let id = UUID()
        #expect(gate.request(id, isReady: false) == nil)
        #expect(gate.pending == id)
    }

    @Test func drainWhenReady_returnsStashedThenClears() {
        var gate = ReadinessGate<UUID>()
        let id = UUID()
        _ = gate.request(id, isReady: false)
        #expect(gate.drainWhenReady() == id)
        #expect(gate.pending == nil)
        #expect(gate.drainWhenReady() == nil)   // idempotent: no replay
    }

    @Test func drainWhenReady_returnsNilWhenNothingPending() {
        var gate = ReadinessGate<UUID>()
        #expect(gate.drainWhenReady() == nil)
    }

    @Test func request_lastWriteWins_whenMultipleDeferred() {
        var gate = ReadinessGate<UUID>()
        let first = UUID(), second = UUID()
        _ = gate.request(first, isReady: false)
        _ = gate.request(second, isReady: false)
        #expect(gate.pending == second)
        #expect(gate.drainWhenReady() == second)
    }

    @Test func request_whenReady_dropsStalePending() {
        var gate = ReadinessGate<UUID>()
        let stale = UUID(), fresh = UUID()
        _ = gate.request(stale, isReady: false)        // deferred
        #expect(gate.request(fresh, isReady: true) == fresh)
        #expect(gate.pending == nil)                   // stale dropped
        #expect(gate.drainWhenReady() == nil)          // no replay of stale
    }

    /// Genericity: the gate carries any payload (the macOS app uses it with a
    /// GameRecord-pair selection payload at the `selectGame(_:)` chokepoint).
    @Test func gate_isGenericOverPayload() {
        var gate = ReadinessGate<Int>()
        #expect(gate.request(7, isReady: false) == nil)
        #expect(gate.pending == 7)
        #expect(gate.drainWhenReady() == 7)
    }
}
