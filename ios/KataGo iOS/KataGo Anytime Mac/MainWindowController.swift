import AppKit
import SwiftUI
import SwiftData
import KataGoUICore

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
    private var katagoThread: Thread?

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

    /// The toolbar's Analyze item, retained weakly so `refreshAnalyzeToolbarItem()`
    /// can mutate its image/toolTip to reflect `gobanState.analysisStatus`. The
    /// `NSToolbar` owns the item; we only borrow a reference (set when the item is
    /// built in the `.analyze` case) to avoid a retain cycle.
    private weak var analyzeToolbarItem: NSToolbarItem?

    /// AppKit equivalent of the iOS `GlobalPreferenceSync` modifier: seeds the
    /// shared `GobanState` from the persisted `GlobalSettings.*` UserDefaults and
    /// writes each subsequent change back. Owned here; created in `init` BEFORE
    /// the board view appears so `GobanState` already holds the user's display
    /// preferences when `BoardView` first renders.
    private var preferenceSync: MacGlobalPreferenceSync?

    /// Gates the board pane until the engine session has finished its initial
    /// handshake + board load (see `BoardReadiness`). Without this, the hosted
    /// `BoardView.onAppear` fires at `init` time — before the engine exists — and
    /// its premature `showboard` desyncs `showBoardCount`, gating analysis off.
    let boardReadiness = BoardReadiness()

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer

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

        // Port of the iOS auto-play machinery (the Chart tab's wand button drives
        // `gobanState.isAutoPlaying`). iOS reacts via two `GameSplitView`
        // `.onChange` handlers (`onChange(of: isAutoPlaying)` +
        // `onChange(of: stones.isReady)`); this observer is their AppKit stand-in.
        // (The per-move stepping branch — iOS lines 495-525 — lives in the EXISTING
        // analysis observer instead, keyed off `waitingForAnalysis`.) Installed
        // before the engine starts so the first stones-ready transition isn't missed.
        installAutoPlayObserver()

        startEngineAndSession()

        #if DEBUG
        scheduleSnapshotIfRequested()
        scheduleAutoPlayTestIfRequested()
        scheduleRelaunchTestIfRequested()
        #endif
    }

    required init?(coder: NSCoder) { fatalError("not used") }

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
    /// built-in network, then run the version handshake, initial commands, board
    /// load and the GTP message loop. macOS defaults inside `KataGoHelper`
    /// (MLX/GPU, 16 search threads) are used as-is — no overrides.
    private func startEngineAndSession() {
        guard let builtIn = NeuralNetworkModel.builtInModel,
              let modelPath = Bundle.main.path(forResource: "default_model", ofType: "bin.gz") else {
            assertionFailure("Built-in model not bundled in the Mac target's Resources.")
            return
        }

        // Arm + clear the crash sentinel exactly as `ModelRunnerView` does so the
        // handshake's `markFirstResponse` is meaningful.
        engineLifecycle.reset()

        startKataGoThread(modelPath: modelPath)

        let context = modelContainer.mainContext
        let gameRecords = (try? GameRecord.fetchGameRecords(container: modelContainer)) ?? []
        let selected = ensureSelectedGameRecord(gameRecords: gameRecords, context: context)

        Task { @MainActor in
            await initializeSession(builtIn: builtIn, selected: selected, context: context)
        }
    }

    private func startKataGoThread(modelPath: String) {
        let katagoThread = Thread {
            // macOS defaults (MLX/GPU device, 16 threads) live inside runGtp.
            KataGoHelper.runGtp(modelPath: modelPath)
        }
        // Expand the stack size to resolve a stack overflow problem (mirrors iOS).
        katagoThread.stackSize = 4096 * 256
        katagoThread.start()
        self.katagoThread = katagoThread
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

    private func initializeSession(builtIn: NeuralNetworkModel,
                                   selected: GameRecord,
                                   context: ModelContext) async {
        // Mirror `ContentView.initializationTask`: handshake → initial commands.
        await session.initialize(
            selectedModelTitle: builtIn.title,
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
    // The Mac app launches KataGo once at window init and (until now) never
    // restarts it. Phase 5 model switching needs to tear the engine down and
    // relaunch it IN-PROCESS. This is the proven iOS `QuitButton` mechanism
    // (`KataGoHelper.sendCommand("quit")` → the engine's GTP loop exits so
    // `runGtp` returns and the `katagoThread` ends; `session.stopRequested =
    // true` ends `GameSession.run()`/`messaging()`), adapted for an in-process
    // relaunch rather than an app exit.
    //
    // IMPORTANT detail about the bridge (`KataGoCpp.cpp`): the to/from-engine
    // streams are GLOBAL, persistent `ThreadSafeStreamBuf`s, and their `done`
    // flag is never set — so `getMessageLine()` (`getline`) does NOT see EOF when
    // the engine exits; it blocks on the buffer's condition variable once drained.
    // `GameSession.messaging` is suspended inside `await Task.detached {
    // KataGoHelper.getMessageLine() }` at that moment. Flipping `stopRequested`
    // alone would NOT release that blocked `getline`, so the previous `run()`
    // Task would hang forever — and a second engine's output would interleave
    // into the same global buffer feeding a still-alive consumer. So we mirror
    // iOS exactly and NUDGE the consumer with `sendMessage("\n")` (which writes a
    // newline into the from-engine buffer) to unblock that final `getline`; the
    // `messaging` body then sees `stopRequested == true` and the outer `run()`
    // loop exits. That guarantees the old `run()` Task ends before the new one
    // starts — i.e. never two concurrent `run()` loops on one shared buffer.

    /// Tears down the running engine + session so a fresh engine can be launched
    /// in-process. Async so the engine-thread join polls with `Task.sleep`
    /// (cooperative) instead of blocking the main thread.
    ///
    /// Ordering (matches the iOS `QuitButton` teardown, with an explicit join):
    ///   1. `stopRequested = true` first, so the `messaging` per-line guard skips
    ///      the engine's quit-response lines and `run()` exits on its next check.
    ///   2. `sendCommand("quit")` → the GTP loop sets `shouldQuitAfterResponse`,
    ///      finishes, and `runGtp` returns, ending `katagoThread`.
    ///   3. `sendMessage("\n")` → unblocks the consumer's currently-suspended
    ///      `getMessageLine`/`getline` so the previous `run()` Task can observe
    ///      `stopRequested` and terminate (see section comment).
    ///   4. Poll `katagoThread?.isFinished` up to a bounded timeout so we never
    ///      start a second engine while the first is still alive (and thus avoid
    ///      two engines fighting over the shared MLX/Metal global state).
    ///   5. Reset all per-launch state and re-seed the observer snapshots so the
    ///      existing `withObservationTracking` observers don't fire spurious
    ///      transitions against stale `lastX` values on the fresh engine.
    private func stopEngineAndSession() async {
        // (1) End the GTP message loop. `messaging`'s `if !stopRequested` guard
        // and `run`'s `while !stopRequested` both collapse on this.
        session.stopRequested = true

        // (2) Make the engine's GTP loop exit so `runGtp` returns and the old
        // engine thread finishes.
        KataGoHelper.sendCommand("quit")

        // (3) Unblock the consumer's suspended `getMessageLine` so the old
        // `run()` Task observes `stopRequested` and terminates. Without this the
        // old consumer stays blocked in `getline` on the shared global buffer.
        KataGoHelper.sendMessage("\n")

        // (4) Wait (bounded, non-blocking) for the old engine thread to finish so
        // we don't launch a second engine alongside the first. ~5s budget in
        // 50ms slices.
        let deadline = Date().addingTimeInterval(5)
        while let thread = katagoThread, !thread.isFinished, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
        if let thread = katagoThread, !thread.isFinished {
            // Should not happen — the engine acked `quit` and cleaned up. Log and
            // proceed; the old thread will exit on its own once `runGtp` returns.
            print("KATAGO_RELAUNCH_WARNING old engine thread did not finish within timeout")
            fflush(stdout)
        }

        // (5) Reset for the next launch.
        boardReadiness.isEngineReady = false
        session.stopRequested = false
        engineLifecycle.reset()
        katagoThread = nil

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
        lastIsAutoPlaying = gobanState.isAutoPlaying
        lastStonesReady = session.stones.isReady
        lastIsEditing = gobanState.isEditing
    }

    /// Tears the running engine down and starts a fresh one in-process. This is
    /// the basis for Phase 5 model switching.
    ///
    /// The `model` parameter is accepted now so P5-T2/T3 can route a user-chosen
    /// model through here; for THIS spike the actual launch reuses the built-in
    /// path inside `startEngineAndSession()` (the model-param → `runGtp` wiring is
    /// P5-T2's job). `startEngineAndSession()` re-runs the FULL init
    /// (handshake → showboard/printsgf → messaging → run) and re-gates
    /// `boardReadiness.isEngineReady` true after init, so the board re-mounts and
    /// analysis re-arms exactly as on first launch. A fresh `initializeSession`
    /// Task is started there, after `stopEngineAndSession()` has confirmed the old
    /// `run()` loop ended — so there are never two concurrent `run()` loops.
    func relaunch(model: NeuralNetworkModel) {
        _ = model // P5-T2 will thread this through to `runGtp`.
        Task { @MainActor in
            await stopEngineAndSession()
            startEngineAndSession()
        }
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

    /// Port of `GameSplitView.processStonesReadyChange` (iOS lines 268-293), minus
    /// the iOS `syncBookState()` call (book sync is a Phase 6 concern not yet wired
    /// on macOS). Persists the just-settled stones into the record at the current
    /// index and, when an auto-play step just played, advances `currentIndex`.
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

        // TODO(Phase 6): book sync (iOS calls `syncBookState()` here).
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
        trackConfirmations()
    }

    /// One observation pass: registers tracking of both confirmation flags, and
    /// on change re-reads the committed values on the main actor, reacts, then
    /// re-arms.
    private func trackConfirmations() {
        withObservationTracking {
            // Touch both flags so a change to either fires `onChange`.
            _ = session.gobanState.confirmingIllegalMove
            _ = session.gobanState.confirmingAIOverwrite
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

        if newConfirmingIllegalMove && !lastConfirmingIllegalMove {
            presentIllegalMoveAlert()
        } else if newConfirmingAIOverwrite && !lastConfirmingAIOverwrite {
            presentAIOverwriteAlert()
        }

        lastConfirmingIllegalMove = gobanState.confirmingIllegalMove
        lastConfirmingAIOverwrite = gobanState.confirmingAIOverwrite
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

    /// View-menu Inspector tab shortcuts (⌘1 Chart · ⌘2 Comments · ⌘3 Moves ·
    /// ⌘4 Info). The menu item's `tag` (0–3) is the tab index; route through the
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
                                         readiness: self.boardReadiness)
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
    func windowWillClose(_ notification: Notification) {
        session.stopRequested = true
    }
}

// MARK: - Toolbar

// MARK: - Menu item validation

extension MainWindowController: NSMenuItemValidation {
    /// Enables/disables menu items via the responder chain, and sets the
    /// checkmark on the toggling Analysis/View items so they always reflect the
    /// LIVE `analysisStatus` / `gobanState` (AppKit calls this just before a menu
    /// opens). Navigate items (Back/Forward/First/Last) use the same
    /// `canGoBackward` / `canGoForward` tests as the toolbar; Rename/Delete/Share
    /// require a selected game; everything else defaults to enabled.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let gobanState = session.gobanState
        let hasGame = navigationContext.selectedGameRecord != nil
        switch menuItem.action {
        case #selector(renameSelectedGame(_:)),
             #selector(deleteSelectedGame(_:)),
             #selector(shareSelectedGame(_:)):
            return hasGame

        // Analysis menu: checkmark reflects the live status, enabled with a game.
        case #selector(toggleAnalysis(_:)):
            menuItem.state = gobanState.analysisStatus != .clear ? .on : .off
            return hasGame
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
