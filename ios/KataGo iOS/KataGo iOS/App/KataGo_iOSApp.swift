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
    // The process-wide shared router (not a private instance) so the Shortcuts
    // "Open …" App Intents can write `pendingGameID` in-process — the system
    // refuses to open the custom katago-anytime scheme on their behalf.
    @State private var deepLinkRouter = DeepLinkRouter.shared
    // App-level so a Listening Session outlives any one screen: audio keeps
    // playing when the sheet is dismissed or the selection changes.
    @State private var listeningController = ListeningSessionController()

    init() {
        // Create the EngineLaunchStatus object first so we can capture a
        // direct reference to it in the updater closure — at init() time
        // the @State wrapper backing store isn't yet reachable via `self`.
        let status = EngineLaunchStatus()
        _engineLaunchStatus = State(initialValue: status)

        KataGoShortcuts.updateAppShortcutParameters()

        // Carry the retired `isLargeThumbnail` bool onto the app-wide
        // `GlobalSettings.thumbnailSize` index. HERE, in init(), and not in a
        // `.onAppear` beside the rest of the preference seeding: the
        // `@AppStorage` that seeds `GobanState.thumbnailSize` reads the store
        // when the property wrapper is created, so a migration running inside
        // the same view's body would land after the value it needs to change.
        ThumbnailSizePreference.migrateLegacyValueIfNeeded()

        // DEBUG-only, and a no-op without its launch argument: put a bundled
        // network where a downloaded one would live, so the Core ML cache UI
        // test never has to reach the internet. Here rather than in a `.task`
        // because the model picker reads that file's presence as it renders.
        #if DEBUG
        ModelStagingUITestSupport.stageIfNeeded()

        // DEBUG-only, and a no-op without its launch argument: drop the
        // per-model Backend Settings so every UI test launch starts from the
        // factory defaults, however the previous one died. Here rather than in
        // a `.task` because `BackendConfigSheet` seeds its pickers in its own
        // initializer and `ModelRunnerView` reads the values as it starts the
        // engine.
        BackendSettingsResetUITestSupport.resetIfNeeded()

        // DEBUG-only, and a no-op without its launch argument: seed a short
        // committed game for the Export GIF test — or the README-screenshot
        // game (`--screenshot-seed`). HERE, in init(), and not in a
        // `.task` — the seed refreshes its own `lastModificationDate` so it wins
        // the recency race and becomes the game the launch auto-selects (the
        // game list pre-fills its search filter with the SELECTED game's name,
        // so a seed that loses that race is filtered out of the list entirely).
        // The board now mounts on the first frame and resolves that selection in
        // its own `.task`, which a sibling `.task` on the App is not ordered
        // against — so the seed has to be in place before any view exists.
        UITestSeed.seedIfNeeded()
        #endif

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

        // Wire the engine-launch status updater seam so the inline engine
        // status can show a secondary caption during cache-miss compiles.
        registerEngineLaunchStatusUpdater(status)
    }

    @ViewBuilder
    private var modelRunnerRoot: some View {
        ModelRunnerView()
            .environment(cacheReadiness)
            .environment(engineLaunchStatus)
            .environment(deepLinkRouter)
            .environment(listeningController)
            .sheet(isPresented: Bindable(listeningController).isPresentingSheet) {
                // Explicit injection: this sheet is attached OUTSIDE the
                // .environment chain above, so its content would not inherit
                // the controller — and a non-optional @Environment traps on
                // view update, not on access.
                ListeningView()
                    .environment(listeningController)
            }
            .onChange(of: deepLinkRouter.pendingListenGameID, initial: true) {
                // The Listen App Intents' drain. Board selection is untouched:
                // a Listening Session is audio over the record, not navigation.
                guard let id = deepLinkRouter.pendingListenGameID else { return }
                deepLinkRouter.pendingListenGameID = nil
                listeningController.listenToGame(withID: id)
            }
            .onOpenURL { url in
                // Capture externally-opened content at the always-mounted root so
                // it survives a cold launch — a URL can be delivered before
                // `GameSplitView` has mounted its own `.onOpenURL`. `open-game`
                // deep links latch a game id; image file-opens latch the DECODED
                // BYTES (read at receipt — the URL's sandbox extension may not
                // survive until GameSplitView mounts). `ContentView`'s
                // engine-free seeding (cold) and `GameSplitView`'s `.onChange`
                // handlers (warm + a mount-time `initial: true` drain) apply the
                // pending id / image. SGF file-import URLs and the Messages
                // `import-sgf` links fall through to GameSplitView's SGF
                // handlers, which are mounted from the first frame now — the
                // model picker's own copy of them is gone.
                if let id = GameDeepLink.gameID(from: url) {
                    deepLinkRouter.pendingGameID = id
                } else if GameDeepLink.importSgfFileName(from: url) == nil,
                          let data = FileOpenClassifier.imageData(at: url) {
                    deepLinkRouter.pendingImageImport = PendingImageImport(
                        imageData: data,
                        suggestedName: url.deletingPathExtension().lastPathComponent)
                    FileOpenClassifier.cleanUpInboxFile(at: url)
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
            .task {
                // Sweeps stale partials, reattaches to whatever the background
                // daemon finished while we were gone, and resumes what was
                // interrupted. Paused downloads are left alone by design. A
                // no-op under `--uitest-disable-downloads`.
                DownloadCenter.shared.restoreOnLaunch()
            }
            // README screenshots are captured in light mode on every platform
            // that has one, so the six images read as one product. `nil` is
            // "no preference", which is what every normal launch gets —
            // `ScreenshotSeed.isActive` is hard-wired false outside DEBUG.
            .preferredColorScheme(ScreenshotSeed.isActive ? .light : nil)
    }

    // This (old, cross-platform SwiftUI) app target now builds for iOS only:
    // macOS is the native AppKit `KataGo Anytime Mac` target, and visionOS is
    // the volumetric `KataGo Anytime Vision` target. So this scene is no
    // longer conditionalised on `os(macOS)`.
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
        scene
            .modelContainer(SharedModelContainer.shared)
            // The system relaunches the app when a background transfer needs
            // attention; this is where those events are drained. The app has
            // never had a UIApplicationDelegate and does not gain one for it.
            .backgroundTask(.urlSession(DownloadCenter.sessionIdentifier)) {
                await DownloadCenter.shared.awaitBackgroundURLSessionEvents()
            }
    }
}
