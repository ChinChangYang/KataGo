import SwiftUI
import SwiftData
import KataGoGameStore

@main
struct KataGoAnytimeWatchApp: App {
    @State private var model = WatchLiveModel()
    @State private var library: WatchLibraryStore

    init() {
        // `shared` is a static let, so touching it here and below is one
        // container, opened once through the CloudKit-only ladder.
        _library = State(initialValue: WatchLibraryStore(
            container: SharedModelContainer.shared,
            storeMode: SharedModelContainer.watchStoreMode))
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView(container: SharedModelContainer.shared)
                .environment(model)
                .environment(library)
                .onAppear { model.activate() }
        }
    }
}
