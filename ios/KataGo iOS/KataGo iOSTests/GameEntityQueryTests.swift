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
}
