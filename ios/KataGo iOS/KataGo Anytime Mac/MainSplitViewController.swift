import AppKit
import KataGoUICore

/// The window's 3-pane content: a collapsible Library sidebar, the board (the
/// resizable content), and a collapsible Inspector. The board pane hosts the
/// reused SwiftUI `BoardView` via `BoardViewController`; the sidebar hosts the
/// native `LibrarySidebarViewController` (Phase 2); the Inspector hosts the
/// tabbed `InspectorViewController` (Phase 4: Chart/Comments/Moves/Info).
final class MainSplitViewController: NSSplitViewController {
    let session: GameSession
    let navigationContext: NavigationContext
    let audioModel: AudioModel
    let libraryStore: LibraryStore
    let readiness: BoardReadiness
    /// Drives the board pane's pre-ready status caption (P5-T9). Threaded down to
    /// `BoardViewController` alongside `readiness`.
    let engineLaunchStatus: EngineLaunchStatus
    /// Weak to avoid a retain cycle: the window controller owns this split VC
    /// (as its window's `contentViewController`). The sidebar routes selection
    /// back through it via `selectGame`.
    private weak var windowController: MainWindowController?

    /// The Inspector's tabbed controller + its split item, retained so the
    /// View-menu tab shortcuts (⌘1–4, via `showInspectorTab`) can select a tab
    /// and expand the pane if it's collapsed.
    private var inspectorViewController: InspectorViewController?
    private var inspectorSplitItem: NSSplitViewItem?

    init(session: GameSession,
         navigationContext: NavigationContext,
         audioModel: AudioModel,
         libraryStore: LibraryStore,
         readiness: BoardReadiness,
         engineLaunchStatus: EngineLaunchStatus,
         windowController: MainWindowController) {
        self.session = session
        self.navigationContext = navigationContext
        self.audioModel = audioModel
        self.libraryStore = libraryStore
        self.readiness = readiness
        self.engineLaunchStatus = engineLaunchStatus
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
            audioModel: audioModel,
            readiness: readiness,
            engineLaunchStatus: engineLaunchStatus,
            activeModelTitle: windowController?.modelSelection.currentModel.title ?? ""
        )
        let boardItem = NSSplitViewItem(viewController: boardVC)
        boardItem.holdingPriority = NSLayoutConstraint.Priority(
            NSLayoutConstraint.Priority.defaultLow.rawValue - 1)
        // The board is the non-collapsible content pane; without a floor it can be
        // squeezed to ~0 width at a narrow window (the sidebar's 180 + the
        // inspector's 220 minimums otherwise eat all the space). A minimum keeps
        // the board (and its win-rate bar) usable, and makes AppKit collapse the
        // sidebar/inspector first — and bound the window's own minimum width.
        boardItem.minimumThickness = 480

        // Inspector — collapsible trailing pane (macOS 14+ has a dedicated API).
        // Tabbed Chart/Comments/Moves/Info inspector (Phase 4); routes through the
        // same readiness gate + collaborators as the board host.
        let inspectorItem: NSSplitViewItem
        let inspectorVC = InspectorViewController(
            session: session,
            navigationContext: navigationContext,
            audioModel: audioModel,
            readiness: readiness
        )
        if #available(macOS 14.0, *) {
            inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorVC)
        } else {
            inspectorItem = NSSplitViewItem(viewController: inspectorVC)
        }
        inspectorItem.canCollapse = true
        inspectorItem.minimumThickness = 220
        inspectorItem.maximumThickness = 360
        self.inspectorViewController = inspectorVC
        self.inspectorSplitItem = inspectorItem

        splitViewItems = [sidebarItem, boardItem, inspectorItem]
    }

    /// Selects an Inspector tab by index (0=Chart, 1=Comments, 2=Moves, 3=Info),
    /// first expanding the Inspector pane if it's collapsed. Backs the ⌘1–4
    /// View-menu shortcuts routed through `MainWindowController.selectInspectorTab`.
    func showInspectorTab(_ index: Int) {
        if inspectorSplitItem?.isCollapsed == true {
            inspectorSplitItem?.isCollapsed = false
        }
        guard let inspectorVC = inspectorViewController,
              inspectorVC.tabViewItems.indices.contains(index) else { return }
        inspectorVC.selectedTabViewItemIndex = index
    }
}
