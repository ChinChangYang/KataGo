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
