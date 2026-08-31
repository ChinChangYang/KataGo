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

        registerEngineLaunchStatusUpdater(status)

        // README screenshots: seed the shared position HERE, in init(), for
        // the reason the iOS app seeds here — `VisionRootView` resolves the
        // game to mount in its own boot task, which a sibling `.task` on the
        // App is not ordered against, so the record has to exist before any
        // view does. The capture script then deep-links to it by id. No-op
        // without `--screenshot-seed`, and outside DEBUG.
        if ScreenshotSeed.isActive {
            ScreenshotSeed.resetReadinessMarker()
            ScreenshotSeed.seed(into: SharedModelContainer.shared.mainContext)
        }
    }

    var body: some Scene {
        WindowGroup {
            VisionRootView()
                .environment(engineLaunchStatus)
                .task {
                    // Sweeps stale partials, reattaches to whatever the
                    // background daemon finished while we were gone, and
                    // resumes what was interrupted. Paused downloads are
                    // left alone by design. A no-op under
                    // `--uitest-disable-downloads`.
                    DownloadCenter.shared.restoreOnLaunch()
                }
        }
        .windowStyle(.volumetric)
        // 19x19 board footprint is ~0.46 x 0.50 m; leave headroom for stones
        // and floating analysis labels. Every defaultSize variant (meters,
        // Size3D, points) was ignored for the plist-preferred-role volumetric
        // scene (volume stayed at the 320 pt minimum, verified empirically),
        // so the volume is sized by its CONTENT: VisionRootView carries an
        // explicit 3D frame and the window adopts it via .contentSize.
        .windowResizability(.contentSize)
        .modelContainer(SharedModelContainer.shared)
        // The system relaunches the app when a background transfer needs
        // attention; this is where those events are drained. The app has
        // never had a UIApplicationDelegate and does not gain one for it.
        .backgroundTask(.urlSession(DownloadCenter.sessionIdentifier)) {
            await DownloadCenter.shared.awaitBackgroundURLSessionEvents()
        }
    }
}
