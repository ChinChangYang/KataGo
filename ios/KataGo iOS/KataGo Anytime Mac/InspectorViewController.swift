import AppKit
import SwiftUI
import KataGoUICore

/// Hosts the macOS Inspector pane as an `NSTabViewController` with native
/// segmented tabs: Chart · Comments · Info.
///
/// The Chart tab is a combined chart-over-moves view (`ChartMovesSplitViewController`:
/// the shared `LinePlotView` over `MovesListView` in a native vertical split with
/// a draggable divider); the Comments tab reuses the shared `CommentView` (via
/// `NSHostingController`) — both fed from the engine-backed `GameSession` plus the
/// Mac-side UI collaborators (mirroring `BoardViewController` / `MacBoardHostView`).
/// The Info tab is the native `InspectorInfoViewController` (game summary + inline
/// common settings).
final class InspectorViewController: NSTabViewController {
    let session: GameSession
    let navigationContext: NavigationContext
    let audioModel: AudioModel
    let readiness: BoardReadiness

    init(session: GameSession,
         navigationContext: NavigationContext,
         audioModel: AudioModel,
         readiness: BoardReadiness) {
        self.session = session
        self.navigationContext = navigationContext
        self.audioModel = audioModel
        self.readiness = readiness
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()

        tabStyle = .segmentedControlOnTop

        let chart = NSTabViewItem(
            viewController: ChartMovesSplitViewController(
                session: session,
                navigationContext: navigationContext,
                readiness: readiness
            )
        )
        chart.label = "Chart"
        chart.image = NSImage(systemSymbolName: "chart.xyaxis.line",
                              accessibilityDescription: "Chart")

        let comments = NSTabViewItem(
            viewController: NSHostingController(
                rootView: CommentsTabView(
                    session: session,
                    navigationContext: navigationContext,
                    readiness: readiness
                )
            )
        )
        comments.label = "Comments"
        comments.image = NSImage(systemSymbolName: "text.bubble",
                                 accessibilityDescription: "Comments")

        let info = NSTabViewItem(
            viewController: InspectorInfoViewController(
                session: session,
                navigationContext: navigationContext
            )
        )
        info.label = "Info"
        info.image = NSImage(systemSymbolName: "info.circle",
                             accessibilityDescription: "Info")

        tabViewItems = [chart, comments, info]
    }
}

/// The combined "Chart" tab's content: the win-rate / score chart over the move
/// list, in a native vertical split (`splitView.isVertical = false` → a
/// horizontal divider stacking the panes top/bottom). Mirrors the top-level
/// `MainSplitViewController` pattern — each pane hosts a shared SwiftUI view via
/// `NSHostingController` — and gives a real draggable divider with per-pane
/// minimums, which a SwiftUI `VSplitView` inside an `NSHostingController` does
/// not reliably provide. Seeds a chart ≈ 58% default; user drags hold for the
/// window's lifetime (clamped by the per-pane minimums).
final class ChartMovesSplitViewController: NSSplitViewController {
    private let session: GameSession
    private let navigationContext: NavigationContext
    private let readiness: BoardReadiness
    private var didSetInitialDivider = false

    init(session: GameSession,
         navigationContext: NavigationContext,
         readiness: BoardReadiness) {
        self.session = session
        self.navigationContext = navigationContext
        self.readiness = readiness
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()

        splitView.isVertical = false
        splitView.dividerStyle = .thin

        let chartItem = NSSplitViewItem(
            viewController: NSHostingController(
                rootView: ChartPaneView(
                    session: session,
                    navigationContext: navigationContext,
                    readiness: readiness
                )
            )
        )
        chartItem.minimumThickness = 140
        chartItem.canCollapse = false

        let movesItem = NSSplitViewItem(
            viewController: NSHostingController(
                rootView: MovesPaneView(
                    session: session,
                    navigationContext: navigationContext,
                    readiness: readiness
                )
            )
        )
        movesItem.minimumThickness = 120
        movesItem.canCollapse = false

        splitViewItems = [chartItem, movesItem]
    }

    /// Seed a sensible default split (chart ≈ 58%) the first time we have real
    /// bounds. Runs once; the user can then drag the divider freely (clamped by
    /// the per-pane minimums) for the window's lifetime.
    override func viewDidLayout() {
        super.viewDidLayout()
        guard !didSetInitialDivider else { return }
        let height = splitView.bounds.height
        guard height > 0 else { return }
        didSetInitialDivider = true
        splitView.setPosition(height * 0.58, ofDividerAt: 0)
    }
}
