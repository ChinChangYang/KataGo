//
//  GameEntityQueryTests.swift
//  KataGo iOSTests
//

import Testing
import SwiftData
import Foundation
import KataGoUICore

struct GameEntityQueryTests {
    @Test @MainActor func gameEntity_capturesNameAndFirstComment() throws {
        let record = GameRecord(config: Config())
        record.name = "Opening Study"
        record.comments = [0: "Black takes 4-4", 1: "White approaches"]
        record.width = 19
        record.height = 19
        let entity = GameEntity(gameRecord: record)
        #expect(entity.name == "Opening Study")
        #expect(entity.firstComment == "Black takes 4-4")
        #expect(entity.boardWidth == 19)
    }

    /// After opening a game, stepping to the end, then navigating BACK, the engine
    /// leaves blackStones/whiteStones keys up to the highest move ever visited
    /// (plain back-navigation never trims them) while `currentIndex` points at the
    /// displayed, earlier move. The widget must render the DISPLAYED position, not
    /// the stale later one — so lastIndex follows currentIndex, not keys.max().
    @Test @MainActor func gameEntity_rendersCurrentIndexPositionNotHighestVisited() {
        let record = GameRecord(config: Config())
        record.width = 19
        record.height = 19
        record.currentIndex = 1
        record.blackStones = [0: "", 1: "Q16", 2: "Q16 D4"]   // stepped to move 2, then back to 1
        record.whiteStones = [0: "", 1: "", 2: ""]
        let entity = GameEntity(gameRecord: record)
        #expect(entity.lastBlackStones == ["Q16"])             // move 1 (displayed), not move 2
    }

    /// When `currentIndex` has no entry in the stone dicts (e.g. a record written
    /// by a path that didn't fill that index), lastIndex falls back to the highest
    /// stored index so the widget still renders something.
    @Test @MainActor func gameEntity_fallsBackToMaxKeyWhenCurrentIndexHasNoStones() {
        let record = GameRecord(config: Config())
        record.currentIndex = 7                                 // no key 7 in the dicts
        record.blackStones = [2: "Q16"]
        record.whiteStones = [:]
        let entity = GameEntity(gameRecord: record)
        #expect(entity.lastBlackStones == ["Q16"])
    }

    /// Seeds a store with two records sharing one UUID.
    @MainActor
    private func seedDuplicateUUIDStore() throws -> (ModelContainer, UUID) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "dup.store")
        let container = try ModelContainer(for: SharedModelContainer.schema,
                                           configurations: ModelConfiguration(url: url))
        let shared = UUID()
        let a = GameRecord.createGameRecord(name: "A"); a.uuid = shared
        let b = GameRecord.createGameRecord(name: "B"); b.uuid = shared
        container.mainContext.insert(a)
        container.mainContext.insert(b)
        try container.mainContext.save()
        return (container, shared)
    }

    /// The widget / AppIntents extension is a second sandboxed process and must
    /// treat the CloudKit-synced store as READ-ONLY: fetching for the picker must
    /// not reassign UUIDs or save. Regression test for the extension writing the
    /// store (CloudKit corruption risk).
    @Test @MainActor func fetchRecords_readOnly_doesNotMutateOrPersist() throws {
        let (container, shared) = try seedDuplicateUUIDStore()

        let returned = try GameEntityQuery.fetchRecords(container: container, repair: false)

        #expect(returned.filter { $0.uuid == shared }.count == 2)   // duplicates untouched in memory
        let fresh = try GameRecord.fetchGameRecords(container: container)
        #expect(fresh.filter { $0.uuid == shared }.count == 2)      // nothing persisted
    }

    /// The main app (repair: true) still repairs duplicate UUIDs and persists.
    @Test @MainActor func fetchRecords_repair_assignsUniqueUUIDsAndPersists() throws {
        let (container, _) = try seedDuplicateUUIDStore()

        _ = try GameEntityQuery.fetchRecords(container: container, repair: true)

        let fresh = try GameRecord.fetchGameRecords(container: container)
        #expect(Set(fresh.compactMap { $0.uuid }).count == 2)       // repaired + persisted
    }

    /// The repair gate must be OFF inside app extensions and ON in the app. The
    /// test host is an app (not an `.appex`), so detection reports false here.
    @Test func isAppExtension_isFalseInAppProcess() {
        #expect(GameEntityQuery.isAppExtension == false)
    }

    // MARK: - Proactive identity repair (Issue 2: nil/duplicate-uuid round-trip)

    @MainActor
    private func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(for: SharedModelContainer.schema,
                           configurations: ModelConfiguration(schema: SharedModelContainer.schema, isStoredInMemoryOnly: true))
    }

    /// The widget's AppIntents round-trip resolves a configured game by its stored
    /// uuid; a record that arrived from CloudKit with a NIL uuid is unresolvable
    /// (`GameEntity.id` becomes a fresh random UUID each time it is built). The
    /// normal app game list uses a plain @Query and never repairs, so this proactive
    /// main-app pass must assign a stable, non-nil uuid and persist it — after which
    /// the formerly-nil game round-trips through `resolveEntities`.
    @Test @MainActor func repairStoredIdentities_fixesNilUUID_andRoundTrips() throws {
        let c = try inMemoryContainer()
        let nilGame = GameRecord(config: Config()); nilGame.name = "NilGame"; nilGame.uuid = nil
        let normal = GameRecord(config: Config()); normal.name = "Normal"
        c.mainContext.insert(nilGame); c.mainContext.insert(normal); try c.mainContext.save()

        let reassigned = try GameEntityQuery.repairStoredIdentities(container: c)
        #expect(reassigned >= 1)

        let fresh = try GameRecord.fetchGameRecords(container: c)
        #expect(fresh.allSatisfy { $0.uuid != nil })                       // nil repaired + persisted

        let target = try #require(fresh.first { $0.name == "NilGame" })
        let resolved = try GameEntityQuery.resolveEntities(for: [try #require(target.uuid)], container: c)
        #expect(resolved.count == 1)
        #expect(resolved.first?.name == "NilGame")
    }

    /// Duplicate uuids get distinct ones so the picker can tell them apart.
    @Test @MainActor func repairStoredIdentities_fixesDuplicateUUIDs() throws {
        let c = try inMemoryContainer()
        let shared = UUID()
        let g1 = GameRecord(config: Config()); g1.name = "A"; g1.uuid = shared
        let g2 = GameRecord(config: Config()); g2.name = "B"; g2.uuid = shared
        c.mainContext.insert(g1); c.mainContext.insert(g2); try c.mainContext.save()

        let reassigned = try GameEntityQuery.repairStoredIdentities(container: c)
        #expect(reassigned == 1)                                           // one of the pair reassigned

        let fresh = try GameRecord.fetchGameRecords(container: c)
        #expect(Set(fresh.compactMap { $0.uuid }).count == 2)             // now unique
    }

    /// Idempotent: a store with unique, non-nil uuids needs no changes — so the
    /// startup pass doesn't churn CloudKit on every launch.
    @Test @MainActor func repairStoredIdentities_cleanStore_isNoOp() throws {
        let c = try inMemoryContainer()
        let a = GameRecord(config: Config()); a.name = "A"
        let b = GameRecord(config: Config()); b.name = "B"
        c.mainContext.insert(a); c.mainContext.insert(b); try c.mainContext.save()

        #expect(try GameEntityQuery.repairStoredIdentities(container: c) == 0)
    }

    // MARK: - ProcessKind (shared app-vs-extension detector)

    @Test func processKind_appexBundlePath_isExtension() {
        #expect(ProcessKind.isAppExtension(bundlePath: "/var/x/KataGoAnytimeWidget.appex") == true)
    }

    @Test func processKind_appBundlePath_isNotExtension() {
        #expect(ProcessKind.isAppExtension(bundlePath: "/Applications/KataGo Anytime.app") == false)
    }

    @Test func processKind_emptyBundlePath_isNotExtension() {
        #expect(ProcessKind.isAppExtension(bundlePath: "") == false)
    }

    // MARK: - BoardPoint.refillString (Tier-3 F: refill key parity with SGF import)

    /// A per-index refill writes into a `[Int: String]` dict; `dict[i] = nil` REMOVES
    /// the key, diverging from the SGF-import path (which writes "" via `joined`) and
    /// breaking `GameEntity.lastIndex`. `refillString` must yield "" for an empty side
    /// so the key stays present-but-empty (matching import byte-for-byte).
    @Test func refillString_emptySide_isEmptyStringNotNil() {
        #expect(BoardPoint.refillString([], width: 19, height: 19) == "")
    }

    /// For a non-empty side `refillString` is identical to `toString` — only the
    /// empty case is corrected, so live rendering is unchanged.
    @Test func refillString_nonEmptySide_matchesToString() {
        let points = [BoardPoint(x: 3, y: 3), BoardPoint(x: 15, y: 15)]
        let expected = BoardPoint.toString(points, width: 19, height: 19)
        #expect(expected != nil)
        #expect(BoardPoint.refillString(points, width: 19, height: 19) == expected)
    }
}
