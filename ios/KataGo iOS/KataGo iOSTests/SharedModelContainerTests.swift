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
