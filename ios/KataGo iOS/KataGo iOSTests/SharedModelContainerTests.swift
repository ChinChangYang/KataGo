import Testing
import SwiftData
import Foundation
import CoreData
import KataGoUICore   // re-exports KataGoGameStore

struct SharedModelContainerTests {

    /// Writes one GameRecord into a SwiftData store at `url`.
    @MainActor
    private func seedStore(at url: URL, name: String) throws {
        let config = ModelConfiguration(url: url)
        let container = try ModelContainer(for: SharedModelContainer.schema, configurations: config)
        let record = GameRecord.createGameRecord(name: name)
        container.mainContext.insert(record)
        try container.mainContext.save()
    }

    @MainActor
    private func names(in url: URL) throws -> [String] {
        let config = ModelConfiguration(url: url)
        let container = try ModelContainer(for: SharedModelContainer.schema, configurations: config)
        return try container.mainContext.fetch(FetchDescriptor<GameRecord>()).map { $0.name }
    }

    @Test @MainActor func migrateStore_copiesExistingDataWhenDestinationMissing() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let oldURL = dir.appending(path: "old.store")
        let newURL = dir.appending(path: "new.store")
        try seedStore(at: oldURL, name: "Migrated Game")

        let didCopy = SharedModelContainer.migrateStore(from: oldURL, to: newURL)

        #expect(didCopy == true)
        #expect(try names(in: newURL).contains("Migrated Game"))
    }

    @Test @MainActor func migrateStore_createsIntermediateDirectories() throws {
        // SwiftData's group-container store lives at a NESTED path
        // (<group>/Library/Application Support/default.store). The migration must
        // create those intermediate directories, not fail because they're absent.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let oldURL = dir.appending(path: "old.store")
        let newURL = dir.appending(path: "Library/Application Support/default.store")
        try seedStore(at: oldURL, name: "Nested Game")

        let didCopy = SharedModelContainer.migrateStore(from: oldURL, to: newURL)

        #expect(didCopy == true)
        #expect(try names(in: newURL).contains("Nested Game"))
    }

    @Test func appGroupStoreURL_pointsIntoApplicationSupport() throws {
        // SwiftData places a `groupContainer:` store under
        // <group>/Library/Application Support/default.store — the migration target
        // must match, or migrated data lands where the live container never reads.
        let url = try #require(SharedModelContainer.appGroupStoreURL(),
                               "App Group not provisioned in this test host")
        #expect(Array(url.pathComponents.suffix(3)) == ["Library", "Application Support", "default.store"])
    }

    @Test @MainActor func migrateStore_noopWhenDestinationExists() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let oldURL = dir.appending(path: "old.store")
        let newURL = dir.appending(path: "new.store")
        try seedStore(at: oldURL, name: "Old")
        try seedStore(at: newURL, name: "Existing")

        let didCopy = SharedModelContainer.migrateStore(from: oldURL, to: newURL)

        #expect(didCopy == false)
        #expect(try names(in: newURL).contains("Existing"))
    }
}
