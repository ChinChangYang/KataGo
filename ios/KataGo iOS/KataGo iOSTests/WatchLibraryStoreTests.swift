//
//  WatchLibraryStoreTests.swift
//  KataGo AnytimeTests
//
//  The watch's own read-only view of the library. Bounded so a wrist-sized
//  process never faults in a game's heavy per-move analysis dictionaries.
//

import Testing
import Foundation
import SwiftData
@testable import KataGoGameStore

@MainActor
struct WatchLibraryStoreTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: SharedModelContainer.schema,
                           configurations: SharedModelContainer.inMemoryConfig())
    }

    @discardableResult
    private func insert(_ container: ModelContainer, name: String, sgf: String,
                        width: Int, height: Int, modified: Date) -> GameRecord {
        // GameRecord.createGameRecord lives in KataGoUICore's bridge
        // extension, which this KataGoGameStore-only suite must not import;
        // the synthesized @Model init is what GameEntityQueryTests uses too.
        let record = GameRecord(config: Config())
        record.name = name
        record.sgf = sgf
        record.width = width
        record.height = height
        record.lastModificationDate = modified
        container.mainContext.insert(record)
        return record
    }

    private let epoch = Date(timeIntervalSince1970: 1_780_000_000)

    @Test func rowsAreNewestFirst() throws {
        let container = try makeContainer()
        insert(container, name: "Older", sgf: "(;GM[1]SZ[19])", width: 19, height: 19,
               modified: epoch)
        insert(container, name: "Newer", sgf: "(;GM[1]SZ[19])", width: 19, height: 19,
               modified: epoch.addingTimeInterval(60))

        let store = WatchLibraryStore(container: container, storeMode: .cloudKit)
        store.refresh()
        #expect(store.rows.map(\.name) == ["Newer", "Older"])
    }

    @Test func rowsCarryBoardSizeAndSgf() throws {
        let container = try makeContainer()
        insert(container, name: "Rect", sgf: "(;GM[1]SZ[19:9];B[aa])", width: 19,
               height: 9, modified: epoch)

        let store = WatchLibraryStore(container: container, storeMode: .cloudKit)
        store.refresh()
        let row = try #require(store.rows.first)
        #expect(row.boardWidth == 19)
        #expect(row.boardHeight == 9)
        #expect(row.sizeText == "19x9")
        #expect(row.sgf.contains("SZ[19:9]"))
    }

    @Test func missingBoardSizeDefaultsToNineteen() throws {
        let container = try makeContainer()
        let record = insert(container, name: "NoSize", sgf: "(;GM[1]SZ[19])",
                            width: 19, height: 19, modified: epoch)
        record.width = nil
        record.height = nil

        let store = WatchLibraryStore(container: container, storeMode: .cloudKit)
        store.refresh()
        let row = try #require(store.rows.first)
        #expect(row.boardWidth == 19)
        #expect(row.boardHeight == 19)
    }

    @Test func moveCountIsScannedAndMemoized() throws {
        let container = try makeContainer()
        insert(container, name: "Three", sgf: "(;GM[1]SZ[9];B[aa];W[bb];B[cc])",
               width: 9, height: 9, modified: epoch)

        let store = WatchLibraryStore(container: container, storeMode: .cloudKit)
        store.refresh()
        let row = try #require(store.rows.first)
        #expect(store.moveCount(for: row) == 3)
        // A second read must return the same answer from the memo.
        #expect(store.moveCount(for: row) == 3)
    }

    @Test func moveCountRefreshesAfterARemoteEdit() throws {
        let container = try makeContainer()
        let record = insert(container, name: "Edited",
                            sgf: "(;GM[1]SZ[9];B[aa];W[bb];B[cc])",
                            width: 9, height: 9, modified: epoch)

        let store = WatchLibraryStore(container: container, storeMode: .cloudKit)
        store.refresh()
        let original = try #require(store.rows.first)
        #expect(store.moveCount(for: original) == 3)

        // Simulate the record changing on another device: same uuid, new
        // sgf, later lastModificationDate.
        record.sgf = "(;GM[1]SZ[9];B[aa];W[bb];B[cc];W[dd];B[ee])"
        record.lastModificationDate = epoch.addingTimeInterval(60)

        store.refresh()
        let edited = try #require(store.rows.first)
        #expect(edited.id == original.id)
        #expect(store.moveCount(for: edited) == 5)
    }

    @Test func unreadableSgfCountsAsZeroMoves() throws {
        let container = try makeContainer()
        insert(container, name: "Broken", sgf: "not an sgf at all",
               width: 19, height: 19, modified: epoch)

        let store = WatchLibraryStore(container: container, storeMode: .cloudKit)
        store.refresh()
        let row = try #require(store.rows.first)
        #expect(store.moveCount(for: row) == 0)
    }

    @Test func rowLookupByIDFindsTheGame() throws {
        let container = try makeContainer()
        insert(container, name: "Findable", sgf: "(;GM[1]SZ[19])", width: 19,
               height: 19, modified: epoch)

        let store = WatchLibraryStore(container: container, storeMode: .cloudKit)
        store.refresh()
        let row = try #require(store.rows.first)
        #expect(store.row(id: row.id)?.name == "Findable")
        #expect(store.row(id: "not-a-real-id") == nil)
    }

    @Test func emptyStateIsUnavailableOnADegradedStore() throws {
        let container = try makeContainer()
        let store = WatchLibraryStore(container: container, storeMode: .localOnly)
        store.refresh()
        #expect(store.emptyState(now: epoch) == .unavailable)
    }

    @Test func emptyStateIsSignedOutWithoutAnAccount() throws {
        let container = try makeContainer()
        let store = WatchLibraryStore(container: container, storeMode: .cloudKit)
        store.accountState = .unavailable
        store.refresh()
        #expect(store.emptyState(now: epoch) == .signedOut)
    }

    @Test func emptyStateStaysSyncingInsideTheLaunchGrace() throws {
        let container = try makeContainer()
        let store = WatchLibraryStore(container: container, storeMode: .cloudKit,
                                      openedAt: epoch)
        store.refresh()
        #expect(store.emptyState(now: epoch.addingTimeInterval(1)) == .syncing)
    }

    @Test func emptyStateSettlesToEmptyAfterTheGrace() throws {
        let container = try makeContainer()
        let store = WatchLibraryStore(container: container, storeMode: .cloudKit,
                                      openedAt: epoch)
        store.refresh()
        let after = epoch.addingTimeInterval(WatchLibraryStore.launchGrace + 1)
        #expect(store.emptyState(now: after) == .empty)
    }
}
