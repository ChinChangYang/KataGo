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
            .task {
                await cacheReadiness.start()
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
