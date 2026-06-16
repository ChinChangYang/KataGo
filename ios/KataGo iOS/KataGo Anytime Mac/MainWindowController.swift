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

        startEngineAndSession()

        #if DEBUG
        scheduleSnapshotIfRequested()
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
    private func ensureSelectedGameRecord(gameRecords: [GameRecord],
                                          context: ModelContext) -> GameRecord {
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
