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

    // MARK: - storeDecision (F11 race fix — pure logic)

    typealias Decision = SharedModelContainer.StoreDecision

    @Test func storeDecision_app_oldExistsNewMissing_migrates() {
        #expect(SharedModelContainer.storeDecision(isApp: true, flagSet: false, oldExists: true, newExists: false) == .migrateThenOpenReal)
    }

    @Test func storeDecision_app_destinationExists_opensRealNoSecondMigration() {
        #expect(SharedModelContainer.storeDecision(isApp: true, flagSet: false, oldExists: true, newExists: true) == .openReal)
        #expect(SharedModelContainer.storeDecision(isApp: true, flagSet: true, oldExists: true, newExists: true) == .openReal)
    }

    @Test func storeDecision_app_freshInstall_opensReal() {
        // No old store, no new store: clean install — open (and create) the real store.
        #expect(SharedModelContainer.storeDecision(isApp: true, flagSet: false, oldExists: false, newExists: false) == .openReal)
        #expect(SharedModelContainer.storeDecision(isApp: true, flagSet: false, oldExists: false, newExists: true) == .openReal)
    }

    @Test func storeDecision_extension_flagSet_opensReal() {
        #expect(SharedModelContainer.storeDecision(isApp: false, flagSet: true, oldExists: false, newExists: true) == .openReal)
        #expect(SharedModelContainer.storeDecision(isApp: false, flagSet: true, oldExists: false, newExists: false) == .openReal)
    }

    @Test func storeDecision_extension_flagUnset_placeholderNeverMigrates() {
        // The extension must NEVER create/migrate the store before the app has run
        // post-update on this device — every old/new combination must yield the
        // in-memory placeholder, not a migrate/create.
        for old in [true, false] {
            for new in [true, false] {
                let d = SharedModelContainer.storeDecision(isApp: false, flagSet: false, oldExists: old, newExists: new)
                #expect(d == .openInMemoryPlaceholder)
                #expect(d != .migrateThenOpenReal)
            }
        }
    }

    // MARK: - postMigration (F11 — don't mark ready / orphan data on a failed migration)

    @Test func postMigration_copied_opensRealAndReady() {
        #expect(SharedModelContainer.postMigration(migrated: true, destinationExists: false) == .openReal)
    }

    @Test func postMigration_destinationAlreadyExists_opensReal() {
        // TOCTOU: migrate no-oped because the destination already exists — still ready.
        #expect(SharedModelContainer.postMigration(migrated: false, destinationExists: true) == .openReal)
        #expect(SharedModelContainer.postMigration(migrated: true, destinationExists: true) == .openReal)
    }

    @Test func postMigration_failedNoDestination_keepsOldStore() {
        // replacePersistentStore threw and nothing was produced — must NOT mark
        // ready or open an empty group store; keep the old store, retry next launch.
        #expect(SharedModelContainer.postMigration(migrated: false, destinationExists: false) == .openOldStore)
    }

    // MARK: - onOpenFailure (F12 fallback routing — pure logic)

    @Test func onOpenFailure_app_retriesThenLocalOnlyThenCrash() {
        #expect(SharedModelContainer.onOpenFailure(isApp: true) == .retryThenLocalOnlyThenCrash)
    }

    @Test func onOpenFailure_extension_inMemoryNeverCrashes() {
        #expect(SharedModelContainer.onOpenFailure(isApp: false) == .inMemoryPlaceholder)
    }

    // MARK: - App Group flags (injected UserDefaults)

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    }

    @Test func storeReadyFlag_defaultsFalse_thenSetsTrueIdempotently() {
        let d = freshDefaults()
        #expect(SharedModelContainer.isAppGroupStoreReady(d) == false)
        SharedModelContainer.setAppGroupStoreReady(d)
        #expect(SharedModelContainer.isAppGroupStoreReady(d) == true)
        SharedModelContainer.setAppGroupStoreReady(d)   // idempotent
        #expect(SharedModelContainer.isAppGroupStoreReady(d) == true)
    }

    @Test func syncDegradedFlag_defaultsFalse_roundTrips() {
        let d = freshDefaults()
        #expect(SharedModelContainer.isCloudKitSyncDegraded(d) == false)
        SharedModelContainer.setCloudKitSyncDegraded(true, d)
        #expect(SharedModelContainer.isCloudKitSyncDegraded(d) == true)
        SharedModelContainer.setCloudKitSyncDegraded(false, d)
        #expect(SharedModelContainer.isCloudKitSyncDegraded(d) == false)
    }

    // MARK: - openContainer retry policy (F12 — injected opener seam)

    @MainActor
    private func makeInMemoryContainer() throws -> ModelContainer {
        try ModelContainer(for: SharedModelContainer.schema,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    struct OpenError: Error {}

    @Test @MainActor func openContainer_succeedsFirstTry_callsOpenerOnce() throws {
        var calls = 0
        _ = try SharedModelContainer.openContainer(retries: 1) {
            calls += 1
            return try makeInMemoryContainer()
        }
        #expect(calls == 1)
    }

    @Test @MainActor func openContainer_throwsOnceThenSucceeds_retriesOnce() throws {
        var calls = 0
        _ = try SharedModelContainer.openContainer(retries: 1) {
            calls += 1
            if calls == 1 { throw OpenError() }
            return try makeInMemoryContainer()
        }
        #expect(calls == 2)
    }

    @Test @MainActor func openContainer_alwaysThrows_retries1_rethrowsAfterTwoAttempts() {
        var calls = 0
        #expect(throws: OpenError.self) {
            _ = try SharedModelContainer.openContainer(retries: 1) {
                calls += 1
                throw OpenError()
            }
        }
        #expect(calls == 2)
    }

    @Test @MainActor func openContainer_alwaysThrows_retries0_rethrowsAfterOneAttempt() {
        var calls = 0
        #expect(throws: OpenError.self) {
            _ = try SharedModelContainer.openContainer(retries: 0) {
                calls += 1
                throw OpenError()
            }
        }
        #expect(calls == 1)
    }

    // MARK: - In-memory fallback config (F11 widget placeholder / F12 widget)

    /// The widget's placeholder container must open WITHOUT touching CloudKit. A
    /// bare in-memory config defaults cloudKitDatabase to `.automatic`, which can
    /// throw; `inMemoryConfig()` sets `.none` so it opens cleanly and empty.
    @Test @MainActor func inMemoryConfig_opensWithoutThrowing_andIsEmpty() throws {
        let container = try ModelContainer(for: SharedModelContainer.schema,
                                           configurations: SharedModelContainer.inMemoryConfig())
        let records = try container.mainContext.fetch(FetchDescriptor<GameRecord>())
        #expect(records.isEmpty)
    }

    // MARK: - CloudKit store-reset directories (F16)

    @Test func storeResetDirectories_includeAppGroupStoreLocation() throws {
        // F16 regression: after migration the LIVE store is in the App-Group
        // container; re-sync must wipe THAT location, not only the app's own
        // sandbox container (the old reset deleted a stale leftover and no-oped).
        let groupParent = try #require(SharedModelContainer.appGroupStoreURL(),
                                       "App Group not provisioned in this test host")
            .deletingLastPathComponent()
        let paths = SharedModelContainer.storeResetDirectories().map { $0.path }
        #expect(paths.contains(groupParent.path))
    }

    @Test func storeResetDirectories_includeMigrationSourceLocation() {
        // The pre-App-Group / migration-source store in the app's own container
        // must ALSO be removed, or `shared` re-migrates it back next launch and
        // defeats the re-import (migrateStore copies, it doesn't move).
        let defaultParent = SharedModelContainer.defaultStoreURL().deletingLastPathComponent()
        let paths = SharedModelContainer.storeResetDirectories().map { $0.path }
        #expect(paths.contains(defaultParent.path))
    }

    @Test func storeResetDirectories_groupAndAppContainerAreDistinct() throws {
        // Sanity: the two reset locations are genuinely different directories, so
        // covering both is meaningful (not the same path twice).
        let groupParent = try #require(SharedModelContainer.appGroupStoreURL())
            .deletingLastPathComponent()
        let defaultParent = SharedModelContainer.defaultStoreURL().deletingLastPathComponent()
        #expect(groupParent.path != defaultParent.path)
    }

    // MARK: - CloudKit store-artifact filter (F16)

    @Test func storeArtifactNames_matchesSqliteFamilyAndSidecars() {
        let entries = ["default.store", "default.store-wal", "default.store-shm",
                       "default.store-journal", ".default_SUPPORT", "default_ckAssets"]
        #expect(Set(SharedModelContainer.storeArtifactNames(in: entries)) == Set(entries))
    }

    @Test func storeArtifactNames_leavesEngineAndModelDataUntouched() {
        // The reset deletes store files only; engine/model/unrelated data stays.
        let entries = ["default.store", "default_model.bin.gz", "b18c384nbt-humanv0.bin.gz",
                       "KataGoData", "prefs.plist", "other.store"]
        #expect(SharedModelContainer.storeArtifactNames(in: entries) == ["default.store"])
    }
}
