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

    /// `GameSession.run`/`messaging` take a `Binding<String?>` for the AI's last
    /// move (the iOS app drives a confirmation flow off it). Phase 1 on macOS
    /// has no AI play, so we back the binding with a throwaway box rather than
    /// changing the `GameSession` signature (which would force re-verifying iOS).
    private let aiMoveBox = AIMoveBox()

    private let modelContainer: ModelContainer
    private var katagoThread: Thread?

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

        w.contentViewController = MainSplitViewController(
            session: session,
            navigationContext: navigationContext,
            audioModel: audioModel
        )
        w.titlebarAppearsTransparent = false
        w.toolbarStyle = .unified

        let toolbar = NSToolbar(identifier: "KataGoAnytimeMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        w.toolbar = toolbar

        w.center()

        startEngineAndSession()
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

        await session.run(
            gameRecords: gameRecords,
            modelContext: context,
            navigationContext: navigationContext,
            audioModel: audioModel,
            aiMove: aiMoveBox.binding
        )
    }
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
    /// Enables/disables the Navigate menu items (Back/Forward/First/Last) via
    /// the responder chain, using the same `canGoBackward` / `canGoForward`
    /// tests as the toolbar. Non-navigation items default to enabled.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        canPerformNavigation(menuItem.action)
    }
}

// MARK: - Toolbar item validation

extension MainWindowController: NSToolbarItemValidation {
    /// Enables/disables the nav-group subitems (⏮◀▶⏭) through the responder
    /// chain. AppKit calls this for each `target = nil` item that resolves to
    /// this responder; non-navigation items default to enabled. Uses the same
    /// `canGoBackward` / `canGoForward` tests as the Navigate menu.
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        canPerformNavigation(item.action)
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
                            action: Selector(("newGame:")))
        case .importSGF:
            return makeItem(itemIdentifier,
                            label: "Import",
                            symbol: "square.and.arrow.down",
                            action: Selector(("importSGF:")))
        case .analyze:
            return makeItem(itemIdentifier,
                            label: "Analyze",
                            symbol: "wand.and.stars",
                            action: Selector(("toggleAnalysis:")))
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
