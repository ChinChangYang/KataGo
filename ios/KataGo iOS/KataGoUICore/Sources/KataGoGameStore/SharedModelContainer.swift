import SwiftData
import Foundation
import CoreData

/// Single source of truth for the app↔widget SwiftData store. The store lives
/// in the shared App Group container so the widget extension (a separate
/// process) can read it; CloudKit keeps it in sync across devices.
public enum SharedModelContainer {
    public static let appGroupID = "group.chinchangyang.KataGo-iOS.tw"
    public static let cloudKitContainerID = "iCloud.chinchangyang.KataGo-iOS.tw"

    public static var schema: Schema { Schema([GameRecord.self, Config.self]) }

    /// The container every app process (app, AppIntents, widget) uses.
    ///
    /// Process-aware to fix F11/F12: only the app migrates/creates the on-disk
    /// store; the widget renders an in-memory placeholder until the app has
    /// produced it (so the widget can't pre-create an empty App-Group store and
    /// strand the app's pre-App-Group library). On open failure the app degrades
    /// to a local-only store (keeps all data, sync paused) instead of crashing.
    public static let shared: ModelContainer = {
        let isApp = !ProcessKind.isAppExtension
        let fm = FileManager.default

        // Without an App-Group destination we can't migrate; go straight to the
        // open ladder (app degrades/crashes visibly, extension placeholders).
        guard let newURL = appGroupStoreURL() else {
            return openRealOrFallback(isApp: isApp)
        }

        switch storeDecision(isApp: isApp,
                             flagSet: isAppGroupStoreReady(),
                             oldExists: fm.fileExists(atPath: defaultStoreURL().path),
                             newExists: fm.fileExists(atPath: newURL.path)) {
        case .openInMemoryPlaceholder:
            return makeInMemoryContainer()
        case .migrateThenOpenReal:
            // Migrate the pre-App-Group store, then mark ready ONLY if the
            // destination actually exists afterward. If the copy threw, keep the
            // old store in place (full data, sync intact) and leave the flag
            // false so migration retries next launch — never flip the flag or
            // create an empty group store that would orphan the library (F11).
            let migrated = migrateStore(from: defaultStoreURL(), to: newURL)
            switch postMigration(migrated: migrated,
                                 destinationExists: fm.fileExists(atPath: newURL.path)) {
            case .openReal:
                setAppGroupStoreReady()
                return openRealOrFallback(isApp: isApp)
            case .openOldStore:
                return openOldStoreOrFallback(isApp: isApp)
            }
        case .openReal:
            if isApp { setAppGroupStoreReady() }
            return openRealOrFallback(isApp: isApp)
        }
    }()

    // MARK: - ModelConfiguration builders

    /// Normal config: App-Group store mirrored to the private CloudKit database.
    static func cloudKitConfig() -> ModelConfiguration {
        ModelConfiguration(schema: schema,
                           groupContainer: .identifier(appGroupID),
                           cloudKitDatabase: .private(cloudKitContainerID))
    }

    /// Same on-disk App-Group store but WITHOUT CloudKit — the F12 degraded
    /// fallback that keeps all local data while sync is unavailable.
    static func localOnlyConfig() -> ModelConfiguration {
        ModelConfiguration(schema: schema,
                           groupContainer: .identifier(appGroupID),
                           cloudKitDatabase: .none)
    }

    /// Ephemeral store with CloudKit EXPLICITLY disabled (a bare in-memory config
    /// defaults `cloudKitDatabase` to `.automatic`, which can itself throw and
    /// defeat the fallback). Used by the widget for a placeholder without creating
    /// the on-disk store.
    public static func inMemoryConfig() -> ModelConfiguration {
        ModelConfiguration(schema: schema,
                           isStoredInMemoryOnly: true,
                           cloudKitDatabase: .none)
    }

    /// The pre-App-Group store at its original default location, mirrored to the
    /// same private CloudKit database it always used. Opened only when migration
    /// into the App-Group container failed, so the user keeps their full library
    /// while migration retries on a later launch.
    static func oldStoreCloudKitConfig() -> ModelConfiguration {
        ModelConfiguration(schema: schema,
                           url: defaultStoreURL(),
                           cloudKitDatabase: .private(cloudKitContainerID))
    }

    /// The pre-App-Group store at its original location, without CloudKit (the
    /// degraded fallback for the old-store path).
    static func oldStoreLocalOnlyConfig() -> ModelConfiguration {
        ModelConfiguration(schema: schema,
                           url: defaultStoreURL(),
                           cloudKitDatabase: .none)
    }

    /// Opens the real (App-Group) CloudKit store with the F12 fallback ladder.
    private static func openRealOrFallback(isApp: Bool) -> ModelContainer {
        openOrFallback(isApp: isApp, cloudKit: cloudKitConfig, localOnly: localOnlyConfig)
    }

    /// Opens the pre-App-Group store in place (migration-failure path) with the
    /// same fallback ladder. The readiness flag is intentionally left unset so
    /// migration retries next launch.
    private static func openOldStoreOrFallback(isApp: Bool) -> ModelContainer {
        openOrFallback(isApp: isApp, cloudKit: oldStoreCloudKitConfig, localOnly: oldStoreLocalOnlyConfig)
    }

    /// Opens `cloudKit()`, applying the F12 fallback ladder on failure: app
    /// retries once, then degrades to `localOnly()` (same file, keep data), then
    /// crashes; an extension never crashes and falls back to an in-memory
    /// placeholder.
    private static func openOrFallback(isApp: Bool,
                                       cloudKit: () -> ModelConfiguration,
                                       localOnly: () -> ModelConfiguration) -> ModelContainer {
        do {
            let container = try openContainer(retries: isApp ? 1 : 0) {
                try ModelContainer(for: schema, configurations: cloudKit())
            }
            if isApp { setCloudKitSyncDegraded(false) }   // CloudKit healthy — clear stale banner
            return container
        } catch {
            switch onOpenFailure(isApp: isApp) {
            case .retryThenLocalOnlyThenCrash:
                // Keep ALL on-disk data; degrade sync rather than crash or lose data.
                setCloudKitSyncDegraded(true)
                do {
                    return try ModelContainer(for: schema, configurations: localOnly())
                } catch {
                    // Even the local store won't open — genuine corruption. A
                    // visible crash beats silently losing the library.
                    fatalError("SharedModelContainer: failed to open store: \(error)")
                }
            case .inMemoryPlaceholder:
                // Extension must never crash; show a placeholder instead.
                return makeInMemoryContainer()
            }
        }
    }

    /// In-memory placeholder container. An in-memory open of a valid schema is
    /// effectively infallible; if it somehow fails the process can't function, so
    /// a clear crash is acceptable as the absolute last resort.
    private static func makeInMemoryContainer() -> ModelContainer {
        do {
            return try ModelContainer(for: schema, configurations: inMemoryConfig())
        } catch {
            fatalError("SharedModelContainer: in-memory fallback failed: \(error)")
        }
    }

    // MARK: - Store-open decision (F11/F12)

    /// What `shared` should do given the current process + on-disk state.
    public enum StoreDecision: Equatable {
        /// App, has a pre-App-Group store to bring forward, destination absent.
        case migrateThenOpenReal
        /// App (fresh install or already-migrated), or an extension after the app
        /// has produced the store on this device: open the real on-disk store.
        case openReal
        /// Extension before the app has run post-update on this device: render a
        /// placeholder from an in-memory store WITHOUT creating the on-disk store
        /// (which would strand the app's pre-App-Group data — F11).
        case openInMemoryPlaceholder
    }

    /// Pure decision logic (no I/O) so the F11 race fix is unit-testable.
    /// Only the app may migrate/create the store; an extension never does.
    public static func storeDecision(isApp: Bool, flagSet: Bool, oldExists: Bool, newExists: Bool) -> StoreDecision {
        if isApp {
            // Only the app migrates/creates the store. Bring a pre-App-Group
            // store forward iff it exists and the destination doesn't; otherwise
            // open (and, on a fresh install, create) the real store.
            return (oldExists && !newExists) ? .migrateThenOpenReal : .openReal
        }
        // Extension: open the real store only once the app has produced it on this
        // device (flag set). Before that, never touch disk — render a placeholder
        // from an in-memory store so an empty App-Group store can't be created and
        // strand the app's pre-App-Group data (F11).
        return flagSet ? .openReal : .openInMemoryPlaceholder
    }

    /// After attempting migration, what `shared` should open. Guards against a
    /// failed migration (replacePersistentStore threw) marking the store ready
    /// and opening an empty App-Group store, which would orphan the pre-App-Group
    /// library AND poison the retry (a created destination flips the next launch
    /// to `.openReal`). On genuine failure we keep the OLD store in place so no
    /// data is orphaned and migration retries on the next launch.
    public enum PostMigration: Equatable {
        case openReal       // destination produced (copied now, or already present)
        case openOldStore   // migration failed, destination absent — keep old store
    }

    /// Pure: ready iff the destination store actually exists after the attempt.
    public static func postMigration(migrated: Bool, destinationExists: Bool) -> PostMigration {
        (migrated || destinationExists) ? .openReal : .openOldStore
    }

    /// How to recover when opening the real store throws (F12).
    public enum OpenFallback: Equatable {
        /// App: retry once, then local-only (keep data, degrade sync), then crash.
        case retryThenLocalOnlyThenCrash
        /// Extension: never crash; fall back to an in-memory placeholder.
        case inMemoryPlaceholder
    }

    public static func onOpenFailure(isApp: Bool) -> OpenFallback {
        isApp ? .retryThenLocalOnlyThenCrash : .inMemoryPlaceholder
    }

    // MARK: - App Group flags (local per-device, NOT CloudKit-synced)

    /// Set true by the app once it has produced the real store on this device;
    /// read by the widget to decide real-store vs in-memory placeholder (F11).
    public static let storeReadyKey = "appGroupStoreReady"
    /// Set true by the app when it had to fall back to a local-only (no-CloudKit)
    /// store; a UI banner can read it to show "iCloud sync unavailable" (F12).
    public static let syncDegradedKey = "cloudKitSyncDegraded"

    static func appGroupDefaults() -> UserDefaults? { UserDefaults(suiteName: appGroupID) }

    public static func isAppGroupStoreReady(_ defaults: UserDefaults? = nil) -> Bool {
        (defaults ?? appGroupDefaults())?.bool(forKey: storeReadyKey) ?? false
    }

    public static func setAppGroupStoreReady(_ defaults: UserDefaults? = nil) {
        (defaults ?? appGroupDefaults())?.set(true, forKey: storeReadyKey)
    }

    public static func isCloudKitSyncDegraded(_ defaults: UserDefaults? = nil) -> Bool {
        (defaults ?? appGroupDefaults())?.bool(forKey: syncDegradedKey) ?? false
    }

    public static func setCloudKitSyncDegraded(_ value: Bool, _ defaults: UserDefaults? = nil) {
        (defaults ?? appGroupDefaults())?.set(value, forKey: syncDegradedKey)
    }

    // MARK: - Container opening with retry (F12)

    /// Opens a container via `opener`, retrying up to `retries` extra times on
    /// throw; rethrows if all attempts fail. `opener` is injectable for tests.
    public static func openContainer(retries: Int, opener: () throws -> ModelContainer) throws -> ModelContainer {
        var attempt = 0
        while true {
            do {
                return try opener()
            } catch {
                if attempt >= retries { throw error }
                attempt += 1
            }
        }
    }

    /// Copies a SwiftData/SQLite store (plus -wal/-shm) from `oldURL` to
    /// `newURL` iff `oldURL` exists and `newURL` does not. SwiftData does NOT
    /// auto-migrate a default-location store into an App Group container.
    @discardableResult
    public static func migrateStore(from oldURL: URL, to newURL: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: oldURL.path),
              !fm.fileExists(atPath: newURL.path) else { return false }
        guard let mom = NSManagedObjectModel.makeManagedObjectModel(for: [GameRecord.self, Config.self]) else {
            return false
        }
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: mom)
        do {
            // The destination (e.g. <group>/Library/Application Support/) may not
            // exist yet — the App-Group container is created lazily — so create the
            // intermediate directories before copying, or replacePersistentStore
            // fails with "parent directory path reported as missing".
            try fm.createDirectory(at: newURL.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try coordinator.replacePersistentStore(
                at: newURL,
                destinationOptions: nil,
                withPersistentStoreFrom: oldURL,
                sourceOptions: nil,
                type: .sqlite
            )
            return true
        } catch {
            NSLog("SharedModelContainer.migrateStore failed: \(error)")
            return false
        }
    }

    /// Where SwiftData's default (pre-App-Group) store lived.
    public static func defaultStoreURL() -> URL {
        URL.applicationSupportDirectory.appending(path: "default.store")
    }

    /// Where SwiftData places the store given `groupContainer: .identifier`:
    /// `<group>/Library/Application Support/default.store` (NOT the group root).
    /// The migration destination must match this exactly, or migrated data lands
    /// where the live container never reads it.
    public static func appGroupStoreURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appending(path: "Library/Application Support/default.store")
    }

    // MARK: - CloudKit store reset (F16)

    /// Store-layout knowledge for the macOS "Re-sync from iCloud" command. It
    /// lives here — not in the app target — so the set of directories and files
    /// that constitute the on-disk store has ONE owner alongside the store URLs,
    /// and so the pure logic is unit-testable from the iOS test target (the
    /// macOS app target has no test target).

    /// Non-`default.store*` sidecars SwiftData/CloudKit leaves beside the SQLite
    /// files (Core Data external-storage support + the CloudKit asset cache).
    public static let storeResetSidecars: Set<String> = [".default_SUPPORT", "default_ckAssets"]

    /// Every Application Support directory that may hold a copy of the SwiftData
    /// store, so a CloudKit re-import wipes ALL of them:
    ///
    /// 1. the **App-Group** container (`appGroupStoreURL()`'s parent) — where the
    ///    live store lives after migration; the old reset code never touched this,
    ///    so re-sync silently no-oped (F16); and
    /// 2. the app's **own sandbox** container (`defaultStoreURL()`'s parent) — the
    ///    pre-App-Group / migration-source copy, which `migrateStore` leaves in
    ///    place (it copies, not moves). It must ALSO go, or `shared` sees
    ///    `oldExists && !newExists` next launch and re-migrates the stale store
    ///    back, defeating the re-import.
    ///
    /// Directories may or may not exist; callers tolerate absence.
    public static func storeResetDirectories() -> [URL] {
        var dirs: [URL] = []
        // 1. App-Group container — the live store post-migration (the F16 fix).
        if let groupParent = appGroupStoreURL()?.deletingLastPathComponent() {
            dirs.append(groupParent)
        }
        // 2. App's own container — the pre-App-Group / migration-source copy.
        dirs.append(defaultStoreURL().deletingLastPathComponent())
        return dirs
    }

    /// Pure: the store-artifact file names within a directory listing — the whole
    /// SQLite family (`default.store`, `-wal`, `-shm`, `-journal`, …) matched by
    /// prefix, plus the named sidecars. Everything else (engine/model data,
    /// unrelated files) is left untouched.
    public static func storeArtifactNames(in entries: [String]) -> [String] {
        entries.filter { $0.hasPrefix("default.store") || storeResetSidecars.contains($0) }
    }
}
