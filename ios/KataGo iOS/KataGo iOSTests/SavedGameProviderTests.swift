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

    // MARK: - configuredGameID: the tap target must follow the user's explicit
    // configured choice, not the resolved display snapshot (which can fall back to
    // most-recent). `SavedGameWidgetView` builds the deep-link URL from
    // `configuredGameID ?? gameID`, so the configured id must survive a display
    // fallback. Without this, a widget whose configured game momentarily can't be
    // resolved opens the most-recent game instead of the one the user picked.

    /// When the configured game can't be resolved (e.g. the widget process's store
    /// lags and the bounded fetch misses), the DISPLAY falls back to most-recent —
    /// but the snapshot must still carry the CONFIGURED id so the tap targets the
    /// user's choice, not the fallback.
    @Test @MainActor func resolveSnapshot_carriesConfiguredGameID_evenWhenDisplayFallsBack() throws {
        let c = try container()
        let newer = GameRecord(config: Config()); newer.name = "Newer"
        newer.lastModificationDate = Date(timeIntervalSince1970: 2)
        c.mainContext.insert(newer); try c.mainContext.save()

        // A configured entity whose game is NOT in this store (never inserted), so
        // the display resolution falls back to `newer`.
        let ghost = GameRecord(config: Config()); ghost.name = "Ghost"; ghost.uuid = UUID()
        let snap = SavedGameSnapshot.resolveSnapshot(for: GameEntity(gameRecord: ghost), container: c)

        #expect(snap.name == "Newer")                       // display fell back
        #expect(snap.gameID == newer.uuid)                  // displayed game's id
        #expect(snap.configuredGameID == ghost.uuid)        // but the TAP target is the configured id
    }

    /// An unconfigured widget legitimately shows most-recent; with no configured
    /// game there is no configured id, so the tap falls back to the displayed id.
    @Test @MainActor func resolveSnapshot_unconfigured_configuredGameIDIsNil() throws {
        let c = try container()
        let only = GameRecord(config: Config()); only.name = "Only"
        c.mainContext.insert(only); try c.mainContext.save()

        let snap = SavedGameSnapshot.resolveSnapshot(for: nil, container: c)
        #expect(snap.configuredGameID == nil)
    }

    /// Healthy path: configured game present → display id and configured id agree.
    @Test @MainActor func resolveSnapshot_configuredPresent_configuredGameIDEqualsGameID() throws {
        let c = try container()
        let alpha = GameRecord(config: Config()); alpha.name = "Alpha"
        let bravo = GameRecord(config: Config()); bravo.name = "Bravo"
        c.mainContext.insert(alpha); c.mainContext.insert(bravo); try c.mainContext.save()

        let snap = SavedGameSnapshot.resolveSnapshot(for: GameEntity(gameRecord: bravo), container: c)
        #expect(snap.gameID == bravo.uuid)
        #expect(snap.configuredGameID == bravo.uuid)
    }

    // MARK: - id-based resolution + sticky-id fallback (the real fix)
    //
    // The root cause: WidgetKit re-materializes `configuration.game` intermittently
    // and it comes back nil under appex memory pressure, so the widget fell back to
    // most-recent. The provider now caches the id whenever it DOES resolve
    // (`WidgetConfiguredGameStore`) and passes it to `resolveSnapshot(configuredID:)`
    // on a nil pass, so the widget stays pinned to the configured game.

    /// THE headline regression: given the configured id of an OLDER game and a newer
    /// game in the store, resolve to the CONFIGURED game — never the most-recent.
    /// (This is what the provider passes from the sticky cache on a nil pass.)
    @Test @MainActor func resolveSnapshot_configuredID_returnsConfiguredNotMostRecent() throws {
        let c = try container()
        let configured = GameRecord(config: Config()); configured.name = "Configured"
        configured.lastModificationDate = Date(timeIntervalSince1970: 1)   // older
        let newer = GameRecord(config: Config()); newer.name = "Newer"
        newer.lastModificationDate = Date(timeIntervalSince1970: 2)        // most-recent
        c.mainContext.insert(configured); c.mainContext.insert(newer); try c.mainContext.save()

        let snap = SavedGameSnapshot.resolveSnapshot(configuredID: configured.uuid, container: c)
        #expect(snap.name == "Configured")                 // NOT "Newer"
        #expect(snap.gameID == configured.uuid)
        #expect(snap.configuredGameID == configured.uuid)
    }

    /// No configured id (never resolved, empty cache) → most-recent, no tap override.
    @Test @MainActor func resolveSnapshot_configuredID_nil_fallsBackToMostRecent() throws {
        let c = try container()
        let older = GameRecord(config: Config()); older.name = "Older"; older.lastModificationDate = Date(timeIntervalSince1970: 1)
        let newer = GameRecord(config: Config()); newer.name = "Newer"; newer.lastModificationDate = Date(timeIntervalSince1970: 2)
        c.mainContext.insert(older); c.mainContext.insert(newer); try c.mainContext.save()

        let snap = SavedGameSnapshot.resolveSnapshot(configuredID: nil, container: c)
        #expect(snap.name == "Newer")
        #expect(snap.configuredGameID == nil)
    }

    /// Configured game was deleted → display falls back to most-recent, but the tap
    /// still targets the configured id (the app's `resolveDeepLinkTarget` then handles
    /// the deleted case), instead of silently switching the tap to most-recent.
    @Test @MainActor func resolveSnapshot_configuredID_deleted_keepsConfiguredIDForTap() throws {
        let c = try container()
        let newer = GameRecord(config: Config()); newer.name = "Newer"; newer.lastModificationDate = Date(timeIntervalSince1970: 2)
        c.mainContext.insert(newer); try c.mainContext.save()

        let missingID = UUID()
        let snap = SavedGameSnapshot.resolveSnapshot(configuredID: missingID, container: c)
        #expect(snap.name == "Newer")                  // display falls back
        #expect(snap.configuredGameID == missingID)    // tap still targets the configured id
    }

    /// The App-Group sticky cache round-trips a configured id and clears.
    @Test func widgetConfiguredGameStore_savesLoadsAndClears() {
        let defaults = UserDefaults(suiteName: "test.widgetcache.\(UUID().uuidString)")!
        let store = WidgetConfiguredGameStore(defaults: defaults)
        #expect(store.load() == nil)            // empty to start
        let id = UUID()
        store.save(id)
        #expect(store.load() == id)             // round-trips
        store.clear()
        #expect(store.load() == nil)            // cleared
    }

    // MARK: - Issue 2: bounded AppIntents resolution (entities(for:) round-trip)

    /// The AppIntents round-trip for a configured widget game must resolve the
    /// SELECTED game (not fall back to most-recent) via a bounded per-id fetch —
    /// never a whole-library scan in the memory-constrained widget extension.
    @Test @MainActor func resolveEntities_returnsConfiguredGame() throws {
        let c = try container()
        let a = GameRecord(config: Config()); a.name = "A"
        let b = GameRecord(config: Config()); b.name = "B"
        c.mainContext.insert(a); c.mainContext.insert(b); try c.mainContext.save()

        let resolved = try GameEntityQuery.resolveEntities(for: [try #require(b.uuid)], container: c)
        #expect(resolved.count == 1)
        #expect(resolved.first?.name == "B")
        #expect(resolved.first?.id == b.uuid)
    }

    /// Duplicate UUIDs (a CloudKit sync artifact) previously made `entities(for:)`
    /// return TWO entities for one identifier → AppIntents treats the selection as
    /// unresolvable → widget falls back to most-recent. The bounded fetch (limit 1,
    /// newest-first) must collapse the pair to a single deterministic game so the
    /// configured selection still loads.
    @Test @MainActor func resolveEntities_duplicateUUID_returnsSingleGame() throws {
        let c = try container()
        let shared = UUID()
        let g1 = GameRecord(config: Config()); g1.name = "A"; g1.uuid = shared; g1.lastModificationDate = Date(timeIntervalSince1970: 1)
        let g2 = GameRecord(config: Config()); g2.name = "B"; g2.uuid = shared; g2.lastModificationDate = Date(timeIntervalSince1970: 2)
        c.mainContext.insert(g1); c.mainContext.insert(g2); try c.mainContext.save()

        let resolved = try GameEntityQuery.resolveEntities(for: [shared], container: c)
        #expect(resolved.count == 1)              // not an ambiguous pair
        #expect(resolved.first?.name == "B")      // newest of the duplicates
    }

    @Test @MainActor func resolveEntities_unknownUUID_returnsEmpty() throws {
        let c = try container()
        let a = GameRecord(config: Config()); a.name = "A"
        c.mainContext.insert(a); try c.mainContext.save()
        #expect(try GameEntityQuery.resolveEntities(for: [UUID()], container: c).isEmpty)
    }

    /// Multi-id resolution must preserve INPUT-id order (the AppIntents
    /// `entities(for:)` contract) and collapse a repeated id to a single entity.
    /// Every other resolveEntities test passes a single id, so the order-preserving
    /// `seen`-dedup branch goes unexercised. To prove the output follows INPUT order
    /// (not the store's sort), `a` is made the NEWEST record so the store's
    /// newest-first order is `[A, B]`; input `[b, a, b]` must then resolve to
    /// `["B", "A"]` — the REVERSE of store order, with the repeated `b` dropped. An
    /// implementation that returned store order would yield `["A", "B"]` and fail.
    @Test @MainActor func resolveEntities_multipleIDs_preservesOrderAndDeDupes() throws {
        let c = try container()
        // Store newest-first order is [A, B] (a newer than b) so it DISAGREES with
        // the asserted input order — otherwise the test can't tell the two apart.
        let a = GameRecord(config: Config()); a.name = "A"; a.lastModificationDate = Date(timeIntervalSince1970: 2)
        let b = GameRecord(config: Config()); b.name = "B"; b.lastModificationDate = Date(timeIntervalSince1970: 1)
        c.mainContext.insert(a); c.mainContext.insert(b); try c.mainContext.save()

        let aID = try #require(a.uuid)
        let bID = try #require(b.uuid)
        let resolved = try GameEntityQuery.resolveEntities(for: [bID, aID, bID], container: c)
        #expect(resolved.map(\.name) == ["B", "A"])   // input order (reverse of store order), repeat collapsed
        #expect(resolved.count == 2)                   // no second entity for the repeated id
    }

    /// The picker's name search must also be bounded (no whole-library scan) and
    /// stay case-insensitive (parity with the previous `localizedCaseInsensitiveContains`).
    @Test @MainActor func matchingEntities_caseInsensitiveAndBounded() throws {
        let c = try container()
        for n in ["Opening Study", "opening notes", "Endgame"] {
            let r = GameRecord(config: Config()); r.name = n; c.mainContext.insert(r)
        }
        try c.mainContext.save()

        let matches = try GameEntityQuery.matchingEntities(for: "opening", container: c, limit: 50)
        #expect(matches.count == 2)                                  // case-insensitive ("Opening" + "opening")
        #expect(try GameEntityQuery.matchingEntities(for: "o", container: c, limit: 1).count == 1)  // limit respected (2 match "o")
        // Empty query returns the whole (bounded) library, NOT none:
        // localizedStandardContains("") is false, so the helper must short-circuit.
        #expect(try GameEntityQuery.matchingEntities(for: "", container: c, limit: 50).count == 3)
        #expect(try GameEntityQuery.matchingEntities(for: "", container: c, limit: 2).count == 2)   // bounded
        // A non-positive limit returns [] (fetchLimit 0 means "no limit" in Core Data).
        #expect(try GameEntityQuery.matchingEntities(for: "", container: c, limit: 0).isEmpty)
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
