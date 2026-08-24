import AppKit
import OSLog
import SwiftUI
import SwiftData
import WidgetKit
import KataGoUICore
import KataGoEngineIPC
import KataGoAnalysisKit

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
    ///
    /// Deliberately NOT surfaced on macOS, and not injected into the board's
    /// environment. The Core ML compile happens inside the `katago-engine`
    /// CHILD process, which has no channel back to the app (ADR 0007), so this
    /// object never leaves `.idle` here — the inline engine status says
    /// "Loading engine…" and makes no claim about compiling. Held so the
    /// registered seam has a stable owner for the window's lifetime.
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

    /// The max board length the RUNNING engine was launched with
    /// (`maxBoardSizeForNNBuffer`). The New Game dialog bounds its board-size
    /// options to this — a board larger than the launched cap fatally aborts the
    /// engine on first analysis (`boardFits`). Set at each engine launch, so it
    /// reflects what's live now, not a settings change awaiting relaunch.
    private(set) var launchedMaxBoardLength: Int = BoardSizeChoice.nineteen.rawValue

    /// The Task running `initializeSession` → `session.run()` (the steady-state
    /// GTP loop). Tracked so `stopEngineAndSession()` can AWAIT it before a
    /// relaunch injects a new engine — `GameSession` is reused across relaunch,
    /// so the old loop must finish before the new engine is wired in.
    private var sessionTask: Task<Void, Never>?

    /// True from the moment `relaunch(model:)` is accepted until the
    /// teardown/spawn pair it started has finished. The in-process controllers
    /// use their `Phase` for this; macOS has no phase, so it needs the flag —
    /// see `relaunch(model:)` and `EngineRestartRules.shouldBeginRelaunch`.
    private var isRelaunching = false

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

    /// Last-seen value of the property the auto-play observer watches.
    /// `lastIsAutoPlaying` lets the (property-agnostic) `withObservationTracking`
    /// callback detect either edge of `gobanState.isAutoPlaying` (it reacts to ANY
    /// `old != new`, matching iOS's `onChange(of: isAutoPlaying)`). Seeded from
    /// the live state in `installAutoPlayObserver()`.
    private var lastIsAutoPlaying = false

    /// One-shot "reload widgets when the switched game's position lands" latch
    /// — same mechanism as iOS `GameSplitView`. Armed in `selectGame(_:)`,
    /// consumed at the end of `handleRecordPositionChange()`. The Mac
    /// previously never reloaded on a plain sidebar switch at all.
    private var widgetReloadLatch = WidgetReloadLatch()

    /// Last-seen identity of the displayed record position, so the
    /// record-position observer can tell a real move/navigation/switch from
    /// the many unrelated mutations `withObservationTracking` also reports.
    /// Seeded in `installRecordPositionObserver()` and re-seeded on relaunch.
    private var lastRecordPositionKey: RecordPositionKey?
    /// Detects the `true -> false` transition of `gobanState.isEditing` that iOS
    /// reacts to (`onChange(of: isEditing)` -> `processIsEditingChange`): leaving
    /// edit mode must cancel any in-flight auto-play.
    private var lastIsEditing = false

    /// Owns the unsaved editing session. While a draft is open,
    /// `navigationContext.selectedGameRecord` is the draft's DETACHED record
    /// rather than a stored game, which is what keeps every existing write
    /// path from reaching SwiftData or iCloud.
    let draftController = DraftController()

    /// True while the crash-mirror Restore sheet is up and unanswered. See
    /// `offerDraftRestoreIfNeeded`.
    private var isOfferingDraftRestore = false

    /// True between returning `.terminateLater` from
    /// `applicationShouldTerminate` and the reply that resolves it. AppKit is
    /// free to re-invoke that delegate method while the sheet is up (a modal
    /// run-loop mode is enough), and a second ask would queue a second sheet
    /// and fire a second reply — one of which leaves the app wedged
    /// "terminating" forever. Exactly one ask is outstanding at a time.
    private(set) var isAwaitingTerminateReply = false

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

    /// Last-seen value of `DownloadCenter.shared.finishedGeneration`, so the
    /// download-center observer can detect a fresh finish. Needed because
    /// closing the Opening Books window no longer cancels a download (see
    /// `OpeningBooksViewController.detachDownloadObservation`) — that window's
    /// own `onBooksChanged()` hook only fires while its row observer is
    /// attached, so a book finishing with the window closed, or never opened
    /// at all, would otherwise stay unloaded with a stale eye state. Seeded in
    /// `installDownloadCenterObserver()`; never re-seeded on relaunch, because
    /// `DownloadCenter` is an app-wide singleton independent of the per-window
    /// engine session.
    private var lastDownloadFinishedGeneration = 0

    /// Last-seen value of `session.engineStatus.availability`, so the
    /// (property-agnostic) `withObservationTracking` callback can tell a real
    /// engine transition from an unrelated mutation. Seeded in
    /// `installEngineAvailabilityObserver()` and re-seeded on relaunch.
    private var lastEngineAvailability = EngineAvailability.launching

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

    /// The toolbar's Board/Book View (eye) item, retained weakly so
    /// `refreshEyeToolbarItem()` can mutate its image/tint/toolTip to reflect
    /// `gobanState.eyeStatus`. The `NSToolbar` owns the item; we only borrow a
    /// reference (set when the item is built in the `.toggleEye` case).
    private weak var eyeToolbarItem: NSToolbarItem?

    /// The toolbar's lock slot, retained weakly so `refreshLockSlotToolbarItem()`
    /// can swap its image/label/tint/action between the Lock/Unlock toggle and
    /// the red "Deactivate Branch" u-turn. One item serves both states — exactly
    /// as the iOS `TopToolbarView` trailing slot does — so the toolbar's width
    /// never changes when a branch starts. The `NSToolbar` owns the item; we only
    /// borrow a reference (set when the item is built in the `.lockSlot` case).
    private weak var lockSlotToolbarItem: NSToolbarItem?

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

    /// Serializes game selections against a running Deep Report at the shared
    /// `selectGame(_:)` chokepoint. The modal report sheet doesn't block
    /// external events, so a Finder SGF-open or a widget deep link could
    /// otherwise interleave a feed and analyze commands with in-flight probe
    /// traffic. `selectGame(_:)` folds `gobanState.reportGenerationActive` into
    /// its `isReady` check; `trackReportGeneration`'s `true -> false` edge
    /// drains the gate.
    ///
    /// It no longer defers on ENGINE readiness (F14/F14b). It used to, because
    /// a selection arriving mid-handshake had its GTP silently dropped — but a
    /// deferred selection also meant a deferred DISPLAY, i.e. a cold-launch
    /// deep link that showed nothing until the model finished loading. The
    /// display now switches at once, the feed is dropped by `MessageList`'s
    /// command gate, and `GobanState.engineSyncGate` remembers the debt so the
    /// handshake's `resyncEngineAfterHandshake` pays it against whatever is
    /// selected by then (latest wins).
    private var selectionGate = ReadinessGate<PendingSelection>()

    /// A game selection awaiting the report to finish. Holds only the target:
    /// the deferred drain does not need the prior game (the projector always
    /// publishes the new game's own size, so `loadGame`'s cosmetic
    /// resize-preload is moot), and not retaining it avoids reading a record
    /// that may have been deleted in the deferred window.
    private struct PendingSelection {
        let game: GameRecord?
    }

    init(modelContainer: ModelContainer, engineLaunchStatus: EngineLaunchStatus) {
        self.modelContainer = modelContainer
        self.engineLaunchStatus = engineLaunchStatus

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "KataGo Anytime"
        // Floor the window at the tallest sheet it presents. `.resizable` +
        // `setFrameAutosaveName` (below) persist the user's chosen size across
        // launches, and without a minimum a shrunk-and-saved frame lets a sheet
        // overhang the window's edge. 700 matches the photo-import sheet's
        // `minHeight` in `LibraryActions.swift`; the deep-report and GIF-export
        // sheets are only 640 tall, so the same floor covers them too. A user
        // whose saved frame is smaller than this will see the window grow back
        // to it on next launch — an accepted trade-off.
        w.contentMinSize = NSSize(width: 560, height: 700)
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

        // Refreshes the window title, dirty dot and conflict subtitle whenever
        // the draft's dirty/conflict state may have changed — including every
        // played move, not just open/close (`DraftController.noteChanged()`).
        draftController.onStateChanged = { [weak self] in
            self?.refreshDraftChrome()
        }

        // Re-checks the conflict state after a coalesced CloudKit remote
        // change, so a game changed on another device is caught live rather
        // than only discovered at Save. `refreshDraftChrome` reads
        // `draftController.hasConflict`, which re-compares `origin` (already
        // updated in place by SwiftData's merge) against the draft's baseline
        // — no separate conflict payload is needed.
        libraryStore.onRemoteChange = { [weak self] in
            // Surfaces as the window subtitle, so a conflict never ambushes
            // the user at Save time.
            self?.refreshDraftChrome()
        }

        let splitVC = MainSplitViewController(
            session: session,
            navigationContext: navigationContext,
            audioModel: audioModel,
            libraryStore: libraryStore,
            windowController: self
        )
        w.contentViewController = splitVC
        // Land keyboard focus on the board pane — not the sidebar `NSSearchField`
        // — when the window first appears, so the LizzieYzy board shortcuts
        // (Space / `,` / `P`) work immediately. Without this, AppKit's key-view-
        // loop default focuses the search field; its field editor is an `NSText`,
        // so `isTextInputActive` is true and the shortcuts type into the search
        // box instead of toggling analysis / playing best / passing. (Setting
        // `contentViewController` above has already loaded the split view's
        // children, so `boardFirstResponderView` is populated here.)
        w.initialFirstResponder = splitVC.boardFirstResponderView
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
        // `maybeCollectSync` sets `player.nextColorForPlayCommand`, and
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
        // `gobanState.isAutoPlaying`). iOS reacts via the `GameSplitView`
        // `.onChange(of: isAutoPlaying)` / `.onChange(of: isEditing)` handlers;
        // this observer is their AppKit stand-in. (The per-move stepping branch
        // lives in the EXISTING analysis observer instead, keyed off
        // `waitingForAnalysis`.)
        installAutoPlayObserver()

        // The board is record-owned, so the AppKit host needs the stand-in for
        // the iOS `recordPositionSync` modifier: publish the record position
        // and run the engine-free side effects (per-index stone cache, book
        // walk, widget reload, draft notice) the moment the record moves.
        // Installed before the engine starts so the launch load's projection
        // is not missed.
        installRecordPositionObserver()

        // Keeps the opening-book lookup walked to the current position so the
        // `.book` overlay (rendered by the hosted `BoardView`) reflects the right
        // node. Reacts to the book `isLoaded` false->true edge and the
        // `eyeStatus -> .book` edge (P6-T5); the per-position sync lives in
        // `handleRecordPositionChange()`. Mirrors the iOS
        // `GameSplitView` `processBookLoadedChange` / `processEyeStatusChange`
        // handlers. Installed before the engine starts so the first book load
        // isn't missed.
        installBookStateObserver()

        // Reconciles a finished book download even when the Opening Books
        // window is closed (or never opened) at the moment it completes —
        // `OpeningBooksViewController`'s own `onBooksChanged()` hook only
        // fires while that window's row observer is attached, and closing the
        // window no longer cancels the transfer. `DownloadCenter` is an
        // app-wide singleton, so this observer is independent of the engine
        // session and installed unconditionally, like the others, before the
        // engine starts.
        installDownloadCenterObserver()

        // Clears the crash sentinel once the engine's first GTP response lands
        // (`engineLifecycle.lastLoadedModelTitle` goes `nil -> non-nil`). Installed
        // before the launch so the first response isn't missed. Mirrors the iOS
        // `ModelRunnerView.onChange(of: engineLifecycle.lastLoadedModelTitle)`.
        installLastLoadedModelObserver()

        // Drains a game selection deferred behind a running Deep Report
        // (`gobanState.reportGenerationActive` true -> false). Installed before the
        // engine starts for consistency with the other observers, though a report
        // cannot start until well after launch.
        installReportGenerationObserver()

        // Re-decides *Held* on every engine transition. Installed before the
        // engine starts so the first `.launching -> .ready` edge is not missed.
        installEngineAvailabilityObserver()

        // What the status line's Retry button does. Set once: `EngineStatus`
        // is owned by the session, which outlives every engine.
        session.engineStatus.onAction = { [weak self] action in
            guard let self, action == .retry else { return }
            // The net that failed is still the active selection, so this
            // relaunches exactly what the user last chose — which is what
            // "Retry" means. `relaunch` is reachable from `.failed` (it has no
            // readiness guard of its own; the guard is on the model dropdown).
            self.relaunch(model: self.modelSelection.currentModel)
        }

        // Put a game on the board NOW, before the engine exists. The board is
        // record-owned, so this needs nothing but the SGF — and running it
        // ahead of `decideRecovery()` means the board is up even when the
        // engine never starts at all.
        seedInitialGame()

        // Run the launch-time crash-recovery decision ONCE, BEFORE arming the
        // sentinel / launching the engine — it must read the PREVIOUS run's
        // sentinel (`pendingLoadModelTitle`), which `startEngineAndSession()`
        // will overwrite (arm) for THIS run. Every outcome launches the engine
        // immediately (last-good model, or the built-in net after an incomplete
        // prior load); see `decideRecovery`.
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

    /// Belt-and-suspenders for `init`'s `initialFirstResponder`: if the sidebar
    /// `NSSearchField` still won the key-view-loop race when the window first
    /// became key, move focus back to the board pane so the LizzieYzy shortcuts
    /// (Space / `,` / `P`) are live immediately. Guarded so it ONLY corrects an
    /// auto-focused text field — it never steals focus the user placed somewhere
    /// deliberately. Deferred one run-loop turn (like `restoreWindowStateOnLaunch`)
    /// so it runs after the window is fully on-screen and the initial focus has
    /// settled.
    func focusBoardOnLaunch() {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let window = self.window,
                  let boardView = (window.contentViewController as? MainSplitViewController)?
                      .boardFirstResponderView
            else { return }
            // The field editor for a focused search/text field is an `NSText`.
            // Only then do we redirect focus; otherwise leave it untouched.
            if window.firstResponder is NSText {
                window.makeFirstResponder(boardView)
            }
        }
    }

    // MARK: - Move navigation
    //
    // The Navigate menu targets the first responder with the selectors
    // implemented below, and the window's local key monitor calls the four
    // arrow-bound ones directly. `NSWindowController` is inserted into the
    // window's responder chain (the window owns it via `super.init(window:)`),
    // so these `@objc` actions are reached after the content view / window
    // decline them. There is no toolbar nav group: move navigation is the
    // keyboard (↑↓ one move, ←→ ten), the Navigate menu, and the Chart tab's
    // click-to-jump.
    //
    // Each action reuses `GobanState`'s `backwardMoves` / `forwardMoves`
    // verbatim — the exact calls the iOS `StatusToolbarItems` makes. Single
    // step uses `limit: 1`, the ten-move jump `limit: 10`, and First/Last
    // `limit: nil`. iOS also mirrors `maybeUpdateAnalysisData` before
    // navigating to persist analysis data while editing, so we do the same.

    /// True while an AppKit sheet (Deep Report, config editor, GIF export) is
    /// presented over the board. The nil-target responder chain still delivers
    /// menu key-equivalents (bare arrows/`,`/`P`/Space, LizzieYzy) to this
    /// controller under a sheet, so game-mutating / analysis-arming actions
    /// gate on this to avoid running behind the sheet — which would desync the
    /// board (and the Deep Report's currentIndex-keyed Copy-to-Comment) and
    /// re-arm the engine the report deliberately paused.
    private var isPresentingSheet: Bool {
        contentViewController?.presentedViewControllers?.isEmpty == false
    }

    /// Mirrors `StatusToolbarItems.isFunctional`: navigation is only allowed
    /// when the engine isn't generating an AI move, isn't auto-playing, no
    /// `showboard` round-trip is in flight, and no modal sheet is up.
    private var isFunctional: Bool {
        guard let gameRecord = navigationContext.selectedGameRecord else { return false }
        let gobanState = session.gobanState
        return !gobanState.shouldGenMove(config: gameRecord.concreteConfig, player: session.player)
            && !gobanState.isAutoPlaying
            && (gobanState.showBoardCount == 0)
            && !isPresentingSheet
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

    /// `↑`: step back one move — the stride of iOS's `backwardFrameAction`,
    /// though reached via `backwardMoves(limit: 1)` like every action here
    /// rather than that method's inline undo.
    @objc func goBackward(_ sender: Any?) { backward(limit: 1) }

    /// `↓`: step forward one move (the stride of iOS's `forwardFrameAction`).
    @objc func goForward(_ sender: Any?) { forward(limit: 1) }

    /// `←`: jump back ten moves (iOS's `backwardAction`, and the same ten-move
    /// stride tvOS uses for a swipe on the review timeline).
    @objc func goBackwardTen(_ sender: Any?) { backward(limit: 10) }

    /// `→`: jump forward ten moves (iOS's `forwardAction`).
    @objc func goForwardTen(_ sender: Any?) { forward(limit: 10) }

    /// `⌥⌘←`: jump to the start of the game.
    @objc func goToStart(_ sender: Any?) { backward(limit: nil) }

    /// `⌥⌘→`: jump to the end of the game.
    @objc func goToEnd(_ sender: Any?) { forward(limit: nil) }

    // MARK: Navigation availability

    /// Whether a move exists at `currentIndex - 1` (i.e. we can step/jump back).
    /// Mirrors `backwardMoves`' loop guard (`getMove(at: currentIndex - 1)` AND
    /// `currentIndex > navigationFloor`): while a branch is active the floor is
    /// the frozen divergence, so Back/First gray out there just as they do at
    /// mainline index 0.
    private var canGoBackward: Bool {
        guard isFunctional,
              let gameRecord = navigationContext.selectedGameRecord,
              let sgf = session.gobanState.getSgf(gameRecord: gameRecord),
              let currentIndex = session.gobanState.getCurrentIndex(gameRecord: gameRecord) else {
            return false
        }
        return currentIndex > session.gobanState.navigationFloor(gameRecord: gameRecord)
            && SgfHelper(sgf: sgf).getMove(at: currentIndex - 1) != nil
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

    /// Shared availability test for the Navigate menu items, keyed off the
    /// action selector.
    ///
    /// The four step/jump items are bound to BARE arrows, so they carry
    /// `!isTextInputActive` — the same gate the bare `,` / `P` / Space items
    /// already have. Without it a menu key equivalent fires while a text control
    /// is editing, and pressing `←` in the sidebar search field or the comment
    /// editor would move the BOARD instead of the caret. It also keeps them in
    /// lockstep with `handleBoardShortcut`, which declines arrows on the same
    /// condition, so the two dispatch paths can never disagree about who owns
    /// the key.
    ///
    /// First/Last deliberately do NOT carry that gate: they are bound to
    /// ⌥⌘← / ⌥⌘→, which is not a text-editing binding and which the local
    /// monitor never claims (it requires no ⌘/⌥/⌃), so there is neither a caret
    /// collision to avoid nor a dispatch path to stay in lockstep with. Gating
    /// them would only disable a working jump whenever a field happens to hold
    /// focus — and with the toolbar nav group gone these are the only
    /// jump-to-either-end commands left.
    private func canPerformNavigation(_ action: Selector?) -> Bool {
        switch action {
        case #selector(goBackward(_:)), #selector(goBackwardTen(_:)):
            return canGoBackward && !isTextInputActive
        case #selector(goForward(_:)), #selector(goForwardTen(_:)):
            return canGoForward && !isTextInputActive
        case #selector(goToStart(_:)):
            return canGoBackward
        case #selector(goToEnd(_:)):
            return canGoForward
        default:
            return true
        }
    }

    // MARK: - Library selection

    /// Public entry: every sidebar click, deep link (`selectGame(byID:)`), New/
    /// Clone/Import, and the deferred-selection drain (`applyPendingSelection`)
    /// land here, so this is where an unsaved draft is resolved before the
    /// board moves on to a different game. Re-selecting the game the open draft
    /// stands for is not a switch at all, so it skips the chokepoint entirely —
    /// otherwise clicking the row you're already editing would look like an
    /// exit and prompt for nothing.
    func selectGame(_ game: GameRecord?) {
        if let game, draftController.resolvedRecord(
            navigationContext.selectedGameRecord) === game {
            return
        }
        resolveDraft(for: .switchGame) { [weak self] in
            self?.performSelectGame(game)
        }
    }

    /// Switches the board to a game chosen from the Library sidebar. Mirrors the
    /// iOS `GameSplitView.processChange` flow via the reusable
    /// `GobanState.loadGame`. The initial launch load is `seedInitialGame()`,
    /// which runs in `init` before any engine exists; this only runs for
    /// genuine post-launch row changes (identity-different from the
    /// currently-selected game). Only reached
    /// through the `selectGame(_:)` chokepoint above, which resolves an open
    /// draft first — by the time this runs there is nothing left to abandon.
    private func performSelectGame(_ game: GameRecord?) {
        let previous = navigationContext.selectedGameRecord
        guard game !== previous else { return }

        // Update the selection synchronously so the sidebar, the board pane, and
        // `ensureSelectedGameRecord` all track it immediately.
        navigationContext.selectedGameRecord = game

        // Arm BEFORE the selection gate: a deferred selection (engine not
        // ready / report active) still loads via `applyPendingSelection` →
        // `load`, and its stones-ready edge must fire the reload too.
        // Deselection has nothing to await — fire immediately.
        switch widgetReloadLatch.gameSwitched(hasNewGame: game != nil) {
        case .fireNow:
            try? modelContainer.mainContext.save()
            WidgetCenter.shared.reloadAllTimelines()
        case .armed:
            break
        }

        // The Deep Report gate, factored into `loadDeferringUntilReady` so
        // every other path that loads a game — not just a sidebar click —
        // shares it.
        loadDeferringUntilReady(game, previous: previous)
    }

    /// Runs the actual `loadGame` for a selection. Split out so both the
    /// ready-path (`performSelectGame(_:)`) and the deferred-path drain
    /// (`applyPendingSelection`) share one call site — and so that the draft
    /// can be re-derived here, once, for every board load in the app.
    ///
    /// `previous` is no longer consulted: it existed only so `loadGame` could
    /// blank the board when the size changed, and the projector now always
    /// publishes the new game's own size. The parameter stays on this seam
    /// (and on `loadDeferringUntilReady`) because eight call sites thread it
    /// through; retiring it is a tidy-up, not part of this change.
    func load(game: GameRecord?, previous: GameRecord?) {
        session.gobanState.loadGame(
            gameRecord: game,
            player: session.player,
            bookLookup: session.bookLookup,
            messageList: session.messageList,
            board: session.board,
            stones: session.stones,
            analysis: session.analysis,
            projector: session.recordPosition
        )
        // `loadGame` re-derives `isEditing` from the loaded SGF, so the draft
        // has to be re-derived with it. The `isEditing` observer cannot cover
        // this on its own: a load that leaves the flag at the value it already
        // had is invisible to an edge detector, which is precisely how the
        // board used to come back unlocked over a stored record.
        syncDraftToEditingState()
    }

    /// Re-derives the draft from the live editing state, so `isEditing == true`
    /// always means a detached draft is taking the writes. See
    /// `DraftEditingSync` for why this is a rule over the state rather than a
    /// pair of edge handlers.
    ///
    /// The two-pass loop itself lives on `DraftEditingSync.settle`, so the test
    /// that pins an engine-free load drives the same loop this does.
    private func syncDraftToEditingState() {
        DraftEditingSync.settle(inputs: { self.draftEditingInputs },
                                apply: { self.applyDraftEditingSync($0) })
    }

    /// Everything `DraftEditingSync` looks at, read from the LIVE state. Read
    /// afresh between passes, which is what lets `.closeStale` be followed by a
    /// decision that sees the draft actually gone.
    private var draftEditingInputs: DraftEditingSync.Inputs {
        let selected = navigationContext.selectedGameRecord
        return DraftEditingSync.Inputs(
            isEditing: session.gobanState.isEditing,
            hasDraft: draftController.draft != nil,
            isDirty: draftController.isDirty,
            draftStandsForSelection: draftController.isDraftRecord(selected),
            hasSelection: selected != nil)
    }

    /// Applies one step of the rule.
    private func applyDraftEditingSync(_ action: DraftEditingSync) {
        switch action {
        case .none:
            break
        case .closeStale:
            draftController.close()
        case .unlock:
            session.gobanState.isEditing = true
        case .open:
            guard let origin = navigationContext.selectedGameRecord else { return }
            // No `loadGame`: the content is identical, so the engine and board
            // must not move — only object identity changes, and from here every
            // existing write path writes into the clone.
            navigationContext.selectedGameRecord = draftController.open(origin: origin)
        }
    }

    /// Defer a board load while a Deep Report is probing: an external trigger
    /// (widget deep link, Finder .sgf open) can arrive mid-report — the modal
    /// sheet doesn't block them — and would interleave a feed and analyze
    /// commands with the report's probe traffic. Drained by
    /// `applyPendingSelection` on the report's `true -> false` edge (see
    /// `trackReportGeneration`).
    ///
    /// That is now the ONLY reason to defer. Engine readiness is no longer one:
    /// the board never waits for the engine, so a selection that lands
    /// mid-handshake switches the display immediately and its GTP is dropped by
    /// `MessageList`'s command gate, which records the debt on
    /// `GobanState.engineSyncGate` for the handshake to pay.
    ///
    /// `internal`, not `private`: `LibraryActions.newGame` (a separate file)
    /// needs it too. Originally only `performSelectGame(_:)` used this gate;
    /// `discardDraftAndReload` and `newGame`'s sheet completion called `load`
    /// straight through. Giving every game-loading call site the same gate,
    /// rather than gating each menu item's `validateMenuItem` and hoping
    /// nothing new calls `load` without also remembering that check, keeps the
    /// guarantee in the one place a future call site would naturally look for it.
    func loadDeferringUntilReady(_ game: GameRecord?, previous: GameRecord?) {
        guard selectionGate.request(PendingSelection(game: game),
                                    isReady: !session.gobanState.reportGenerationActive) != nil
        else {
            // The board has not moved, but the SELECTION already has, so the
            // draft is re-derived now rather than when the gate drains: a clean
            // draft left open by the exit gate would otherwise go on taking the
            // writes for the game the board is about to leave.
            syncDraftToEditingState()
            return
        }
        load(game: game, previous: previous)
    }

    /// Deep-link entry: fetch the game with the given UUID from the model store
    /// and select it — mirrors the iOS `GameSplitView.selectGame(byID:)` helper.
    @MainActor
    func selectGame(byID id: UUID) {
        // F5: fall back to the most-recent game when the deep-linked game was
        // deleted (a widget can lag the store), instead of silently doing nothing.
        // A cold-launch deep link opens the game AT ONCE — engine-free — and is
        // fed to the engine at the handshake; the only remaining deferral (a
        // running Deep Report) is handled by `selectGame(_:)` at the shared
        // chokepoint.
        guard let match = GameRecord.resolveDeepLinkTarget(id: id, container: modelContainer)
        else { return }
        selectGame(match)
    }

    /// Drain: applies a game selection that arrived while a Deep Report was
    /// probing. Called by `trackReportGeneration`'s `true -> false` edge, so a
    /// deferred selection is applied the moment the report finishes (or
    /// aborts).
    ///
    /// It is no longer called on the engine-ready edge — nothing defers on
    /// engine readiness any more (see `loadDeferringUntilReady`). The
    /// handshake's own equivalent is `GobanState.resyncEngineAfterHandshake`,
    /// which feeds the LIVE selection rather than replaying an old one.
    @MainActor
    private func applyPendingSelection() {
        // A report ending is one of the two moments a crash-recovered draft
        // mirror may be offered (the other is the engine-ready edge, in
        // `initializeSession`) — so this runs via `defer`, unconditionally on
        // every call, rather than as a plain trailing statement. A trailing
        // statement would sit after the early-return guard below and so would
        // be skipped whenever nothing was deferred, and it must not be nested
        // inside `resolveDraft`'s completion either: that continuation runs
        // asynchronously behind a Save · Discard · Cancel sheet when a draft is
        // open, or not at all if the user cancels.
        defer { offerDraftRestoreIfNeeded() }

        guard let pending = selectionGate.drainWhenReady() else { return }
        // The target may have been deleted while the report ran (a CloudKit
        // remote delete, or a delete-replacement). Rather than load nothing,
        // re-resolve to the most-recent game — the F5 fallback that
        // `resolveDeepLinkTarget` applies at deep-link time but that was not
        // re-applied here. `previous: nil`: the projector always publishes the
        // new game's own size, so the resize-preload is unnecessary here.
        let fetched = (try? GameRecord.fetchGameRecords(container: modelContainer)) ?? []
        let target = GameRecord.resolveDrainTarget(
            stashed: pending.game,
            stashedIsDeleted: pending.game?.isDeleted == true,
            fetched: fetched)
        // A deferred selection can land while a draft is open (a widget deep
        // link or .sgf file-open doesn't wait on the user), so this drain is an
        // exit too and goes through the same chokepoint as a sidebar switch.
        resolveDraft(for: .switchGame) { [weak self] in
            guard let self else { return }
            self.navigationContext.selectedGameRecord = target
            self.load(game: target, previous: nil)
        }
    }

    /// If a mirror file survived a crash or force-quit, offer to restore it.
    ///
    /// Restore is always a conscious choice, never automatic: a stale draft
    /// silently reattaching itself to a saved game is exactly the class of
    /// surprise this whole feature exists to remove.
    ///
    /// Called on the engine-ready edge (`initializeSession`) and, via `defer`,
    /// whenever a Deep Report releases the selection gate — Restore selects a
    /// game, and offering it against a live engine means the restored position
    /// is fed rather than dropped. Safe to call repeatedly in one session: the
    /// `draftController.draft == nil` guard alone is what stops a second offer
    /// while a draft is open.
    /// Discard clears the mirror immediately; Restore does not (it opens a
    /// draft over the recovered content instead, and that draft's own edits
    /// reschedule the mirror write, same as any other draft) — but either way
    /// `draftController.draft` is non-nil afterward, so the guard above already
    /// covers both buttons and a resolved offer never returns.
    ///
    /// That guard only holds once the sheet has been ANSWERED, though: the
    /// sheet is window-modal, the menu bar stays live under it, and Models ▸
    /// Play produces another engine-ready edge. `isOfferingDraftRestore`
    /// covers the window in between — two sheets would otherwise queue, and
    /// answering Restore then Discard would clear the mirror belonging to the
    /// draft the first sheet had just restored.
    func offerDraftRestoreIfNeeded() {
        guard !isOfferingDraftRestore,
              draftController.draft == nil,
              let mirror = draftController.mirrorStore.read(),
              let window else { return }
        isOfferingDraftRestore = true

        let name = mirror.draft.game.name
        let alert = NSAlert()
        alert.messageText = "KataGo Anytime has unsaved changes to \"\(name)\"."
        alert.informativeText = "These changes were never saved to iCloud. Restore them, or discard them and open the saved game."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Discard")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.isOfferingDraftRestore = false
            guard response == .alertFirstButtonReturn else {
                self.draftController.mirrorStore.clear()
                return
            }

            // The origin may have been deleted, or synced away, while the app
            // was gone. This deliberately uses `fetchGameRecord`, NOT the
            // deep-link resolver: `resolveDeepLinkTarget` falls back to the
            // most-recently-modified game on a miss (right for a widget tap
            // racing a delete), which here would silently reattach the
            // restored draft to an unrelated game — exactly the surprise this
            // feature exists to remove. A plain nil-on-miss fetch keeps the
            // restore untitled instead, so the work survives either way.
            let origin = mirror.draft.originUUID.flatMap {
                try? GameRecord.fetchGameRecord(uuid: $0, container: self.modelContainer)
            }
            let previous = self.navigationContext.selectedGameRecord
            let record = self.draftController.restore(from: mirror, origin: origin)
            self.navigationContext.selectedGameRecord = record
            self.load(game: record, previous: previous)
            self.session.gobanState.isEditing = true
            self.refreshDraftChrome()
        }
    }

    // MARK: - Deep Report selection gating
    //
    // The `selectionGate` (`ReadinessGate` at the shared `selectGame(_:)`
    // chokepoint) exists for exactly one case now — a Deep Report in flight: the
    // report's sheet is modal to user interaction but does NOT block external
    // events (a Finder SGF-open or widget deep link can still call `selectGame(_:)`
    // while probes are running), which would interleave a feed and analyze commands
    // with the report's `kata-analyze` probe traffic. `selectGame(_:)` folds
    // `!gobanState.reportGenerationActive` into the gate's `isReady` check; this
    // observer drains the gate on the report's `true -> false` edge, mirroring the
    // exact self-rescheduling `withObservationTracking` pattern the other
    // observers use (e.g. `installLastLoadedModelObserver`/`trackLastLoadedModel`).
    // Minimal by design: defer + drain only — never cancels the running report.

    /// Last-seen value of `session.gobanState.reportGenerationActive`, so the
    /// (property-agnostic) `withObservationTracking` callback can detect the
    /// `true -> false` transition (report finished or aborted) that should drain
    /// the selection gate. Seeded in `installReportGenerationObserver()` and
    /// re-seeded on relaunch.
    private var lastReportGenerationActive = false

    /// Seeds the snapshot from the live `gobanState` and starts the
    /// self-rescheduling observation bridge. Called once in `init`.
    private func installReportGenerationObserver() {
        lastReportGenerationActive = session.gobanState.reportGenerationActive
        trackReportGeneration()
    }

    /// One observation pass: tracks `reportGenerationActive`, and on change
    /// re-reads the committed value on the main actor, reacts, then re-arms.
    private func trackReportGeneration() {
        withObservationTracking {
            _ = session.gobanState.reportGenerationActive
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.handleReportGenerationChange()
                self.trackReportGeneration()
            }
        }
    }

    /// On `reportGenerationActive` going `true -> false`, drain any selection the
    /// gate deferred while the report was running. Refreshes the snapshot at the
    /// end.
    private func handleReportGenerationChange() {
        let newValue = session.gobanState.reportGenerationActive
        if lastReportGenerationActive && !newValue {
            applyPendingSelection()
        }
        lastReportGenerationActive = newValue
    }

    // MARK: - Engine availability observer + the Held rule
    //
    // Engine availability is a STATE the board displays, never a screen that
    // replaces it. `EngineStatusView` (inside the hosted `BoardView`) renders
    // it; the window controller only has to keep the one state the board's own
    // size decides — *Held* — in step with the engine and the record.

    /// Seeds the availability snapshot from the live session and starts the
    /// self-rescheduling observation bridge. Called once in `init`.
    private func installEngineAvailabilityObserver() {
        lastEngineAvailability = session.engineStatus.availability
        trackEngineAvailability()
    }

    /// One observation pass: tracks the engine's availability, and on change
    /// re-reads the committed value on the main actor, reacts, then re-arms
    /// (one-shot).
    private func trackEngineAvailability() {
        withObservationTracking {
            _ = session.engineStatus.availability
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.handleEngineAvailabilityChange()
                self.trackEngineAvailability()
            }
        }
    }

    /// Whether the board on screen is one the engine can take depends on the
    /// engine's state as much as on the board's size, so every availability
    /// edge re-decides Held.
    ///
    /// `applyHeldStatus` refreshes `lastEngineAvailability` itself (it has to —
    /// its own write lands while observation is un-armed and produces no
    /// callback), so this only has to filter out the passes where nothing moved.
    private func handleEngineAvailabilityChange() {
        guard session.engineStatus.availability != lastEngineAvailability else { return }
        applyHeldStatus()
    }

    /// Feeds the engine the position the board is showing, and re-arms analysis
    /// off the answer.
    ///
    /// The turn is PARKED at `.unknown` as part of the feed — inside the shared
    /// seam, which parks only when a feed actually goes out. Analysis re-arms
    /// off the turn EDGE (`BoardView.onChange(of: player.nextColorForPlayCommand)`),
    /// and a relaunch does not change whose move it is: without the park the
    /// showboard reply would restate the colour the board already held, no edge
    /// would fire, and a perfectly healthy fresh engine would sit there
    /// analysing nothing. This used to be a local park-then-un-park here; the
    /// seam owns it now, so iOS and visionOS get the same behaviour for free.
    private func resyncEngineToRecord() {
        guard session.messageList.isAcceptingCommands,
              let gameRecord = navigationContext.selectedGameRecord else { return }
        session.gobanState.resyncEngineAfterHandshake(
            gameRecord: gameRecord,
            player: session.player,
            messageList: session.messageList,
            stones: session.stones,
            projector: session.recordPosition)
    }

    /// Re-decides *Held* — "this board is larger than the running engine's Max
    /// Board Size" — from the projected board size, the cap the running engine
    /// LAUNCHED with, and the current availability.
    ///
    /// Held is a status, not a screen: the record position keeps drawing, and
    /// navigation keeps working. What changes is that the engine must not be
    /// fed. `GobanState.loadGame` already refuses an oversized record
    /// (`boardFitsEngine`), but `forwardMoves`/`backwardMoves` do not check
    /// board size at all — so scrubbing one would push `play` after `play` at
    /// an engine that was never told this board exists, and its `?` refusals
    /// would then force `stones.isReady = true`, i.e. claim a sync that does
    /// not exist. Shutting the command gate for the duration closes that, and
    /// reuses the launching-engine machinery rather than adding a second one.
    ///
    /// The size comes from the PROJECTED position (`session.board`), which the
    /// projector writes from the record's SGF — the same source the feed sizes
    /// itself from. Reading `Config.boardWidth` instead would let the two
    /// disagree on an imported record whose config was never updated, and then
    /// the status line would call a board fine that the feed refuses.
    private func applyHeldStatus() {
        let engineStatus = session.engineStatus
        // Whatever this decides, the observer's snapshot must end up agreeing
        // with it. `withObservationTracking` is UN-ARMED while this runs — the
        // callback that led here fires once and re-arms only afterwards — so a
        // write below produces no callback of its own, and the other two call
        // sites (the record-position observer, the handshake) never went
        // through the callback at all. A snapshot left behind would make the
        // next genuine edge look like one already handled, and Held would stop
        // being re-decided.
        defer { lastEngineAvailability = engineStatus.availability }
        let current = engineStatus.availability
        // Zero when nothing is selected: the projector keeps the outgoing
        // game's size, and "no game" is not "too large".
        let hasGame = navigationContext.selectedGameRecord != nil
        let next = EngineHeldRule.decide(
            current: current,
            boardWidth: hasGame ? Int(session.board.width) : 0,
            boardHeight: hasGame ? Int(session.board.height) : 0,
            maxBoardLength: launchedMaxBoardLength)
        // Assign only on a real change: an `@Observable` write invalidates
        // every reader even when the value is identical, and this runs on
        // every game switch and every engine transition.
        guard next != current else { return }

        // The rule decides THAT it happens; the session owns WHAT happens
        // (`holdEngineSession` / `releaseEngineHold`), shared with iOS,
        // visionOS and tvOS. Four hand-written copies of the effect is how
        // three of them ended up skipping `abortInFlightBoardCollection` —
        // which strands a half-read `showboard` block and kills analysis until
        // a relaunch.
        switch next {
        case .held(let maxBoardLength):
            session.holdEngineSession(maxBoardLength: maxBoardLength)
        case .ready:
            session.releaseEngineHold(gameRecord: navigationContext.selectedGameRecord)
        default:
            // Unreachable — `EngineHeldRule` only ever moves `.ready ↔ .held`,
            // and an unchanged verdict returned above.
            engineStatus.availability = next
        }
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
                session.engineStatus.availability = .failed(
                    reason: "The built-in network is missing from this build.")
                return
            }
            // Say so. The engine that comes up is NOT the one the user chose,
            // and the note survives into `.ready` (a perfectly working engine
            // running the wrong net is exactly what has to be reported).
            session.engineStatus.note =
                "\(model.title) was removed — using the built-in network"
            model = builtIn
            modelPath = builtInPath
        } else {
            // A previous launch's fallback note must not outlive the launch
            // that earned it.
            session.engineStatus.note = nil
        }

        guard let modelPath else { return } // unreachable — fallback set it above.

        // Per-model engine settings (backend device, board-size NN buffer, tuner
        // flags). Same UserDefaults keys as iOS.
        var settings = BackendSettings(model: model)

        // Arm the crash sentinel BEFORE starting the engine thread, exactly as
        // the iOS `ModelRunnerView` does (lines 92-94). If the engine
        // OOM-crashes before the first GTP response, this value survives the
        // process death and the NEXT launch's `decideRecovery()` falls back to
        // the built-in net instead of restarting the same crash. `reset()` first so
        // the `lastLoadedModelTitle` observer re-fires even when the same model
        // is (re)launched; `synchronize()` flushes the sentinel to disk
        // immediately so an imminent crash can't lose it.
        engineLifecycle.reset()
        modelSelection.pendingLoadModelTitle = model.title
        UserDefaults.standard.synchronize()

        let engineStarted = startKataGoThread(
            modelPath: modelPath,
            deviceAssignments: EngineDeviceAssignments.platformMux,
            maxBoardSizeForNNBuffer: settings.effectiveMaxBoardLength,
            requireExactNNLen: settings.requireExactNNLen,
            tunerFull: settings.tunerFull,
            reTune: settings.reTune
        )

        // The engine helper failed to spawn. Do NOT start the session loop — it
        // would drive the uninitialized in-process bridge and hang. Surface the
        // failure instead; the app stays responsive, and the board — which
        // needs no engine to draw the record — stays on screen behind the
        // alert with the failure named on it.
        guard engineStarted else {
            session.endEngineSession(
                .failed(reason: "KataGo Anytime couldn’t launch its engine helper."))
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
        // Insurance for the relaunch path (and for a store emptied while the
        // app ran): `seedInitialGame()` already selected a game at launch, and
        // this keeps its own selection when there is one.
        let gameRecords = (try? GameRecord.fetchGameRecords(container: modelContainer)) ?? []
        _ = ensureSelectedGameRecord(gameRecords: gameRecords, context: context)

        sessionTask = Task { @MainActor in
            await initializeSession(model: model, context: context)
        }
    }

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
        // Remember the cap the engine is actually launching with, so the New Game
        // dialog can't offer a board this engine would fatally reject.
        launchedMaxBoardLength = maxBoardSizeForNNBuffer
        // Same number, in the two places that gate on it at RUN time: the
        // status line (what *Held* reports) and the feed itself, which refuses
        // a record this engine cannot hold. Set here, at the spawn, because
        // this is the first moment the number is true.
        session.engineStatus.launchedMaxBoardLength = maxBoardSizeForNNBuffer
        session.gobanState.engineMaxBoardLength = maxBoardSizeForNNBuffer
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

    /// Puts a game on the board BEFORE any engine exists.
    ///
    /// The board is record-owned — its position is replayed from the record's
    /// own SGF — so a selection plus `load(game:)` is the whole of it. `load`
    /// is exactly what the launch used to run only AFTER the GTP handshake,
    /// which is why this pane sat on a spinner for the entire model load.
    ///
    /// The feed `loadGame` builds is offered to a command gate that is still
    /// shut; `MessageList` drops it (and says so in the transcript) and
    /// `GobanState.engineSyncGate` records the debt, which
    /// `resyncEngineAfterHandshake` pays against whatever is selected by then.
    private func seedInitialGame() {
        let context = modelContainer.mainContext
        let gameRecords = (try? GameRecord.fetchGameRecords(container: modelContainer)) ?? []
        let selected = ensureSelectedGameRecord(gameRecords: gameRecords, context: context)
        load(game: selected, previous: nil)
    }

    /// The handshake and everything that follows it, for one engine launch.
    ///
    /// `handshake` and then the FEED — never a fixed bundle of config commands
    /// first. macOS was the platform that proved the bundle wrong (it is now
    /// deleted everywhere), for two reasons, and the first is a bug:
    ///
    ///  1. The bundle stated the SELECTED GAME's board size, and it ran before
    ///     anything had asked whether this engine can hold that board. An
    ///     iCloud-synced 37x37 record against a 19 NN buffer would be announced
    ///     as `rectangular_boardsize 37 37` to the very engine that must never
    ///     hear it — before `applyHeldStatus` got a word in.
    ///  2. It was redundant anyway. `EngineFeed.openingCommands` — what the
    ///     feed below sends — is a strict superset: board size (taken from the
    ///     SGF, which is the record's own authority on its geometry, not from a
    ///     `Config` that may disagree), `clear_board`, the rules bundle, komi,
    ///     `friendlyPassOk false`, playout-doubling advantage, wide root noise,
    ///     the symmetric human-SL bundle, the setup stones, and the moves
    ///     (pinned by `EngineFeedInitialCommandsTests`).
    ///
    /// So macOS states the engine's whole world exactly once, in the feed, and
    /// only for a board the engine can actually take.
    private func initializeSession(model: NeuralNetworkModel,
                                   context: ModelContext) async {
        // Until this returns the command gate is shut: the board has been
        // showing the record position since `seedInitialGame`, and everything
        // it wanted to tell the engine was dropped and remembered.
        await session.handshake(
            selectedModelTitle: model.title,
            engineLifecycle: engineLifecycle
        )

        // The engine that just came up may be smaller than the board on screen.
        // Settled BEFORE anything is sent, so an oversized board is never
        // mentioned to an engine that would abort on it.
        applyHeldStatus()

        // Pay the debt: feed the LIVE selection at the LIVE cursor. Latest
        // wins — during the handshake the user may have switched games,
        // scrubbed, or both, and every one of those sends was dropped. A
        // no-op while Held (the gate is shut) or with nothing selected, which
        // is exactly the case where the engine must be told nothing at all.
        resyncEngineToRecord()

        // Engine-ready edge: offer a draft mirror left behind by a crash, so a
        // restored position reaches an engine that can be told about it.
        offerDraftRestoreIfNeeded()

        let gameRecords = (try? GameRecord.fetchGameRecords(container: modelContainer)) ?? []

        // Straight into the steady-state loop. There used to be one standalone
        // `messaging()` first, copied from an iOS launch that no longer exists;
        // `run()` is `while !stopRequested { messaging() }`, so it is the same
        // thing minus two hazards. A launch that ends HELD sends the engine
        // nothing at all, so that lone read would park on a helper that has not
        // been asked anything — and a launch whose engine had already been
        // declared gone would have had its `.failed` overwritten by that read's
        // own `.expected` EOF classification.
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
    ///   2. `sendLifecycleCommand("quit")` → the child is told to go, and the
    ///      transcript says so. This MUST precede step 3: `endEngineSession`
    ///      shuts the command gate, and while the `quit` itself bypasses that
    ///      gate (that is what "lifecycle command" means), keeping the order
    ///      stated here is what makes "the engine was asked to stop, THEN
    ///      declared gone" true of every teardown.
    ///   3. `endEngineSession(.launching)` → the session state that claims an
    ///      engine exists comes down at once, so the ~3.5s `terminate()`
    ///      escalation below is not a window in which a sidebar click can push
    ///      GTP at a quitting child.
    ///   4. `terminate()` → the child exits and EOFs its stdout, unblocking the
    ///      consumer's suspended `getMessageLine`.
    ///   5. `await sessionTask` → guarantees the old `run()` loop finished before
    ///      a new engine is injected (no two concurrent loops on one session).
    ///   6. Reset the remaining per-launch state and re-seed the observer
    ///      snapshots so the existing `withObservationTracking` observers don't
    ///      fire spurious transitions against stale `lastX` values on the fresh
    ///      engine.
    private func stopEngineAndSession() async {
        // (1) End the GTP message loop. `messaging`'s `if !stopRequested` guard
        // and `run`'s `while !stopRequested` both collapse on this.
        session.stopRequested = true

        // (2) Ask the engine to quit — BEFORE the session is declared gone.
        //
        // Through the SESSION, so the Developer-Mode transcript echoes it like
        // every other command: a teardown that leaves no trace is a teardown
        // nobody can debug. `sendLifecycleCommand` writes to the same
        // subprocess (`session.engine` IS `engineProcess` once
        // `startKataGoThread` wired it in) and bypasses the command gate, which
        // is exactly what a teardown must not be blocked by.
        //
        // Identity-checked rather than assumed: before the first spawn — or
        // after one that failed — `session.engine` is still the unused
        // in-process bridge, and a `quit` written into that process-global
        // input buffer would sit there waiting for an engine that has not
        // started yet.
        if let engineProcess, session.engine === engineProcess {
            session.sendLifecycleCommand("quit")
        } else {
            engineProcess?.sendCommand("quit")
        }

        // (3) The engine is on its way out, so nothing may still behave as
        // though one is there. `endEngineSession` shuts the command gate,
        // abandons any handshake still waiting on the dying child, and drops
        // every signal claiming the board and the engine agree
        // (`stones.isReady`, `showBoardCount`, the pending move) — which is
        // also what stops the old run loop from collecting the quitting
        // engine's trailing output as if it described the board on screen.
        //
        // `.launching`, not a failure: this exit is one we ASKED for, and the
        // relaunch sets `.launching` again a moment later anyway. The run
        // loop's own EOF branch usually classifies it identically first
        // (`GameSession.noteEngineExit` reads `stopRequested`, raised in step
        // 1); this covers the case where it exited on the flag instead, and is
        // idempotent either way. The board does NOT come down for any of it.
        session.endEngineSession(.launching)

        // (4) Force the child down. Closing its stdin (and SIGTERM if needed)
        // makes the child exit, which EOFs its stdout — that is what unblocks
        // the run loop's suspended `getMessageLine` (no in-process "\n" nudge
        // needed out-of-process). terminate() is synchronous (brief), so run it
        // OFF the main actor to keep the UI responsive and to let the run
        // loop's main-actor continuation make progress once EOF arrives.
        if let engine = engineProcess {
            await Task.detached { engine.terminate() }.value
        }

        // (5) Await the old run loop's completion before wiring a new engine —
        // `GameSession` is reused across relaunch, so the old loop (which reads
        // through `session.engine`) must finish first. The child's EOF lets it
        // observe `stopRequested` and exit; this Task then completes.
        await sessionTask?.value
        sessionTask = nil

        // (6) Reset for the next launch.
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
        lastIsEditing = gobanState.isEditing
        // Re-seed the displayed-position key so the relaunch's own reload does
        // not read as a position change (the board never moved).
        lastRecordPositionKey = gobanState.recordPositionKey(
            gameRecord: navigationContext.selectedGameRecord)
        // Re-seed the branch-reload snapshot too, so a relaunch's fresh engine
        // (which reloads the board itself) doesn't spuriously fire the reload
        // observer on an unrelated `branchSgf` value carried across the relaunch.
        lastBranchSgf = gobanState.branchSgf
        // Re-seed the book-state snapshots so the still-armed observer doesn't read
        // a relaunch's fresh book-load / eye-status as a spurious edge.
        lastBookLoaded = session.bookLookup.isLoaded
        lastEyeStatus = gobanState.eyeStatus
        // Re-seed the report-generation snapshot too, matching the other observers'
        // reseed convention (in practice always false — a report doesn't survive
        // an engine relaunch).
        lastReportGenerationActive = gobanState.reportGenerationActive
        // And the engine's own state. The teardown just wrote `.launching`, so
        // without this the availability observer would read the relaunch's
        // `.launching -> .ready` edge against a stale `.ready` snapshot and
        // skip it — which is the edge that re-decides Held for the fresh
        // engine's (possibly different) Max Board Size.
        lastEngineAvailability = session.engineStatus.availability
    }

    /// Switches the active model and relaunches the engine in-process. Records
    /// `model` as the authoritative user selection (`modelSelection.setActiveModel`)
    /// BEFORE tearing the old engine down, so the fresh `startEngineAndSession()`
    /// resolves `modelSelection.currentModel == model` and launches it via
    /// `BackendSettings` (P5-T2). This makes `relaunch(.builtIn)` and
    /// `relaunch(otherDownloadedNet)` both genuinely switch.
    ///
    /// `startEngineAndSession()` re-runs the FULL init (handshake → resync →
    /// messaging → run). The board does NOT come down for any of it: it keeps
    /// drawing the record position, the status line says "Loading engine…",
    /// and `resyncEngineAfterHandshake` re-states that position to the new
    /// engine. A fresh `initializeSession` Task is started there, after
    /// `stopEngineAndSession()` has confirmed the old `run()` loop ended — so
    /// there are never two concurrent `run()` loops.
    ///
    /// Deliberately UNGUARDED on engine readiness: this is also the Retry
    /// action on the status line's `.failed` state, and refusing to relaunch a
    /// dead engine would leave the only way out disabled.
    ///
    /// It IS guarded on re-entrancy. Readiness is not the same question: a
    /// relaunch spends most of its life with the engine unready, and the three
    /// ways in here (Retry, the Models window's Play, the toolbar dropdown)
    /// are not all covered by the dropdown's own `isReady` check — Retry is
    /// reachable precisely when the engine is NOT ready, and the Models window
    /// switches nets with no readiness check at all. Two overlapping calls
    /// would run two teardown/spawn pairs against one session: two `run()`
    /// loops on one transport, and `engineProcess` replaced underneath the
    /// teardown still waiting on it. `EngineRestartRules.shouldBeginRelaunch`
    /// is the decision, so it is pinned by a test this target cannot host.
    ///
    /// NOTE: arming/clearing the crash sentinel (`pendingLoadModelTitle`) around
    /// this launch is P5-T4's job; this method only records the selection.
    func relaunch(model: NeuralNetworkModel) {
        guard EngineRestartRules.shouldBeginRelaunch(isRelaunchInFlight: isRelaunching) else { return }
        isRelaunching = true
        modelSelection.setActiveModel(model)
        Task { @MainActor in
            // `defer` rather than a trailing assignment: `startEngineAndSession`
            // is synchronous but starts its own handshake Task, and anything
            // that throws or returns early below must still release the guard —
            // a stuck flag would make the app permanently un-relaunchable, with
            // Retry silently doing nothing.
            defer { isRelaunching = false }
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
    /// the P5-T6 toolbar dropdown). The window's "Play" path routes back
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

    /// Retained for the same reason as `modelsWindowController`.
    private var openingBooksWindowController: OpeningBooksWindowController?

    /// Opens (or brings forward) the native Opening Books window. Reached through
    /// the responder chain from the Window-menu "Manage Opening Books…" item. A
    /// download, import, delete, or active-book change inside the window
    /// re-evaluates the active game's book load + eye state via
    /// `refreshBookStateForSelectedGame()`.
    @objc func showOpeningBooksWindow(_ sender: Any?) {
        if openingBooksWindowController == nil {
            openingBooksWindowController = OpeningBooksWindowController(
                onBooksChanged: { [weak self] in
                    self?.refreshBookStateForSelectedGame()
                }
            )
        }
        openingBooksWindowController?.showWindow(sender)
        openingBooksWindowController?.window?.makeKeyAndOrderFront(sender)
    }

    /// Reconciles the active game's opening-book state after a book is
    /// downloaded, imported, deleted, or the active-book choice changes: load
    /// the size's resolved book if one is available (`loadIfNeeded` reloads
    /// when the resolved identity changed); otherwise unload and leave book
    /// view.
    private func refreshBookStateForSelectedGame() {
        // The change may concern a size other than the selected game's — e.g.
        // deleting a 9x9 book while a 19x19 game is up. If the loaded book no
        // longer resolves for its own size, drop it rather than leaving a
        // dangling identity answering isReady for a deleted file.
        session.bookLookup.unloadIfStale()

        guard let cfg = navigationContext.selectedGameRecord?.concreteConfig else { return }
        let size = cfg.boardWidth
        if selectedBookAvailable {
            session.bookLookup.loadIfNeeded(boardSize: size)
        } else {
            if session.bookLookup.isReady(forBoardSize: size) {
                session.bookLookup.unload()
            }
            if session.gobanState.eyeStatus == .book {
                session.gobanState.eyeStatus = .opened
            }
        }
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
    // Port of the iOS `ModelRunnerView` `.onAppear` recovery branch + the
    // `lastLoadedModelTitle` clear, adapted for AppKit. iOS presents a model
    // picker over its (always-mounted) board; macOS has no picker — the net is
    // chosen from the Models window — so where iOS would `.presentPicker` or
    // report a `.failedLastLaunch`, the Mac app falls back to launching the
    // BUILT-IN net (never re-launching a model that apparently just crashed).
    // The board is up throughout either way, and a launch that then FAILS is
    // reported inline with a Retry button rather than by a screen.
    //
    // Ordering is the crux: the decision reads `pendingLoadModelTitle` /
    // `selectedModelTitle` reflecting the PREVIOUS run, and must run BEFORE
    // `startEngineAndSession()` arms `pendingLoadModelTitle` for THIS run. So
    // `init` calls `decideRecovery()` (not `startEngineAndSession()` directly):
    //   • `.autoRestore` -> launch the last-good model immediately (and, on a
    //     fresh Release install, the built-in net it resolves to).
    //   • `.presentPicker` (DEBUG) / `.failedLastLaunch` (an incomplete prior
    //     load) -> launch the safe built-in net; never auto-relaunch a model
    //     that may have OOM'd. No alert is shown.

    /// Runs the launch-time recovery decision exactly once and launches the
    /// engine. Guarded by `hasDecidedRecovery` so scene/relaunch transitions
    /// can't re-run it.
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
            isDebug: isDebug,
            builtInTitle: NeuralNetworkModel.builtInModel?.title ?? ""
        ) {
        case .autoRestore:
            // `modelSelection.currentModel` already resolves the active model
            // from `selectedModelTitle` — and falls back to the built-in net
            // when nothing is persisted, which is exactly the Release
            // fresh-install case the decision now spells as
            // `.autoRestore(builtInTitle)`.
            startEngineAndSession()

        case .presentPicker, .failedLastLaunch:
            // DEBUG, OR an incomplete prior load (the sentinel survived process
            // death). macOS has no launch picker, so both fall back to the safe
            // built-in net — never auto-relaunch the model that may have OOM'd.
            // No alert is shown; the Models window is how a user picks another.
            // Launching the built-in net re-arms and then clears the sentinel
            // via the normal lifecycle.
            if !pending.isEmpty {
                recoveryLogger.error(
                    "Previous launch did not finish loading model: \(pending, privacy: .public). Falling back to the built-in network."
                )
            }
            if let builtIn = NeuralNetworkModel.builtInModel {
                modelSelection.setActiveModel(builtIn)
            }
            startEngineAndSession()
        }
    }

    // MARK: - First-response sentinel clear (P5-T4)
    //
    // Port of the iOS `ModelRunnerView.onChange(of: engineLifecycle.lastLoadedModelTitle)`
    // (lines 115-119): when the engine's first GTP response lands,
    // `GameSession.handshake` calls `engineLifecycle.markFirstResponse(...)`,
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
        // The engine just reported the net it actually loaded; refresh the
        // toolbar button title so a fallback launch (picked net missing → built-in
        // runs) shows the running net, not the optimistic pick. The dropdown's
        // checkmark is already live — it rebuilds via `menuNeedsUpdate` on open.
        refreshActiveModelToolbarItem()
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
        // Deep Report probes own the engine stream; the report's restore path
        // deliberately does NOT re-arm analysis (the sheet pauses it, and it
        // stays paused until the user resumes). Frozen waitingForAnalysis
        // means this can't fire mid-report today — this guard keeps that true
        // if the freeze semantics ever change. Placed before the `lastWaitingForAnalysis`/
        // `lastAnalysisStatus` snapshot update below (not just the reactive
        // block): a skipped pass must skip that update too, or the transition
        // that triggered this call would be silently marked "seen" without
        // ever being handled, desyncing the snapshots from what actually ran.
        guard !session.gobanState.reportGenerationActive else { return }
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
                    // The bundle embeds the maxVisits reset (structural fix for
                    // the sticky human-profile gen-move cap).
                    session.messageList.appendAndSend(commands: GtpCommandBuilder.continuousAnalyzeCommands(
                        interval: gameRecord.concreteConfig.analysisInterval,
                        maxMoves: gameRecord.concreteConfig.maxAnalysisMoves))
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
                // That next `info` line is the next `true -> false` edge. The
                // ADVANCE itself no longer waits for anything: `autoPlayStep`
                // moves `currentIndex` and plays in the same call, so no
                // `stones.isReady` edge can be missed or doubled. The terminal
                // `getMove` miss sets `isAutoPlaying = false`, ending the loop.
                if gobanState.isAutoPlaying,
                   !session.analysis.info.isEmpty,
                   session.stones.isReady {
                    gobanState.maybeUpdateAnalysisData(
                        gameRecord: gameRecord,
                        analysis: session.analysis,
                        board: session.board,
                        stones: session.stones
                    )

                    gobanState.autoPlayStep(
                        gameRecord: gameRecord,
                        messageList: session.messageList,
                        player: session.player,
                        stones: session.stones,
                        audioModel: audioModel
                    )
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
    //
    // Same `withObservationTracking` gotchas as the other observers: `onChange`
    // fires ONCE per tracked-property change, BEFORE the mutation commits, and
    // doesn't say which property changed. So we hop to `Task { @MainActor }`, read
    // LIVE committed values, react, update the snapshots, and re-register tracking
    // (it's one-shot). iOS's `onChange(of: isAutoPlaying)` reacts to either edge
    // (`old != new`).
    //
    // Re-entrancy: handler (1)'s TRUE branch mutates `analysisStatus`/`eyeStatus`
    // (both tracked by OTHER observers) and the stones via `undo`. None of those
    // observers re-enter this one, and this observer's reactions send raw GTP /
    // mutate state without itself flipping `isAutoPlaying` (except the explicit
    // terminal `false`, handled by the stepping branch, not here). The stepping
    // loop's terminal condition (`getMove` miss -> `isAutoPlaying = false`)
    // guarantees the cycle stops. See the orchestrator notes for the full trace.

    /// Seeds the snapshots from the live state and starts the self-rescheduling
    /// observation bridge for `isAutoPlaying` + `isEditing`. Called once in
    /// `init`, right after `installConfirmationObserver()`.
    private func installAutoPlayObserver() {
        lastIsAutoPlaying = session.gobanState.isAutoPlaying
        lastIsEditing = session.gobanState.isEditing
        trackAutoPlay()
    }

    /// One observation pass: registers tracking of the properties, and on change
    /// re-reads the committed values on the main actor, reacts, then re-arms.
    private func trackAutoPlay() {
        withObservationTracking {
            // Touch each property so a change to any fires `onChange`.
            _ = session.gobanState.isAutoPlaying
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

        // iOS `onChange(of: gobanState.isAutoPlaying)` -> `processIsAutoPlayingChange`
        // reacts to ANY change (it reads the live `isAutoPlaying` rather than the
        // edge), so mirror with `old != new`.
        if newIsAutoPlaying != lastIsAutoPlaying {
            handleIsAutoPlayingChange()
        }

        // iOS `onChange(of: gobanState.isEditing)` -> `processIsEditingChange`:
        // leaving edit mode cancels auto-play (parity + safety — guarantees the
        // loop can't be left running with no edit session). iOS lines 351-356.
        if !gobanState.isEditing && lastIsEditing {
            gobanState.isAutoPlaying = false
        }

        // The draft rides along, but NOT on the edge: it is re-derived from the
        // live state (see `syncDraftToEditingState`), because the edge is
        // exactly what a load that leaves `isEditing` already true does not
        // produce.
        syncDraftToEditingState()

        lastIsAutoPlaying = gobanState.isAutoPlaying
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

            // auto-play analysis by best AI profile. BEFORE the rewind, which
            // ends with `sendPostExecutionCommands` (mirrors iOS).
            if let humanSLModel = HumanSLModel(profile: "AI") {
                session.messageList.appendAndSend(commands: humanSLModel.commands)
                session.messageList.appendAndSend(command: "kata-set-param playoutDoublingAdvantage 0")
                session.messageList.appendAndSend(command: "kata-set-param analysisWideRootNoise 0")
            }

            // Rewind to the start of the game through the shared path, which
            // only `undo`s the moves the engine was actually fed.
            gobanState.backwardMoves(
                limit: nil,
                gameRecord: gameRecord,
                messageList: session.messageList,
                player: session.player,
                stones: session.stones
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

                session.messageList.appendAndSend(command: GtpCommandBuilder.playoutDoublingAdvantageCommand(config.playoutDoublingAdvantage))
                session.messageList.appendAndSend(command: GtpCommandBuilder.analysisWideRootNoiseCommand(config.analysisWideRootNoise))

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

    // MARK: - Record-position observer (the AppKit `recordPositionSync`)
    //
    // The board is record-owned: the position it draws is replayed from the
    // record's SGF, never from the engine's `showboard`. iOS mounts the
    // `recordPositionSync` modifier for that; an `NSWindowController` has no
    // SwiftUI body, so the same job is done with the house
    // `withObservationTracking` pattern (one-shot, re-armed on every callback,
    // committed values read on the main actor).

    /// Seeds the key snapshot from the live state and starts the
    /// self-rescheduling observation bridge for the displayed record position.
    /// Called once in `init`.
    private func installRecordPositionObserver() {
        lastRecordPositionKey = session.gobanState.recordPositionKey(
            gameRecord: navigationContext.selectedGameRecord)
        trackRecordPosition()
    }

    /// One observation pass: touches everything the position key is built from
    /// so a change to any of them fires, then re-reads the committed values on
    /// the main actor, reacts, and re-arms.
    private func trackRecordPosition() {
        withObservationTracking {
            // The selection itself, the active branch line, and — through the
            // selected record — the mainline SGF and cursor.
            let record = navigationContext.selectedGameRecord
            _ = session.gobanState.branchSgf
            _ = session.gobanState.branchIndex
            _ = record?.sgf
            _ = record?.currentIndex
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.handleRecordPositionChange()
                self.trackRecordPosition()
            }
        }
    }

    /// Publishes the record position and runs the engine-free side effects.
    /// Mirrors iOS `GameSplitView.processRecordPositionChange`.
    private func handleRecordPositionChange() {
        let key = session.gobanState.recordPositionKey(
            gameRecord: navigationContext.selectedGameRecord)
        // The tracked properties change for reasons the board does not care
        // about (a rules edit, a comment); only a genuinely different position
        // is worth publishing.
        guard key != lastRecordPositionKey else { return }
        lastRecordPositionKey = key

        // Idempotent when `loadGame` already projected this key — the side
        // effects below still run, which is what a game switch needs.
        let position = session.projectRecordPosition(key: key)

        // The new position may be a board this engine cannot take (an
        // iCloud-synced 37x37 record against a 19 NN buffer). Decided here,
        // straight after the projection that settled `session.board`.
        applyHeldStatus()

        if let key, let gameRecord = navigationContext.selectedGameRecord {
            RecordStoneCache.write(position: position, key: key, into: gameRecord)
        }

        // Sync book state after undo/forward/backward (mirrors iOS).
        syncBookState()

        // A game switch armed the latch; the switched game's position has now
        // been published and cached, so flush the App Group store and reload
        // the widgets. Per-move changes find the latch unarmed — no reload.
        if widgetReloadLatch.consumeDataLanded() {
            try? modelContainer.mainContext.save()
            WidgetCenter.shared.reloadAllTimelines()
        }

        // Every played move, undo and navigation lands here, so this is the one
        // place that has to tell the draft its content may have moved.
        draftController.noteChanged()
    }

    // MARK: - Opening-book state sync (P6-T5)
    //
    // Port of `GameSplitView.syncBookState()` (GameSplitView.swift lines 537-565).
    // The hosted `BoardView` already RENDERS the book overlay + win-rate bar when
    // `gobanState.eyeStatus == .book`; this just keeps `session.bookLookup` walked
    // to the current position so that overlay reflects the right book node. iOS
    // calls it from three places — the record position changing, the book
    // `isLoaded` false->true edge, and the `eyeStatus -> .book` edge — and so do
    // we (the position call is in `handleRecordPositionChange()`; the two edges
    // are dedicated observers below). `withAnimation` is dropped: there is no SwiftUI animation
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
              gameRecord.concreteConfig.isBookEligible,
              bookLookup.isReady(forBoardSize: gameRecord.concreteConfig.boardWidth) else {
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

        // Keep the eye toolbar item's icon/tint/toolTip in sync with EVERY
        // eyeStatus change — toolbar click, menu pick, and the auto-correction in
        // refreshBookStateForSelectedGame (which forces .opened) all mutate
        // gobanState.eyeStatus, which this observer tracks, so they all land here.
        refreshEyeToolbarItem()
    }

    // MARK: - Download center observer
    //
    // Reconciles a finished book download against the active game even when
    // the Opening Books window never sees it — its own `onBooksChanged()`
    // fires only while that window's row observer is attached
    // (`OpeningBooksViewController.attachDownloadObservation`/
    // `detachDownloadObservation`), and closing the window no longer cancels
    // the transfer, so a book that finishes downloading with the window
    // closed (or never opened at all) would otherwise stay unloaded with a
    // stale eye state. This observer dedups on `finishedGeneration` and then
    // re-reads disk state, rather than filtering on
    // `lastFinishedDestination` — a single slot that a coalesced pair of
    // finishes overwrites (see `handleDownloadCenterChange`). Mirrors the iOS
    // `ContentView.onChange(of: DownloadCenter.shared.finishedGeneration)`
    // handler, which re-scans for the same reason.

    /// Seeds the snapshot from the live state and starts the self-rescheduling
    /// observation bridge for `DownloadCenter.shared.finishedGeneration`.
    /// Called once in `init`, independent of the engine session, since
    /// `DownloadCenter` is an app-wide singleton.
    private func installDownloadCenterObserver() {
        lastDownloadFinishedGeneration = DownloadCenter.shared.finishedGeneration
        trackDownloadCenter()
    }

    /// One observation pass: tracks `finishedGeneration`, and on change re-reads
    /// the committed value on the main actor, reacts, then re-arms.
    private func trackDownloadCenter() {
        withObservationTracking {
            _ = DownloadCenter.shared.finishedGeneration
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.handleDownloadCenterChange()
                self.trackDownloadCenter()
            }
        }
    }

    /// Detects a fresh finish against the snapshot and reconciles the active
    /// game's book load + eye state via `refreshBookStateForSelectedGame()`,
    /// the same reconciliation the Opening Books window's `onBooksChanged()`
    /// triggers.
    ///
    /// Deliberately does NOT read `lastFinishedDestination` to decide whether
    /// the finish was a book: two finishes CAN land in one main-actor turn
    /// (`finish` ends with `advanceQueue`, which starts the next download,
    /// which short-circuits straight back to `finish` when its staged partial
    /// already covers the declared total), and only the last destination
    /// survives. `refreshBookStateForSelectedGame()` re-reads disk state
    /// itself and is a no-op for the selected game's size when nothing
    /// changed, so running it on every bump — including a finished network,
    /// which has no book to reconcile — is both cheaper and more truthful than
    /// filtering on a value that can be overwritten.
    private func handleDownloadCenterChange() {
        let newGeneration = DownloadCenter.shared.finishedGeneration
        guard newGeneration != lastDownloadFinishedGeneration else { return }
        lastDownloadFinishedGeneration = newGeneration
        refreshBookStateForSelectedGame()
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

        // Swap the toolbar's lock slot the instant branch mode changes, in
        // EITHER direction, rather than waiting for AppKit's next validation
        // pass. (`validateToolbarItem` still refreshes it defensively, which is
        // what covers plain `isEditing` / `isAutoPlaying` changes.)
        refreshLockSlotToolbarItem()

        if lastBranchSgf.isActiveSgf && !newBranchSgf.isActiveSgf {
            // Through `load(game:previous:)` rather than `gobanState.loadGame`
            // directly, so this board load re-derives the draft like every
            // other one — a committed branch requests unlock on reload, and an
            // unlocked board must be a drafting board.
            load(game: navigationContext.selectedGameRecord, previous: nil)
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

    /// Bare-arrow characters as `charactersIgnoringModifiers` reports them —
    /// arrows arrive as function-key unicode scalars, not printable text. The
    /// same scalars the Navigate menu uses for its key equivalents.
    private static let leftArrowKey = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
    private static let rightArrowKey = String(UnicodeScalar(NSRightArrowFunctionKey)!)
    private static let upArrowKey = String(UnicodeScalar(NSUpArrowFunctionKey)!)
    private static let downArrowKey = String(UnicodeScalar(NSDownArrowFunctionKey)!)

    /// Installs the local key-down monitor that actually drives the bare-key board
    /// shortcuts. The Game/Analysis/Navigate menu items carry the matching key
    /// equivalents (Space / `,` / `P` / the four arrows) for discoverability and
    /// mouse use, but a bare LETTER like
    /// `P` never reaches a menu equivalent when the sidebar `NSTableView` is first
    /// responder: the table's type-select consumes it first (it jumps to a game
    /// starting with "P"), and clicking the board does NOT move first responder off
    /// the table. A local monitor runs inside `-[NSApplication sendEvent:]` BEFORE
    /// key-equivalent dispatch and the responder chain, so it wins that race — while
    /// still deferring to text editing (so Space / `,` / `P` type normally in the
    /// search field, the rename field, the Config editor, and the comment editor).
    ///
    /// The arrows need that same head start for a stronger reason: `NSTableView`
    /// consumes ↑/↓ as row navigation, and because board clicks leave first
    /// responder on the table, a focus-dependent binding would keep stepping the
    /// GAME LIST — and each row change loads a different game — long after the
    /// user has turned their attention to the board.
    private func installBoardShortcutMonitor() {
        boardShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Returning nil swallows the event (we handled it); returning the event
            // lets normal dispatch (menus, responder chain, type-select) proceed.
            return self.handleBoardShortcut(event) ? nil : event
        }
    }

    /// Handles a key-down for the LizzieYzy board shortcuts and move navigation.
    /// Returns true when the event was one of them AND was claimed (so the caller
    /// swallows it). Bare
    /// keys only (no ⌘/⌥/⌃), only for THIS window's events, never while a text
    /// control is editing, and only with a selected game — otherwise it returns
    /// false so the key keeps its normal meaning (typing, scrolling, type-select).
    ///
    /// Sheets are excluded for free: `presentAsSheet` and `beginSheetModal` each
    /// run in their OWN window, so `event.window === window` already fails and
    /// arrows keep driving the sheet's own controls. (The Navigate menu's
    /// equivalents are app-global rather than window-scoped, which is why
    /// `canPerformNavigation` gates them on `isPresentingSheet` as well.)
    private func handleBoardShortcut(_ event: NSEvent) -> Bool {
        guard event.window === window,
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              !isTextInputActive,
              navigationContext.selectedGameRecord != nil,
              let chars = event.charactersIgnoringModifiers, chars.count == 1
        else { return false }

        // Move navigation: ← → jump ten moves, ↑ ↓ step one — the same strides
        // the iOS bottom bar offers (backward/forward vs. backward.frame/
        // forward.frame). Handled before the character switch because arrows are
        // function-key scalars rather than printable characters.
        //
        // These are claimed UNCONDITIONALLY: `backward`/`forward` already no-op
        // when navigation isn't currently possible (an AI move is due, auto-play
        // is running, a `showboard` is still in flight, or we're at the end of
        // the line), and returning false in those moments would hand the key to
        // the sidebar table — turning a stalled ↓ into a game switch. Held keys
        // therefore self-throttle to one jump per engine round-trip rather than
        // queueing up. Shift is not excluded, for the same reason: shift+↓ must
        // not leak to the table either.
        switch chars {
        case Self.leftArrowKey:
            goBackwardTen(nil)
            return true
        case Self.rightArrowKey:
            goForwardTen(nil)
            return true
        case Self.upArrowKey:
            goBackward(nil)
            return true
        case Self.downArrowKey:
            goForward(nil)
            return true
        default:
            break
        }

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

    /// The concrete config of the currently-selected game (nil when none). The
    /// source for every eye-control opening-book decision below.
    private var selectedBookConfig: Config? {
        navigationContext.selectedGameRecord?.concreteConfig
    }

    /// The selected game's board width (0 when none) — the size key for book lookup.
    private var selectedBookSize: Int {
        selectedBookConfig?.boardWidth ?? 0
    }

    /// Whether an eligible opening book is downloaded for the selected game's size.
    /// The single source of truth behind every eye-control enable/tooltip decision
    /// (toolbar button, View ▸ Board/Book View menu, menu validation, and the
    /// post-download reconcile), so the rule lives in exactly one place.
    private var selectedBookAvailable: Bool {
        (selectedBookConfig?.isBookEligible ?? false)
            && session.bookLookup.isAvailable(forBoardSize: selectedBookSize)
    }

    /// The toolbar eye button's action: cycles board -> book -> hidden.
    /// Mirrors `eyeAction()`. With no selected game the book branch is impossible
    /// (no `concreteConfig`), so `.opened` falls straight to `.closed`. The View
    /// menu no longer uses this — it sets a mode directly via `setEyeStatus(_:)`.
    @objc func toggleEyeStatus(_ sender: Any?) {
        let gobanState = session.gobanState

        switch gobanState.eyeStatus {
        case .opened:
            if selectedBookAvailable {
                session.bookLookup.loadIfNeeded(boardSize: selectedBookSize)
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

    /// View ▸ Board/Book View submenu: sets `eyeStatus` directly by the sender's
    /// `tag` (0 = AI Analysis/`.opened`, 1 = Opening Book/`.book`, 2 = Hidden/
    /// `.closed`) — the same tag-dispatch idiom as `selectInspectorTab`. For the
    /// book mode it mirrors `toggleEyeStatus`'s book branch: preload the book and
    /// refuse the mode when no eligible+downloaded book exists (defensive —
    /// `validateMenuItem` already disables that row in that case).
    @objc func setEyeStatus(_ sender: NSMenuItem) {
        let gobanState = session.gobanState
        switch sender.tag {
        case 1:
            guard selectedBookAvailable else { return }
            session.bookLookup.loadIfNeeded(boardSize: selectedBookSize)
            gobanState.eyeStatus = .book
        case 2:
            gobanState.eyeStatus = .closed
        default:
            gobanState.eyeStatus = .opened
        }
    }

    // MARK: - Edit-mode lock (P6-T7)
    //
    // Toggles `gobanState.isEditing`, the same flag the iOS Chart wand / edit
    // affordances drive. Leaving edit mode (`true -> false`) is already handled by
    // the auto-play observer's `isEditing` branch (it cancels any in-flight
    // auto-play), so this action just flips the flag.

    /// Game-menu "Allow Editing" and the toolbar's lock slot: toggles edit mode
    /// (`isEditing == true` means UNLOCKED). `validateMenuItem` shows the
    /// checkmark from the live `gobanState.isEditing`.
    @objc func toggleEditing(_ sender: Any?) {
        let gobanState = session.gobanState
        // Locking with unsaved changes is an exit: resolve before the flag
        // flips, or the draft-close branch in `handleAutoPlayChange` would
        // silently drop them.
        if gobanState.isEditing {
            resolveDraft(for: .lock) { [weak self] in
                self?.performLock()
            }
        } else {
            gobanState.isEditing = true
        }
    }

    /// Locks the board, closing the draft first.
    ///
    /// Closing is not optional here. `syncDraftToEditingState` reads an open
    /// draft as proof that the board belongs unlocked, so clearing the flag on
    /// its own would simply be pushed back — locking is the one place a draft
    /// is ended by intent rather than re-derived. (`resolveDraft` has already
    /// closed it on the Save and Discard branches; a CLEAN draft arrives here
    /// still open, which is the case this handles.)
    private func performLock() {
        guard draftController.draft != nil else {
            session.gobanState.isEditing = false
            return
        }
        // An untitled draft has no saved record to fall back to, so closing it
        // in place would leave the board on nothing at all. It takes the same
        // close-and-reload path Discard uses, which picks a replacement game.
        // (Only a clean untitled draft reaches here — a dirty one was already
        // resolved — so there is nothing to lose by dropping it.)
        if draftController.isUntitled {
            discardDraftAndReload()
            return
        }
        closeDraftAndResyncSelection()
        // Redundant with the assignment `closeDraftAndResyncSelection()` now
        // makes internally — kept explicit anyway so this function reads as
        // correct on its own, without relying on a callee's side effect.
        session.gobanState.isEditing = false
    }

    // MARK: - Draft save / revert

    /// File ▸ Save (⌘S). Writes the draft through to the store: onto the
    /// origin when there is one, otherwise as a newly inserted record. The
    /// draft object stays live and selected afterwards, so saving never churns
    /// object identity or reloads the board.
    @objc func saveGame(_ sender: Any?) {
        guard draftController.draft != nil else { return }
        // ⌘S never leaves the game, so unlike `resolveDraft`'s Save branch it
        // has nothing to gate on the outcome — the draft stays open (or, for
        // Save as New Game, gets replaced by the new one) either way, so the
        // user just gets another try.
        saveResolvingConflict { _ in }
    }

    /// The one path into a commit that both ⌘S and the exit chokepoint
    /// (`resolveDraft`) go through, so a conflicted draft is handled
    /// identically no matter which door the user leaves through: presents the
    /// conflict sheet when the saved game changed underneath the draft,
    /// otherwise commits straight away.
    ///
    /// `completion` reports whether the draft actually ended up resolved —
    /// `true` for a plain commit or a successful conflict-sheet choice,
    /// `false` for a failed save or Cancel. `resolveDraft` needs that signal
    /// to decide whether the exit may proceed; `saveGame` ignores it.
    private func saveResolvingConflict(completion: @escaping (Bool) -> Void) {
        if draftController.hasConflict {
            presentConflictAlert(completion: completion)
        } else {
            completion(commitDraft())
        }
    }

    /// The unconditional half of Save, shared with the exit sheet and the
    /// conflict sheet's Overwrite button.
    ///
    /// No selection change is needed after an insert: the draft object stays
    /// live and `draft.origin` now points at the newly inserted record, so
    /// `resolvedRecord` maps the selection onto the new sidebar row by itself.
    ///
    /// Returns whether the save actually succeeded. `saveResolvingConflict`
    /// forwards that result: `saveGame` (⌘S) ignores it — the draft stays
    /// open either way, so the user just gets another try — but the exit
    /// chokepoint (`resolveDraft`) needs to know: a failed save must not be
    /// allowed to close the draft and continue the exit, or the changes
    /// `presentSaveFailureAlert` just said are "still here and unsaved" would
    /// be discarded right underneath that reassurance.
    @discardableResult
    func commitDraft() -> Bool {
        do {
            guard try draftController.save(into: modelContainer.mainContext) != nil
            else { return true }
            libraryStore.refetch()
            WidgetCenter.shared.reloadAllTimelines()
            refreshDraftChrome()
            return true
        } catch {
            presentSaveFailureAlert(error)
            return false
        }
    }

    /// File ▸ Revert to Saved. Drops the draft and reloads the saved game so
    /// the engine and board resync — the same path a game switch takes.
    @objc func revertGame(_ sender: Any?) {
        guard draftController.draft != nil else { return }
        discardDraftAndReload()
    }

    /// Shared by Revert and the exit sheet's Discard button. Loads through
    /// `loadDeferringUntilReady`, not `load` directly, so a Revert that lands
    /// while a Deep Report is probing waits for it rather than interleaving a
    /// feed with the report's probes. (Mid-relaunch is no longer a hazard here:
    /// the command gate is shut for the whole teardown, so the load's GTP is
    /// dropped and re-owed rather than pushed at a dying engine.)
    func discardDraftAndReload() {
        let previous = navigationContext.selectedGameRecord
        let origin = draftController.resolvedRecord(previous)
        draftController.close()
        session.gobanState.isEditing = false

        if let origin {
            navigationContext.selectedGameRecord = origin
            loadDeferringUntilReady(origin, previous: previous)
        } else {
            // An untitled draft has no saved counterpart: fall back to the
            // most-recent game, or the empty state.
            let fetched = (try? GameRecord.fetchGameRecords(container: modelContainer)) ?? []
            let target = fetched.first
            navigationContext.selectedGameRecord = target
            loadDeferringUntilReady(target, previous: previous)
        }
        libraryStore.refetch()
        refreshDraftChrome()
    }

    /// `internal`, not `private`: the conflict sheet below also reports a
    /// failed Save as New Game through this same alert.
    func presentSaveFailureAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not save this game."
        // The draft is deliberately left open and dirty: nothing is discarded
        // on a failed save.
        alert.informativeText = "\(error.localizedDescription)\n\nYour changes are still here and unsaved."
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window) }
    }

    /// Save found the saved game changed underneath the draft — another
    /// device's CloudKit import landed after the draft opened.
    ///
    /// Save as New Game is the default because nothing is lost either way:
    /// the draft becomes its own record and the incoming version stays intact.
    /// Discarding the user's own side is already File ▸ Revert to Saved, so it
    /// is named in the body rather than given a button.
    ///
    /// `completion` fires exactly once with the outcome: `true` once the
    /// conflict is actually resolved (Save as New Game or Overwrite both
    /// succeeded), `false` for Cancel or a failed save. `saveResolvingConflict`
    /// is the only caller, shared by ⌘S and `resolveDraft`'s Save branch — the
    /// latter needs this signal to know whether it's safe to close the draft
    /// and let the exit continue.
    func presentConflictAlert(completion: @escaping (Bool) -> Void) {
        guard let window, let draft = draftController.draft, let origin = draft.origin
        else { completion(false); return }

        let theirMoves = SgfHeaderScan(sgf: origin.sgf)?.moveCount ?? 0
        let mine = draft.moveCount

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        let changedAt = origin.lastModificationDate.map { formatter.string(from: $0) }
            ?? "another device"

        let alert = NSAlert()
        alert.messageText = "\"\(draft.record.name)\" was changed on another device."
        alert.informativeText = """
            The saved game now has \(theirMoves) moves; yours has \(mine). \
            It was last changed \(changedAt).

            To keep the other version instead, cancel and choose File > \
            Revert to Saved.
            """
        alert.addButton(withTitle: "Save as New Game")
        alert.addButton(withTitle: "Overwrite")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                do {
                    guard let inserted = try self.draftController.saveAsNewGame(
                        into: self.modelContainer.mainContext)
                    else { completion(false); return }
                    // `saveAsNewGame` re-baselines against the ORIGIN, which
                    // is still the conflicting version — so leaving the draft
                    // open here would leave it dirty (mine vs. theirs again)
                    // and pointed at the very record this button was chosen
                    // to protect. Closing it and selecting the new copy is
                    // what actually keeps that version safe: left open, a
                    // later Save could overwrite it, and exiting would prompt
                    // the user all over again. `isEditing = false` mirrors
                    // `discardDraftAndReload` — without it the now-live
                    // `inserted` record would take direct moves outside any
                    // draft, the exact write path this feature exists to close.
                    self.draftController.close()
                    self.session.gobanState.isEditing = false
                    self.navigationContext.selectedGameRecord = inserted
                    self.libraryStore.refetch()
                    WidgetCenter.shared.reloadAllTimelines()
                    self.refreshDraftChrome()
                    completion(true)
                } catch {
                    self.presentSaveFailureAlert(error)
                    completion(false)
                }
            case .alertSecondButtonReturn:
                completion(self.commitDraft())
            default:
                completion(false)   // Cancel: the draft stays open and dirty.
            }
        }
    }

    // MARK: - Draft exit chokepoint

    /// Every way of leaving the game being edited goes through here.
    ///
    /// Clean (or no draft) runs `continuation` straight through. Dirty presents
    /// Save · Discard · Cancel, and Cancel abandons the continuation entirely —
    /// the caller must NOT have performed any part of the exit before calling.
    /// Save routes through `saveResolvingConflict`, the same conflict-aware
    /// entry point ⌘S uses, so a draft that is both dirty and conflicted gets
    /// the conflict sheet here too instead of silently overwriting the other
    /// device's version.
    func resolveDraft(for trigger: DraftExitTrigger,
                      then continuation: @escaping () -> Void) {
        guard draftController.decision(for: trigger) == .prompt else {
            continuation()
            return
        }
        guard let window else {
            continuation()
            return
        }

        let name = draftController.displayName ?? "this game"
        let alert = NSAlert()
        alert.messageText = "Save changes to \(name)?"
        alert.informativeText = "Your changes have not been saved to iCloud yet. If you don't save them, they will be lost."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                // A dirty draft can ALSO be conflicted — another device may
                // have synced a change in while it was open — and this branch
                // used to call `commitDraft()` directly, which would silently
                // overwrite that other device's work with no warning. Routing
                // through the same conflict-aware entry point `saveGame` uses
                // makes every exit, not just ⌘S, present the conflict sheet
                // first when one is needed.
                //
                // A failed save or a cancelled conflict sheet must not let
                // the exit proceed — that would silently discard or overwrite
                // the very changes the user was just asked about. Both count
                // as an abort like Cancel below, routed through
                // `abortDraftExit` rather than repeated here, so this branch
                // cannot forget it the way it did before.
                self.saveResolvingConflict { [weak self] resolved in
                    guard let self else { return }
                    guard resolved else {
                        self.abortDraftExit(for: trigger)
                        return
                    }
                    // Save as New Game (inside `presentConflictAlert`) already
                    // closed the draft and moved the selection to the new
                    // record. A plain commit — no conflict, or Overwrite —
                    // leaves the draft open, the way ⌘S wants it, so only
                    // that case still needs closing here before the exit can
                    // continue.
                    if self.draftController.draft != nil {
                        self.closeDraftAndResyncSelection()
                    }
                    continuation()
                }
            case .alertSecondButtonReturn:
                // Reuses the same close-and-reload `revertGame` uses: Discard
                // has to put the engine board back to the last-saved content,
                // not just drop the draft object, or an exit that stays on
                // this game (lock) would keep showing the abandoned edits.
                self.discardDraftAndReload()
                continuation()
            default:
                // Cancel: the continuation is abandoned, so it goes through
                // the same abort path as a failed Save above.
                self.abortDraftExit(for: trigger)
            }
        }
    }

    /// Every abort out of the exit sheet (Cancel, or a failed Save) lands
    /// here instead of calling `continuation()`. `.quit` is the one trigger
    /// that already returned `.terminateLater` before this sheet appeared
    /// (`AppDelegate.applicationShouldTerminate`); with no reply on an abort
    /// the app would sit stuck "terminating" forever, so this is the one case
    /// an abort still has to act on `NSApp` rather than simply doing nothing.
    /// Routing both abort branches through one helper — instead of each
    /// remembering to reply for itself — is what caught the failed-Save path
    /// missing this the first time, and keeps a future third abort branch
    /// from missing it too.
    ///
    /// Never fires alongside `continuation()`: every path out of
    /// `resolveDraft`'s callback — including the Save case's nested
    /// `saveResolvingConflict` completion, which itself either aborts here or
    /// falls through to `continuation()` — takes this abort branch or the
    /// success branch that calls `continuation()`, never both — so
    /// `NSApp.reply(toApplicationShouldTerminate:)` still only ever fires
    /// once per sheet answer.
    private func abortDraftExit(for trigger: DraftExitTrigger) {
        // A sidebar row click can be what started this exit (`.switchGame`), and
        // `NSTableView` already moved its own highlight to that row before the
        // prompt even appeared — see `resyncSidebarSelection`'s doc comment. Every
        // abort, from any trigger, restores it from `navigationContext`; the call
        // is a no-op when the highlight was never touched.
        (window?.contentViewController as? MainSplitViewController)?.resyncSidebarSelection()

        guard trigger == .quit else { return }
        replyToPendingTerminate(false)
    }

    /// Records that `applicationShouldTerminate` has deferred a quit.
    func beginPendingTerminate() { isAwaitingTerminateReply = true }

    /// Answers the deferred quit, at most once per ask. Both the resume
    /// (`AppDelegate`'s continuation) and the abort (`abortDraftExit`) come
    /// through here so neither can reply to an ask that is no longer
    /// outstanding.
    func replyToPendingTerminate(_ shouldTerminate: Bool) {
        guard isAwaitingTerminateReply else { return }
        isAwaitingTerminateReply = false
        NSApp.reply(toApplicationShouldTerminate: shouldTerminate)
    }

    /// Closes the draft after a successful Save and points the selection back
    /// at the origin it was just committed onto. No reload is needed here —
    /// unlike Discard (`discardDraftAndReload`), a successful commit already
    /// made the origin match what's on screen — but without this the
    /// selection is left on the now-detached draft clone, which breaks the
    /// `===` identity checks `deleteGame` and the lock-mode observer in
    /// `handleAutoPlayChange` rely on to find "the game on screen".
    ///
    /// Also lowers `isEditing`, inseparably from closing the draft. Both
    /// callers can leave without ever reaching a load: `resolveDraft`'s Save
    /// branch hands off to a `continuation` that may itself do nothing more
    /// (⌘N's sheet dismissed with Cancel, a delete confirmation dismissed
    /// with Cancel), and `performLock` sets the flag right after anyway. With
    /// no load to re-derive the state, a resting `isEditing == true` over a
    /// `draft == nil` selection is exactly the invariant this feature exists
    /// to hold — the board would sit unlocked over a live stored record, with
    /// every write path pointed straight at it again and no dirty dot to
    /// betray it. `syncDraftToEditingState` cannot catch this afterwards: its
    /// `.unlock` case only fires for an OPEN draft, and by then there is none.
    private func closeDraftAndResyncSelection() {
        let origin = draftController.resolvedRecord(navigationContext.selectedGameRecord)
        draftController.close()
        navigationContext.selectedGameRecord = origin
        session.gobanState.isEditing = false
    }

    /// True while a dirty draft is waiting on the user.
    var hasUnresolvedDraft: Bool { draftController.isDirty }

    // MARK: - Deep Analysis Report

    /// Game-menu "Deep Analysis Report…": presents the shared SwiftUI report
    /// sheet. Injects exactly the environment objects DeepReportView declares
    /// (messageList only) — the InspectorTabs wrapper pattern. Sheet size comes
    /// from the SwiftUI root's min frame (the ConfigEditorViewController
    /// precedent uses AppKit constraints).
    @objc func showDeepReport(_ sender: Any?) {
        guard let gameRecord = navigationContext.selectedGameRecord,
              !session.gobanState.reportGenerationActive else { return }
        // The report's probes cancel live analysis and its restore doesn't
        // re-arm, so the engine sits idle under the sheet; analysis re-arms on
        // dismissal (dismissSheet). Deliberately no maybePauseAnalysis() here:
        // its waitingForAnalysis edge would emit a stray "stop" whose ack
        // desyncs the probe collector's FIFO.
        // SwiftUI's \.dismiss cannot reach an NSHostingController presented via
        // presentAsSheet, so DeepReportView is handed a closure that bridges
        // Done/Cancel back to AppKit dismissal. `dismissSheet` is filled in
        // after `hosting` exists (it needs to reference it weakly) and closed
        // over by the root view built just above.
        var dismissSheet: (() -> Void) = {}
        // No NavigationStack wrapper: DeepReportView owns its stack (the
        // alternative-move picker pushes inside it).
        let root = DeepReportView(gameRecord: gameRecord, onClose: { dismissSheet() })
            .environment(session.messageList)
            .frame(minWidth: 560, minHeight: 640)
        let hosting = NSHostingController(rootView: root)
        dismissSheet = { [weak hosting, weak self] in
            guard let hosting else { return }
            // ConfigEditorViewController.done(_:) idiom — the codebase's
            // canonical way to close a presentAsSheet presentation.
            if let presenting = hosting.presentingViewController {
                presenting.dismiss(hosting)
            } else {
                hosting.dismiss(nil)
            }
            // Re-arm live analysis the report left idle (a no-op unless
            // analysis is on), so it — and a human-vs-AI opponent — resumes.
            if let self {
                self.session.gobanState.resumeAnalysisAfterReport(
                    config: gameRecord.concreteConfig,
                    nextColorForPlayCommand: self.session.player.nextColorForPlayCommand,
                    messageList: self.session.messageList)
            }
        }
        contentViewController?.presentAsSheet(hosting)
        // SwiftUI's navigationTitle never reaches an AppKit-presented sheet's
        // window (its toolbar showed the NSWindow default "Untitled"), so
        // title the window directly. Async: the sheet window may not exist
        // until presentAsSheet's presentation work completes.
        DispatchQueue.main.async { [weak hosting] in
            hosting?.view.window?.title = "Deep Analysis Report"
        }
    }

    /// File-menu "Export GIF…": presents the shared GIF export sheet for the
    /// selected game. Same NSHostingController/presentAsSheet + onClose bridge as
    /// showDeepReport; engine-free, so gated only on a selected game.
    @objc func exportGameGif(_ sender: Any?) {
        guard let gameRecord = navigationContext.selectedGameRecord else { return }
        var dismissSheet: (() -> Void) = {}
        let root = NavigationStack {
            GameGifExportView(gameRecord: gameRecord, onClose: { dismissSheet() })
        }
        .frame(minWidth: 420, minHeight: 640)
        let hosting = NSHostingController(rootView: root)
        dismissSheet = { [weak hosting] in
            guard let hosting else { return }
            if let presenting = hosting.presentingViewController {
                presenting.dismiss(hosting)
            } else {
                hosting.dismiss(nil)
            }
        }
        contentViewController?.presentAsSheet(hosting)
        DispatchQueue.main.async { [weak hosting] in
            hosting?.view.window?.title = "Export GIF"
        }
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
    /// `validateToolbarItem`.
    ///
    /// Uses the iOS `custom.sparkle` / `custom.sparkle.slash` symbols (copied
    /// into the Mac catalog) so the button matches `StatusToolbarItems`, which
    /// likewise swaps to the slashed variant when analysis is off.
    ///
    /// `.pause` deliberately keeps a dimmed tint rather than copying iOS
    /// exactly: iOS separates run from pause ONLY via
    /// `.symbolEffect(.variableColor.iterative.reversing)`, and neither
    /// symbolset declares a `variable-N` layer, so that effect renders nothing
    /// — dropping the tint would leave the two states indistinguishable here.
    /// The item's `label` carries the accessible name (the toolbar runs
    /// `displayMode = .iconOnly`, so `label` is VoiceOver-only and `toolTip` is
    /// what a pointer user reads); the catalog image is used unmutated so the
    /// shared cached instance never picks up one state's tint.
    private func refreshAnalyzeToolbarItem() {
        guard let item = analyzeToolbarItem else { return }
        let status = session.gobanState.analysisStatus
        let symbolName = (status == .clear) ? "custom.sparkle.slash" : "custom.sparkle"
        // Fall back to the stock wand if the catalog lookup ever fails, so the
        // item can never render as an empty slot.
        let base = NSImage(named: symbolName)
            ?? NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "Analyze")
        switch status {
        case .clear:
            // Analysis OFF: red slashed sparkle signals "click to start".
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

    /// Updates the eye toolbar item's image/tint/toolTip from the live
    /// `gobanState.eyeStatus`. The icon carries the current mode (eye/book/
    /// eye.slash, mirroring iOS `StatusToolbarItems`); the toolTip names the NEXT
    /// action (the Analyze item's convention), computed from the SAME book
    /// availability as `toggleEyeStatus` so it never promises a mode the cycle
    /// won't reach. Called after the item is built, from `handleBookStateChange()`
    /// on every `eyeStatus` change, and defensively from `validateToolbarItem`.
    /// A fresh `NSImage` is built each call so the red palette of `.closed` never
    /// leaks into the other states.
    private func refreshEyeToolbarItem() {
        guard let item = eyeToolbarItem else { return }

        switch session.gobanState.eyeStatus {
        case .opened:
            item.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "View")
            item.toolTip = selectedBookAvailable ? "Show Opening Book" : "Hide Analysis"
        case .book:
            item.image = NSImage(systemSymbolName: "book", accessibilityDescription: "View")
            item.toolTip = "Hide Analysis"
        case .closed:
            // Red tint signals "everything hidden", mirroring Analyze's clear case.
            item.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "View")?
                .withSymbolConfiguration(.init(paletteColors: [.systemRed]))
            item.toolTip = "Show AI Analysis"
        }
    }

    /// The live state of the lock slot, resolved by the shared `LockSlotModel`
    /// so macOS, visionOS and the iOS `TopToolbarView` cannot drift apart. With
    /// no game selected there is no `concreteConfig` to ask about a pending
    /// genmove, so `shouldGenMove` reads false — the slot then shows the plain
    /// Lock toggle and `validateToolbarItem` disables it for want of a game.
    private var lockSlotState: LockSlotModel {
        let gobanState = session.gobanState
        let shouldGenMove = navigationContext.selectedGameRecord.map {
            gobanState.shouldGenMove(config: $0.concreteConfig, player: session.player)
        } ?? false
        return LockSlotModel.make(isBranchActive: gobanState.isBranchActive,
                                  isEditing: gobanState.isEditing,
                                  shouldGenMove: shouldGenMove,
                                  isAutoPlaying: gobanState.isAutoPlaying)
    }

    /// Window title, dirty dot and conflict subtitle.
    ///
    /// The title was a static "KataGo Anytime", which left an untitled game
    /// with nothing on screen naming it — it has no sidebar row either.
    func refreshDraftChrome() {
        let name = draftController.displayName
            ?? navigationContext.selectedGameRecord?.name
        window?.title = name ?? "KataGo Anytime"
        window?.subtitle = draftController.hasConflict ? "Changed on another device" : ""
        window?.isDocumentEdited = draftController.isDirty
    }

    /// Updates the lock slot's image/label/tint/action from `lockSlotState`.
    /// Called after the item is built, from the branch observer (so entering or
    /// leaving a branch swaps the slot immediately), and defensively from
    /// `validateToolbarItem` — the same refresh pattern the Analyze and eye
    /// items use, which also covers `isEditing` and `isAutoPlaying` changes
    /// without a dedicated observer.
    ///
    /// The `action` swaps with the state, so `validateToolbarItem` keys off the
    /// live selector and needs no extra branch. `label` copies iOS verbatim and
    /// describes the CURRENT state ("Unlock" = this game is unlocked); `toolTip`
    /// follows this file's convention of naming the NEXT action instead, which
    /// is what a pointer user actually reads under `displayMode = .iconOnly`.
    private func refreshLockSlotToolbarItem() {
        guard let item = lockSlotToolbarItem else { return }
        let slot = lockSlotState

        let base = NSImage(systemSymbolName: slot.systemImage,
                           accessibilityDescription: slot.label)
        // A fresh NSImage each call, so the red palette of the branch state
        // never leaks into the lock toggle (mirrors `refreshEyeToolbarItem`).
        item.image = slot.isRed
            ? base?.withSymbolConfiguration(.init(paletteColors: [.systemRed]))
            : base
        item.label = slot.label

        switch slot.kind {
        case .toggleLock:
            item.action = #selector(toggleEditing(_:))
            // `isEditing == true` means UNLOCKED, so the next action locks.
            item.toolTip = session.gobanState.isEditing ? "Lock Editing" : "Unlock Editing"
        case .deactivateBranch:
            item.action = #selector(deactivateBranchAction(_:))
            item.toolTip = "Deactivate Branch"
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
                                         audioModel: self.audioModel)
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

    /// Polls `session.engineStatus.isReady` via the same self-rescheduling
    /// `withObservationTracking` style used elsewhere; once ready, starts the
    /// test after a short settle delay. Re-arms on every availability change
    /// rather than once, because availability is no longer a one-way flag (a
    /// launch, a Held board and a helper crash all move it).
    private func waitForEngineReadyThenRunAutoPlayTest() {
        if session.engineStatus.isReady {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                self?.runAutoPlayTest()
            }
            return
        }
        withObservationTracking {
            _ = session.engineStatus.availability
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

    /// Polls `session.engineStatus.isReady` via the same self-rescheduling
    /// `withObservationTracking` style used by the auto-play test; once ready,
    /// starts the relaunch test after an ~8s settle delay so the first engine's
    /// analysis is flowing before we tear it down.
    private func waitForEngineReadyThenRunRelaunchTest() {
        if session.engineStatus.isReady {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.runRelaunchTest()
            }
            return
        }
        withObservationTracking {
            _ = session.engineStatus.availability
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
        // reached "GTP ready" (ready=true) AND whether the FEED reached the
        // engine: `inSync` is the record position's acknowledgement
        // (`stones.isReady`) and `showBoardCount=0` says no ack is still
        // outstanding. Both matter now — a relaunch no longer re-mounts the
        // board, so "ready" alone would not prove the engine was ever told
        // which position it is looking at.
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self else { return }
            let gobanState = self.session.gobanState
            print("KATAGO_RELAUNCH ready=\(self.session.engineStatus.isReady) " +
                  "inSync=\(self.session.stones.isReady) " +
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

    /// Polls `session.engineStatus.isReady` via the same self-rescheduling
    /// `withObservationTracking` style used by the other DEBUG self-tests; once
    /// ready, starts the test after an ~8s settle delay so the first engine's
    /// analysis is flowing before we enable AI play.
    private func waitForEngineReadyThenRunAIPlayTest() {
        if session.engineStatus.isReady {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.runAIPlayTest()
            }
            return
        }
        withObservationTracking {
            _ = session.engineStatus.availability
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

    /// Blocks the close while a dirty draft is open, re-issuing it once the
    /// user answers. `performClose` rather than `close` so the delegate chain
    /// runs again from a now-clean state.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard hasUnresolvedDraft else { return true }
        resolveDraft(for: .closeWindow) { [weak self] in
            self?.window?.performClose(nil)
        }
        return false
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
    /// opens). The six Navigate items route to `canPerformNavigation`, which adds
    /// `!isTextInputActive` for the four bare-arrow ones (the toolbar no longer
    /// carries any navigation items); Rename/Delete/Share require a selected
    /// game; everything else defaults to enabled.
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

    /// True while ANY sheet is attached to the window.
    ///
    /// Broader than `isPresentingSheet`, which only sees `presentAsSheet`
    /// children and so misses `NSAlert.beginSheetModal` and `NSOpenPanel`
    /// sheets — including `resolveDraft`'s own Save · Discard · Cancel prompt.
    /// Edit ▸ Paste re-enters `resolveDraft`, so without this a ⌘V while that
    /// prompt is up would stack a second copy of it on the same window.
    private var isAnySheetAttached: Bool {
        window?.attachedSheet != nil
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let gobanState = session.gobanState
        let hasGame = navigationContext.selectedGameRecord != nil
        switch menuItem.action {
        case #selector(renameSelectedGame(_:)),
             #selector(deleteSelectedGame(_:)),
             #selector(shareSelectedGame(_:)),
             #selector(exportGameGif(_:)):
            return hasGame

        // Game menu "Deactivate Branch": only meaningful when a branch is active
        // and the engine isn't mid-move-generation (mirrors the iOS gating). With
        // no game there is no branch to exit, so it's disabled.
        case #selector(deactivateBranchAction(_:)):
            guard let gameRecord = navigationContext.selectedGameRecord else { return false }
            return gobanState.isBranchActive
                && !gobanState.shouldGenMove(config: gameRecord.concreteConfig, player: session.player)

        // Game menu "Allow Editing": checkmark reflects the live `isEditing`
        // (true == unlocked), enabled when a game is selected.
        //
        // Disabled while a branch is active. A branch and a draft are both
        // uncommitted lines with different commit paths (Replace/Discard vs
        // Save/Revert), and unlocking on top of a branch would leave both live
        // at once. Deactivate Branch first, as the toolbar already forces.
        case #selector(toggleEditing(_:)):
            menuItem.state = gobanState.isEditing ? .on : .off
            return hasGame && !gobanState.isBranchActive

        // Game menu "Deep Analysis Report…": requires a selected game, a ready
        // board, no AI move due, the game not finished (both-pass), and no
        // report already running.
        case #selector(showDeepReport(_:)):
            guard let gameRecord = navigationContext.selectedGameRecord else { return false }
            return session.stones.isReady
                && !gobanState.reportGenerationActive
                && gobanState.passCount < 2
                && !gobanState.shouldGenMove(config: gameRecord.concreteConfig,
                                              player: session.player)

        // View ▸ Board/Book View submenu: radio checkmark on the active mode.
        // Tag 0 = AI Analysis (.opened), 1 = Opening Book (.book), 2 = Hidden
        // (.closed). "Opening Book" additionally requires an eligible+downloaded
        // book, so it greys out when none is available; the other two need only a
        // selected game. With no game all three are disabled, which auto-greys the
        // "Board/Book View" parent item (NSMenu.autoenablesItems).
        case #selector(setEyeStatus(_:)):
            let mode: EyeStatus = menuItem.tag == 1 ? .book
                : menuItem.tag == 2 ? .closed : .opened
            menuItem.state = (gobanState.eyeStatus == mode) ? .on : .off
            if menuItem.tag == 1 {
                return hasGame && selectedBookAvailable
            }
            return hasGame

        // Game-menu board-move shortcuts: bare `,` / `P` (LizzieYzy). Disabled
        // while a text control is editing so the key types instead of playing,
        // and while a sheet is presented so a bare key doesn't play a real move
        // into the game (and re-arm analysis) behind the Deep Report / config
        // sheet via the nil-target responder chain.
        // "Play Best Move" additionally requires a live best move (analysis on).
        case #selector(playBestMove(_:)):
            let hasBestMove = session.analysis.getBestMove(
                width: Int(session.board.width),
                height: Int(session.board.height)) != nil
            return hasGame && hasBestMove && !isTextInputActive && !isPresentingSheet
        case #selector(passMove(_:)):
            return hasGame && !isTextInputActive && !isPresentingSheet

        // Analysis menu: checkmark reflects the live status, enabled with a game.
        // `toggleAnalysis` is bound to bare Space (LizzieYzy), so it is also
        // disabled while a text control is editing — `false` lets Space type there.
        // Also disabled while any sheet is presented: the responder chain still
        // reaches this controller under an AppKit sheet (e.g. the Deep Report,
        // which pauses analysis and must keep it down), and a .clear→.run
        // toggle would re-arm the engine underneath it. Pause/Off stay enabled
        // — they cannot resume anything.
        case #selector(toggleAnalysis(_:)):
            menuItem.state = gobanState.analysisStatus != .clear ? .on : .off
            return hasGame && !isTextInputActive && !isPresentingSheet
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
            return menuItem.isEnabled && session.engineStatus.isReady
        // "Manage Models…" is always available.
        case #selector(showModelsWindow(_:)):
            return true
        // "Manage Opening Books…" is always available.
        case #selector(showOpeningBooksWindow(_:)):
            return true

        // File ▸ "Re-sync from iCloud…": always available — it presents its own
        // confirmation (and a stronger warning when not signed into iCloud), so it
        // never needs a selected game or any particular engine/analysis state.
        case #selector(resyncLibraryFromICloud(_:)):
            return true

        // File ▸ Save / Revert to Saved: only meaningful with unsaved changes.
        case #selector(saveGame(_:)), #selector(revertGame(_:)):
            return draftController.isDirty

        // Edit ▸ Copy (⌘C): copy the game on the board as SGF. Only reached
        // through the responder chain when no text control has focus — a field
        // editor implements `copy:` too and, being earlier in the chain, wins
        // the target lookup and validates for itself.
        case #selector(copyGameSgf(_:)):
            return gobanState.getSgf(gameRecord: navigationContext.selectedGameRecord) != nil
                && !isAnySheetAttached

        // Edit ▸ Paste (⌘V): create a game from the clipboard's SGF.
        //
        // This asks only whether the pasteboard OFFERS text, never what that
        // text IS. macOS 26 alerts the user when an app reads the general
        // pasteboard outside a paste-related user action, and menu validation
        // runs on every Edit-menu open — so reading contents here could raise a
        // system permission prompt just for opening a menu. `canReadObject` is
        // a type query, not a read. Whether the text actually parses as an SGF,
        // and whether its board fits the running engine, are decided inside
        // `pasteGameSgf` (a real paste action, and so exempt), which explains
        // rather than silently doing nothing.
        case #selector(pasteGameSgf(_:)):
            return NSPasteboard.general.canReadObject(forClasses: [NSString.self], options: nil)
                && !isAnySheetAttached

        default:
            return canPerformNavigation(menuItem.action)
        }
    }
}

// MARK: - Toolbar item validation

extension MainWindowController: NSToolbarItemValidation {
    /// Enables/disables the toolbar's `target = nil` items through the responder
    /// chain. AppKit calls this for each item that resolves to this responder,
    /// which also gives the state-carrying items (Analyze, eye, lock slot) a
    /// periodic hook to re-sync their appearance. Items with no rule of their
    /// own default to enabled.
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        // Active-model dropdown: always enabled; opportunistically refresh its
        // displayed title so it tracks the live selection even when the model was
        // changed elsewhere (Models window "Play", crash recovery).
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
        if item.action == #selector(toggleEyeStatus(_:)) {
            // The eye button only makes sense with a game loaded; refresh its
            // icon/tint/toolTip opportunistically while we're here.
            refreshEyeToolbarItem()
            return navigationContext.selectedGameRecord != nil
        }
        if item.itemIdentifier == .lockSlot {
            // Keyed off the IDENTIFIER, not the selector: this item's action
            // swaps between `toggleEditing` and `deactivateBranchAction` with
            // its state, so a selector test would miss one of the two. Refresh
            // opportunistically, then apply the shared model's own disable rule
            // (auto-play for the toggle, a pending genmove for the branch exit)
            // on top of "a game must be loaded".
            refreshLockSlotToolbarItem()
            return navigationContext.selectedGameRecord != nil && !lockSlotState.isDisabled
        }
        // Everything else (sidebar, New, Import, Model, Inspector) is always
        // available. This used to fall through to `canPerformNavigation`, but no
        // toolbar item carries a navigation selector any more — that routing
        // existed purely for the removed nav group, and leaving it here would
        // suggest new items can opt into navigation validation by selector when
        // they would in fact land on its `default` and come back enabled.
        return true
    }
}

private extension NSToolbarItem.Identifier {
    static let toggleSidebar = NSToolbarItem.Identifier("toggleSidebar")
    static let newGame = NSToolbarItem.Identifier("newGame")
    static let importSGF = NSToolbarItem.Identifier("importSGF")
    static let activeModel = NSToolbarItem.Identifier("activeModel")
    static let analyze = NSToolbarItem.Identifier("analyze")
    static let toggleEye = NSToolbarItem.Identifier("toggleEye")
    static let lockSlot = NSToolbarItem.Identifier("lockSlot")
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
            // Game-state controls sit centred; the sidebar/inspector chrome
            // brackets them. Move navigation is keyboard-only (← → jump ten,
            // ↑ ↓ step one — see `handleBoardShortcut`) plus the Navigate menu
            // and the Chart tab's click-to-jump, so there is no nav group here.
            .analyze,
            .toggleEye,
            .lockSlot,
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
            .analyze,
            .toggleEye,
            .lockSlot,
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
            // The symbol here is only the seed; `refreshAnalyzeToolbarItem()`
            // immediately replaces it with the catalog sparkle for the live
            // status, so the stock wand is never actually drawn.
            let item = makeItem(itemIdentifier,
                                label: "Analyze",
                                symbol: "wand.and.stars",
                                action: #selector(toggleAnalysis(_:)))
            // Borrow a weak reference so `refreshAnalyzeToolbarItem()` can reflect
            // `analysisStatus` on the button, and seed its initial appearance.
            analyzeToolbarItem = item
            refreshAnalyzeToolbarItem()
            return item
        case .toggleEye:
            let item = makeItem(itemIdentifier,
                                label: "View",
                                symbol: "eye",
                                action: #selector(toggleEyeStatus(_:)))
            // Borrow a weak reference so `refreshEyeToolbarItem()` can reflect
            // `eyeStatus` on the button, and seed its initial appearance.
            eyeToolbarItem = item
            refreshEyeToolbarItem()
            return item
        case .lockSlot:
            // iOS `TopToolbarView` parity: ONE slot that is the Lock/Unlock
            // toggle off-branch and the red "Deactivate Branch" u-turn on it.
            // Both the image and the action are set by the refresh below, so
            // the seed values here are never seen.
            let item = makeItem(itemIdentifier,
                                label: "Lock",
                                symbol: "lock",
                                action: #selector(toggleEditing(_:)))
            lockSlotToolbarItem = item
            refreshLockSlotToolbarItem()
            return item
        case .activeModel:
            return makeActiveModelItem(itemIdentifier)
        case .toggleInspector:
            // macOS 14+ NSSplitViewController responds to toggleInspector:.
            return makeItem(itemIdentifier,
                            label: "Inspector",
                            symbol: "sidebar.right",
                            action: #selector(NSSplitViewController.toggleInspector(_:)))
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

    /// The model the switcher should mark active — its checkmark and the toolbar
    /// button title. Prefers the net the engine actually reported loading
    /// (`engineLifecycle.lastLoadedModelTitle`, the ground truth), so a fallback
    /// launch (the picked net's file is missing → the engine runs the built-in)
    /// marks the net that is really running rather than the optimistic pick.
    /// Falls back to the persisted selection only before the first load completes
    /// (`lastLoadedModelTitle` is nil until the engine's first GTP response).
    private var activeModelTitleForDisplay: String {
        if let loaded = engineLifecycle.lastLoadedModelTitle, !loaded.isEmpty {
            return loaded
        }
        return modelSelection.currentModel.title
    }

    /// Rebuilds the active-model dropdown's menu items from the live catalog +
    /// selection. Called from `menuNeedsUpdate(_:)` each time the menu opens, so
    /// checkmarks (active model) and enablement (downloaded?) are always current.
    fileprivate func rebuildActiveModelMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let currentTitle = activeModelTitleForDisplay

        // A pull-down `NSMenuToolbarItem` consumes menu item 0 as the button's
        // label and does NOT show it in the dropdown list. Without a throwaway
        // first item, the FIRST catalog entry — the built-in net, which is
        // `NeuralNetworkModel.allCases[0]` — would silently vanish from the list.
        // Prepend a disabled placeholder carrying the active title (matching the
        // standard pull-down convention where item 0 is the current selection),
        // so item 0 is the throwaway and every real model — built-in included —
        // stays visible and selectable below it.
        let header = NSMenuItem(title: currentTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

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
        activeModelToolbarItem?.title = activeModelTitleForDisplay
    }

    /// Switches the active network from the toolbar dropdown. Resolves the chosen
    /// model from the menu item's `representedObject` and relaunches the engine via
    /// `relaunch(model:)`. Guarded on `session.engineStatus.isReady` to avoid a
    /// re-entrant relaunch while a launch is already in flight. (Retry from the
    /// board's status line does NOT go through here — a failed engine has to be
    /// relaunchable, and `relaunch(model:)` carries no readiness guard.)
    @objc func selectActiveModel(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? NeuralNetworkModel else { return }
        // Don't switch mid-launch (avoids re-entrant teardown/relaunch).
        guard session.engineStatus.isReady else { return }
        // No-op if it's already the active net.
        guard model.title != modelSelection.currentModel.title else { return }
        relaunch(model: model)
        refreshActiveModelToolbarItem()
    }

}
