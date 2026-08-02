import SwiftUI
import SwiftData
import KataGoGameStore

/// A saved game the watch replays itself: board page plus a review page,
/// the same two-page shape as the live mirror.
struct WatchStoredGameView: View {
    let row: WatchLibraryRow
    let container: ModelContainer

    // Built lazily in `.task(id:)`, not eagerly in `init`: constructing
    // WatchBrowseModel does a full mainline replay plus a SwiftData fetch,
    // and this view is recreated by WatchRootView's `navigationDestination`
    // closure on every coalesced CloudKit refetch while a game is open (that
    // closure reads the @Observable library, which reassigns `rows`
    // unconditionally on every `refresh()`). Building it eagerly via
    // `State(initialValue:)` used to pay that cost on every one of those
    // re-renders only to have SwiftUI discard the result after the first —
    // `.task(id: row.id)` reruns only when `row.id` actually changes, i.e.
    // when the user opens a different game.
    @State private var model: WatchBrowseModel?
    @State private var crownIndex: Double = 0

    var body: some View {
        Group {
            if let model {
                if model.isReadable, let frame = model.frame {
                    TabView {
                        boardPage(model, frame)
                        reviewPage(frame)
                    }
                    .tabViewStyle(.verticalPage)
                } else {
                    ContentUnavailableView("Can't read this game",
                                           systemImage: "doc.questionmark",
                                           description: Text("Its record could not be parsed."))
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(model?.row.name ?? row.name)
        .task(id: row.id) {
            let opened = WatchBrowseModel(row: row, container: container)
            crownIndex = Double(opened.index)
            model = opened
        }
    }

    private func boardPage(_ model: WatchBrowseModel, _ frame: WatchBoardFrame) -> some View {
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
