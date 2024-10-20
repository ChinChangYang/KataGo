//
//  KataGo_iOSApp.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2023/7/2.
//

import CoreData
import SwiftData
import SwiftUI

@main
struct KataGo_iOSApp: App {
    init() {
        #if false
            removeAllGameRecords()
        #endif

        #if false
            initializeCloutKitDevSchema(
                containerIdentifier: "iCloud.chinchangyang.KataGo-iOS.tw")
        #endif

        KataGoShortcuts.updateAppShortcutParameters()
    }

    var scene: some Scene {
        #if os(macOS)
            Window("KataGo Anytime", id: "KataGo Anytime") {
                ContentView()
            }
        #else
            WindowGroup {
                ContentView()
            }
        #endif
    }

    var body: some Scene {
        scene.modelContainer(for: GameRecord.self)
    }

    private func removeAllGameRecords() {
        try! autoreleasepool {
            let container = try ModelContainer(for: GameRecord.self)
            let context = container.mainContext
            try context.delete(model: GameRecord.self)
            try context.delete(model: Config.self)
        }
    }

    private func initializeCloutKitDevSchema(containerIdentifier: String) {
        let config = ModelConfiguration()

        // Use an autorelease pool to make sure Swift deallocates the persistent
        // container before setting up the SwiftData stack.
        try! autoreleasepool {
            let desc = NSPersistentStoreDescription(url: config.url)
            let opts = NSPersistentCloudKitContainerOptions(
                containerIdentifier: containerIdentifier)
            desc.cloudKitContainerOptions = opts
            // Load the store synchronously so it completes before initializing the
            // CloudKit schema.
            desc.shouldAddStoreAsynchronously = false
            if let mom = NSManagedObjectModel.makeManagedObjectModel(for: [
                GameRecord.self
            ]) {
                let container = NSPersistentCloudKitContainer(
                    name: "GameRecords", managedObjectModel: mom)
                container.persistentStoreDescriptions = [desc]
                container.loadPersistentStores { _, err in
                    if let err {
                        fatalError(err.localizedDescription)
                    }
                }
                // Initialize the CloudKit schema after the store finishes loading.
                try container.initializeCloudKitSchema()
                // Remove and unload the store from the persistent container.
                if let store = container.persistentStoreCoordinator
                    .persistentStores.first
                {
                    try container.persistentStoreCoordinator.remove(store)
                }
            }
        }
    }
}
