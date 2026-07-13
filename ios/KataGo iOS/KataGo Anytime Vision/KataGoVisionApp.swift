//
//  KataGoVisionApp.swift
//  KataGo Anytime Vision
//
//  visionOS app: a volumetric window hosting a real-scale 3D goban with
//  game-controller move input. The in-process engine runs CoreML/ANE-only
//  (the GPU belongs to the 90 Hz compositor).
//

import SwiftUI
import KataGoUICore

@main
struct KataGoVisionApp: App {
    @State private var engineLaunchStatus: EngineLaunchStatus

    init() {
        // Create the EngineLaunchStatus object first so we can capture a
        // direct reference to it in the updater closure — at init() time
        // the @State wrapper backing store isn't yet reachable via `self`
        // (mirrors KataGo_iOSApp / KataGoTVApp).
        let status = EngineLaunchStatus()
        _engineLaunchStatus = State(initialValue: status)

        // Wire the cache-aware CoreML bridge into the KataGoSwift seam before
        // any engine launch, and force the engine stack to link.
        registerCoreMLBridge()

        registerEngineLaunchStatusUpdater { phase in
            await MainActor.run { status.phase = phase }
        }
    }

    var body: some Scene {
        WindowGroup {
            VisionRootView()
                .environment(engineLaunchStatus)
        }
        .windowStyle(.volumetric)
        // 19x19 board footprint is ~0.46 x 0.50 m; leave headroom for stones
        // and floating analysis labels.
        .defaultSize(width: 0.8, height: 0.6, depth: 0.8, in: .meters)
        .modelContainer(SharedModelContainer.shared)
    }
}
