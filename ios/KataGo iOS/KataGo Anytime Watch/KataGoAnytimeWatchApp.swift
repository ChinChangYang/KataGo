import SwiftUI
import SwiftData
import KataGoGameStore

@main
struct KataGoAnytimeWatchApp: App {
    // `let`, not `@State`: `init()` calls into it, and the model has no
    // observable state the App scene itself renders.
    private let model = WatchLiveModel()
    /// Built here too, for the same reason `model` is: `WatchWidgetMirror`
    /// needs only `UserDefaults` (see its doc comment), so nothing stops
    /// constructing it in `init()` and wiring it into `model.widgetMirror`
    /// BEFORE `activateForLaunch()` registers the WCSession delegate — so a
    /// delegate callback can never arrive before there is a writer to hand it
    /// to. A background launch for a complication payload never evaluates the
    /// window body, so if the mirror were built there (as it used to be) the
    /// wake's write would be a silent no-op.
    private let widgetMirror = WatchWidgetMirror()
    /// Built at first UI appearance, NOT in `init()`.
    ///
    /// `SharedModelContainer.shared` takes the CloudKit-only branch on
    /// watchOS: an NSPersistentCloudKitContainer open with schema setup,
    /// mirroring, import/export scheduling and push registration. A background
    /// wake whose whole job is a UserDefaults write and a WidgetCenter reload
    /// must not pay that — the budget it spends is the one the 0xc51bad0x
    /// termination codes police.
    @State private var library: WatchLibraryStore?

    init() {
        model.widgetMirror = widgetMirror
        // Registering the delegate here — rather than at `.onAppear` — is what
        // lets a background launch for a complication payload be received at
        // all: the window body is never evaluated on such a launch.
        model.activateForLaunch()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let library {
                    WatchRootView(container: SharedModelContainer.shared)
                        .environment(model)
                        .environment(library)
                } else {
                    ProgressView()
                }
            }
            .task {
                model.startClock()
                guard library == nil else { return }
                library = WatchLibraryStore(container: SharedModelContainer.shared,
                                            storeMode: SharedModelContainer.watchStoreMode)
            }
        }
        // SwiftUI completes the underlying WKWatchConnectivityRefreshBackgroundTask
        // when this action returns, so the body must not return before the
        // delegate callback has written the record and asked for the reload.
        .backgroundTask(.watchConnectivity) {
            await model.drainWatchConnectivity()
        }
    }
}
