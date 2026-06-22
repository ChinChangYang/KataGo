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
    public static let shared: ModelContainer = {
        // Best-effort one-time migration of a pre-App-Group store.
        if let appGroupURL = appGroupStoreURL() {
            _ = migrateStore(from: defaultStoreURL(), to: appGroupURL)
        }
        let config = ModelConfiguration(
            schema: schema,
            groupContainer: .identifier(appGroupID),
            cloudKitDatabase: .private(cloudKitContainerID)
        )
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("SharedModelContainer: failed to open store: \(error)")
        }
    }()

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
    static func defaultStoreURL() -> URL {
        URL.applicationSupportDirectory.appending(path: "default.store")
    }

    /// Where SwiftData places the store given `groupContainer: .identifier`.
    static func appGroupStoreURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appending(path: "default.store")
    }
}
