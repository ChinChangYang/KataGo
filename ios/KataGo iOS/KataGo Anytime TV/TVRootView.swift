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
    @State private var engineController = TVEngineController()
    @State private var audioModel = AudioModel()
    @State private var navigationContext = NavigationContext()
    @State private var syncMonitor = CloudKitSyncMonitor()
    @State private var attractMode = TVAttractModeController()
    @Environment(\.scenePhase) private var scenePhase
    @State private var aiMove: String? = nil
    @State private var isReady = false
    @State private var engineStarted = false
    // NavigationPath (not [GameRecord]) so the self-play route can coexist
    // with game records in one stack.
    @State private var path = NavigationPath()

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
                        .navigationDestination(for: SelfPlayRoute.self) { route in
                            TVSelfPlayScreen(route: route)
                        }
                        .navigationDestination(for: SettingsRoute.self) { _ in
                            TVSettingsScreen()
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
                .environment(syncMonitor)
                .environment(attractMode)
                .environment(engineController)
                // The session itself (not just its sub-models): the settings
                // screen's benchmark needs its command list + line tap.
                .environment(session)
                // Idle-attract signals. Interaction detail (focus movement)
                // is reported by TVLibraryView; the root owns the structural
                // signals: navigation depth and scene phase.
                .onChange(of: path.count) { _, newCount in
                    // NavigationPath is not Equatable — observe its count.
                    attractMode.pathIsEmpty = (newCount == 0)
                    if newCount == 0 {
                        attractMode.noteUserActivity()   // back at the library: restart the countdown
                    } else {
                        attractMode.disarm()             // a screen is up: no auto-start beneath it
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    attractMode.sceneIsActive = (phase == .active)
                    if phase == .active, path.isEmpty {
                        attractMode.noteUserActivity()
                    } else if phase != .active {
                        attractMode.disarm()
                    }
                }
                .task {
                    // Wire the push closure and start the first countdown once
                    // the library exists (this branch is engine-ready-gated).
                    attractMode.startAttract = {
                        path.append(SelfPlayRoute(entry: .attract))
                    }
                    guard !isRunningInPreview else { return }
                    attractMode.noteUserActivity()
                }
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
                    // models. Runs for the app's lifetime; across an engine
                    // restart (Settings backend switch / benchmark) it exits
                    // (stopRequested) and PARKS in the controller until the
                    // new engine's handshake — which must be the bridge's
                    // sole reader — completes, then reads again.
                    while !Task.isCancelled {
                        await session.run(gameRecords: gameRecords,
                                          modelContext: modelContext,
                                          navigationContext: navigationContext,
                                          audioModel: audioModel,
                                          aiMove: $aiMove)
                        await engineController.noteRunLoopExited()
                    }
                }
            } else {
                TVLoadingView(caption: "Loading engine…")
            }
        }
        .onAppear(perform: startEngineIfNeeded)
        .task {
            // The TV never auto-creates a game from a printsgf reply: the
            // CloudKit library is legitimately empty until sync delivers
            // games, and the self-play demo plays into an in-memory record
            // that must never be duplicated into the synced store (a
            // session-level switch so no reply race can re-arm the insert).
            // Set before the engine handshake completes — no printsgf reply
            // can precede it.
            session.autoCreatesGameOnEmptyLibrary = false

            // tvOS draws the standard diagram orientation (GTP row 1 at the
            // bottom), matching the WidgetBoardView card thumbnails.
            // GlobalPreferenceSync never runs on TV, so nothing overwrites it.
            session.gobanState.verticalFlip = false

            // Stone/capture sounds (the mp3s ship in the KataGoUICore package
            // bundle) — persisted via the TV Settings toggle, default ON.
            session.gobanState.soundEffect = TVSettingsStore.soundEffects

            // Only the last move carries a number — the last-3 default's
            // trailing ①②③ markers read as clutter at 10-foot distance.
            session.gobanState.moveNumberStyle = MoveNumberStyle.lastMove.rawValue

            // Stream continuous kata-analyze at the game's analysisInterval
            // (default 0.5 s) instead of the 0.1 s fast-first-report interval:
            // 10 Hz of info+ownership parsing visibly bogs down the A15 UI,
            // and unlike iOS the TV root never re-arms at the config interval.
            session.gobanState.continuousAnalysisUsesConfigInterval = true

            // Start the sync monitor at launch, in parallel with the engine
            // handshake — the grace window and account check tick behind
            // "Loading engine…", so by the time the library appears the
            // empty-state verdict already has a head start.
            guard !isRunningInPreview else { return }
            syncMonitor.start()
        }
        .task {
            guard !isReady, !isRunningInPreview else { return }
            // Blocks on the engine's `version` reply (i.e. until the b18 net has
            // finished loading), then sends the default board setup.
            _ = await session.initialize(
                selectedModelTitle: NeuralNetworkModel.builtInModel?.title ?? "",
                engineLifecycle: engineLifecycle,
                config: nil)
            // Handshake done: clear the crash sentinel armed before the spawn.
            engineController.noteInitialHandshakeComplete()
            isReady = true
        }
    }

    private func startEngineIfNeeded() {
        guard !engineStarted, !isRunningInPreview else { return }
        engineStarted = true
        // Backend comes from TV Settings via the crash-safe recovery ladder
        // (a spawn that killed the process boots plain CoreML next launch).
        engineController.configure(session: session, engineLifecycle: engineLifecycle)
        engineController.startInitial()
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

// #Preview bodies still compile in Release, and the TVPreviewData fixtures are
// DEBUG-only — guard the whole section or archiving fails.
#if DEBUG
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
#endif
