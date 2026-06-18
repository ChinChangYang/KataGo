import AppKit
import OSLog
import SwiftUI
import SwiftData
import KataGoUICore
import KataGoEngineIPC

/// Logs the launch-time crash-recovery decision (mirrors the iOS
/// `ModelRunnerView` `recoveryLogger`, ModelRunnerView.swift lines 12-15).
private let recoveryLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "KataGo Anytime",
    category: "engine.recovery"
)

@MainActor
final class MainWindowController: NSWindowController {
    // Owns the engine-driven game state and the UI collaborators `BoardView`
    // (and the rest of the reused SwiftUI layer) needs.
    let session = GameSession()
    let navigationContext = NavigationContext()
    let audioModel = AudioModel()
    let thumbnailModel = ThumbnailModel()
    let topUIState = TopUIState()
    private let engineLifecycle = EngineLifecycle()

    /// Observable engine-launch status (created + wired by the `AppDelegate`,
    /// which registers the `registerEngineLaunchStatusUpdater` seam against it).
    /// Held here so P5-T9 can surface its caption in the board pane during a
    /// cache-miss CoreML compile. Mirrors the iOS `engineLaunchStatus` plumbed
    /// from `KataGo_iOSApp` into `ContentView`.
    let engineLaunchStatus: EngineLaunchStatus

    /// Backs the Library sidebar's list of persisted games (fetch + observe).
    lazy var libraryStore = LibraryStore(container: modelContainer)

    /// `GameSession.run`/`messaging` take a `Binding<String?>` for the AI's last
    /// move (the iOS app drives a confirmation flow off it). Phase 1 on macOS
    /// has no AI play, so we back the binding with a throwaway box rather than
    /// changing the `GameSession` signature (which would force re-verifying iOS).
    private let aiMoveBox = AIMoveBox()

    /// `internal` (not `private`) so the `LibraryActions` extension — in a
    /// separate file — can reach the main context for inserts/deletes.
    let modelContainer: ModelContainer

    /// The per-window KataGo engine, now an out-of-process `katago-engine` child
    /// (was an in-process `Thread` running `KataGoHelper.runGtp`). Owning it here
    /// means each window has its own independent engine.
    private var engineProcess: SubprocessKataGoEngine?

    /// The Task running `initializeSession` → `session.run()` (the steady-state
    /// GTP loop). Tracked so `stopEngineAndSession()` can AWAIT it before a
    /// relaunch injects a new engine — `GameSession` is reused across relaunch,
    /// so the old loop must finish before the new engine is wired in.
    private var sessionTask: Task<Void, Never>?

    /// Persisted model-selection store (same `ModelRunnerView.*` UserDefaults keys
    /// as iOS). `startEngineAndSession()` reads `currentModel` to decide which net
    /// to launch; `relaunch(model:)` writes the user's choice via `setActiveModel`.
    let modelSelection = MacModelSelection()

    /// Last-seen values of the two analysis-lifecycle properties we observe, so
    /// the (property-agnostic) `withObservationTracking` callback can tell which
    /// one changed and detect the specific transitions iOS reacts to. Seeded from
    /// the current `gobanState` when `installAnalysisLifecycleObserver()` runs.
    private var lastWaitingForAnalysis = false
    private var lastAnalysisStatus = AnalysisStatus.run

    /// Last-seen values of the two confirmation flags the second observer
    /// watches, so its (property-agnostic) `withObservationTracking` callback can
    /// detect the specific `false -> true` transitions that should present an
    /// NSAlert. Seeded from the live `gobanState` in `installConfirmationObserver()`.
    private var lastConfirmingIllegalMove = false
    private var lastConfirmingAIOverwrite = false

    /// Last-seen values of the three branch-exit confirmation flags the same
    /// confirmation observer also watches (P6-T2), so its property-agnostic
    /// `withObservationTracking` callback can detect each `false -> true`
    /// transition that should present a branch NSAlert sheet. Seeded from the live
    /// `gobanState` in `installConfirmationObserver()`.
    private var lastConfirmingBranchDeactivation = false
    private var lastConfirmingBranchReplace = false
    private var lastConfirmingBranchDiscard = false

    /// Last-seen value of `gobanState.branchSgf`, snapshotted so the branch-reload
    /// observer (P6-T3) can detect the active->inactive transition (the branch
    /// being committed or discarded) and rebuild the engine board from the saved
    /// SGF. Seeded in `installBranchReloadObserver()` and re-seeded on relaunch.
    private var lastBranchSgf: String = .inActiveSgf

    /// Last-seen values of the two properties the auto-play observer watches.
    /// `lastIsAutoPlaying` lets the (property-agnostic) `withObservationTracking`
    /// callback detect either edge of `gobanState.isAutoPlaying` (it reacts to ANY
    /// `old != new`, matching iOS's `onChange(of: isAutoPlaying)`); `lastStonesReady`
    /// detects the `false -> true` transition of `session.stones.isReady` that iOS
    /// reacts to (`onChange(of: stones.isReady)`). Seeded from the live state in
    /// `installAutoPlayObserver()`.
    private var lastIsAutoPlaying = false
    private var lastStonesReady = false
    /// Detects the `true -> false` transition of `gobanState.isEditing` that iOS
    /// reacts to (`onChange(of: isEditing)` -> `processIsEditingChange`): leaving
    /// edit mode must cancel any in-flight auto-play.
    private var lastIsEditing = false

    /// Last-seen value of `session.bookLookup.isLoaded`, so the book-state observer
    /// (P6-T5) can detect the `false -> true` edge that iOS reacts to
    /// (`processBookLoadedChange`) and re-sync the book to the current move. Seeded
    /// in `installBookStateObserver()` and re-seeded on relaunch.
    private var lastBookLoaded = false

    /// Last-seen value of `gobanState.eyeStatus`, so the book-state observer (P6-T5)
    /// can detect the `-> .book` edge that iOS reacts to (`processEyeStatusChange`)
    /// and re-sync the book. Seeded in `installBookStateObserver()` and re-seeded on
    /// relaunch.
    private var lastEyeStatus = EyeStatus.opened

    /// Last-seen value of `engineLifecycle.lastLoadedModelTitle`. The
    /// (property-agnostic) `withObservationTracking` callback diffs against this
    /// to detect the `nil -> non-nil` transition that signals the engine's first
    /// GTP response, on which the crash sentinel is cleared (mirrors iOS
    /// `ModelRunnerView.onChange(of: engineLifecycle.lastLoadedModelTitle)`,
    /// lines 115-119).
    private var lastLoadedModelTitle: String?

    /// One-shot guard so the launch-time crash-recovery decision runs EXACTLY
    /// once for the window's lifetime. Scene/relaunch transitions must not re-run
    /// recovery — only the very first launch consults the previous run's sentinel.
    /// Mirrors the iOS `ModelRunnerView.hasDecidedRecovery` (ModelRunnerView.swift
    /// lines 21, 44-45).
    private var hasDecidedRecovery = false

    /// The toolbar's Analyze item, retained weakly so `refreshAnalyzeToolbarItem()`
    /// can mutate its image/toolTip to reflect `gobanState.analysisStatus`. The
    /// `NSToolbar` owns the item; we only borrow a reference (set when the item is
    /// built in the `.analyze` case) to avoid a retain cycle.
    private weak var analyzeToolbarItem: NSToolbarItem?

    /// The toolbar's active-model dropdown (P5-T6), retained weakly so
    /// `refreshActiveModelToolbarItem()` can update its displayed title after a
    /// model switch (the menu rebuilds itself live via `menuNeedsUpdate(_:)`, but
    /// the always-visible item title is set imperatively). The `NSToolbar` owns the
    /// item; we only borrow a reference (set when the item is built).
    private weak var activeModelToolbarItem: NSMenuToolbarItem?

    /// AppKit equivalent of the iOS `GlobalPreferenceSync` modifier: seeds the
    /// shared `GobanState` from the persisted `GlobalSettings.*` UserDefaults and
    /// writes each subsequent change back. Owned here; created in `init` BEFORE
    /// the board view appears so `GobanState` already holds the user's display
    /// preferences when `BoardView` first renders.
    private var preferenceSync: MacGlobalPreferenceSync?

    /// Local key-down monitor backing the LizzieYzy board shortcuts (Space =
    /// toggle analysis, `,` = play best move, `P` = pass). Installed in `init`,
    /// removed in `windowWillClose`. See `installBoardShortcutMonitor()` for why a
    /// monitor (not just the menu key equivalents) is needed.
    private var boardShortcutMonitor: Any?

    /// Gates the board pane until the engine session has finished its initial
    /// handshake + board load (see `BoardReadiness`). Without this, the hosted
    /// `BoardView.onAppear` fires at `init` time — before the engine exists — and
    /// its premature `showboard` desyncs `showBoardCount`, gating analysis off.
    let boardReadiness = BoardReadiness()

    init(modelContainer: ModelContainer, engineLaunchStatus: EngineLaunchStatus) {
        self.modelContainer = modelContainer
        self.engineLaunchStatus = engineLaunchStatus

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "KataGo Anytime"
        super.init(window: w)

        // Stop the GTP message loop when the window closes (the katago thread
        // itself runs the engine's own run loop and is left to be torn down by
        // process exit; `stopRequested` ends `GameSession.run()`/`messaging()`).
        w.delegate = self

        // Seed `GobanState` from the persisted `GlobalSettings.*` UserDefaults
        // (and begin write-back) BEFORE the content view controller — which hosts
        // `BoardView` — is built, so the board renders with the user's saved
        // display preferences from the very first frame. Mirrors the iOS
        // `GlobalPreferenceSync` `.onAppear` seeding.
        preferenceSync = MacGlobalPreferenceSync(gobanState: session.gobanState)

        w.contentViewController = MainSplitViewController(
            session: session,
            navigationContext: navigationContext,
            audioModel: audioModel,
            libraryStore: libraryStore,
            readiness: boardReadiness,
            engineLaunchStatus: engineLaunchStatus,
            windowController: self
        )
        w.titlebarAppearsTransparent = false
        w.toolbarStyle = .unified

        let toolbar = NSToolbar(identifier: "KataGoAnytimeMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        w.toolbar = toolbar

        w.center()
        // Remember the windowed size/position across launches. If a frame was
        // saved under this name, this applies it (overriding the center() above);
        // on the first-ever launch there's none, so the centered 1100×720 stands.
        // The full-screen state is remembered separately (see
        // `restoreWindowStateOnLaunch` + the full-screen delegate callbacks).
        w.setFrameAutosaveName("KataGoAnytimeMainWindow")

        // Install before the engine starts so the first `true -> false`
        // `waitingForAnalysis` transition isn't missed. That first analyze is
        // kicked downstream of the hosted `BoardView`'s `showboard` round-trip:
        // `maybeCollectBoard` sets `player.nextColorForPlayCommand`, and
        // `BoardView.onChange(of:)` then calls `maybeRequestAnalysis`, which
        // flips `waitingForAnalysis` true; the engine's first `info` line flips
        // it back to false (parsed in `GameSession.maybeCollectAnalysis`).
        installAnalysisLifecycleObserver()

        // Bridge the two `GobanState` confirmation flags (illegal-move / AI-
        // overwrite) to AppKit NSAlert sheets. The shared `GobanState` already
        // SETS these flags (`GameSession.maybeCollectCheckMove` /
        // `postProcessAIMove`); the Mac app just lacks the iOS dialogs that react
        // to them. Installed right after the analysis observer so the same
        // self-rescheduling pattern is armed before the engine starts.
        installConfirmationObserver()

        // Rebuilds the engine board from the saved SGF when an active branch is
        // exited (committed or discarded) — both end via `deactivateBranch`,
        // flipping `branchSgf` inactive. Mirrors the iOS `GameSplitView`
        // `branchSgf` reload observer (lines 104-107 / 530-535). Installed before
        // the engine starts so the first transition isn't missed.
        installBranchReloadObserver()

        // Port of the iOS auto-play machinery (the Chart tab's wand button drives
        // `gobanState.isAutoPlaying`). iOS reacts via two `GameSplitView`
        // `.onChange` handlers (`onChange(of: isAutoPlaying)` +
        // `onChange(of: stones.isReady)`); this observer is their AppKit stand-in.
        // (The per-move stepping branch — iOS lines 495-525 — lives in the EXISTING
        // analysis observer instead, keyed off `waitingForAnalysis`.) Installed
        // before the engine starts so the first stones-ready transition isn't missed.
        installAutoPlayObserver()

        // Keeps the opening-book lookup walked to the current position so the
        // `.book` overlay (rendered by the hosted `BoardView`) reflects the right
        // node. Reacts to the book `isLoaded` false->true edge and the
        // `eyeStatus -> .book` edge (P6-T5); the stones-ready sync lives in the
        // auto-play observer's `handleStonesReadyChange()`. Mirrors the iOS
        // `GameSplitView` `processBookLoadedChange` / `processEyeStatusChange`
        // handlers. Installed before the engine starts so the first book load
        // isn't missed.
        installBookStateObserver()

        // Clears the crash sentinel once the engine's first GTP response lands
        // (`engineLifecycle.lastLoadedModelTitle` goes `nil -> non-nil`). Installed
        // before the launch so the first response isn't missed. Mirrors the iOS
        // `ModelRunnerView.onChange(of: engineLifecycle.lastLoadedModelTitle)`.
        installLastLoadedModelObserver()

        // Run the launch-time crash-recovery decision ONCE, BEFORE arming the
        // sentinel / launching the engine — it must read the PREVIOUS run's
        // sentinel (`pendingLoadModelTitle`), which `startEngineAndSession()`
        // will overwrite (arm) for THIS run. For the non-banner outcomes this
        // launches the engine immediately; for the banner outcome it defers the
        // launch until the user dismisses the NSAlert sheet (see `decideRecovery`).
        decideRecovery()

        // Arm the LizzieYzy board shortcuts (Space / `,` / `P`). A local monitor —
        // not just the Game/Analysis menu key equivalents — because a bare letter
        // like `P` is otherwise swallowed by the sidebar `NSTableView`'s type-select
        // (jumping to a game beginning with "P") before any menu equivalent fires,
        // and clicking the board does not move first responder off that table.
        installBoardShortcutMonitor()

        #if DEBUG
        scheduleSnapshotIfRequested()
        scheduleAutoPlayTestIfRequested()
        scheduleRelaunchTestIfRequested()
        scheduleAIPlayTestIfRequested()
        #endif
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// UserDefaults key persisting whether the main window was full-screen at last
    /// use, so launch restores the user's last windowed-vs-full-screen choice (the
    /// windowed frame itself is remembered separately via the window's
    /// frame-autosave name, set in `init`).
    private static let wasFullScreenKey = "MainWindow.wasFullScreen"

    /// Restores the user's last windowed-vs-full-screen choice on launch. If the
    /// window was full-screen when last used, re-enter full screen on top of the
    /// restored windowed frame; otherwise leave it windowed. Deferred to the next
    /// run-loop turn so the window is fully on-screen first, and guarded so it
    /// never toggles redundantly. The window already advertises full-screen
    /// support (the View ▸ Enter Full Screen menu item works), so no
    /// `collectionBehavior` change is needed.
    func restoreWindowStateOnLaunch() {
        guard UserDefaults.standard.bool(forKey: Self.wasFullScreenKey) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window else { return }
            if !window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
        }
    }

    // MARK: - Move navigation
    //
    // The toolbar nav group (⏮◀▶⏭) and the Navigate menu (Back/Forward/First/
    // Last) target the first responder with the selectors implemented below.
    // `NSWindowController` is inserted into the window's responder chain (the
    // window owns it via `super.init(window:)`), so these `@objc` actions are
    // reached after the content view / window decline them.
    //
    // Each action reuses `GobanState`'s `backwardMoves` / `forwardMoves`
    // verbatim — the exact calls the iOS `StatusToolbarItems` makes. Single
    // step uses `limit: 1`; First/Last jump with `limit: nil`. iOS also
    // mirrors `maybeUpdateAnalysisData` before navigating to persist analysis
    // data while editing, so we do the same.

    /// Mirrors `StatusToolbarItems.isFunctional`: navigation is only allowed
    /// when the engine isn't generating an AI move, isn't auto-playing, and no
    /// `showboard` round-trip is in flight.
    private var isFunctional: Bool {
        guard let gameRecord = navigationContext.selectedGameRecord else { return false }
        let gobanState = session.gobanState
        return !gobanState.shouldGenMove(config: gameRecord.concreteConfig, player: session.player)
            && !gobanState.isAutoPlaying
            && (gobanState.showBoardCount == 0)
    }

    /// Persists in-progress analysis data (when editing) before navigating,
    /// exactly as iOS does ahead of every back/forward action.
    private func maybeUpdateAnalysisData(gameRecord: GameRecord) {
        session.gobanState.maybeUpdateAnalysisData(
            gameRecord: gameRecord,
            analysis: session.analysis,
            board: session.board,
            stones: session.stones,
            all: false
        )
    }

    private func backward(limit: Int?) {
        guard let gameRecord = navigationContext.selectedGameRecord else { return }
        maybeUpdateAnalysisData(gameRecord: gameRecord)
        guard isFunctional else { return }
        session.gobanState.backwardMoves(
            limit: limit,
            gameRecord: gameRecord,
            messageList: session.messageList,
            player: session.player,
            stones: session.stones
        )
    }

    private func forward(limit: Int?) {
        guard let gameRecord = navigationContext.selectedGameRecord else { return }
        maybeUpdateAnalysisData(gameRecord: gameRecord)
        guard isFunctional else { return }
        session.gobanState.forwardMoves(
            limit: limit,
            gameRecord: gameRecord,
            board: session.board,
            messageList: session.messageList,
            player: session.player,
            audioModel: audioModel,
            stones: session.stones
        )
    }

    /// `← / ◀`: step back one move.
    @objc func goBackward(_ sender: Any?) { backward(limit: 1) }

    /// `→ / ▶`: step forward one move.
    @objc func goForward(_ sender: Any?) { forward(limit: 1) }

    /// `⌥⌘← / ⏮`: jump to the start of the game.
    @objc func goToStart(_ sender: Any?) { backward(limit: nil) }

    /// `⌥⌘→ / ⏭`: jump to the end of the game.
    @objc func goToEnd(_ sender: Any?) { forward(limit: nil) }

    // MARK: Navigation availability

    /// Whether a move exists at `currentIndex - 1` (i.e. we can step/jump back).
    /// Mirrors `backwardMoves`' loop guard (`getMove(at: currentIndex - 1)`).
    private var canGoBackward: Bool {
        guard isFunctional,
              let gameRecord = navigationContext.selectedGameRecord,
              let sgf = session.gobanState.getSgf(gameRecord: gameRecord),
              let currentIndex = session.gobanState.getCurrentIndex(gameRecord: gameRecord) else {
            return false
        }
        return SgfHelper(sgf: sgf).getMove(at: currentIndex - 1) != nil
    }

    /// Whether a move exists at `currentIndex` (i.e. we can step/jump forward).
    /// Mirrors `forwardMoves`' loop guard (`getMove(at: currentIndex)`).
    private var canGoForward: Bool {
        guard isFunctional,
              let gameRecord = navigationContext.selectedGameRecord,
              let sgf = session.gobanState.getSgf(gameRecord: gameRecord),
              let currentIndex = session.gobanState.getCurrentIndex(gameRecord: gameRecord) else {
            return false
        }
        return SgfHelper(sgf: sgf).getMove(at: currentIndex) != nil
    }

    /// Shared availability test for both the Navigate menu items and the
    /// toolbar nav-group subitems, keyed off the action selector.
    private func canPerformNavigation(_ action: Selector?) -> Bool {
        switch action {
        case #selector(goBackward(_:)), #selector(goToStart(_:)):
            return canGoBackward
        case #selector(goForward(_:)), #selector(goToEnd(_:)):
            return canGoForward
        default:
            return true
        }
    }

    // MARK: - Library selection

    /// Switches the board to a game chosen from the Library sidebar. Mirrors the
    /// iOS `GameSplitView.processChange` flow via the reusable
    /// `GobanState.loadGame`. The initial launch load stays in
    /// `initializeSession`; this only runs for genuine post-launch row changes
    /// (identity-different from the currently-selected game).
    func selectGame(_ game: GameRecord?) {
        let previous = navigationContext.selectedGameRecord
        guard game !== previous else { return }

        navigationContext.selectedGameRecord = game
        session.gobanState.loadGame(
            gameRecord: game,
            previous: previous,
            player: session.player,
            bookLookup: session.bookLookup,
            messageList: session.messageList,
            board: session.board,
            stones: session.stones
        )
    }

    // MARK: - Engine launch + session loop

    /// Mirrors the iOS launch (`ModelRunnerView` engine thread + `ContentView`
    /// initialization sequence): start KataGo on a background thread loading the
    /// ACTIVE network (resolved from the persisted `modelSelection`), then run the
    /// version handshake, initial commands, board load and the GTP message loop.
    ///
    /// The engine launch is parameterized by `BackendSettings` (same per-model
    /// UserDefaults the iOS `ModelRunnerView` uses), NOT by the per-game `Config`:
    /// backend device, NN-buffer max board length, exact-NN-len, and the Winograd
    /// tuner flags all come from `BackendSettings`. The per-game `Config` still
    /// drives rules/komi/board size via `loadGame` (`initializeSession`), unchanged.
    private func startEngineAndSession() {
        // Resolve the active model and its file path. A downloaded model that is
        // somehow active but no longer present on disk would yield a nil path;
        // rather than crash, fall back to the built-in net + its bundled path.
        var model = modelSelection.currentModel
        var modelPath = model.builtIn
            ? Bundle.main.path(forResource: "default_model", ofType: "bin.gz")
            : model.downloadedURL?.path()

        if modelPath == nil {
            guard let builtIn = NeuralNetworkModel.builtInModel,
                  let builtInPath = Bundle.main.path(forResource: "default_model", ofType: "bin.gz") else {
                assertionFailure("Built-in model not bundled in the Mac target's Resources.")
                return
            }
            model = builtIn
            modelPath = builtInPath
        }

        guard let modelPath else { return } // unreachable — fallback set it above.

        // Per-model engine settings (backend device, board-size NN buffer, tuner
        // flags). Same UserDefaults keys as iOS.
        var settings = BackendSettings(model: model)

        // Arm the crash sentinel BEFORE starting the engine thread, exactly as
        // the iOS `ModelRunnerView` does (lines 92-94). If the engine
        // OOM-crashes before the first GTP response, this value survives the
        // process death and the NEXT launch's `decideRecovery()` shows the
        // recovery alert instead of restarting the same crash. `reset()` first so
        // the `lastLoadedModelTitle` observer re-fires even when the same model
        // is (re)launched; `synchronize()` flushes the sentinel to disk
        // immediately so an imminent crash can't lose it.
        engineLifecycle.reset()
        modelSelection.pendingLoadModelTitle = model.title
        UserDefaults.standard.synchronize()

        let engineStarted = startKataGoThread(
            modelPath: modelPath,
            deviceAssignments: Self.engineDeviceAssignments,
            maxBoardSizeForNNBuffer: settings.muxMaxBoardLength,
            requireExactNNLen: settings.requireExactNNLen,
            tunerFull: settings.tunerFull,
            reTune: settings.reTune
        )

        // The engine helper failed to spawn. Do NOT start the session loop — it
        // would drive the uninitialized in-process bridge and hang. Surface the
        // failure instead; the app stays responsive.
        guard engineStarted else {
            presentEngineStartFailureAlert()
            return
        }

        // One-shot: consume a pending re-tune so it fires exactly once. The mux
        // always runs MLX/GPU server threads (which read the Winograd tuner
        // flags), so a re-tune request is always consumed here.
        if settings.reTune {
            settings.reTune = false
        }

        let context = modelContainer.mainContext
        let gameRecords = (try? GameRecord.fetchGameRecords(container: modelContainer)) ?? []
        let selected = ensureSelectedGameRecord(gameRecords: gameRecords, context: context)

        sessionTask = Task { @MainActor in
            await initializeSession(model: model, selected: selected, context: context)
        }
    }

    /// The macOS "best throughput" engine mux: 1 MLX/GPU + 2 CoreML/ANE NN
    /// server threads. The 2 ANE threads run unserialized and overlap the GPU
    /// work (all GPU work serializes on `mlxGpuEvalMutex` — one Apple GPU — so a
    /// 2nd GPU thread only adds contention; the throughput win is GPU∥ANE
    /// concurrency). Measured fastest on-device (~1.25× the old single-GPU
    /// default). `0` = MLX/GPU, `100` = CoreML/ANE, matching
    /// `BackendChoice.mlxDeviceToUse`. This replaces the per-model backend picker
    /// on macOS; iOS/visionOS stay single-backend.
    static let engineDeviceAssignments: [Int] = [
        BackendChoice.mlxGPU.mlxDeviceToUse,    // GPU
        BackendChoice.coremlNE.mlxDeviceToUse,  // ANE
        BackendChoice.coremlNE.mlxDeviceToUse,  // ANE
    ]

    /// Spawns the `katago-engine` child process and wires the session's GTP I/O
    /// to it (the macOS replacement for the in-process `KataGoHelper.runGtp`
    /// thread). The child reads model/config paths + `-override-config` flags
    /// from argv. `deviceAssignments` becomes the per-server-thread device mux
    /// (`numNNServerThreadsPerModel` + `mlxDeviceToUseThread<i>`). (Method name
    /// kept for the existing callers.)
    /// Returns `true` if the engine child spawned. On `false` the caller MUST NOT
    /// start the session message loop: on macOS `session.engine` is still the
    /// default in-process bridge, whose global stream buffers were never
    /// initialized (the in-process `runGtp` is not used on macOS), so driving it
    /// would block `getMessageLine` forever and hang the UI.
    @discardableResult
    private func startKataGoThread(modelPath: String,
                                   deviceAssignments: [Int],
                                   maxBoardSizeForNNBuffer: Int,
                                   requireExactNNLen: Bool,
                                   tunerFull: Bool,
                                   reTune: Bool) -> Bool {
        guard let helperURL = SubprocessKataGoEngine.bundledHelperURL else {
            assertionFailure("katago-engine helper is not embedded in the app bundle (Contents/MacOS).")
            return false
        }
        // The parent resolves the bundled human-SL model + GTP config and passes
        // absolute paths to the child (the child's own Bundle.main is the app).
        let humanModelPath = Bundle.main.path(forResource: "b18c384nbt-humanv0", ofType: "bin.gz") ?? ""
        let configPath = Bundle.main.path(forResource: "default_gtp", ofType: "cfg") ?? ""

        let arguments = KataGoEngineArguments.gtp(
            modelPath: modelPath,
            humanModelPath: humanModelPath,
            configPath: configPath,
            deviceAssignments: deviceAssignments,
            numSearchThreads: KataGoHelper.mlxNumSearchThreads,
            nnMaxBatchSize: KataGoHelper.mlxNnMaxBatchSize,
            maxBoardSizeForNNBuffer: maxBoardSizeForNNBuffer,
            requireExactNNLen: requireExactNNLen,
            // macOS: the default ~/.katago home-data dir is writable, so (like
            // the in-process bridge) no homeDataDir override is needed.
            homeDataDir: "",
            tunerFull: tunerFull,
            reTune: reTune)

        let engine = SubprocessKataGoEngine(helperURL: helperURL, arguments: arguments)
        do {
            try engine.start()
        } catch {
            assertionFailure("Failed to spawn katago-engine: \(error)")
            return false
        }
        session.useEngine(engine)
        self.engineProcess = engine
        return true
    }

    /// Critical-failure UX when the engine helper can't spawn (should never
    /// happen in a correctly built/installed bundle). Shown as a sheet so the
    /// app stays responsive instead of hanging on a dead engine.
    private func presentEngineStartFailureAlert() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "The analysis engine couldn’t start."
        alert.informativeText = "KataGo Anytime couldn’t launch its engine helper. Please reopen the app; if this keeps happening, reinstall the app."
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    /// Loads the first persisted `GameRecord`, or creates and inserts a default
    /// 19×19 game when the store is empty, and selects it.
    ///
    /// Relaunch-safe: if a game is ALREADY selected (the common case on relaunch,
    /// where the engine restarts but the user's game shouldn't change), keep it
    /// rather than re-selecting `gameRecords.first` or inserting a new default —
    /// inserting unconditionally would create a duplicate empty game on every
    /// relaunch. Only the empty-store first-launch path inserts a default.
    private func ensureSelectedGameRecord(gameRecords: [GameRecord],
                                          context: ModelContext) -> GameRecord {
        if let current = navigationContext.selectedGameRecord {
            return current
        }
        if let first = gameRecords.first {
            navigationContext.selectedGameRecord = first
            return first
        }
        let newGame = GameRecord.createGameRecord()
        context.insert(newGame)
        navigationContext.selectedGameRecord = newGame
        return newGame
    }

    private func initializeSession(model: NeuralNetworkModel,
                                   selected: GameRecord,
                                   context: ModelContext) async {
        // Mirror `ContentView.initializationTask`: handshake → initial commands.
        await session.initialize(
            selectedModelTitle: model.title,
            engineLifecycle: engineLifecycle,
            config: selected.concreteConfig
        )

        selected.updateToLatestVersion()
        if selected.concreteConfig.isBookCompatible {
            session.bookLookup.loadIfNeeded()
        }

        session.gobanState.maybeLoadSgf(
            gameRecord: selected,
            messageList: session.messageList
        )
        session.gobanState.sendShowBoardCommand(messageList: session.messageList)
        session.messageList.appendAndSend(command: "printsgf")

        let gameRecords = (try? GameRecord.fetchGameRecords(container: modelContainer)) ?? []

        // Drain one line (the iOS app does a single `messaging` then sleeps) and
        // then enter the steady-state loop.
        await session.messaging(
            gameRecords: gameRecords,
            modelContext: context,
            navigationContext: navigationContext,
            audioModel: audioModel,
            aiMove: aiMoveBox.binding
        )

        // The engine handshake + initial board load are done. Mount the live
        // board now (mirrors iOS setting `isInitialized` after `initialize()`):
        // `BoardView.onAppear` then sends its `showboard` while the run loop below
        // is active to consume the response, so `showBoardCount` stays balanced
        // and the `nextColorForPlayCommand` change drives the first analyze.
        boardReadiness.isEngineReady = true

        await session.run(
            gameRecords: gameRecords,
            modelContext: context,
            navigationContext: navigationContext,
            audioModel: audioModel,
            aiMove: aiMoveBox.binding
        )
    }

    // MARK: - Engine teardown + relaunch (Phase 5 model switching)
    //
    // The Mac app launches KataGo at window init and relaunches it on model
    // switch. The engine is now an OUT-OF-PROCESS `katago-engine` child, which
    // makes teardown clean: quitting the child closes its stdout, and that real
    // EOF unblocks the run loop's suspended `getMessageLine` (the
    // `SubprocessKataGoEngine` reports `hasReachedEOF`, so `GameSession.messaging`
    // observes EOF and stops). No "\n" nudge / shared-global-buffer juggling
    // (that was needed only by the in-process bridge, whose global streams never
    // EOF). Because `GameSession` is reused across relaunch, we AWAIT the old
    // run-loop Task (`sessionTask`) before `startEngineAndSession()` wires in a
    // new engine — so there are never two concurrent `run()` loops.

    /// Tears down the running engine + session so a fresh engine can be launched.
    /// Async so it can await the old run loop's completion cooperatively.
    ///
    /// Ordering:
    ///   1. `stopRequested = true` first, so `messaging`'s per-line guard skips
    ///      the engine's quit-response lines and `run()` exits on its next check.
    ///   2. `sendCommand("quit")` + `terminate()` → the child exits and EOFs its
    ///      stdout, unblocking the consumer's suspended `getMessageLine`.
    ///   3. `await sessionTask` → guarantees the old `run()` loop finished before
    ///      a new engine is injected (no two concurrent loops on one session).
    ///   4. Reset all per-launch state and re-seed the observer snapshots so the
    ///      existing `withObservationTracking` observers don't fire spurious
    ///      transitions against stale `lastX` values on the fresh engine.
    private func stopEngineAndSession() async {
        // (1) End the GTP message loop. `messaging`'s `if !stopRequested` guard
        // and `run`'s `while !stopRequested` both collapse on this.
        session.stopRequested = true

        // (2) Ask the engine to quit, then force the child down. Closing its
        // stdin (and SIGTERM if needed) makes the child exit, which EOFs its
        // stdout — that is what unblocks the run loop's suspended
        // `getMessageLine` (no in-process "\n" nudge needed out-of-process).
        // terminate() is synchronous (brief), so run it OFF the main actor to
        // keep the UI responsive and to let the run loop's main-actor
        // continuation make progress once EOF arrives.
        engineProcess?.sendCommand("quit")
        if let engine = engineProcess {
            await Task.detached { engine.terminate() }.value
        }

        // (3) Await the old run loop's completion before wiring a new engine —
        // `GameSession` is reused across relaunch, so the old loop (which reads
        // through `session.engine`) must finish first. The child's EOF lets it
        // observe `stopRequested` and exit; this Task then completes.
        await sessionTask?.value
        sessionTask = nil

        // (4) Reset for the next launch.
        boardReadiness.isEngineReady = false
        session.stopRequested = false
        engineLifecycle.reset()
        engineProcess = nil

        // Re-seed the observer snapshots from the LIVE state so the still-armed
        // `withObservationTracking` observers don't interpret the fresh engine's
        // first mutations as spurious transitions. We do NOT re-register tracking
        // here — the observers self-reschedule; we only refresh the `lastX`
        // values they diff against.
        reseedObservers()
    }

    /// Refreshes the `lastX` observer snapshots from the current `gobanState` /
    /// `stones` WITHOUT re-registering `withObservationTracking` (the observers
    /// reschedule themselves on every callback, so double-registering would arm a
    /// second, redundant tracking closure). Used by `stopEngineAndSession()` so a
    /// relaunch's fresh engine doesn't replay stale transitions. Mirrors exactly
    /// the seeding the three `installX` methods do up front.
    private func reseedObservers() {
        let gobanState = session.gobanState
        lastWaitingForAnalysis = gobanState.waitingForAnalysis
        lastAnalysisStatus = gobanState.analysisStatus
        lastConfirmingIllegalMove = gobanState.confirmingIllegalMove
        lastConfirmingAIOverwrite = gobanState.confirmingAIOverwrite
        lastConfirmingBranchDeactivation = gobanState.confirmingBranchDeactivation
        lastConfirmingBranchReplace = gobanState.confirmingBranchReplace
        lastConfirmingBranchDiscard = gobanState.confirmingBranchDiscard
        lastIsAutoPlaying = gobanState.isAutoPlaying
        lastStonesReady = session.stones.isReady
        lastIsEditing = gobanState.isEditing
        // Re-seed the branch-reload snapshot too, so a relaunch's fresh engine
        // (which reloads the board itself) doesn't spuriously fire the reload
        // observer on an unrelated `branchSgf` value carried across the relaunch.
        lastBranchSgf = gobanState.branchSgf
        // Re-seed the book-state snapshots so the still-armed observer doesn't read
        // a relaunch's fresh book-load / eye-status as a spurious edge.
        lastBookLoaded = session.bookLookup.isLoaded
        lastEyeStatus = gobanState.eyeStatus
    }

    /// Switches the active model and relaunches the engine in-process. Records
    /// `model` as the authoritative user selection (`modelSelection.setActiveModel`)
    /// BEFORE tearing the old engine down, so the fresh `startEngineAndSession()`
    /// resolves `modelSelection.currentModel == model` and launches it via
    /// `BackendSettings` (P5-T2). This makes `relaunch(.builtIn)` and
    /// `relaunch(otherDownloadedNet)` both genuinely switch.
    ///
    /// `startEngineAndSession()` re-runs the FULL init (handshake →
    /// showboard/printsgf → messaging → run) and re-gates
    /// `boardReadiness.isEngineReady` true after init, so the board re-mounts and
    /// analysis re-arms exactly as on first launch. A fresh `initializeSession`
    /// Task is started there, after `stopEngineAndSession()` has confirmed the old
    /// `run()` loop ended — so there are never two concurrent `run()` loops.
    ///
    /// NOTE: arming/clearing the crash sentinel (`pendingLoadModelTitle`) around
    /// this launch is P5-T4's job; this method only records the selection.
    func relaunch(model: NeuralNetworkModel) {
        modelSelection.setActiveModel(model)
        Task { @MainActor in
            await stopEngineAndSession()
            startEngineAndSession()
        }
    }

    // MARK: - Models window (P5-T7 / P5-T8)

    /// Retains the lazily-created Models window controller so it isn't
    /// deallocated while on screen. Cleared is unnecessary — the controller is
    /// cheap and reused across opens.
    private var modelsWindowController: ModelsWindowController?

    /// Opens (or brings forward) the native Models window. Reached through the
    /// responder chain from the Window-menu "Manage Models…" item (and, later,
    /// the P5-T6 toolbar dropdown). The window's "Set Active" path routes back
    /// into `relaunch(model:)` to switch the active net + relaunch the engine;
    /// the "Active" badge reads the live `modelSelection.currentModel`.
    @objc func showModelsWindow(_ sender: Any?) {
        if modelsWindowController == nil {
            modelsWindowController = ModelsWindowController(
                currentModelTitle: { [weak self] in
                    self?.modelSelection.currentModel.title ?? ""
                },
                onSetActive: { [weak self] model in
                    self?.relaunch(model: model)
                }
            )
        }
        modelsWindowController?.showWindow(sender)
        modelsWindowController?.window?.makeKeyAndOrderFront(sender)
    }

    // MARK: - Settings window (P5-T11)

    /// Retains the lazily-created Settings window controller so it isn't
    /// deallocated while on screen. Reused across opens (it reads/writes the
    /// live `session.gobanState`, so it always reflects the current state).
    private var settingsWindowController: SettingsWindowController?

    /// Opens (or brings forward) the native Settings window (⌘,). Reached
    /// through the responder chain from the app menu's "Settings…" item, which
    /// targets `Selector(("showSettings:"))` — `NSWindowController` is in the
    /// window's responder chain, so this `@objc` action is what activates that
    /// menu item. The window's controls read/WRITE `session.gobanState`;
    /// `MacGlobalPreferenceSync` persists those changes (single writer).
    @objc func showSettings(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(session: session)
        }
        settingsWindowController?.showWindow(sender)
        settingsWindowController?.window?.makeKeyAndOrderFront(sender)
    }

    // MARK: - Launch-time crash recovery (P5-T5)
    //
    // Port of the iOS `ModelRunnerView` `.onAppear` recovery branch
    // (ModelRunnerView.swift lines 41-70) + the `lastLoadedModelTitle` clear
    // (lines 115-119), adapted for AppKit. iOS has a picker screen at launch;
    // macOS does not, so where iOS would `.showPicker` / show a banner, the Mac
    // app falls back to launching the BUILT-IN net (never re-launching a model
    // that apparently just crashed).
    //
    // Ordering is the crux: the decision reads `pendingLoadModelTitle` /
    // `selectedModelTitle` reflecting the PREVIOUS run, and must run BEFORE
    // `startEngineAndSession()` arms `pendingLoadModelTitle` for THIS run. So
    // `init` calls `decideRecovery()` (not `startEngineAndSession()` directly):
    //   • `.autoRestore` / `.showPicker` -> launch immediately.
    //   • `.showPickerWithBanner` (a prior load crashed) -> DEFER launch until
    //     the user dismisses the NSAlert sheet; both alert buttons fall back to
    //     the built-in net for safety (never retry the crashing model on Mac).

    /// Runs the launch-time recovery decision exactly once and either launches
    /// the engine immediately or defers to the recovery alert. Guarded by
    /// `hasDecidedRecovery` so scene/relaunch transitions can't re-run it.
    private func decideRecovery() {
        guard !hasDecidedRecovery else { return }
        hasDecidedRecovery = true

        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif

        // These reflect the PREVIOUS run (set by the last launch's arming /
        // first-response clear); `startEngineAndSession()` overwrites `pending`
        // for THIS run only after the decision below.
        let pending = modelSelection.pendingLoadModelTitle
        let selected = modelSelection.selectedModelTitle

        switch RecoveryDecision.decide(
            pendingLoadModelTitle: pending,
            selectedModelTitle: selected,
            isDebug: isDebug
        ) {
        case .autoRestore:
            // `modelSelection.currentModel` already resolves the active model
            // from `selectedModelTitle`, so a normal launch restores it.
            startEngineAndSession()

        case .showPicker:
            // Fresh install / DEBUG: macOS has no launch picker, so default to
            // the built-in net.
            if let builtIn = NeuralNetworkModel.builtInModel {
                modelSelection.setActiveModel(builtIn)
            }
            startEngineAndSession()

        case .showPickerWithBanner:
            // A prior load apparently crashed before the engine ever responded.
            // Do NOT launch yet — present the recovery alert once the window is
            // on screen; its completion launches the built-in net.
            recoveryLogger.error(
                "Recovered from apparent crash loading model: \(pending, privacy: .public)"
            )
            presentRecoveryAlert(pending: pending)
        }
    }

    /// Presents the crash-recovery NSAlert as a SHEET on the window, then (in the
    /// completion) clears the sentinel and launches the BUILT-IN net regardless of
    /// which button was chosen — on Mac we never retry the crashing model. Mirrors
    /// the spec's locked decision. The window is on screen by the time `init`
    /// returns and `showWindow` runs, but we defer to the next run-loop turn so
    /// the sheet attaches to a presented window; if there's still no window we
    /// fall back to a windowless built-in launch.
    private func presentRecoveryAlert(pending: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let window = self.window else {
                // No window to host the sheet — clear the sentinel and launch the
                // built-in net so the app isn't left engine-less.
                self.recoverWithBuiltIn()
                return
            }

            let alert = NSAlert()
            alert.messageText = "Loading “\(pending)” may not have finished last time."
            alert.informativeText =
                "The app restarted before that network finished loading, which can "
                + "happen if it ran out of memory. To be safe, the built-in network "
                + "will be used instead. You can switch networks again from the "
                + "Models window."
            // First-added button is the default (rightmost / return-key).
            alert.addButton(withTitle: "Use Built-in Network")
            alert.addButton(withTitle: "Choose Later")

            alert.beginSheetModal(for: window) { [weak self] _ in
                // BOTH responses fall back to the built-in net — never retry the
                // model that apparently crashed.
                self?.recoverWithBuiltIn()
            }
        }
    }

    /// Clears the crash sentinel, makes the built-in net the active model, and
    /// launches it. Used by both recovery-alert buttons and the no-window path.
    private func recoverWithBuiltIn() {
        recoveryLogger.notice("Crash recovery: falling back to the built-in network.")
        modelSelection.pendingLoadModelTitle = ""
        if let builtIn = NeuralNetworkModel.builtInModel {
            modelSelection.setActiveModel(builtIn)
        }
        startEngineAndSession()
    }

    // MARK: - First-response sentinel clear (P5-T4)
    //
    // Port of the iOS `ModelRunnerView.onChange(of: engineLifecycle.lastLoadedModelTitle)`
    // (lines 115-119): when the engine's first GTP response lands,
    // `GameSession.initialize` calls `engineLifecycle.markFirstResponse(...)`,
    // which sets `lastLoadedModelTitle`. On that `nil -> non-nil` transition we
    // record the title as the last-good selection and CLEAR the crash sentinel.
    // Same self-rescheduling `withObservationTracking` pattern (and gotchas) as
    // the other observers; `lastLoadedModelTitle` is one-way per launch
    // (`reset()` -> nil before each launch, set once on first response), so the
    // snapshot diff just detects that single edge.

    /// Seeds the snapshot from the live `engineLifecycle` and starts the
    /// self-rescheduling observation bridge. Called once in `init`.
    private func installLastLoadedModelObserver() {
        lastLoadedModelTitle = engineLifecycle.lastLoadedModelTitle
        trackLastLoadedModel()
    }

    /// One observation pass: tracks `lastLoadedModelTitle`, and on change re-reads
    /// the committed value on the main actor, reacts, then re-arms (one-shot).
    private func trackLastLoadedModel() {
        withObservationTracking {
            _ = engineLifecycle.lastLoadedModelTitle
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.handleLastLoadedModelChange()
                self.trackLastLoadedModel()
            }
        }
    }

    /// On `lastLoadedModelTitle` becoming non-nil, persist it as the last-good
    /// selection and clear the crash sentinel (mirrors ModelRunnerView lines
    /// 116-118). Refreshes the snapshot at the end.
    private func handleLastLoadedModelChange() {
        let newValue = engineLifecycle.lastLoadedModelTitle
        if let title = newValue {
            modelSelection.selectedModelTitle = title
            modelSelection.pendingLoadModelTitle = ""
        }
        lastLoadedModelTitle = newValue
    }

    // MARK: - Continuous analysis lifecycle
    //
    // `GameSession` only PARSES `kata-analyze` output (setting
    // `gobanState.waitingForAnalysis` in `maybeCollectAnalysis`); it never sends
    // `kata-analyze`/`stop` itself. On iOS that lifecycle is host-driven by two
    // SwiftUI `.onChange` handlers in `GameSplitView`; the AppKit
    // `MainWindowController` is not a SwiftUI view, so without these the overlay
    // would populate once and go stale. This mirrors those two handlers:
    //
    //   • `GameSplitView` lines 414-418 (`processAnalysisStatusChange`): on entry
    //     into `.clear`, send `stop`.
    //   • `GameSplitView` lines 483-493 (`processChange(oldWaitingForAnalysis:…)`):
    //     on a `true -> false` transition of `waitingForAnalysis`, IF there is a
    //     selected game and `!shouldGenMove`, re-arm by sending `stop` (when
    //     paused) or `config.getKataAnalyzeCommand()`. iOS's extra auto-play
    //     forward logic (lines 495-525) is intentionally NOT ported — macOS has
    //     no auto-play UI yet.
    //
    // `withObservationTracking`'s `onChange` is the AppKit-side stand-in for
    // `.onChange`, with two gotchas this method handles:
    //   1. It fires exactly ONCE per tracked-property change and is invoked
    //      *before* the new value is committed, so we hop to `Task { @MainActor }`
    //      to read the post-change values, and we RE-REGISTER tracking on every
    //      callback (otherwise observation stops after the first change).
    //   2. It doesn't say WHICH property changed, so we keep `lastWaitingForAnalysis`
    //      / `lastAnalysisStatus` snapshots to detect the specific transitions and
    //      update them at the end of each pass.
    //
    // There is a tiny window between a tracked mutation committing and the
    // deferred `Task` re-registering tracking; a change landing in it isn't
    // observed. Correctness survives this because the handler re-reads LIVE
    // `gobanState` values (not whatever `onChange` "saw"), so a coalesced second
    // mutation is still caught on the next pass. All mutation sites are
    // `@MainActor`, and `GameSession.messaging` suspends on `await Task.detached`
    // per line, draining the re-arm `Task` before the next analysis line lands.
    //
    // Reacting sends raw GTP via `appendAndSend` directly (not `requestAnalysis`),
    // which does NOT mutate `waitingForAnalysis`/`analysisStatus`, so there is no
    // self-trigger loop. (`maybeCollectAnalysis` flips `waitingForAnalysis` back
    // to `true` only when the engine's next analysis line arrives.)

    /// Seeds the snapshots from the live `gobanState` and starts the
    /// self-rescheduling observation bridge. Called once, early in `init`.
    private func installAnalysisLifecycleObserver() {
        let gobanState = session.gobanState
        lastWaitingForAnalysis = gobanState.waitingForAnalysis
        lastAnalysisStatus = gobanState.analysisStatus
        trackAnalysisLifecycle()
    }

    /// One observation pass: registers tracking of both properties, and on change
    /// re-reads the committed values on the main actor, reacts, then re-arms.
    private func trackAnalysisLifecycle() {
        withObservationTracking {
            // Touch both properties so a change to either fires `onChange`.
            _ = session.gobanState.waitingForAnalysis
            _ = session.gobanState.analysisStatus
        } onChange: { [weak self] in
            // `onChange` runs before the mutation commits; defer to read the new
            // values, react, then re-register (tracking is one-shot).
            Task { @MainActor in
                guard let self else { return }
                self.handleAnalysisLifecycleChange()
                self.trackAnalysisLifecycle()
            }
        }
    }

    /// Applies the iOS `GameSplitView` analyze re-arm / stop decision based on the
    /// transitions detected against the snapshots, then refreshes the snapshots.
    private func handleAnalysisLifecycleChange() {
        let gobanState = session.gobanState
        let newWaitingForAnalysis = gobanState.waitingForAnalysis
        let newAnalysisStatus = gobanState.analysisStatus

        // Mirror `processAnalysisStatusChange` (lines 414-418): on entry into
        // `.clear`, stop the running analysis.
        if newAnalysisStatus == .clear && lastAnalysisStatus != .clear {
            session.messageList.appendAndSend(command: "stop")
        }

        // Mirror `processChange(oldWaitingForAnalysis:newWaitingForAnalysis:)`
        // (lines 483-493): on a `true -> false` transition, re-arm continuous
        // analysis (or stop, when paused) for the selected game.
        if lastWaitingForAnalysis && !newWaitingForAnalysis {
            if let gameRecord = navigationContext.selectedGameRecord,
               !gobanState.shouldGenMove(config: gameRecord.concreteConfig, player: session.player) {
                if gobanState.analysisStatus == .pause {
                    session.messageList.appendAndSend(command: "stop")
                } else {
                    session.messageList.appendAndSend(
                        command: gameRecord.concreteConfig.getKataAnalyzeCommand())
                }

                // Auto-play stepping (port of `GameSplitView` lines 495-525,
                // nested in the same `true -> false` / selected-game / !shouldGenMove
                // block on iOS). While auto-playing, once the engine has produced an
                // analysis for the current position and the board stones are settled,
                // persist that analysis (fills `scoreLeads`/`winRates` for the move)
                // and advance to the next SGF move; when none remains, stop the loop.
                // The advance plays a stone but goes through `gobanState.play`/
                // `sendShowBoardCommand`, NOT `requestAnalysis`, so it does not itself
                // flip `waitingForAnalysis`. NOTE: during auto-play `analysisStatus`
                // is `.pause`, so the re-arm branch above sends `stop` (not analyze);
                // the NEXT position's analysis is re-armed by the hosted
                // `BoardView.onChange(of: player.nextColorForPlayCommand)` (fired by
                // the `toggleNextColorForPlayCommand()` below) -> `maybeRequestAnalysis`.
                // That next `info` line is the next `true -> false` edge, and the
                // `sendShowBoardCommand` round-trip's `stones.isReady` false->true edge
                // is what the auto-play observer turns into `currentIndex += 1`. The
                // terminal `getMove` miss sets `isAutoPlaying = false`, ending the loop.
                if gobanState.isAutoPlaying,
                   !session.analysis.info.isEmpty,
                   session.stones.isReady {
                    gobanState.maybeUpdateAnalysisData(
                        gameRecord: gameRecord,
                        analysis: session.analysis,
                        board: session.board,
                        stones: session.stones
                    )

                    // forward move
                    let sgfHelper = SgfHelper(sgf: gameRecord.sgf)

                    if let nextMove = sgfHelper.getMove(at: gameRecord.currentIndex),
                       let move = session.board.locationToMove(location: nextMove.location) {
                        let nextPlayer = nextMove.player == Player.black ? "b" : "w"

                        gobanState.play(
                            turn: nextPlayer,
                            move: String(move),
                            messageList: session.messageList,
                            stones: session.stones
                        )

                        session.player.toggleNextColorForPlayCommand()
                        gobanState.sendShowBoardCommand(messageList: session.messageList)
                        audioModel.playPlaySound(soundEffect: gobanState.soundEffect)
                        gobanState.isAutoPlayed = true
                    } else {
                        gobanState.isAutoPlaying = false
                        gobanState.isAutoPlayed = false
                    }
                }
            }
        }

        lastWaitingForAnalysis = newWaitingForAnalysis
        lastAnalysisStatus = newAnalysisStatus

        // Keep the toolbar's Analyze button in sync with `analysisStatus` from
        // EVERY path that mutates it — the `toggleAnalysis` action, a future
        // Analysis menu, and the overwrite-cancel path a later task adds — by
        // refreshing here, since they all funnel an `analysisStatus` change
        // through this observer.
        refreshAnalyzeToolbarItem()
    }

    // MARK: - Auto-play
    //
    // Ports the iOS auto-play machinery (`GameSplitView`) so the Chart tab's wand
    // button — which sets `gobanState.isEditing = true; isAutoPlaying.toggle()` —
    // actually re-runs the loaded game, refilling `gameRecord.scoreLeads` /
    // `winRates` move-by-move. iOS wires this with three `.onChange` handlers; on
    // macOS the host is this `NSWindowController`, so two of them become a
    // self-rescheduling `withObservationTracking` observer here (the SAME pattern
    // as the analysis / confirmation observers), and the third (the per-move
    // stepping branch) lives in `handleAnalysisLifecycleChange()` above since it
    // keys off `waitingForAnalysis`. The two handled here:
    //
    //   • `processIsAutoPlayingChange` (iOS `GameSplitView` lines 295-349): on
    //     `isAutoPlaying` becoming TRUE — pause analysis, open the eye, deactivate
    //     any branch, rewind to the game start, install the "AI" profile, and send
    //     post-execution commands. On becoming FALSE — clear analysis, restore the
    //     human profile, and forward to recover `currentIndex`.
    //   • `processStonesReadyChange` (iOS lines 268-293): on `stones.isReady`
    //     going `false -> true` with a selected game, persist the current stones
    //     into the record and, when an auto-play step just landed, bump
    //     `currentIndex`. (iOS's `syncBookState()` is a Phase 6 concern — see TODO.)
    //
    // Same `withObservationTracking` gotchas as the other observers: `onChange`
    // fires ONCE per tracked-property change, BEFORE the mutation commits, and
    // doesn't say which property changed. So we hop to `Task { @MainActor }`, read
    // LIVE committed values, react, update both snapshots, and re-register tracking
    // (it's one-shot). iOS's `onChange(of: isAutoPlaying)` reacts to either edge
    // (`old != new`); `onChange(of: stones.isReady)` only to `false -> true`.
    //
    // Re-entrancy: handler (1)'s TRUE branch mutates `analysisStatus`/`eyeStatus`
    // (both tracked by OTHER observers) and the stones via `undo`. None of those
    // observers re-enter this one, and this observer's reactions send raw GTP /
    // mutate state without itself flipping `isAutoPlaying` (except the explicit
    // terminal `false`, handled by the stepping branch, not here). The stepping
    // loop's terminal condition (`getMove` miss -> `isAutoPlaying = false`)
    // guarantees the cycle stops. See the orchestrator notes for the full trace.

    /// Seeds the snapshots from the live state and starts the self-rescheduling
    /// observation bridge for `isAutoPlaying` + `stones.isReady`. Called once in
    /// `init`, right after `installConfirmationObserver()`.
    private func installAutoPlayObserver() {
        lastIsAutoPlaying = session.gobanState.isAutoPlaying
        lastStonesReady = session.stones.isReady
        lastIsEditing = session.gobanState.isEditing
        trackAutoPlay()
    }

    /// One observation pass: registers tracking of the properties, and on change
    /// re-reads the committed values on the main actor, reacts, then re-arms.
    private func trackAutoPlay() {
        withObservationTracking {
            // Touch each property so a change to any fires `onChange`.
            _ = session.gobanState.isAutoPlaying
            _ = session.stones.isReady
            _ = session.gobanState.isEditing
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.handleAutoPlayChange()
                self.trackAutoPlay()
            }
        }
    }

    /// Detects which transition occurred against the snapshots and ports the
    /// matching iOS handler, then refreshes both snapshots.
    private func handleAutoPlayChange() {
        let gobanState = session.gobanState
        let newIsAutoPlaying = gobanState.isAutoPlaying
        let newStonesReady = session.stones.isReady

        // iOS `onChange(of: gobanState.isAutoPlaying)` -> `processIsAutoPlayingChange`
        // reacts to ANY change (it reads the live `isAutoPlaying` rather than the
        // edge), so mirror with `old != new`.
        if newIsAutoPlaying != lastIsAutoPlaying {
            handleIsAutoPlayingChange()
        }

        // iOS `onChange(of: stones.isReady)` -> `processStonesReadyChange` reacts
        // only on the `false -> true` transition.
        if newStonesReady && !lastStonesReady {
            handleStonesReadyChange()
        }

        // iOS `onChange(of: gobanState.isEditing)` -> `processIsEditingChange`:
        // leaving edit mode cancels auto-play (parity + safety — guarantees the
        // loop can't be left running with no edit session). iOS lines 351-356.
        if !gobanState.isEditing && lastIsEditing {
            gobanState.isAutoPlaying = false
            gobanState.isAutoPlayed = false
        }

        lastIsAutoPlaying = gobanState.isAutoPlaying
        lastStonesReady = session.stones.isReady
        lastIsEditing = gobanState.isEditing
    }

    /// Port of `GameSplitView.processIsAutoPlayingChange` (iOS lines 295-349).
    /// Reads the LIVE `isAutoPlaying` exactly as iOS does (the handler branches on
    /// `gobanState.isAutoPlaying`, not the captured old/new pair). Uses
    /// `concreteConfig` everywhere for consistency with the rest of this file
    /// (iOS reads `gameRecord.config` optionally in the FALSE branch).
    private func handleIsAutoPlayingChange() {
        let gobanState = session.gobanState

        if gobanState.isAutoPlaying,
           let gameRecord = navigationContext.selectedGameRecord {
            gobanState.analysisStatus = .pause
            gobanState.eyeStatus = .opened
            gobanState.deactivateBranch()

            // Rewind to the start of the game (mirrors iOS's `while ... undo()`).
            let sgfHelper = SgfHelper(sgf: gameRecord.sgf)
            while sgfHelper.getMove(at: gameRecord.currentIndex - 1) != nil {
                gameRecord.undo()
                gobanState.undo(messageList: session.messageList, stones: session.stones)
                session.player.toggleNextColorForPlayCommand()
            }

            // auto-play analysis by best AI profile
            if let humanSLModel = HumanSLModel(profile: "AI") {
                session.messageList.appendAndSend(commands: humanSLModel.commands)
                session.messageList.appendAndSend(command: "kata-set-param playoutDoublingAdvantage 0")
                session.messageList.appendAndSend(command: "kata-set-param analysisWideRootNoise 0")
            }

            gobanState.sendPostExecutionCommands(
                config: gameRecord.concreteConfig,
                messageList: session.messageList,
                player: session.player
            )
        } else {
            gobanState.analysisStatus = .clear

            // restore human profile for the next player
            if let gameRecord = navigationContext.selectedGameRecord {
                let config = gameRecord.concreteConfig
                gobanState.maybeSendAsymmetricHumanAnalysisCommands(
                    nextColorForPlayCommand: session.player.nextColorForPlayCommand,
                    config: config,
                    messageList: session.messageList)

                session.messageList.appendAndSend(command: config.getKataPlayoutDoublingAdvantageCommand())
                session.messageList.appendAndSend(command: config.getKataAnalysisWideRootNoiseCommand())

                // current index might not be correct, recover it
                gobanState.forwardMoves(
                    limit: nil,
                    gameRecord: gameRecord,
                    board: session.board,
                    messageList: session.messageList,
                    player: session.player,
                    audioModel: audioModel,
                    stones: session.stones)
            }
        }
    }

    /// Port of `GameSplitView.processStonesReadyChange` (iOS lines 268-293).
    /// Persists the just-settled stones into the record at the current index and,
    /// when an auto-play step just played, advances `currentIndex`. Ends by
    /// re-syncing the opening-book state (P6-T5), exactly as iOS does (line 291).
    ///
    /// CAVEAT: this is the one observed edge whose miss is NOT self-correcting. The
    /// `withObservationTracking` re-arm gap (see `handleAnalysisLifecycleChange`'s
    /// note) is harmless for `waitingForAnalysis` (re-read live + self-correct), but
    /// a dropped `stones.isReady` false->true edge during auto-play would skip one
    /// `currentIndex += 1`, permanently mis-indexing later `scoreLeads`/`winRates`
    /// writes. In practice the edges are spaced by full `showboard` round-trips and
    /// the re-arm `Task` drains on `messaging`'s per-line `await` well before the
    /// next edge, so a miss is not reachable in this flow — but auto-play is the one
    /// path to revisit if that assumption ever changes.
    private func handleStonesReadyChange() {
        let gobanState = session.gobanState
        guard let gameRecord = navigationContext.selectedGameRecord else { return }

        let currentIndex = gameRecord.currentIndex

        gameRecord.blackStones?[currentIndex] = BoardPoint.toString(
            session.stones.blackPoints,
            width: Int(session.board.width),
            height: Int(session.board.height)
        )

        gameRecord.whiteStones?[currentIndex] = BoardPoint.toString(
            session.stones.whitePoints,
            width: Int(session.board.width),
            height: Int(session.board.height)
        )

        if gobanState.isAutoPlayed {
            gameRecord.currentIndex += 1
        }

        // Sync book state after undo/forward/backward (mirrors iOS line 291).
        syncBookState()
    }

    // MARK: - Opening-book state sync (P6-T5)
    //
    // Port of `GameSplitView.syncBookState()` (GameSplitView.swift lines 537-565).
    // The hosted `BoardView` already RENDERS the book overlay + win-rate bar when
    // `gobanState.eyeStatus == .book`; this just keeps `session.bookLookup` walked
    // to the current position so that overlay reflects the right book node. iOS
    // calls it from three places — stones-ready, the book `isLoaded` false->true
    // edge, and the `eyeStatus -> .book` edge — and so do we (the stones-ready
    // call is in `handleStonesReadyChange()`; the two edges are dedicated
    // observers below). `withAnimation` is dropped: there is no SwiftUI animation
    // transaction in an `NSWindowController`, and `syncFromMoves` is a pure data
    // walk — the overlay animates from the hosted SwiftUI side regardless.

    /// Replays the book lookup to the current move index so the `.book` overlay
    /// reflects the right node. Mirrors `GameSplitView.syncBookState()`: a
    /// `justAdvanced` hint short-circuits (the book already advanced itself during
    /// a play, so re-walking would be redundant), otherwise it is gated on a
    /// selected, book-compatible game with a loaded book, then walks moves
    /// `0..<currentIndex` from the authoritative SGF.
    private func syncBookState() {
        let bookLookup = session.bookLookup

        if bookLookup.justAdvanced {
            bookLookup.clearJustAdvanced()
            return
        }

        guard let gameRecord = navigationContext.selectedGameRecord,
              gameRecord.concreteConfig.isBookCompatible,
              bookLookup.isLoaded else {
            return
        }

        let gobanState = session.gobanState
        let sgf = gobanState.getSgf(gameRecord: gameRecord) ?? gameRecord.sgf
        let currentIndex = gobanState.getCurrentIndex(gameRecord: gameRecord) ?? gameRecord.currentIndex
        let sgfHelper = SgfHelper(sgf: sgf)
        let width = Int(session.board.width)
        let height = Int(session.board.height)

        var moves: [BoardPoint] = []
        for i in 0..<currentIndex {
            if let move = sgfHelper.getMove(at: i) {
                moves.append(BoardPoint(location: move.location, width: width, height: height))
            }
        }

        bookLookup.syncFromMoves(moves, boardWidth: width, boardHeight: height)
    }

    // MARK: - Book-loaded + eye-status observers (P6-T5)
    //
    // iOS reacts to two `GameSplitView` `.onChange` handlers that the Mac app is
    // missing because it hosts `BoardView` but not `GameSplitView`:
    //   • `processBookLoadedChange` (line 420-424): on the book `isLoaded`
    //     false->true edge, sync the book state (the book finished loading after a
    //     book-compatible game was already selected — walk it to the current move).
    //   • `processEyeStatusChange` (line 426-430): on `eyeStatus` becoming `.book`,
    //     sync (the overlay is about to show, so make sure it's at the right node).
    // Both fold into ONE self-rescheduling `withObservationTracking` observer (the
    // SAME pattern + gotchas as the analysis/confirmation/branch observers): track
    // both properties, hop to `Task { @MainActor }` to read committed values,
    // detect each edge against a snapshot, react, refresh snapshots, re-arm.

    /// Seeds the snapshots from the live state and starts the self-rescheduling
    /// observation bridge for `bookLookup.isLoaded` + `gobanState.eyeStatus`.
    /// Called once in `init`.
    private func installBookStateObserver() {
        lastBookLoaded = session.bookLookup.isLoaded
        lastEyeStatus = session.gobanState.eyeStatus
        trackBookState()
    }

    /// One observation pass: registers tracking of both properties, and on change
    /// re-reads the committed values on the main actor, reacts, then re-arms.
    private func trackBookState() {
        withObservationTracking {
            // Touch both so a change to either fires `onChange`.
            _ = session.bookLookup.isLoaded
            _ = session.gobanState.eyeStatus
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.handleBookStateChange()
                self.trackBookState()
            }
        }
    }

    /// Detects the book `isLoaded` false->true edge and the `eyeStatus -> .book`
    /// edge against the snapshots, calls `syncBookState()` on either, then refreshes
    /// the snapshots. Mirrors iOS `processBookLoadedChange` / `processEyeStatusChange`.
    private func handleBookStateChange() {
        let newBookLoaded = session.bookLookup.isLoaded
        let newEyeStatus = session.gobanState.eyeStatus

        if newBookLoaded && !lastBookLoaded {
            syncBookState()
        }
        if newEyeStatus == .book && lastEyeStatus != .book {
            syncBookState()
        }

        lastBookLoaded = newBookLoaded
        lastEyeStatus = newEyeStatus
    }

    // MARK: - Move confirmation dialogs
    //
    // Mirror the two SwiftUI `.confirmationDialog`s in `GameSplitView.detailView`
    // (GameSplitView.swift lines 144-195) that the Mac app is missing because it
    // hosts `BoardView` but not `GameSplitView`. The shared `GobanState` already
    // drives the underlying state: `GameSession.maybeCollectCheckMove` sets
    // `confirmingIllegalMove` (+ `illegalMoveReason`) on ko/superko/suicide, and
    // `GameSession.postProcessAIMove` sets `confirmingAIOverwrite`; only the
    // AppKit presentation is absent.
    //
    // Presented as NSAlert SHEETS (`beginSheetModal(for:)`), never `runModal()`:
    // a modal run loop would block this `@MainActor` while the GTP run loop
    // (`GameSession.run`/`messaging`) needs it, risking deadlock/reentrancy. The
    // completion handler is invoked on the main actor, so the play/clear work
    // happens there.
    //
    // Re-fire prevention has two layers, matching the analysis observer:
    //   1. We act only on a `false -> true` transition (snapshot diff against
    //      `lastConfirmingIllegalMove` / `lastConfirmingAIOverwrite`), so a flag
    //      already true on a later pass isn't re-presented.
    //   2. Every handling path clears the triggering flag (illegal:
    //      `playPendingHumanMove`/`clearPendingMove` reset `confirmingIllegalMove`,
    //      and we also set it false defensively before presenting; overwrite:
    //      `playAIMove` does NOT touch the flag, so the handler clears it
    //      explicitly, and Cancel clears it as iOS does).
    // The snapshots are refreshed at the end of `handleConfirmationChange()`.
    //
    // Same `withObservationTracking` gotchas as the analysis observer apply:
    // `onChange` fires once per change, before the mutation commits and without
    // saying which property changed — so we hop to `Task { @MainActor }` to read
    // committed values, then re-register tracking (it's one-shot).

    /// Seeds the snapshots from the live `gobanState` and starts the
    /// self-rescheduling observation bridge for the two confirmation flags.
    /// Called once in `init`, right after `installAnalysisLifecycleObserver()`.
    private func installConfirmationObserver() {
        let gobanState = session.gobanState
        lastConfirmingIllegalMove = gobanState.confirmingIllegalMove
        lastConfirmingAIOverwrite = gobanState.confirmingAIOverwrite
        lastConfirmingBranchDeactivation = gobanState.confirmingBranchDeactivation
        lastConfirmingBranchReplace = gobanState.confirmingBranchReplace
        lastConfirmingBranchDiscard = gobanState.confirmingBranchDiscard
        trackConfirmations()
    }

    /// One observation pass: registers tracking of both confirmation flags, and
    /// on change re-reads the committed values on the main actor, reacts, then
    /// re-arms.
    private func trackConfirmations() {
        withObservationTracking {
            // Touch every flag so a change to any one fires `onChange`.
            _ = session.gobanState.confirmingIllegalMove
            _ = session.gobanState.confirmingAIOverwrite
            _ = session.gobanState.confirmingBranchDeactivation
            _ = session.gobanState.confirmingBranchReplace
            _ = session.gobanState.confirmingBranchDiscard
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.handleConfirmationChange()
                self.trackConfirmations()
            }
        }
    }

    /// Presents the matching NSAlert sheet on each `false -> true` transition,
    /// then refreshes the snapshots. If both flip in the same pass, the
    /// illegal-move alert is presented first; the overwrite flag stays true and
    /// is presented on the next pass (acceptable — see section comment).
    private func handleConfirmationChange() {
        let gobanState = session.gobanState
        let newConfirmingIllegalMove = gobanState.confirmingIllegalMove
        let newConfirmingAIOverwrite = gobanState.confirmingAIOverwrite
        let newConfirmingBranchDeactivation = gobanState.confirmingBranchDeactivation
        let newConfirmingBranchReplace = gobanState.confirmingBranchReplace
        let newConfirmingBranchDiscard = gobanState.confirmingBranchDiscard

        if newConfirmingIllegalMove && !lastConfirmingIllegalMove {
            presentIllegalMoveAlert()
        } else if newConfirmingAIOverwrite && !lastConfirmingAIOverwrite {
            presentAIOverwriteAlert()
        } else if newConfirmingBranchDeactivation && !lastConfirmingBranchDeactivation {
            presentBranchDeactivationAlert()
        } else if newConfirmingBranchReplace && !lastConfirmingBranchReplace {
            presentBranchReplaceAlert()
        } else if newConfirmingBranchDiscard && !lastConfirmingBranchDiscard {
            presentBranchDiscardAlert()
        }

        lastConfirmingIllegalMove = gobanState.confirmingIllegalMove
        lastConfirmingAIOverwrite = gobanState.confirmingAIOverwrite
        lastConfirmingBranchDeactivation = gobanState.confirmingBranchDeactivation
        lastConfirmingBranchReplace = gobanState.confirmingBranchReplace
        lastConfirmingBranchDiscard = gobanState.confirmingBranchDiscard
    }

    /// Mirrors `GameSplitView` lines 171-195 (illegal-move dialog). Title is the
    /// `illegalMoveReasonText` switch over `gobanState.illegalMoveReason`; buttons
    /// are "Play Anyway" (destructive) and "Cancel". With no window we can't
    /// present, so we clear the pending move rather than leave it dangling.
    private func presentIllegalMoveAlert() {
        let gobanState = session.gobanState
        guard let window else {
            gobanState.clearPendingMove()
            lastConfirmingIllegalMove = gobanState.confirmingIllegalMove
            return
        }

        let alert = NSAlert()
        alert.messageText = illegalMoveReasonText
        // Order matters: the first added button is the default (rightmost).
        let playAnyway = alert.addButton(withTitle: "Play Anyway")
        playAnyway.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            let gobanState = self.session.gobanState
            // Defensive: both branches reset `confirmingIllegalMove`, but the
            // `playPendingHumanMove` guard can early-return without clearing if
            // there is no pending move, so set it false up front (idempotent).
            gobanState.confirmingIllegalMove = false

            if response == .alertFirstButtonReturn {
                // "Play Anyway"
                if let gameRecord = self.navigationContext.selectedGameRecord {
                    gobanState.playPendingHumanMove(
                        gameRecord: gameRecord,
                        analysis: self.session.analysis,
                        board: self.session.board,
                        stones: self.session.stones,
                        messageList: self.session.messageList,
                        player: self.session.player,
                        audioModel: self.audioModel
                    )
                } else {
                    gobanState.clearPendingMove()
                }
            } else {
                // "Cancel"
                gobanState.clearPendingMove()
            }

            self.lastConfirmingIllegalMove = gobanState.confirmingIllegalMove
        }
    }

    /// Mirrors `GameSplitView` lines 144-170 (AI-overwrite dialog). Title is the
    /// fixed "Do you allow AI overwriting this move?"; buttons are "Overwrite"
    /// (destructive) and "Cancel". `playAIMove` does not clear the flag, so the
    /// handler clears it on every path (matching iOS Cancel, which also sets
    /// `analysisStatus = .clear`). With no window, just clear the flag.
    private func presentAIOverwriteAlert() {
        let gobanState = session.gobanState
        guard let window else {
            gobanState.confirmingAIOverwrite = false
            lastConfirmingAIOverwrite = gobanState.confirmingAIOverwrite
            return
        }

        let alert = NSAlert()
        alert.messageText = "Do you allow AI overwriting this move?"
        let overwrite = alert.addButton(withTitle: "Overwrite")
        overwrite.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            let gobanState = self.session.gobanState

            if response == .alertFirstButtonReturn {
                // "Overwrite": guard the AI move + turn exactly as iOS does.
                if let gameRecord = self.navigationContext.selectedGameRecord,
                   let aiMove = self.aiMoveBox.value,
                   let turn = self.session.player.nextColorSymbolForPlayCommand {
                    gobanState.playAIMove(
                        aiMove: aiMove,
                        gameRecord: gameRecord,
                        turn: turn,
                        analysis: self.session.analysis,
                        board: self.session.board,
                        stones: self.session.stones,
                        messageList: self.session.messageList,
                        player: self.session.player,
                        audioModel: self.audioModel
                    )
                }
                // `playAIMove` never touches the flag — clear it so the observer
                // does not re-present.
                gobanState.confirmingAIOverwrite = false
            } else {
                // "Cancel": iOS clears the flag AND drops analysis to `.clear`.
                gobanState.confirmingAIOverwrite = false
                gobanState.analysisStatus = .clear
            }

            self.lastConfirmingAIOverwrite = gobanState.confirmingAIOverwrite
        }
    }

    // MARK: - Branch-exit dialogs (P6-T2)
    //
    // Mirror the three SwiftUI branch `.confirmationDialog`s in
    // `GameSplitView.detailView` (GameSplitView.swift lines 196-249) that the Mac
    // app is missing. A "branch" is the temporary variation entered IMPLICITLY by
    // playing an off-mainline move (driven by the shared `GobanState`, already
    // working on Mac); these dialogs are how it is EXITED. The flow is a chooser
    // (`confirmingBranchDeactivation`) that branches into a Replace
    // (`confirmingBranchReplace`) or Discard (`confirmingBranchDiscard`) confirm.
    //
    // Presented as NSAlert SHEETS (`beginSheetModal(for:)`), never `runModal()` —
    // same reasoning as the move-confirmation sheets above (a modal run loop would
    // block this `@MainActor` while the GTP run loop needs it). Each handler clears
    // its triggering flag in the completion so the snapshot-diff observer doesn't
    // re-present, exactly as the illegal-move / AI-overwrite sheets do.
    //
    // The chooser's Replace/Discard buttons set the SECOND flag on the NEXT runloop
    // turn (`DispatchQueue.main.async`), mirroring the iOS comment (lines 202-210):
    // presenting the second sheet while the first is still dismissing is fragile, so
    // we let the first sheet's dismissal complete before the next flag flips and the
    // observer presents the follow-up sheet.

    /// Chooser sheet (on `confirmingBranchDeactivation` true). Mirrors
    /// `GameSplitView` lines 196-220. With no window we can't present, so just
    /// clear the flag so the branch isn't left stuck mid-confirmation.
    private func presentBranchDeactivationAlert() {
        let gobanState = session.gobanState
        guard let window else {
            gobanState.confirmingBranchDeactivation = false
            lastConfirmingBranchDeactivation = gobanState.confirmingBranchDeactivation
            return
        }

        let alert = NSAlert()
        alert.messageText =
            "Branch moves are temporary. Replace the original game with this branch, or discard it?"
        // Order matters: the first added button is the default (rightmost).
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Discard Branch")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            let gobanState = self.session.gobanState
            // Clear the chooser flag in the completion so the observer doesn't
            // re-fire when we (possibly) flip a follow-up flag below.
            gobanState.confirmingBranchDeactivation = false

            switch response {
            case .alertFirstButtonReturn:
                // "Replace": defer to the next runloop so this chooser sheet fully
                // dismisses before the Replace-confirm sheet presents (see comment).
                DispatchQueue.main.async {
                    gobanState.confirmingBranchReplace = true
                }
            case .alertSecondButtonReturn:
                // "Discard Branch": same next-runloop hop for the Discard sheet.
                DispatchQueue.main.async {
                    gobanState.confirmingBranchDiscard = true
                }
            default:
                break // "Cancel"
            }

            self.lastConfirmingBranchDeactivation = gobanState.confirmingBranchDeactivation
        }
    }

    /// Replace-confirm sheet (on `confirmingBranchReplace` true). Mirrors
    /// `GameSplitView` lines 221-238. "Replace" commits the branch onto the saved
    /// record (or, with no game, just deactivates); "Cancel" backs out. The
    /// active->inactive `branchSgf` flip this triggers fires the reload observer.
    private func presentBranchReplaceAlert() {
        let gobanState = session.gobanState
        guard let window else {
            gobanState.confirmingBranchReplace = false
            lastConfirmingBranchReplace = gobanState.confirmingBranchReplace
            return
        }

        let alert = NSAlert()
        alert.messageText =
            "Replace the original game with this branch? "
            + "The original game’s moves after this point will be permanently lost."
        let replace = alert.addButton(withTitle: "Replace")
        replace.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            let gobanState = self.session.gobanState
            gobanState.confirmingBranchReplace = false

            if response == .alertFirstButtonReturn {
                // "Replace": commit synchronously. `commitBranch` reassigns the
                // record's sgf/currentIndex THEN calls `deactivateBranch()`, so the
                // reload observer (which reads the committed sgf) runs after this.
                if let gameRecord = self.navigationContext.selectedGameRecord {
                    gobanState.commitBranch(gameRecord: gameRecord)
                } else {
                    // No game to replace (unreachable in practice): exit branch
                    // mode anyway so confirming never leaves the branch stuck.
                    gobanState.deactivateBranch()
                }
            }
            // else "Cancel": nothing to do beyond clearing the flag above.

            self.lastConfirmingBranchReplace = gobanState.confirmingBranchReplace
        }
    }

    /// Discard-confirm sheet (on `confirmingBranchDiscard` true). Mirrors
    /// `GameSplitView` lines 239-249. "Discard Branch" deactivates the branch
    /// (dropping the newly played stones); "Cancel" backs out. The deactivation
    /// flips `branchSgf` inactive, firing the reload observer.
    private func presentBranchDiscardAlert() {
        let gobanState = session.gobanState
        guard let window else {
            gobanState.confirmingBranchDiscard = false
            lastConfirmingBranchDiscard = gobanState.confirmingBranchDiscard
            return
        }

        let alert = NSAlert()
        alert.messageText = "Discard this branch? Your newly played stones will be lost."
        let discard = alert.addButton(withTitle: "Discard Branch")
        discard.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            let gobanState = self.session.gobanState
            gobanState.confirmingBranchDiscard = false

            if response == .alertFirstButtonReturn {
                // "Discard Branch"
                gobanState.deactivateBranch()
            }
            // else "Cancel".

            self.lastConfirmingBranchDiscard = gobanState.confirmingBranchDiscard
        }
    }

    // MARK: - Branch-exit affordance (P6-T1)

    /// Game-menu "Deactivate Branch" (routed through the responder chain). Sets
    /// `confirmingBranchDeactivation`, which the confirmation observer turns into
    /// the chooser sheet. Branch ENTRY stays implicit (shared `GobanState`); this
    /// only provides the EXIT path the Mac app was missing. Enabled state is owned
    /// by `validateMenuItem`.
    @objc func deactivateBranchAction(_ sender: Any?) {
        session.gobanState.confirmingBranchDeactivation = true
    }

    // MARK: - Branch reload-on-deactivation observer (P6-T3)
    //
    // Port of the iOS `GameSplitView` `branchSgf` reload observer (lines 104-107
    // -> `processChange(oldBranchStateSgf:newBranchStateSgf:)` lines 530-535). When
    // an active branch is exited — by either commit (`commitBranch`) or discard
    // (`deactivateBranch`), both of which end by flipping `branchSgf` inactive —
    // the engine board must be rebuilt from the now-authoritative saved SGF, or it
    // stays desynced on the branch line. iOS reacts to the active->inactive
    // `branchSgf.isActiveSgf` transition by calling `loadGame`; this is its AppKit
    // stand-in, using the same self-rescheduling `withObservationTracking` pattern
    // (and the same gotchas) as the other observers.
    //
    // Commit ordering is the crux: `commitBranch` reassigns `gameRecord.sgf` /
    // `currentIndex` and THEN calls `deactivateBranch()` (which flips `branchSgf`).
    // Because `commitBranch` is synchronous and runs fully before this observer's
    // deferred `Task` hops, the `loadGame` below reads the ALREADY-committed sgf.

    /// Seeds the `branchSgf` snapshot from the live state and starts the
    /// self-rescheduling observation bridge. Called once in `init`.
    private func installBranchReloadObserver() {
        lastBranchSgf = session.gobanState.branchSgf
        trackBranchReload()
    }

    /// One observation pass: tracks `branchSgf`, and on change re-reads the
    /// committed value on the main actor, reacts, then re-arms (one-shot).
    private func trackBranchReload() {
        withObservationTracking {
            _ = session.gobanState.branchSgf
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.handleBranchReloadChange()
                self.trackBranchReload()
            }
        }
    }

    /// On the active->inactive `branchSgf` transition (branch committed or
    /// discarded), rebuild the engine board from the saved SGF, then refresh the
    /// snapshot. Mirrors `processChange(oldBranchStateSgf:newBranchStateSgf:)`.
    private func handleBranchReloadChange() {
        let gobanState = session.gobanState
        let newBranchSgf = gobanState.branchSgf

        if lastBranchSgf.isActiveSgf && !newBranchSgf.isActiveSgf {
            gobanState.loadGame(
                gameRecord: navigationContext.selectedGameRecord,
                previous: nil,
                player: session.player,
                bookLookup: session.bookLookup,
                messageList: session.messageList,
                board: session.board,
                stones: session.stones
            )
        }

        lastBranchSgf = gobanState.branchSgf
    }

    /// Title text for the illegal-move alert, mirroring `GameSplitView`'s
    /// `illegalMoveReasonText` computed property (lines 252-259) over the
    /// optional `gobanState.illegalMoveReason`.
    private var illegalMoveReasonText: String {
        switch session.gobanState.illegalMoveReason {
        case "ko": return "This move violates the ko rule."
        case "suicide": return "This move is a suicide (self-capture)."
        case "superko": return "This move violates the superko rule."
        default: return "This move is illegal."
        }
    }

    // MARK: - Analyze toggle
    //
    // Drives the toolbar's Analyze button. Mirrors the iOS `StatusToolbarItems`
    // `sparkleAction()` (StatusToolbarItems.swift lines 217-225) 3-way state
    // machine over `gobanState.analysisStatus`:
    //   • `.pause` -> stop (`.clear`)
    //   • `.run`   -> pause
    //   • `.clear` -> start (`.run`)
    //
    // The `.clear` branch only sets `analysisStatus = .clear`; it does NOT send
    // `"stop"` — T1's `handleAnalysisLifecycleChange()` observer sends that on
    // entry into `.clear`, and duplicating it here would double-send.

    /// Toolbar Analyze button (`Selector(("toggleAnalysis:"))` resolves here via
    /// the responder chain). Cycles analysis on -> paused -> off, mirroring iOS
    /// `sparkleAction()`.
    @objc func toggleAnalysis(_ sender: Any?) {
        guard let gameRecord = navigationContext.selectedGameRecord else { return }
        let gobanState = session.gobanState

        if gobanState.analysisStatus == .pause {
            // stopAction(): T1's observer sends `"stop"` on entry into `.clear`.
            gobanState.analysisStatus = .clear
        } else if gobanState.analysisStatus == .run {
            // pauseAnalysisAction()
            gobanState.maybePauseAnalysis()
        } else {
            // startAnalysisAction(): set `.run`, then reset the visits/s session
            // BEFORE the request so a prior pause doesn't inflate the elapsed-time
            // denominator (matches the iOS ordering), then arm continuous analysis.
            gobanState.analysisStatus = .run
            session.analysis.resetVisitsPerSecondSession()
            gobanState.maybeRequestAnalysis(
                config: gameRecord.concreteConfig,
                nextColorForPlayCommand: session.player.nextColorForPlayCommand,
                messageList: session.messageList
            )
        }
    }

    // MARK: - Analysis & view menu actions
    //
    // Backing actions for the Analysis menu (Toggle/Pause/Clear/Show Ownership)
    // and the View menu's display toggles (Coordinates/Pass/Win-Rate Bar/Visits
    // per Second). All are reached through the responder chain — the menu items
    // are built with `target = nil` (see `AppDelegate`), so AppKit walks from the
    // first responder up to this `NSWindowController` and lands here. Each one
    // simply mutates the shared `gobanState`; T6's `MacGlobalPreferenceSync`
    // persists any display-flag change automatically, so no UserDefaults writes
    // are needed here. Checkmarks are NOT set on the actions — `validateMenuItem`
    // owns checkmark + enable state so they always reflect the LIVE state.

    /// Analysis menu "Pause": pause a running analysis. `maybePauseAnalysis()`
    /// transitions only from `.run`, so calling it while clear/paused is a no-op.
    @objc func pauseAnalysis(_ sender: Any?) {
        session.gobanState.maybePauseAnalysis()
    }

    /// Analysis menu "Clear": stop and clear analysis. Sets `.clear` only — T1's
    /// `handleAnalysisLifecycleChange()` observer sends `"stop"` on entry into
    /// `.clear`, so sending it here too would double-send.
    @objc func clearAnalysis(_ sender: Any?) {
        session.gobanState.analysisStatus = .clear
    }

    /// Analysis menu "Show Ownership": toggle the ownership overlay. (Lives only
    /// in the Analysis menu, intentionally not duplicated in View.)
    @objc func toggleOwnership(_ sender: Any?) {
        session.gobanState.showOwnership.toggle()
    }

    /// View menu "Show Visits per Second": toggle the visits/s readout.
    @objc func toggleVisitsPerSecond(_ sender: Any?) {
        session.gobanState.showVisitsPerSecond.toggle()
    }

    /// View menu "Show Win-Rate Bar": toggle the win-rate bar.
    @objc func toggleWinrateBar(_ sender: Any?) {
        session.gobanState.showWinrateBar.toggle()
    }

    /// View menu "Show Coordinates": toggle the board coordinate labels.
    @objc func toggleCoordinates(_ sender: Any?) {
        session.gobanState.showCoordinate.toggle()
    }

    /// View menu "Show Pass": toggle display of the pass indicator.
    @objc func togglePass(_ sender: Any?) {
        session.gobanState.showPass.toggle()
    }

    // MARK: - Board move shortcuts (LizzieYzy keys: `,` best move · `P` pass)
    //
    // Keyboard equivalents for two board actions, mirroring LizzieYzy: `,` plays
    // the engine's current best move (the top analysis candidate) and `P` passes.
    // Both route through `GobanState.sendCheckMoveCommand` — the SAME human-move
    // entry the board tap uses (`MacBoardInteractionLayer.attemptPlay`) — so branch
    // handling, the illegal-move alert, analysis re-arm, audio and SGF update all
    // happen identically; they just supply the move string ("pass" or a vertex like
    // "Q16") in place of a clicked vertex. Reached through the responder chain from
    // the Game menu (`target = nil`); enable/text-input gating lives in
    // `validateMenuItem`.

    /// Game-menu "Play Best Move" (`,`): play the top analysis candidate for the
    /// side to move. No-op when there is no live analysis (no best move yet).
    @objc func playBestMove(_ sender: Any?) {
        guard let move = session.analysis.getBestMove(
            width: Int(session.board.width),
            height: Int(session.board.height)
        ) else { return }
        attemptKeyboardPlay(move: move)
    }

    /// Game-menu "Pass" (`P`): play a pass for the side to move.
    @objc func passMove(_ sender: Any?) {
        attemptKeyboardPlay(move: "pass")
    }

    /// Shared guard + dispatch for the keyboard board actions. Replicates
    /// `MacBoardInteractionLayer.attemptPlay`'s guards exactly (stones ready, not
    /// auto-playing, no live pending move, a known side to move, and AI play not
    /// armed for that side), clears a stale pending move first, then either confirms
    /// an overwrite (edit/branch mid-line) via an NSAlert sheet — as the board tap's
    /// `confirmingOverwrite` dialog does — or sends the move straight through.
    private func attemptKeyboardPlay(move: String) {
        guard let gameRecord = navigationContext.selectedGameRecord else { return }
        let gobanState = session.gobanState

        guard session.stones.isReady,
              !gobanState.isAutoPlaying,
              gobanState.pendingMoveTurn == nil || gobanState.isPendingMoveStale,
              let turn = session.player.nextColorSymbolForPlayCommand,
              !gobanState.shouldGenMove(config: gameRecord.concreteConfig, player: session.player)
        else { return }

        if gobanState.isPendingMoveStale {
            gobanState.clearPendingMove()
        }

        if gobanState.isOverwriting(gameRecord: gameRecord) {
            presentKeyboardOverwriteAlert(turn: turn, move: move)
        } else {
            gobanState.sendCheckMoveCommand(turn: turn, move: move, messageList: session.messageList)
        }
    }

    /// Overwrite confirmation for a keyboard-driven play, mirroring
    /// `MacBoardInteractionLayer`'s "Are you sure you want to overwrite this move?"
    /// dialog (and the AI-overwrite NSAlert pattern). Presented as a SHEET so it
    /// never blocks the GTP run loop on this `@MainActor`; with no window we just
    /// play (matching the board layer's no-window fallbacks).
    private func presentKeyboardOverwriteAlert(turn: String, move: String) {
        guard let window else {
            session.gobanState.sendCheckMoveCommand(
                turn: turn, move: move, messageList: session.messageList)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Are you sure you want to overwrite this move?"
        let overwrite = alert.addButton(withTitle: "Overwrite")
        overwrite.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.session.gobanState.sendCheckMoveCommand(
                turn: turn, move: move, messageList: self.session.messageList)
        }
    }

    /// Installs the local key-down monitor that actually drives the bare-key board
    /// shortcuts. The Game/Analysis menu items carry the matching key equivalents
    /// (Space / `,` / `P`) for discoverability and mouse use, but a bare LETTER like
    /// `P` never reaches a menu equivalent when the sidebar `NSTableView` is first
    /// responder: the table's type-select consumes it first (it jumps to a game
    /// starting with "P"), and clicking the board does NOT move first responder off
    /// the table. A local monitor runs inside `-[NSApplication sendEvent:]` BEFORE
    /// key-equivalent dispatch and the responder chain, so it wins that race — while
    /// still deferring to text editing (so Space / `,` / `P` type normally in the
    /// search field, the rename field, the Config editor, and the comment editor).
    private func installBoardShortcutMonitor() {
        boardShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Returning nil swallows the event (we handled it); returning the event
            // lets normal dispatch (menus, responder chain, type-select) proceed.
            return self.handleBoardShortcut(event) ? nil : event
        }
    }

    /// Handles a key-down for the LizzieYzy board shortcuts. Returns true when the
    /// event was one of them AND was actionable (so the caller swallows it). Bare
    /// keys only (no ⌘/⌥/⌃), only for THIS window's events, never while a text
    /// control is editing, and only with a selected game — otherwise it returns
    /// false so the key keeps its normal meaning (typing, scrolling, type-select).
    private func handleBoardShortcut(_ event: NSEvent) -> Bool {
        guard event.window === window,
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              !isTextInputActive,
              navigationContext.selectedGameRecord != nil,
              let chars = event.charactersIgnoringModifiers, chars.count == 1
        else { return false }

        switch chars.lowercased() {
        case " ":
            toggleAnalysis(nil)
            return true
        case ",":
            // Only swallow `,` when there is actually a best move to play, so the
            // key falls through otherwise (mirrors the menu item's enable rule).
            guard session.analysis.getBestMove(
                width: Int(session.board.width),
                height: Int(session.board.height)) != nil else { return false }
            playBestMove(nil)
            return true
        case "p":
            passMove(nil)
            return true
        default:
            return false
        }
    }

    // MARK: - Board/Book visibility (P6-T4)
    //
    // Port of the iOS `StatusToolbarItems.eyeAction()` (StatusToolbarItems.swift
    // lines 243-258) 3-state cycle over `gobanState.eyeStatus`:
    //   • `.opened` -> `.book` (only when the game is book-compatible AND the book
    //                 is loaded), else `.closed`
    //   • `.book`   -> `.closed`
    //   • `.closed` -> `.opened`
    // The hosted `BoardView` renders the board (`.opened`), the opening-book
    // overlay + win-rate bar (`.book`), or a hidden board (`.closed`) off this
    // state — no rendering work here. The `eyeStatus -> .book` edge is picked up by
    // the book-state observer, which re-syncs `bookLookup` to the current move.
    // `withAnimation` is dropped (no SwiftUI transaction in an NSWindowController;
    // the hosted SwiftUI layer animates the change itself).

    /// View-menu "Toggle Board/Book View": cycles board -> book -> hidden.
    /// Mirrors `eyeAction()`. With no selected game the book branch is impossible
    /// (no `concreteConfig`), so `.opened` falls straight to `.closed`.
    @objc func toggleEyeStatus(_ sender: Any?) {
        let gobanState = session.gobanState
        let isBookCompatible =
            navigationContext.selectedGameRecord?.concreteConfig.isBookCompatible ?? false

        switch gobanState.eyeStatus {
        case .opened:
            if isBookCompatible && session.bookLookup.isLoaded {
                gobanState.eyeStatus = .book
            } else {
                gobanState.eyeStatus = .closed
            }
        case .book:
            gobanState.eyeStatus = .closed
        case .closed:
            gobanState.eyeStatus = .opened
        }
    }

    // MARK: - Edit-mode lock (P6-T7)
    //
    // Toggles `gobanState.isEditing`, the same flag the iOS Chart wand / edit
    // affordances drive. Leaving edit mode (`true -> false`) is already handled by
    // the auto-play observer's `isEditing` branch (it cancels any in-flight
    // auto-play), so this action just flips the flag.

    /// Game-menu "Lock Editing": toggles edit mode. `validateMenuItem` shows the
    /// checkmark from the live `gobanState.isEditing`.
    @objc func toggleEditing(_ sender: Any?) {
        session.gobanState.isEditing.toggle()
    }

    /// View-menu Inspector tab shortcuts (⌘1 Chart [chart + moves] · ⌘2 Comments
    /// · ⌘3 Info). The menu item's `tag` (0–2) is the tab index; route through the
    /// split VC, which expands the Inspector pane first if it's collapsed.
    @objc func selectInspectorTab(_ sender: NSMenuItem) {
        (window?.contentViewController as? MainSplitViewController)?
            .showInspectorTab(sender.tag)
    }

    /// Updates the Analyze toolbar item's image + toolTip from the live
    /// `gobanState.analysisStatus`. Called after the item is built (initial
    /// state), at the end of T1's `handleAnalysisLifecycleChange()` (so any path
    /// that changes `analysisStatus` refreshes the button), and defensively from
    /// `validateToolbarItem`. Uses the SF Symbol `wand.and.stars` throughout —
    /// the iOS `custom.sparkle` asset is not guaranteed in the Mac catalog.
    private func refreshAnalyzeToolbarItem() {
        guard let item = analyzeToolbarItem else { return }
        let base = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "Analyze")
        switch session.gobanState.analysisStatus {
        case .clear:
            // Analysis OFF: red tint signals "tap to start", toolTip says so.
            item.image = base?.withSymbolConfiguration(
                .init(paletteColors: [.systemRed]))
            item.toolTip = "Start Analysis"
        case .run:
            // Running: plain template image, toolTip offers to pause.
            item.image = base
            item.toolTip = "Pause Analysis"
        case .pause:
            // Paused: dimmed tint distinguishes it from running, toolTip resumes.
            item.image = base?.withSymbolConfiguration(
                .init(hierarchicalColor: .secondaryLabelColor))
            item.toolTip = "Resume Analysis"
        }
    }

    #if DEBUG
    // MARK: - Verification snapshot (DEBUG only)
    //
    // When the env var `KATAGO_MAC_SNAPSHOT` is set (any non-empty value), render
    // the SwiftUI board to a PNG after it has had time to render, then quit. This
    // is an in-app SwiftUI render via `ImageRenderer` (no screen-recording / TCC
    // permission needed, and — unlike `NSView.cacheDisplay` — it reliably captures
    // the layer-backed SwiftUI content). Because the app is sandboxed it writes
    // into its own temporary directory and prints the absolute path so the caller
    // can find it. (The native window chrome is best verified on-screen / via the
    // screencapture path once screen-recording permission is in effect.)
    private func scheduleSnapshotIfRequested() {
        guard let flag = ProcessInfo.processInfo.environment["KATAGO_MAC_SNAPSHOT"], !flag.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 16) { [weak self] in
            guard let self else { NSApp.terminate(nil); return }
            let dirURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("katago-snapshot", isDirectory: true)
            try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

            let board = MacBoardHostView(session: self.session,
                                         navigationContext: self.navigationContext,
                                         audioModel: self.audioModel,
                                         readiness: self.boardReadiness,
                                         engineLaunchStatus: self.engineLaunchStatus,
                                         activeModelTitle: self.modelSelection.currentModel.title)
                .frame(width: 760, height: 800)
            let renderer = ImageRenderer(content: board)
            renderer.scale = 2
            if let nsImage = renderer.nsImage,
               let tiff = nsImage.tiffRepresentation,
               let bmp = NSBitmapImageRep(data: tiff),
               let data = bmp.representation(using: .png, properties: [:]) {
                try? data.write(to: dirURL.appendingPathComponent("board.png"))
            }

            print("KATAGO_SNAPSHOT_DIR=\(dirURL.path)")
            fflush(stdout)
            NSApp.terminate(nil)
        }
    }

    // MARK: - Auto-play smoke test (DEBUG only)
    //
    // When `KATAGO_MAC_AUTOPLAY_TEST` is set, drive the auto-play loop headlessly
    // so an automated run can confirm it advances/fills (when the loaded game has
    // moves) or cleanly STOPS (when empty) without hanging. Waits ~6s after the
    // engine is ready (so the first analysis is flowing), flips the same flags the
    // Chart wand button sets (`isEditing = true; isAutoPlaying = true`), then ~12s
    // later prints a one-line summary and flushes. Does NOT terminate — the
    // existing snapshot hook (if `KATAGO_MAC_SNAPSHOT` is also set) handles that;
    // otherwise the run is left for the caller to stop.
    private func scheduleAutoPlayTestIfRequested() {
        guard let flag = ProcessInfo.processInfo.environment["KATAGO_MAC_AUTOPLAY_TEST"],
              !flag.isEmpty else { return }
        waitForEngineReadyThenRunAutoPlayTest()
    }

    /// Polls `boardReadiness.isEngineReady` via the same self-rescheduling
    /// `withObservationTracking` style used elsewhere; once ready, starts the test
    /// after a short settle delay. (A one-shot observer is enough: `isEngineReady`
    /// only ever flips `false -> true` once.)
    private func waitForEngineReadyThenRunAutoPlayTest() {
        if boardReadiness.isEngineReady {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                self?.runAutoPlayTest()
            }
            return
        }
        withObservationTracking {
            _ = boardReadiness.isEngineReady
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.waitForEngineReadyThenRunAutoPlayTest()
            }
        }
    }

    private func runAutoPlayTest() {
        session.gobanState.isEditing = true
        session.gobanState.isAutoPlaying = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self else { return }
            let gobanState = self.session.gobanState
            let scoreLeads = self.navigationContext.selectedGameRecord?.scoreLeads?.count ?? -1
            let currentIndex = self.navigationContext.selectedGameRecord?.currentIndex ?? -1
            let moves = self.navigationContext.selectedGameRecord
                .map { SgfHelper(sgf: $0.sgf).moveSize ?? -1 } ?? -1
            print("KATAGO_AUTOPLAY scoreLeads=\(scoreLeads) currentIndex=\(currentIndex) " +
                  "isAutoPlaying=\(gobanState.isAutoPlaying) moves=\(moves)")
            fflush(stdout)
        }
    }

    // MARK: - Engine relaunch self-test (DEBUG only)
    //
    // When `KATAGO_MAC_RELAUNCH_TEST` is set, exercise the in-process teardown +
    // relaunch headlessly so an automated run can confirm a SECOND engine launch
    // reaches "GTP ready" with analysis live again — or surfaces a crash/hang
    // (MLX/Metal global state being the risk this spike exists to probe). Waits
    // ~8s after the FIRST engine becomes ready (so the first analysis is
    // flowing), prints a `KATAGO_RELAUNCH_STARTED` marker, calls
    // `relaunch(model:)` with the built-in net, then ~12s after that prints a
    // one-line summary and flushes. Does NOT terminate — the snapshot hook (if
    // also requested) handles that; otherwise the run is left for the caller.
    private func scheduleRelaunchTestIfRequested() {
        guard let flag = ProcessInfo.processInfo.environment["KATAGO_MAC_RELAUNCH_TEST"],
              !flag.isEmpty else { return }
        waitForEngineReadyThenRunRelaunchTest()
    }

    /// Polls `boardReadiness.isEngineReady` via the same one-shot
    /// `withObservationTracking` style used by the auto-play test; once ready,
    /// starts the relaunch test after an ~8s settle delay so the first engine's
    /// analysis is flowing before we tear it down.
    private func waitForEngineReadyThenRunRelaunchTest() {
        if boardReadiness.isEngineReady {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.runRelaunchTest()
            }
            return
        }
        withObservationTracking {
            _ = boardReadiness.isEngineReady
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.waitForEngineReadyThenRunRelaunchTest()
            }
        }
    }

    private func runRelaunchTest() {
        guard let builtIn = NeuralNetworkModel.builtInModel else {
            print("KATAGO_RELAUNCH_ERROR builtInModel missing")
            fflush(stdout)
            return
        }
        print("KATAGO_RELAUNCH_STARTED")
        fflush(stdout)
        relaunch(model: builtIn)

        // ~12s after kicking the relaunch, report whether the SECOND engine
        // reached "GTP ready" (ready=true) with analysis live again
        // (analysisInfo>0) and a balanced showboard count (showBoardCount=0).
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self else { return }
            let gobanState = self.session.gobanState
            print("KATAGO_RELAUNCH ready=\(self.boardReadiness.isEngineReady) " +
                  "analysisInfo=\(self.session.analysis.info.count) " +
                  "showBoardCount=\(gobanState.showBoardCount) " +
                  "nextColor=\(self.session.player.nextColorForPlayCommand)")
            fflush(stdout)
        }
    }

    // MARK: - AI move-generation self-test (DEBUG only)
    //
    // When `KATAGO_MAC_AIPLAY_TEST` is set, verify the gen-move → play chain
    // headlessly (the highest-risk Phase 6 wiring): enabling an AI color mid-game
    // (here Black, on a fresh empty board where it's Black's turn) must make the
    // engine GENERATE a move (`kata-search_analyze_cancellable`) and the shared
    // `GameSession.postProcessAIMove` must PLAY it. Waits ~8s after the engine is
    // ready (so the first analysis is flowing), then sets Black's `maxTime` and
    // re-arms analysis — exactly what the config editor's `setBlackMaxTime` now
    // does, so this also exercises that re-arm path. ~12s later prints a one-line
    // summary and flushes. Does NOT terminate.
    private func scheduleAIPlayTestIfRequested() {
        guard let flag = ProcessInfo.processInfo.environment["KATAGO_MAC_AIPLAY_TEST"],
              !flag.isEmpty else { return }
        waitForEngineReadyThenRunAIPlayTest()
    }

    /// Polls `boardReadiness.isEngineReady` via the same one-shot
    /// `withObservationTracking` style used by the other DEBUG self-tests; once
    /// ready, starts the test after an ~8s settle delay so the first engine's
    /// analysis is flowing before we enable AI play.
    private func waitForEngineReadyThenRunAIPlayTest() {
        if boardReadiness.isEngineReady {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.runAIPlayTest()
            }
            return
        }
        withObservationTracking {
            _ = boardReadiness.isEngineReady
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.waitForEngineReadyThenRunAIPlayTest()
            }
        }
    }

    private func runAIPlayTest() {
        guard let gameRecord = navigationContext.selectedGameRecord else {
            print("KATAGO_AIPLAY_ERROR no selected game")
            fflush(stdout)
            return
        }

        // Enable Black for AI play (computed setter persists to
        // `optionalBlackMaxTime`) and force a re-evaluation of
        // `getRequestAnalysisCommands` — on a fresh game it's Black's turn, so
        // this issues the gen-move set. Mirrors the config editor's re-arm.
        gameRecord.concreteConfig.blackMaxTime = 1.0
        session.gobanState.maybeRequestAnalysis(
            config: gameRecord.concreteConfig,
            nextColorForPlayCommand: session.player.nextColorForPlayCommand,
            messageList: session.messageList
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self else { return }
            let config = gameRecord.concreteConfig
            let player = self.session.player
            let lastPlayLine = self.session.messageList.messages
                .last { $0.text.hasPrefix("play ") }?.text ?? "<none>"
            print("KATAGO_AIPLAY blackMaxTime=\(config.blackMaxTime) " +
                  "nextColor=\(player.nextColorForPlayCommand) " +
                  "blackStones=\(self.session.stones.blackPoints.count) " +
                  "whiteStones=\(self.session.stones.whitePoints.count) " +
                  "lastPlayLine=\(lastPlayLine)")
            fflush(stdout)
        }
    }
    #endif
}

/// Tiny main-actor box that vends a `Binding<String?>` for `GameSession`'s
/// `aiMove` parameter without an enclosing SwiftUI view. Phase 1 macOS never
/// reads it back (no AI-play confirmation UI yet).
@MainActor
private final class AIMoveBox {
    var value: String?
    var binding: Binding<String?> {
        Binding(get: { self.value }, set: { self.value = $0 })
    }
}

// MARK: - Window lifecycle

extension MainWindowController: NSWindowDelegate {
    /// Ends the `GameSession` message loop when the window closes so `run()`
    /// stops polling `KataGoHelper.getMessageLine()` after teardown.
    /// Backstop teardown invoked from `AppDelegate.applicationWillTerminate` so a
    /// ⌘Q (which may not fire `windowWillClose`) still kills the engine child.
    /// Bounded `terminate()` → app quit never hangs.
    func shutdownEngineForAppTermination() {
        session.stopRequested = true
        engineProcess?.terminate()
        engineProcess = nil
    }

    func windowWillClose(_ notification: Notification) {
        session.stopRequested = true
        // Kill the engine child so closing the window never leaves an orphaned
        // katago-engine process. terminate() can block briefly (grace period +
        // SIGTERM/SIGKILL escalation), so run it OFF the main thread to keep
        // window close responsive; the child also self-exits on stdin EOF, and
        // KataGoEngineProcess.deinit is the final backstop.
        if let engine = engineProcess {
            engineProcess = nil
            Task.detached { engine.terminate() }
        }
        if let boardShortcutMonitor {
            NSEvent.removeMonitor(boardShortcutMonitor)
            self.boardShortcutMonitor = nil
        }
    }

    // Persist the windowed-vs-full-screen choice so the next launch restores it
    // (read back in `restoreWindowStateOnLaunch`). These fire on every transition,
    // so the saved flag matches the state the window is left in at quit — including
    // quitting straight from full screen (no exit transition occurs, flag stays true).
    func windowDidEnterFullScreen(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: Self.wasFullScreenKey)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: Self.wasFullScreenKey)
    }
}

// MARK: - Toolbar

// MARK: - Active-model dropdown menu

extension MainWindowController: NSMenuDelegate {
    /// Rebuilds the active-model toolbar dropdown's menu just before it opens, so
    /// checkmarks (active net) and per-item enablement (downloaded?) are live. The
    /// controller is the delegate of ONLY that menu, but we guard on identity so a
    /// future shared use can't accidentally trigger a rebuild of the wrong menu.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === activeModelToolbarItem?.menu else { return }
        rebuildActiveModelMenu(menu)
    }
}

// MARK: - Menu item validation

extension MainWindowController: NSMenuItemValidation {
    /// Enables/disables menu items via the responder chain, and sets the
    /// checkmark on the toggling Analysis/View items so they always reflect the
    /// LIVE `analysisStatus` / `gobanState` (AppKit calls this just before a menu
    /// opens). Navigate items (Back/Forward/First/Last) use the same
    /// `canGoBackward` / `canGoForward` tests as the toolbar; Rename/Delete/Share
    /// require a selected game; everything else defaults to enabled.
    /// True when the key window's first responder is a text input. On macOS,
    /// AppKit and SwiftUI text editing both run through an `NSText`/`NSTextView`
    /// field editor, so this catches the library search field, the rename field,
    /// the Config editor, and the SwiftUI comment editor alike. The bare-key board
    /// shortcuts (Space / `,` / `P`, mirroring LizzieYzy) return `false` from
    /// `validateMenuItem` while this holds, so the keystroke falls through to the
    /// focused text control rather than triggering the command — the same reasoning
    /// that keeps bare ⏎/⌫ from being global menu equivalents.
    private var isTextInputActive: Bool {
        window?.firstResponder is NSText
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let gobanState = session.gobanState
        let hasGame = navigationContext.selectedGameRecord != nil
        switch menuItem.action {
        case #selector(renameSelectedGame(_:)),
             #selector(deleteSelectedGame(_:)),
             #selector(shareSelectedGame(_:)):
            return hasGame

        // Game menu "Deactivate Branch": only meaningful when a branch is active
        // and the engine isn't mid-move-generation (mirrors the iOS gating). With
        // no game there is no branch to exit, so it's disabled.
        case #selector(deactivateBranchAction(_:)):
            guard let gameRecord = navigationContext.selectedGameRecord else { return false }
            return gobanState.isBranchActive
                && !gobanState.shouldGenMove(config: gameRecord.concreteConfig, player: session.player)

        // Game menu "Lock Editing": checkmark reflects the live `isEditing`,
        // enabled when a game is selected.
        case #selector(toggleEditing(_:)):
            menuItem.state = gobanState.isEditing ? .on : .off
            return hasGame

        // View menu "Toggle Board/Book View": a 3-state cycle, so no checkmark.
        // Enabled when a game is selected.
        case #selector(toggleEyeStatus(_:)):
            return hasGame

        // Game-menu board-move shortcuts: bare `,` / `P` (LizzieYzy). Disabled
        // while a text control is editing so the key types instead of playing.
        // "Play Best Move" additionally requires a live best move (analysis on).
        case #selector(playBestMove(_:)):
            let hasBestMove = session.analysis.getBestMove(
                width: Int(session.board.width),
                height: Int(session.board.height)) != nil
            return hasGame && hasBestMove && !isTextInputActive
        case #selector(passMove(_:)):
            return hasGame && !isTextInputActive

        // Analysis menu: checkmark reflects the live status, enabled with a game.
        // `toggleAnalysis` is bound to bare Space (LizzieYzy), so it is also
        // disabled while a text control is editing — `false` lets Space type there.
        case #selector(toggleAnalysis(_:)):
            menuItem.state = gobanState.analysisStatus != .clear ? .on : .off
            return hasGame && !isTextInputActive
        case #selector(pauseAnalysis(_:)):
            menuItem.state = gobanState.analysisStatus == .pause ? .on : .off
            return hasGame
        case #selector(clearAnalysis(_:)):
            menuItem.state = gobanState.analysisStatus == .clear ? .on : .off
            return hasGame
        case #selector(toggleOwnership(_:)):
            menuItem.state = gobanState.showOwnership ? .on : .off
            return hasGame

        // View menu display toggles: checkmark reflects the live flag; these are
        // pure display preferences, always available regardless of selection.
        case #selector(toggleCoordinates(_:)):
            menuItem.state = gobanState.showCoordinate ? .on : .off
            return true
        case #selector(togglePass(_:)):
            menuItem.state = gobanState.showPass ? .on : .off
            return true
        case #selector(toggleWinrateBar(_:)):
            menuItem.state = gobanState.showWinrateBar ? .on : .off
            return true
        case #selector(toggleVisitsPerSecond(_:)):
            menuItem.state = gobanState.showVisitsPerSecond ? .on : .off
            return true

        // Active-model dropdown rows: keep the per-item enablement set during the
        // menu rebuild (availability), but additionally disable ALL switching while
        // a launch is in flight so the user can't trigger a re-entrant relaunch.
        case #selector(selectActiveModel(_:)):
            return menuItem.isEnabled && boardReadiness.isEngineReady
        // "Manage Models…" is always available.
        case #selector(showModelsWindow(_:)):
            return true

        default:
            return canPerformNavigation(menuItem.action)
        }
    }
}

// MARK: - Toolbar item validation

extension MainWindowController: NSToolbarItemValidation {
    /// Enables/disables the nav-group subitems (⏮◀▶⏭) through the responder
    /// chain. AppKit calls this for each `target = nil` item that resolves to
    /// this responder; non-navigation items default to enabled. Uses the same
    /// `canGoBackward` / `canGoForward` tests as the Navigate menu.
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        // Active-model dropdown: always enabled; opportunistically refresh its
        // displayed title so it tracks the live selection even when the model was
        // changed elsewhere (Models window "Set Active", crash recovery).
        if item.itemIdentifier == .activeModel {
            refreshActiveModelToolbarItem()
            return true
        }
        if item.action == #selector(toggleAnalysis(_:)) {
            // Analyze only makes sense with a game loaded; refresh its on/off
            // appearance opportunistically while we're here.
            refreshAnalyzeToolbarItem()
            return navigationContext.selectedGameRecord != nil
        }
        return canPerformNavigation(item.action)
    }
}

private extension NSToolbarItem.Identifier {
    static let toggleSidebar = NSToolbarItem.Identifier("toggleSidebar")
    static let newGame = NSToolbarItem.Identifier("newGame")
    static let importSGF = NSToolbarItem.Identifier("importSGF")
    static let activeModel = NSToolbarItem.Identifier("activeModel")
    static let navGroup = NSToolbarItem.Identifier("navGroup")
    static let analyze = NSToolbarItem.Identifier("analyze")
    static let toggleInspector = NSToolbarItem.Identifier("toggleInspector")
}

extension MainWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar,
            .newGame,
            .importSGF,
            .activeModel,
            .flexibleSpace,
            .navGroup,
            .analyze,
            .flexibleSpace,
            .toggleInspector,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar,
            .newGame,
            .importSGF,
            .activeModel,
            .navGroup,
            .analyze,
            .toggleInspector,
            .flexibleSpace,
            .space,
        ]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .toggleSidebar:
            // NSSplitViewController responds to toggleSidebar: via the responder chain.
            return makeItem(itemIdentifier,
                            label: "Sidebar",
                            symbol: "sidebar.left",
                            action: #selector(NSSplitViewController.toggleSidebar(_:)))
        case .newGame:
            return makeItem(itemIdentifier,
                            label: "New",
                            symbol: "plus",
                            action: #selector(newGame(_:)))
        case .importSGF:
            return makeItem(itemIdentifier,
                            label: "Import",
                            symbol: "square.and.arrow.down",
                            action: #selector(importSGF(_:)))
        case .analyze:
            let item = makeItem(itemIdentifier,
                                label: "Analyze",
                                symbol: "wand.and.stars",
                                action: #selector(toggleAnalysis(_:)))
            // Borrow a weak reference so `refreshAnalyzeToolbarItem()` can reflect
            // `analysisStatus` on the button, and seed its initial appearance.
            analyzeToolbarItem = item
            refreshAnalyzeToolbarItem()
            return item
        case .activeModel:
            return makeActiveModelItem(itemIdentifier)
        case .toggleInspector:
            // macOS 14+ NSSplitViewController responds to toggleInspector:.
            return makeItem(itemIdentifier,
                            label: "Inspector",
                            symbol: "sidebar.right",
                            action: #selector(NSSplitViewController.toggleInspector(_:)))
        case .navGroup:
            return makeNavGroup(itemIdentifier)
        default:
            return nil
        }
    }

    // MARK: Builders

    private func makeItem(_ identifier: NSToolbarItem.Identifier,
                          label: String,
                          symbol: String,
                          action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = nil  // first responder
        item.action = action
        return item
    }

    /// Active-model dropdown (P5-T6): an `NSMenuToolbarItem` whose title shows the
    /// current net and whose menu lists every visible model (checkmark = active,
    /// disabled = not yet downloaded) plus a "Manage Models…" item. The menu is
    /// rebuilt fresh each time it opens (via `menuNeedsUpdate(_:)`) so checkmarks /
    /// availability are always live.
    private func makeActiveModelItem(_ identifier: NSToolbarItem.Identifier) -> NSMenuToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: identifier)
        item.label = "Model"
        item.toolTip = "Active Network"
        item.image = NSImage(systemSymbolName: "square.stack.3d.up",
                             accessibilityDescription: "Active Network")
        // Don't collapse into the chevron-arrow style; show the pulldown directly.
        item.showsIndicator = true

        // The menu's delegate is this controller, so `menuNeedsUpdate(_:)` rebuilds
        // the items on every open (live checkmarks + availability).
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        activeModelToolbarItem = item
        refreshActiveModelToolbarItem()
        return item
    }

    /// Rebuilds the active-model dropdown's menu items from the live catalog +
    /// selection. Called from `menuNeedsUpdate(_:)` each time the menu opens, so
    /// checkmarks (active model) and enablement (downloaded?) are always current.
    fileprivate func rebuildActiveModelMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let currentTitle = modelSelection.currentModel.title

        for model in NeuralNetworkModel.allCases.filter({ $0.visible }) {
            let menuItem = NSMenuItem(title: model.title,
                                      action: #selector(selectActiveModel(_:)),
                                      keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = model
            menuItem.state = (model.title == currentTitle) ? .on : .off
            // Built-in is always available; others only when the file is present.
            // A non-downloaded model is disabled — the Models window is where it
            // gets downloaded.
            let available = model.builtIn
                || (model.downloadedURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
            menuItem.isEnabled = available
            menu.addItem(menuItem)
        }

        menu.addItem(.separator())
        let manage = NSMenuItem(title: "Manage Models…",
                                action: #selector(showModelsWindow(_:)),
                                keyEquivalent: "")
        manage.target = self
        menu.addItem(manage)
    }

    /// Updates the active-model dropdown's displayed title to the current net.
    /// Called when the item is built and after a switch (the menu rebuilds itself,
    /// but the always-visible title is set imperatively).
    private func refreshActiveModelToolbarItem() {
        activeModelToolbarItem?.title = modelSelection.currentModel.title
    }

    /// Switches the active network from the toolbar dropdown. Resolves the chosen
    /// model from the menu item's `representedObject` and relaunches the engine via
    /// `relaunch(model:)`. Guarded on `boardReadiness.isEngineReady` to avoid a
    /// re-entrant relaunch while a launch is already in flight.
    @objc func selectActiveModel(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? NeuralNetworkModel else { return }
        // Don't switch mid-launch (avoids re-entrant teardown/relaunch).
        guard boardReadiness.isEngineReady else { return }
        // No-op if it's already the active net.
        guard model.title != modelSelection.currentModel.title else { return }
        relaunch(model: model)
        refreshActiveModelToolbarItem()
    }

    /// ⏮ ◀ ▶ ⏭ as a segmented navigation group routed through the responder chain.
    private func makeNavGroup(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItemGroup {
        let specs: [(label: String, symbol: String, action: Selector)] = [
            ("First", "backward.end", #selector(goToStart(_:))),
            ("Back", "backward", #selector(goBackward(_:))),
            ("Forward", "forward", #selector(goForward(_:))),
            ("Last", "forward.end", #selector(goToEnd(_:))),
        ]

        let subitems = specs.enumerated().map { index, spec -> NSToolbarItem in
            let sub = NSToolbarItem(
                itemIdentifier: NSToolbarItem.Identifier("\(identifier.rawValue).\(index)"))
            sub.label = spec.label
            sub.toolTip = spec.label
            sub.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: spec.label)
            sub.target = nil  // first responder
            sub.action = spec.action
            return sub
        }

        let group = NSToolbarItemGroup(itemIdentifier: identifier)
        group.label = "Navigate"
        group.subitems = subitems
        group.controlRepresentation = .expanded
        group.selectionMode = .momentary
        return group
    }
}
