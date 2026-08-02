import SwiftUI
import SwiftData
import KataGoGameStore

/// A saved game the watch replays itself: board page plus a review page,
/// the same two-page shape as the live mirror.
struct WatchStoredGameView: View {
    @State private var model: WatchBrowseModel
    @State private var crownIndex: Double = 0

    init(row: WatchLibraryRow, container: ModelContainer) {
        _model = State(initialValue: WatchBrowseModel(row: row, container: container))
    }

    var body: some View {
        Group {
            if model.isReadable, let frame = model.frame {
                TabView {
                    boardPage(frame)
                    reviewPage(frame)
                }
                .tabViewStyle(.verticalPage)
            } else {
                ContentUnavailableView("Can't read this game",
                                       systemImage: "doc.questionmark",
                                       description: Text("Its record could not be parsed."))
            }
        }
        .navigationTitle(model.row.name)
        .onAppear { crownIndex = Double(model.index) }
    }

    private func boardPage(_ frame: WatchBoardFrame) -> some View {
        VStack(spacing: 2) {
            WatchFrameBoard(frame: frame)
        }
        .focusable()
        .digitalCrownRotation($crownIndex,
                              from: 0, through: Double(model.moveCount),
                              by: 1, sensitivity: .medium,
                              isContinuous: false, isHapticFeedbackEnabled: true)
        .onChange(of: crownIndex) { _, newValue in
            // A local index over the watch's own replay: nothing to confirm
            // with the phone, so no debounce and no shared cursor here.
            model.index = min(max(Int(newValue.rounded()), 0), model.moveCount)
        }
    }

    private func reviewPage(_ frame: WatchBoardFrame) -> some View {
        List {
            if let best = frame.bestMove {
                LabeledContent("Best") {
                    Text(best).font(.system(.body, design: .monospaced)).bold()
                }
            }
            if let comment = frame.comment {
                Text(comment).font(.caption)
            }
            if frame.bestMove == nil, frame.comment == nil {
                Text("No analysis saved for this move").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Review")
    }
}
