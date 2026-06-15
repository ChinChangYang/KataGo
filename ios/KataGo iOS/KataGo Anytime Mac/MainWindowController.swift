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

        w.contentViewController = MainSplitViewController(
            session: session,
            navigationContext: navigationContext,
            audioModel: audioModel,
            thumbnailModel: thumbnailModel,
            topUIState: topUIState
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

// MARK: - Toolbar

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
            ("First", "backward.end", Selector(("goToStart:"))),
            ("Back", "backward", Selector(("goBackward:"))),
            ("Forward", "forward", Selector(("goForward:"))),
            ("Last", "forward.end", Selector(("goToEnd:"))),
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
