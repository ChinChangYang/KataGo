import SwiftUI

@main
struct KataGoAnytimeWatchApp: App {
    @State private var model = WatchLiveModel()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(model)
                .onAppear { model.activate() }
        }
    }
}
