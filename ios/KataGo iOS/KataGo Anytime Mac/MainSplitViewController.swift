import AppKit
import KataGoUICore

/// The window's 3-pane content: a collapsible Library sidebar, the board (the
/// resizable content), and a collapsible Inspector. The board pane hosts the
/// reused SwiftUI `BoardView` via `BoardViewController`; the sidebar hosts the
/// native `LibrarySidebarViewController` (Phase 2). The Inspector pane is still
/// a placeholder (Phase 4).
final class MainSplitViewController: NSSplitViewController {
    let session: GameSession
    let navigationContext: NavigationContext
    let audioModel: AudioModel
    let libraryStore: LibraryStore
    /// Weak to avoid a retain cycle: the window controller owns this split VC
    /// (as its window's `contentViewController`). The sidebar routes selection
    /// back through it via `selectGame`.
    private weak var windowController: MainWindowController?

    init(session: GameSession,
         navigationContext: NavigationContext,
         audioModel: AudioModel,
         libraryStore: LibraryStore,
         windowController: MainWindowController) {
        self.session = session
        self.navigationContext = navigationContext
        self.audioModel = audioModel
        self.libraryStore = libraryStore
        self.windowController = windowController
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Sidebar (Library) — collapsible leading pane hosting the native
        // game list. A row selection routes back through the window controller
        // to switch the board (`selectGame` → `GobanState.loadGame`).
        let librarySidebarVC = LibrarySidebarViewController(
            store: libraryStore,
            navigationContext: navigationContext,
            onSelect: { [weak windowController] game in
                windowController?.selectGame(game)
            }
        )
        // Route the right-click context-menu CRUD actions back through the window
        // controller (weak — see the property's doc comment for the cycle).
        librarySidebarVC.actionsDelegate = windowController
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: librarySidebarVC)
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 320

        // Board (content) — takes the slack on resize.
        let boardVC = BoardViewController(
            session: session,
            navigationContext: navigationContext,
            audioModel: audioModel
        )
        let boardItem = NSSplitViewItem(viewController: boardVC)
        boardItem.holdingPriority = NSLayoutConstraint.Priority(
            NSLayoutConstraint.Priority.defaultLow.rawValue - 1)

        // Inspector — collapsible trailing pane (macOS 14+ has a dedicated API).
        let inspectorItem: NSSplitViewItem
        let inspectorVC = PlaceholderViewController(labelText: "Inspector (Phase 4)")
        if #available(macOS 14.0, *) {
            inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorVC)
        } else {
            inspectorItem = NSSplitViewItem(viewController: inspectorVC)
        }
        inspectorItem.canCollapse = true
        inspectorItem.minimumThickness = 220
        inspectorItem.maximumThickness = 360

        splitViewItems = [sidebarItem, boardItem, inspectorItem]
    }
}
