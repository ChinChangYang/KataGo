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
    /// Whether the transient move counter is on screen. The board takes the
    /// whole page now, so a PERMANENT counter would obscure its top edge for
    /// the whole time a game is being read; this shows it while the Crown is
    /// moving and gets out of the way afterwards.
    @State private var showsCounter = false

    /// Blends the record's cached best move onto the board. `@AppStorage`
    /// rather than `@State` for two reasons: the watch has no settings screen
    /// to hold it, and this view is rebuilt by `WatchRootView`'s
    /// `navigationDestination` closure on every coalesced CloudKit refetch —
    /// plain `@State` would be reset by a background sync. Defaults on: the
    /// point of the toggle is that the move is visible on the board.
    @AppStorage("WatchSettings.showBestMove") private var showBestMove = true

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
        // The VStack is kept as the modifier host for parity with
        // WatchBoardPage — `.focusable()` is what wins the Crown away from the
        // enclosing TabView's vertical paging, and it must not move.
        VStack(spacing: 2) {
            WatchFrameBoard(frame: frame, showBestMove: showBestMove)
        }
        .overlay(alignment: .top) { counterPill(frame) }
        .animation(.easeInOut(duration: 0.2), value: showsCounter)
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
        // `.task(id:)` IS the debounce: SwiftUI cancels the running task the
        // moment the Crown moves again, so the two-second countdown restarts
        // on every detent and only completes once scrubbing stops. It also
        // fires on first appearance, which shows the reader where the game
        // opened before getting out of the way.
        .task(id: crownIndex) {
            showsCounter = true
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            showsCounter = false
        }
    }

    @ViewBuilder
    private func counterPill(_ frame: WatchBoardFrame) -> some View {
        if showsCounter, let index = frame.moveIndex, let count = frame.moveCount {
            Text("\(index)/\(count)")
                .font(.caption2)
                .padding(3)
                .background(.orange.opacity(0.85), in: Capsule())
                .transition(.opacity)
        }
    }

    private func reviewPage(_ frame: WatchBoardFrame) -> some View {
        List {
            // Always present and always enabled, even at the many indices with
            // no cached analysis: the setting is global, and a control that
            // appeared and vanished as the user scrubbed would read as a
            // per-move property of the game rather than a preference.
            Toggle("Show best move", isOn: $showBestMove)

            // The one case where the vertex still has to be spelled out. A
            // cached "pass" cannot be drawn on the board, so with the toggle
            // on and no caption the user could not tell it apart from "nothing
            // was analyzed here" — which at the end of a scored game is
            // exactly the wrong conclusion.
            if case .unrenderable(let vertex) = frame.bestMoveMark(showBestMove: showBestMove) {
                Text("Best: \(vertex)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
