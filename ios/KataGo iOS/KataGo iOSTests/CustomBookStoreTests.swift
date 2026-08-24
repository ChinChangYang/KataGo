//
//  CustomBookStoreTests.swift
//  KataGo AnytimeTests
//
//  Pins the persistence, naming, and selection rules for user-imported opening
//  books. Pure defaults-injected — no file system, no process-global overrides
//  — so this suite is parallel-safe. Everything that touches
//  `CustomBookStore._directoryOverride`/`_defaultsOverride` or the resolver's
//  file checks lives in the serialized `OpeningBookTests` suite instead.
//

import Foundation
import Testing
@testable import KataGoUICore

struct CustomBookStoreTests {

    /// A throwaway defaults suite so tests never touch the app's real
    /// UserDefaults (which also carry the simulator host's state).
    private func makeStore(_ name: String = #function) -> (CustomBookStore, UserDefaults) {
        let suiteName = "CustomBookStoreTests.\(name)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (CustomBookStore(defaults: defaults), defaults)
    }

    private func makeRecord(_ name: String,
                            id: UUID = UUID(),
                            boardSize: Int = 9,
                            size: Int = 1_000) -> CustomBookRecord {
        CustomBookRecord(id: id,
                         displayName: name,
                         fileName: CustomBookStore.makeFileName(id: id, isGzipped: true),
                         fileSize: size,
                         boardSize: boardSize)
    }

    // MARK: - Records

    @Test func emptyDefaultsHoldNoRecords() {
        let (store, _) = makeStore()
        #expect(store.records.isEmpty)
    }

    @Test func recordsRoundTripThroughDefaults() {
        let (store, _) = makeStore()
        let record = makeRecord("My Book", boardSize: 13, size: 4_321)
        store.add(record)

        let reread = store.records
        #expect(reread.count == 1)
        #expect(reread.first?.id == record.id)
        #expect(reread.first?.displayName == "My Book")
        #expect(reread.first?.boardSize == 13)
        #expect(reread.first?.fileSize == 4_321)
    }

    @Test func removeRecordDropsOnlyThatRecord() {
        let (store, _) = makeStore()
        let a = makeRecord("A")
        let b = makeRecord("B")
        store.add(a)
        store.add(b)
        store.removeRecord(id: a.id)
        #expect(store.records.map(\.id) == [b.id])
    }

    @Test func recordsForBoardSizeFilters() {
        let (store, _) = makeStore()
        store.add(makeRecord("Nine", boardSize: 9))
        store.add(makeRecord("Thirteen", boardSize: 13))
        store.add(makeRecord("Nine Two", boardSize: 9))
        #expect(store.records(forBoardSize: 9).count == 2)
        #expect(store.records(forBoardSize: 13).count == 1)
        #expect(store.records(forBoardSize: 6).isEmpty)
    }

    // MARK: - File naming

    @Test func makeFileNameIsUniquePerIdAndSniffsExtension() {
        let id = UUID()
        let gz = CustomBookStore.makeFileName(id: id, isGzipped: true)
        let plain = CustomBookStore.makeFileName(id: id, isGzipped: false)
        #expect(gz == "custom-\(id.uuidString.lowercased()).kbook.gz")
        #expect(plain == "custom-\(id.uuidString.lowercased()).kbook")
        #expect(CustomBookStore.makeFileName(id: UUID(), isGzipped: true) != gz)
    }

    @Test func identityIsLowercasedUUID() {
        let id = UUID()
        let record = makeRecord("X", id: id)
        #expect(record.identity == id.uuidString.lowercased())
    }

    @Test func decompressedCacheURLStripsOnlyLastExtension() {
        let record = makeRecord("X")
        // custom-<uuid>.kbook.gz -> cached "custom-<uuid>.kbook"
        #expect(record.decompressedCacheURL.lastPathComponent.hasSuffix(".kbook"))
        #expect(record.decompressedCacheURL.lastPathComponent.hasSuffix(".gz") == false)
    }

    // MARK: - Naming

    @Test func uniqueDisplayNameAvoidsCatalogTitles() {
        let (store, _) = makeStore()
        let catalogTitle = OpeningBook.allCases[0].title
        #expect(store.uniqueDisplayName(catalogTitle) == "\(catalogTitle) (2)")
    }

    @Test func uniqueDisplayNameAvoidsOtherRecords() {
        let (store, _) = makeStore()
        store.add(makeRecord("My Book"))
        #expect(store.uniqueDisplayName("My Book") == "My Book (2)")
        store.add(makeRecord("My Book (2)"))
        #expect(store.uniqueDisplayName("My Book") == "My Book (3)")
    }

    @Test func uniqueDisplayNameFallsBackWhenEmpty() {
        let (store, _) = makeStore()
        #expect(store.uniqueDisplayName("   ") == "Custom Opening Book")
    }

    // MARK: - Active-book selection

    @Test func activeBookSelectionRoundTrips() {
        let (store, _) = makeStore()
        #expect(store.activeBookIdentity(forBoardSize: 9) == nil)
        store.setActiveBookIdentity("some-identity", forBoardSize: 9)
        #expect(store.activeBookIdentity(forBoardSize: 9) == "some-identity")
        // Other sizes are untouched.
        #expect(store.activeBookIdentity(forBoardSize: 7) == nil)
        store.setActiveBookIdentity(nil, forBoardSize: 9)
        #expect(store.activeBookIdentity(forBoardSize: 9) == nil)
    }

    @Test func clearSelectionsSweepsOnlyMatchingIdentity() {
        let (store, _) = makeStore()
        store.setActiveBookIdentity("doomed", forBoardSize: 7)
        store.setActiveBookIdentity("doomed", forBoardSize: 9)
        store.setActiveBookIdentity("kept", forBoardSize: 13)
        store.clearSelections(pointingTo: "doomed")
        #expect(store.activeBookIdentity(forBoardSize: 7) == nil)
        #expect(store.activeBookIdentity(forBoardSize: 9) == nil)
        #expect(store.activeBookIdentity(forBoardSize: 13) == "kept")
    }
}
