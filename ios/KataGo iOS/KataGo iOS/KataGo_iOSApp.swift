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

/// File names auto-warmed at app launch when their cache entry is
/// missing. Built-in + bundled human SL aux only — downloaded mains
/// are handled by `ModelPickerView.downloader.onDownloadComplete`.
private let autoWarmFileNames: [String] = [
    "default_model.bin.gz",
    "b18c384nbt-humanv0.bin.gz"
]

/// Cache-empty sweep. For each auto-warm target whose status is not
/// `.ready`, `.queued`, or `.compiling`, enqueue a precompile. Runs
/// after `scheduler.hydrate(...)` in the app's scene `.task`. The
/// gating switch skips in-flight targets at the helper boundary;
/// `scheduleForModel`'s `inFlight` set is a defense-in-depth backstop.
/// On scene reactivation a target's status may be `.idle` again, in
/// which case the call lands but is deduped by `inFlight`. The
/// bundle-version rewarm in `ModelRunnerView.onAppear` cooperates via
/// the same dedup path.
@MainActor
func runCacheEmptySweep(scheduler: PrecompileScheduler) async {
    for fileName in autoWarmFileNames {
        switch scheduler.status[fileName] {
        case .ready, .queued, .compiling:
            break
        default:
            await scheduler.scheduleForModel(fileName: fileName)
        }
    }
}

@main
struct KataGo_iOSApp: App {
    @State private var precompileScheduler: PrecompileScheduler = PrecompileScheduler(
        worker: { fileName in
            try await runPrecompileWorker(fileName: fileName)
        },
        cache: .shared,
        digestFor: makeProjectionDigestFor())
    @State private var cacheReadiness: CoreMLCacheReadiness = CoreMLCacheReadiness()
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
                    .environment(cacheReadiness)
                    .environment(engineLaunchStatus)
                    .task {
                        let knownFileNames = Set(NeuralNetworkModel.allCases.map(\.fileName))
                            .union(autoWarmFileNames)
                        let digestFor = makeProjectionDigestFor()
                        await CoreMLModelCache.shared.start()
                        await cacheReadiness.start()
                        await cacheReadiness.update(
                            forFileNames: Array(knownFileNames))
                        await precompileScheduler.hydrate(
                            from: .shared,
                            fileNames: knownFileNames,
                            digestFor: digestFor)
                        await precompileScheduler.subscribeToCacheEvents(
                            .shared,
                            fileNames: knownFileNames,
                            digestFor: digestFor)
                        await runCacheEmptySweep(scheduler: precompileScheduler)
                    }
            }
        #else
            WindowGroup {
                ModelRunnerView()
                    .environment(precompileScheduler)
                    .environment(cacheReadiness)
                    .environment(engineLaunchStatus)
                    .task {
                        let knownFileNames = Set(NeuralNetworkModel.allCases.map(\.fileName))
                            .union(autoWarmFileNames)
                        let digestFor = makeProjectionDigestFor()
                        await CoreMLModelCache.shared.start()
                        await cacheReadiness.start()
                        await cacheReadiness.update(
                            forFileNames: Array(knownFileNames))
                        await precompileScheduler.hydrate(
                            from: .shared,
                            fileNames: knownFileNames,
                            digestFor: digestFor)
                        await precompileScheduler.subscribeToCacheEvents(
                            .shared,
                            fileNames: knownFileNames,
                            digestFor: digestFor)
                        await runCacheEmptySweep(scheduler: precompileScheduler)
                    }
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

// MARK: - PrecompileScheduler worker

/// Sentinel server-thread index for precompile conversions. The C++
/// converter uses `serverThreadIdx` only in temp-path naming and log
/// messages; passing -1 distinguishes precompile work from any real
/// engine thread (0..N-1) and avoids temp-path collisions when an
/// engine launch and a precompile happen to convert simultaneously.
private let kPrecompileServerThreadIdx: Int32 = -1

/// Real precompile worker. Resolves projection inputs from the named
/// model's persisted BackendSettings, then asks CoreMLModelCache.warm
/// to compute the digest and either hit the cache or invoke the same
/// converter the engine launch uses.
@MainActor
private func runPrecompileWorker(fileName: String) async throws {
    guard let inputs = makeProjectionResolver()(fileName) else { return }
    // Ensure the on-disk index is loaded into memory; without this, a
    // precompile fired before the first engine launch sees an empty
    // `entries` map and always recompiles. `start()` is idempotent.
    await CoreMLModelCache.shared.start()
    try await CoreMLModelCache.shared.warm(
        forSourcePath: inputs.sourcePath,
        nnXLen: inputs.nnXLen, nnYLen: inputs.nnYLen,
        requireExactNNLen: inputs.requireExactNNLen,
        useFP16: inputs.useFP16,
        maxBatchSize: inputs.maxBatchSize,
        sourceFileName: fileName,
        downloadedHasher: BinFileHasher.shared.identityForDownloadedFile,
        missCallback: {
            return try await convertOnCooperativePool(
                coremlModelPath: inputs.sourcePath,
                boardX: inputs.nnXLen, boardY: inputs.nnYLen,
                useFP16: inputs.useFP16,
                optimizeMask: inputs.requireExactNNLen,
                maxBatchSize: Int32(inputs.maxBatchSize),
                serverThreadIdx: kPrecompileServerThreadIdx)
        })
}
