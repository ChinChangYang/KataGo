import AppKit
import KataGoUICore

/// The window's 3-pane content: a collapsible Library sidebar, the board (the
/// resizable content), and a collapsible Inspector. The board placeholder lets
/// the split build before the real board is wired in Task 4.
final class MainSplitViewController: NSSplitViewController {
    let session: GameSession

    init(session: GameSession) {
        self.session = session
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
        let boardItem = NSSplitViewItem(viewController: BoardViewController(session: session))
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
