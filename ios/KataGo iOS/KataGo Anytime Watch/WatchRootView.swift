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
            .overlay(alignment: .bottom) {
                if let message = model.rejectionMessage {
                    Label { Text(message) } icon: { Image(systemName: "xmark.circle.fill") }
                        .font(.caption2).padding(4)
                        .background(.red.opacity(0.9), in: Capsule())
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: model.rejectionMessage)
        }
    }
}
