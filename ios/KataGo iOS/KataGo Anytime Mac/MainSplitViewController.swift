import AppKit
import KataGoUICore

/// The window's 3-pane content: a collapsible Library sidebar, the board (the
/// resizable content), and a collapsible Inspector. The Library and Inspector
/// panes are still placeholders (Phase 2 / Phase 4); the board pane hosts the
/// reused SwiftUI `BoardView` via `BoardViewController`.
final class MainSplitViewController: NSSplitViewController {
    let session: GameSession
    let navigationContext: NavigationContext
    let audioModel: AudioModel

    init(session: GameSession,
         navigationContext: NavigationContext,
         audioModel: AudioModel) {
        self.session = session
        self.navigationContext = navigationContext
        self.audioModel = audioModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Sidebar (Library) — collapsible leading pane.
        let sidebarItem = NSSplitViewItem(
            sidebarWithViewController: PlaceholderViewController(labelText: "Library (Phase 2)"))
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
