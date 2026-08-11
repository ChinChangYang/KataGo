//
//  TVRootView.swift
//  KataGo Anytime TV
//
//  Root of the tvOS review/spectate app. Launches the in-process engine (built-in
//  b18 net, tvOS CoreML/NE config), does the GTP version handshake once, then
//  hosts a TabView with two tabs: Library (a NavigationStack — game grid →
//  read-only review / self-play drill-downs) and Settings. The GTP message loop
//  (`session.run`) stays active at the root so analysis streams while a game is
//  open.
//

import SwiftUI
import SwiftData
import KataGoUICore

/// Top-level tabs. Settings and Search are first-class destinations (tabs), not
/// cards in the library grid. Library hosts the game grid and its review /
/// self-play drill-downs; those stay pushed inside the Library tab's own stack.
private enum TVTab: Hashable {
    case library
    case search
    case settings
}

/// The `GameRecord` navigation destination, shared by both the Library and
/// Search stacks. Classifies the pushed record as playable vs. review-only
/// EXACTLY ONCE PER PUSH — in `init`, not by reading `TVPlayability` from
/// inside the `navigationDestination` closure or a plain computed property.
///
/// `TVPlayability.isPlayable` re-parses the game's SGF through the C++
/// bridge, and `game.sgf` / `game.concreteConfig`'s max-time fields are
/// observable SwiftData properties that change on every `printsgf` echo
/// while a game is being played. Reading them directly in the destination
/// closure would re-run that parse on every move and, the instant the
/// second pass (or a resulting `RE[...]`) lands in `game.sgf`, flip the
/// branch out from under an already-mounted `TVPlayScreen` — replacing it
/// with a locked `TVReviewScreen` and losing the result overlay's "Undo to
/// keep playing" recovery (see `TVPlayScreen.resultOverlay`). Caching the
/// verdict in `@State`, seeded once at construction, decouples the mounted
/// screen's identity from every subsequent SGF mutation while it stays
/// pushed.
///
/// `.onChange(of: game.persistentModelID)` reclassifies only if this view's
/// identity is ever reused for a different underlying record (the same
/// defensive edge as `TVGameCard`'s cached badge) — never for the SAME
/// record mid-game. A fresh push still re-classifies (a new
/// `TVGameDestinationView` is constructed for every push), so backing out
/// of a finished game and re-entering it correctly opens review.
private struct TVGameDestinationView: View {
    let game: GameRecord
    let onContinueLive: (SelfPlaySeed) -> Void

    @State private var isPlayable: Bool

    init(game: GameRecord, onContinueLive: @escaping (SelfPlaySeed) -> Void) {
        self.game = game
        self.onContinueLive = onContinueLive
        _isPlayable = State(initialValue: TVPlayability.isPlayable(game))
    }

    var body: some View {
        Group {
            if isPlayable {
                TVPlayScreen(game: game)
            } else {
                TVReviewScreen(game: game, onContinueLive: onContinueLive)
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .onChange(of: game.persistentModelID) { _, _ in
            isPlayable = TVPlayability.isPlayable(game)
        }
    }
}

struct TVRootView: View {
    @State private var session = GameSession()
    @State private var engineLifecycle = EngineLifecycle()
    @State private var engineController = TVEngineController()
    @State private var audioModel = AudioModel()
    @State private var navigationContext = NavigationContext()
    @State private var syncMonitor = CloudKitSyncMonitor()
    @State private var attractMode = TVAttractModeController()
    /// ONE owner for the whole app: pressedChangedHandler is a single slot per
    /// button, and the review and self-play screens coexist on one stack.
    @State private var controllerInput = TVControllerInput()
    @Environment(\.scenePhase) private var scenePhase
    @State private var aiMove: String? = nil
    @State private var isReady = false
    @State private var engineStarted = false
    // NavigationPath (not [GameRecord]) so the self-play route can coexist
    // with game records in the Library tab's stack.
    @State private var libraryPath = NavigationPath()
    /// The Search tab's own stack path. Separate from `libraryPath`: the live
    /// handoff must push onto whichever stack the review screen was opened on.
    @State private var searchPath = NavigationPath()
    /// Which top-level tab is showing. Always starts on Library; not persisted
    /// across launches.
    @State private var selectedTab: TVTab = .library

    /// Diagnostics memory overlay (Settings ▸ Diagnostics). Hosted at the root so
    /// it floats in the top-right corner over every screen while enabled.
    @AppStorage("TVSettings.showMemoryOverlay") private var showMemoryOverlay = false

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
                TabView(selection: $selectedTab) {
                    NavigationStack(path: $libraryPath) {
                        TVLibraryView()
                            .navigationDestination(for: GameRecord.self) { game in
                                TVGameDestinationView(game: game, onContinueLive: { seed in
                                    libraryPath.append(SelfPlayRoute(entry: .manual, seed: seed))
                                })
                            }
                            .navigationDestination(for: SelfPlayRoute.self) { route in
                                TVSelfPlayScreen(route: route)
                                    .toolbar(.hidden, for: .tabBar)
                            }
                            .navigationDestination(for: NewGameRoute.self) { _ in
                                TVNewGameScreen(onStart: { record in
                                    libraryPath.removeLast()      // replace the form with the game
                                    libraryPath.append(record)    // classifier routes it to TVPlayScreen
                                })
                                .toolbar(.hidden, for: .tabBar)
                            }
                    }
                    .tabItem { Label("Library", systemImage: "square.grid.2x2") }
                    .tag(TVTab.library)

                    // Search is its own tab so tvOS renders its full-screen
                    // keyboard there instead of pinning it above the Library
                    // grid. Selecting a result pushes review inside this stack —
                    // which therefore needs the SelfPlayRoute destination too,
                    // or the live handoff silently no-ops for a game opened
                    // from Search.
                    NavigationStack(path: $searchPath) {
                        TVSearchView()
                            .navigationDestination(for: GameRecord.self) { game in
                                TVGameDestinationView(game: game, onContinueLive: { seed in
                                    searchPath.append(SelfPlayRoute(entry: .manual, seed: seed))
                                })
                            }
                            .navigationDestination(for: SelfPlayRoute.self) { route in
                                TVSelfPlayScreen(route: route)
                                    .toolbar(.hidden, for: .tabBar)
                            }
                    }
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                    .tag(TVTab.search)

                    // Review and Self-Play stay drill-downs inside the Library
                    // tab (they rely on @Environment(\.dismiss) + the attract/
                    // manual exit contract), so only Search and Settings are
                    // sibling tabs. `.toolbar(.hidden, for: .tabBar)` on every
                    // pushed game screen keeps the persistent tab bar from
                    // overlapping the hero board.
                    NavigationStack {
                        TVSettingsScreen()
                    }
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(TVTab.settings)
                }
                // Inject the session's engine-driven models so the shared
                // BoardView / analysis views resolve them via @Environment.
                // Hosted on the TabView so BOTH tabs resolve them — the Library
                // drill-downs AND the Settings screen's engine views.
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
                .environment(controllerInput)
                // The session itself (not just its sub-models): shared board /
                // analysis views resolve it via @Environment.
                .environment(session)
                // Idle-attract signals. Interaction detail (focus movement)
                // is reported by TVLibraryView; the root owns the structural
                // signals: which tab is showing, navigation depth, scene phase.
                // Attract may only start while idling at the Library tab's root
                // grid — never over a pushed screen or the Settings tab.
                .onChange(of: libraryPath.count) { _, _ in
                    // NavigationPath is not Equatable — observe its count.
                    refreshAttractIdle()
                }
                .onChange(of: selectedTab) { _, _ in
                    refreshAttractIdle()
                }
                .onChange(of: scenePhase) { _, phase in
                    attractMode.sceneIsActive = (phase == .active)
                    refreshAttractIdle()
                }
                .task {
                    // Wire the push closure and start the first countdown once
                    // the library exists (this branch is engine-ready-gated).
                    // Attract always runs on the Library tab, so select it first.
                    attractMode.startAttract = {
                        selectedTab = .library
                        libraryPath.append(SelfPlayRoute(entry: .attract))
                    }
                    guard !isRunningInPreview else { return }
                    refreshAttractIdle()
                }
                // Analysis stop lifecycle. tvOS has no per-game host controller
                // (iOS uses GameSplitView, macOS MainWindowController), so the
                // "stop" that halts the continuously-streaming kata-analyze lives
                // here at the always-alive root. Without it the fanless Apple TV
                // would keep running NN search forever after the user turns
                // analysis off or backs out to the library.
                .onChange(of: session.gobanState.analysisStatus) { _, newValue in
                    // User toggled analysis off (TVReviewScreen sets .clear) —
                    // but never while the broadcast's licensed gen-move is in
                    // flight; see GobanState.shouldStopEngineOnAnalysisClear.
                    if newValue == .clear,
                       session.gobanState.shouldStopEngineOnAnalysisClear {
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
                    // restart (the Settings "Restart Engine" recovery) it exits
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
                TVLoadingView(caption: "Loading engine")
            }
        }
        // Diagnostics memory readout — floats over both the loading and ready
        // branches so it's visible on every screen (and can catch the CoreML
        // model-load spike if enabled before the engine starts/restarts).
        .overlay(alignment: .topTrailing) {
            if showMemoryOverlay {
                TVMemoryOverlay()
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

    /// Mirror "idle at the Library tab's root grid" into the attract controller
    /// and re-arm or cancel its trailing-edge countdown. Idle means the Library
    /// tab is selected AND its stack is at the root (no review/self-play pushed).
    /// The Settings tab or any pushed screen disarms attract entirely.
    private func refreshAttractIdle() {
        let idleAtLibrary = (selectedTab == .library) && libraryPath.isEmpty
        attractMode.pathIsEmpty = idleAtLibrary
        if idleAtLibrary, scenePhase == .active {
            attractMode.noteUserActivity()   // restart the idle countdown
        } else {
            attractMode.disarm()             // a screen/tab is up: no auto-start beneath it
        }
    }

    private func startEngineIfNeeded() {
        guard !engineStarted, !isRunningInPreview else { return }
        engineStarted = true
        // Apple TV runs a single fixed CoreML/Neural Engine backend.
        engineController.configure(session: session, engineLifecycle: engineLifecycle)
        engineController.startInitial()
    }
}

// MARK: - Previews

// #Preview bodies still compile in Release, and the TVPreviewData fixtures are
// DEBUG-only — guard the whole section or archiving fails.
#if DEBUG
// The pre-handshake branch: spinning icon + caption while the engine loads the
// net. The preview guard keeps the real engine from launching in the canvas.
#Preview("Root — engine loading") {
    TVRootView()
        .environment(EngineLaunchStatus())
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

#endif
