import SwiftUI
import KataGoGameStore

struct WatchRootView: View {
    @Environment(WatchLiveModel.self) private var model

    var body: some View {
        if model.peek.entries.isEmpty {
            ContentUnavailableView("No live session",
                                   systemImage: "circle.grid.cross",
                                   description: Text("Start analysis on your iPhone."))
        } else {
            TabView {
                WatchBoardPage()
                WatchMovesPage()
            }
            .tabViewStyle(.verticalPage)
        }
    }
}
