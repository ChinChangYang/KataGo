//
//  KataGo_iOSApp.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2023/7/2.
//

import SwiftData
import SwiftUI
import KataGoUICore

@main
struct KataGo_iOSApp: App {
    @State private var cacheReadiness: CoreMLCacheReadiness = CoreMLCacheReadiness()
    @State private var engineLaunchStatus: EngineLaunchStatus
    @State private var deepLinkRouter = DeepLinkRouter()

    init() {
        // Create the EngineLaunchStatus object first so we can capture a
        // direct reference to it in the updater closure — at init() time
        // the @State wrapper backing store isn't yet reachable via `self`.
        let status = EngineLaunchStatus()
        _engineLaunchStatus = State(initialValue: status)

        KataGoShortcuts.updateAppShortcutParameters()

        // Register the cache-aware CoreML bridge (Task 19) before any view
        // appears (and thus before any engine launch). This wires
        // loadCoreMLHandleWithBridgeTimeout into the KataGoSwift seam. It runs
        // here rather than inside KataGoUICore's KataGoHelper because the
        // loader imports the KataGoSwift Xcode framework, which a SwiftPM
        // package target cannot order against on a cold build.
        registerCoreMLBridge()

        // Wire the bridge's downloaded-hasher seam so downloaded models
        // can compute their `sourceIdentity` for cache-key construction.
        registerDownloadedHasher(BinFileHasher.shared.identityForDownloadedFile)

        // Wire the engine-launch status updater seam so LoadingView can
        // show a secondary caption during cache-miss compiles.
        registerEngineLaunchStatusUpdater { phase in
            await MainActor.run { status.phase = phase }
        }
    }

    @ViewBuilder
    private var modelRunnerRoot: some View {
        ModelRunnerView()
            .environment(cacheReadiness)
            .environment(engineLaunchStatus)
            .environment(deepLinkRouter)
            .onOpenURL { url in
                // Capture an `open-game` deep link at the always-mounted root so
                // it survives a cold launch — the model picker / loading screen
                // have no handler for it, and `GameSplitView`'s own `.onOpenURL`
                // is not mounted yet. `ContentView.initializationTask` (cold) and
                // `GameSplitView`'s `.onChange` (warm) apply the pending id. SGF
                // file-import URLs are ignored here and fall through to the
                // existing ModelPickerView / GameSplitView import handlers.
                if let id = GameDeepLink.gameID(from: url) {
                    deepLinkRouter.pendingGameID = id
                }
            }
            .task {
                await cacheReadiness.start()
            }
            .task {
                // Proactive identity hygiene (Issue 2): assign stable, unique,
                // non-nil uuids to CloudKit-synced records so the widget's
                // AppIntents round-trip can resolve a configured game by id. The
                // in-app game list uses a plain @Query and never repairs, so
                // without this nil/duplicate uuids stay unselectable in the widget.
                // Main-app only + idempotent (a clean store saves nothing).
                do {
                    try GameEntityQuery.repairStoredIdentities(container: SharedModelContainer.shared)
                } catch {
                    NSLog("repairStoredIdentities failed: \(error)")
                }
            }
    }

    // The macOS build of this (old, cross-platform SwiftUI) app target was
    // retired in Phase 6 — `KataGo Anytime` now builds for iOS/visionOS only,
    // and the native AppKit `KataGo Anytime Mac` target is the macOS product.
    // So this scene is no longer conditionalised on `os(macOS)`.
    var scene: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains(MLXTuneExperimentView.launchArg) {
                MLXTuneExperimentView()
            } else {
                modelRunnerRoot
            }
            #else
            modelRunnerRoot
            #endif
        }
    }

    var body: some Scene {
        scene.modelContainer(SharedModelContainer.shared)
    }
}
