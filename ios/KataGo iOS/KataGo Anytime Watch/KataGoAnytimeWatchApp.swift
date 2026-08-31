import SwiftUI
import SwiftData
import KataGoGameStore

@main
struct KataGoAnytimeWatchApp: App {
    /// Built at first UI appearance, NOT in `init()`.
    ///
    /// `SharedModelContainer.shared` takes the CloudKit-only branch on
    /// watchOS: an NSPersistentCloudKitContainer open with schema setup,
    /// mirroring, import/export scheduling and push registration. Deferring it
    /// keeps that cost off the launch path until something actually renders.
    @State private var library: WatchLibraryStore?
    /// Needs only `UserDefaults`, but built here alongside the library because
    /// the library refresh is now its only caller. It used to be constructed in
    /// `init()` so that a WatchConnectivity background launch — which never
    /// evaluates the window body — still had a writer to hand a frame to.
    /// There are no background launches any more.
    @State private var widgetMirror: WatchWidgetMirror?

    var body: some Scene {
        WindowGroup {
            Group {
                if let library, let widgetMirror {
                    WatchRootView(container: SharedModelContainer.shared,
                                  widgetMirror: widgetMirror)
                        .environment(library)
                } else {
                    ProgressView()
                }
            }
            .task {
                guard library == nil else { return }
                // README screenshots: seed BEFORE the library store is built,
                // so its first fetch already sees the record the capture
                // script deep-links to. `ScreenshotSeed` lives in
                // KataGoGameStore — the only store package this app links —
                // for exactly this call. No-op without `--screenshot-seed`,
                // and outside DEBUG.
                if ScreenshotSeed.isActive {
                    ScreenshotSeed.resetReadinessMarker()
                    ScreenshotSeed.seed(into: SharedModelContainer.shared.mainContext)
                }
                widgetMirror = WatchWidgetMirror()
                library = WatchLibraryStore(container: SharedModelContainer.shared,
                                            storeMode: SharedModelContainer.watchStoreMode)
            }
        }
    }
}
