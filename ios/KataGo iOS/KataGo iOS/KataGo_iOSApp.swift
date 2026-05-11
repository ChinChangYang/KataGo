//
//  KataGo_iOSApp.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2023/7/2.
//

import CoreData
import SwiftData
import SwiftUI
import KataGoInterface

@main
struct KataGo_iOSApp: App {
    @State private var precompileScheduler = PrecompileScheduler { fileName in
        try await runPrecompileWorker(fileName: fileName)
    }
    @State private var engineLaunchStatus: EngineLaunchStatus

    init() {
        // Create the EngineLaunchStatus object first so we can capture a
        // direct reference to it in the updater closure — at init() time
        // the @State wrapper backing store isn't yet reachable via `self`.
        let status = EngineLaunchStatus()
        _engineLaunchStatus = State(initialValue: status)

        #if false
            removeAllGameRecords()
        #endif

        #if false
            initializeCloutKitDevSchema(
                containerIdentifier: "iCloud.chinchangyang.KataGo-iOS.tw")
        #endif

        KataGoShortcuts.updateAppShortcutParameters()

        // Wire the bridge's downloaded-hasher seam (Task 23) to the
        // BinFileHasher in the main app target so downloaded models can
        // compute their `sourceIdentity` for cache-key construction.
        registerDownloadedHasher(BinFileHasher.shared.identityForDownloadedFile)

        // Wire the engine-launch status updater seam (Task 25) so that
        // LoadingView can show a secondary caption during cache-miss compiles.
        registerEngineLaunchStatusUpdater { phase in
            await MainActor.run { status.phase = phase }
        }
    }

    var scene: some Scene {
        #if os(macOS)
            Window("KataGo Anytime", id: "KataGo Anytime") {
                ModelRunnerView()
                    .environment(precompileScheduler)
                    .environment(engineLaunchStatus)
            }
        #else
            WindowGroup {
                ModelRunnerView()
                    .environment(precompileScheduler)
                    .environment(engineLaunchStatus)
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

// MARK: - PrecompileScheduler worker (Tasks 20/21)

/// Placeholder worker for `PrecompileScheduler`. Sleeps briefly so that
/// badge UI transitions through .queued → .compiling → .ready are
/// observable. The full bridge call (Task 19) needs channel counts that
/// come from the C++ LoadedModel descriptor and will be wired in a
/// follow-up task.
@MainActor
private func runPrecompileWorker(fileName: String) async throws {
    try await Task.sleep(for: .seconds(1))
}
