//
//  GameEntityQueryTests.swift
//  KataGo iOSTests
//

import Testing
import SwiftData
import Foundation
import KataGoUICore
import GoRulesKit

struct GameEntityQueryTests {
    /// A 19×19 game whose moves are Q16, D4, Q4 — enough to tell "the cursor's
    /// move" apart from "some other move of the same game".
    private static let sgf = "(;FF[4]GM[1]SZ[19]KM[7.5];B[pd];W[dp];B[pq])"

    @Test @MainActor func gameEntity_capturesNameAndComments() throws {
        let record = GameRecord(config: Config())
        record.name = "Opening Study"
        record.comments = [0: "Black takes 4-4", 1: "White approaches"]
        let entity = GameEntity(gameRecord: record)
        #expect(entity.name == "Opening Study")
        // The entity is an identity, not a board: the comment LIST is what
        // Shortcuts and the picker show. The displayed position's single
        // comment belongs to the snapshot, which knows which move is drawn.
        #expect(entity.comments == ["Black takes 4-4", "White approaches"])
    }

    /// The widget shows the comment of the DISPLAYED position, not the move-0
    /// comment — and "displayed" now means the move the replay actually drew.
    @Test @MainActor func snapshot_commentFollowsTheDrawnMove_notMoveZero() throws {
        let record = GameRecord(sgf: Self.sgf, currentIndex: 2, config: Config())
        record.comments = [0: "Game intro", 2: "The pivotal cut"]
        let snap = SavedGameSnapshot(record: record,
                                     position: try #require(SgfDisplayPosition.resolve(record)))
        #expect(snap.comment == "The pivotal cut")
        #expect(snap.moveCount == 2)
    }

    /// When the drawn move has no comment, the widget shows none — falling back to
    /// the move-0 comment would reproduce the bug this guards.
    @Test @MainActor func snapshot_uncommentedDrawnMove_hasEmptyComment() throws {
        let record = GameRecord(sgf: Self.sgf, currentIndex: 2, config: Config())
        record.comments = [0: "Game intro"]
        let snap = SavedGameSnapshot(record: record,
                                     position: try #require(SgfDisplayPosition.resolve(record)))
        #expect(snap.comment == "")
    }

    /// A cursor past the end of its own game draws the last move — and captions
    /// THAT move. The board and the "Move N" line cannot describe different
    /// positions, because both read `position.moveIndex`.
    @Test @MainActor func snapshot_cursorPastTheEndClampsAndSaysSo() throws {
        let record = GameRecord(sgf: Self.sgf, currentIndex: 99, config: Config())
        record.comments = [3: "The last move", 99: "A comment on a move that isn't there"]
        let snap = SavedGameSnapshot(record: record,
                                     position: try #require(SgfDisplayPosition.resolve(record)))
        #expect(snap.moveCount == 3)
        #expect(snap.comment == "The last move")
        #expect(snap.lastBlackStones.sorted() == ["Q16", "Q3"])
    }

    /// After stepping to the end of a game and navigating BACK, the per-move stone
    /// cache still holds keys up to the highest move ever visited while
    /// `currentIndex` points at the displayed, earlier move. The widget must draw
    /// the cursor's position — which is now structural rather than guarded, since
    /// the cache is not consulted at all.
    @Test @MainActor func snapshot_drawsTheCursorNotTheHighestVisitedMove() throws {
        let record = GameRecord(sgf: Self.sgf, currentIndex: 1, config: Config())
        record.blackStones = [0: "", 1: "Q16", 3: "Q16 Q3"]   // stepped to the end, then back
        record.whiteStones = [0: "", 1: "", 3: "D4"]
        let snap = SavedGameSnapshot(record: record,
                                     position: try #require(SgfDisplayPosition.resolve(record)))
        #expect(snap.lastBlackStones == ["Q16"])
        #expect(snap.lastWhiteStones.isEmpty)
    }

    /// The shape that made the widget disagree with the phone: a cursor the stone
    /// cache never reached (a branch saved as a new game parks on the branch tip
    /// while its dictionaries stop at the divergence). The old resolution fell back
    /// to the highest CACHED move and drew that instead.
    @Test @MainActor func snapshot_ignoresTheStoneCacheEntirely() throws {
        let record = GameRecord(sgf: Self.sgf, currentIndex: 3, config: Config())
        // A cache that stops short of the cursor AND describes another game.
        record.blackStones = [1: "A1"]
        record.whiteStones = [1: "T19"]
        let snap = SavedGameSnapshot(record: record,
                                     position: try #require(SgfDisplayPosition.resolve(record)))
        #expect(snap.lastBlackStones.sorted() == ["Q16", "Q3"])
        #expect(snap.lastWhiteStones == ["D4"])
        #expect(!snap.lastBlackStones.contains("A1"))
    }

    /// Geometry comes from the replay, not from the record's cached size fields —
    /// the same rule the in-app rows follow (ADR 0014).
    @Test @MainActor func snapshot_geometryBeatsALyingCachedField() throws {
        let record = GameRecord(sgf: "(;FF[4]GM[1]SZ[9];B[ee])", currentIndex: 1, config: Config())
        record.width = 19
        record.height = 19
        let snap = SavedGameSnapshot(record: record,
                                     position: try #require(SgfDisplayPosition.resolve(record)))
        #expect(snap.boardWidth == 9)
        #expect(snap.boardHeight == 9)
    }

    /// An unreadable SGF has no replay to take geometry from, so the cached size
    /// is all there is — and nothing is drawn on it, so it cannot be confidently
    /// wrong about stones.
    @Test @MainActor func unreadableRecordDrawsAnEmptyBoardOfItsCachedSize() {
        #expect(SgfDisplayPosition.resolve(sgf: "not an sgf at all", index: 0) == nil)

        let fallback = RecordDisplayPosition.unreadable(width: 13, height: 13)
        #expect(fallback.width == 13)
        #expect(fallback.blackVertices.isEmpty)
        #expect(fallback.moveIndex == 0)
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
