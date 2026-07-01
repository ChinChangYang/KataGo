//
//  TVRootView.swift
//  KataGo Anytime TV
//
//  Root of the tvOS review/spectate app. Launches the in-process engine (built-in
//  b18 net, tvOS CoreML/NE config), does the GTP version handshake once, then
//  hosts a NavigationStack: library grid → read-only review screen. The GTP
//  message loop (`session.run`) stays active at the root so analysis streams
//  while a game is open.
//

import SwiftUI
import SwiftData
import KataGoUICore

struct TVRootView: View {
    @State private var session = GameSession()
    @State private var engineLifecycle = EngineLifecycle()
    @State private var audioModel = AudioModel()
    @State private var navigationContext = NavigationContext()
    @State private var aiMove: String? = nil
    @State private var isReady = false
    @State private var engineStarted = false
    @State private var path: [GameRecord] = []

    @Query(sort: \GameRecord.lastModificationDate, order: .reverse) private var gameRecords: [GameRecord]
    @Environment(\.modelContext) private var modelContext

    /// Xcode Previews run this view inside the preview host, where launching
    /// the real GTP engine (a C++ thread that loads the neural net) or blocking
    /// on its replies would hang/crash the canvas. All engine side effects are
    /// gated on this flag; previews render pure UI.
    private let isRunningInPreview =
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"

    init(isReady: Bool = false) {
        // Previews inject `isReady: true` to render the post-handshake branch
        // (NavigationStack + library) without an engine. The app always starts
        // false and flips when the GTP version handshake completes.
        _isReady = State(initialValue: isReady)
    }

    var body: some View {
        Group {
            if isReady {
                NavigationStack(path: $path) {
                    TVLibraryView()
                        .navigationDestination(for: GameRecord.self) { game in
                            TVReviewScreen(game: game)
                        }
                }
                // Inject the session's engine-driven models so the shared
                // BoardView / analysis views resolve them via @Environment.
                .environment(session.stones)
                .environment(session.messageList)
                .environment(session.board)
                .environment(session.player)
                .environment(session.analysis)
                .environment(session.gobanState)
                .environment(session.rootWinrate)
                .environment(session.rootScore)
                .environment(session.bookLookup)
                .environment(audioModel)
                .environment(navigationContext)
                // Analysis stop lifecycle. tvOS has no per-game host controller
                // (iOS uses GameSplitView, macOS MainWindowController), so the
                // "stop" that halts the continuously-streaming kata-analyze lives
                // here at the always-alive root. Without it the fanless Apple TV
                // would keep running NN search forever after the user turns
                // analysis off or backs out to the library.
                .onChange(of: session.gobanState.analysisStatus) { _, newValue in
                    // User toggled analysis off (TVReviewScreen sets .clear).
                    if newValue == .clear {
                        session.messageList.appendAndSend(command: "stop")
                    }
                }
                .onChange(of: session.gobanState.waitingForAnalysis) { oldValue, newValue in
                    // Leaving the review screen pauses analysis (BoardView's
                    // onDisappear → maybePauseAnalysis sets .pause and arms
                    // waitingForAnalysis); the next streamed line drives this
                    // true→false edge, at which point we stop the engine.
                    if oldValue, !newValue, session.gobanState.analysisStatus == .pause {
                        session.messageList.appendAndSend(command: "stop")
                    }
                }
                .task {
                    guard !isRunningInPreview else { return }
                    // The GTP read loop — parses board/analysis lines into the
                    // models. Stays alive for the app's lifetime.
                    await session.run(gameRecords: gameRecords,
                                      modelContext: modelContext,
                                      navigationContext: navigationContext,
                                      audioModel: audioModel,
                                      aiMove: $aiMove)
                }
            } else {
                TVLoadingView(caption: "Loading engine…")
            }
        }
        .onAppear(perform: startEngineIfNeeded)
        .task {
            guard !isReady, !isRunningInPreview else { return }
            // Blocks on the engine's `version` reply (i.e. until the b18 net has
            // finished loading via CoreML/NE), then sends the default board setup.
            _ = await session.initialize(
                selectedModelTitle: NeuralNetworkModel.builtInModel?.title ?? "",
                engineLifecycle: engineLifecycle,
                config: nil)
            isReady = true
        }
    }

    private func startEngineIfNeeded() {
        guard !engineStarted, !isRunningInPreview else { return }
        engineStarted = true
        engineLifecycle.reset()
        // Built-in b18 net + tvOS defaults (CoreML/NE device [100], 1 search
        // thread, human-SL net skipped). Needs a >512 KB stack (BoardHistory
        // copies) — match the iOS app's 1 MB.
        let engineThread = Thread { KataGoHelper.runGtp() }
        engineThread.stackSize = 4096 * 256
        engineThread.start()
    }
}

/// Simple centered loading screen for the engine handshake / CloudKit first sync.
struct TVLoadingView: View {
    var caption: String
    var body: some View {
        VStack(spacing: 28) {
            ProgressView()
                .controlSize(.large)
            Text(caption)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Previews

// The pre-handshake branch: spinner + caption while the engine loads the net.
// The preview guard keeps the real engine from launching in the canvas.
#Preview("Root — engine loading") {
    TVRootView()
        .modelContainer(TVPreviewData.container(games: []))
}

// The post-handshake branch: NavigationStack + library, no engine.
#Preview("Root — library") {
    TVRootView(isReady: true)
        .modelContainer(TVPreviewData.container(games: [
            TVPreviewData.openingGame(),
            TVPreviewData.smallBoardGame(),
        ]))
}

// The standalone loading screen used for both engine and iCloud waits.
#Preview("Loading view") {
    TVLoadingView(caption: "Loading engine…")
}
