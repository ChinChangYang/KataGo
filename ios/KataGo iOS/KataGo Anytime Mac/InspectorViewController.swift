import AppKit
import SwiftUI
import KataGoUICore

/// Hosts the macOS Inspector pane as an `NSTabViewController` with native
/// segmented tabs: Chart · Comments · Moves · Info.
///
/// The Chart and Comments tabs reuse the shared SwiftUI views (`LinePlotView` /
/// `CommentView`) via `NSHostingController`, fed from the engine-backed
/// `GameSession` plus the Mac-side UI collaborators (mirroring
/// `BoardViewController` / `MacBoardHostView`). The Moves and Info tabs are
/// simple placeholders until later Phase 4 tasks fill them in.
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
            viewController: NSHostingController(
                rootView: ChartTabView(
                    session: session,
                    navigationContext: navigationContext,
                    readiness: readiness
                )
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

        let moves = NSTabViewItem(
            viewController: NSHostingController(
                rootView: MovesTabView(
                    session: session,
                    navigationContext: navigationContext,
                    readiness: readiness
                )
            )
        )
        moves.label = "Moves"
        moves.image = NSImage(systemSymbolName: "list.number",
                              accessibilityDescription: "Moves")

        let info = NSTabViewItem(
            viewController: PlaceholderViewController(labelText: "Info (Phase 4)")
        )
        info.label = "Info"
        info.image = NSImage(systemSymbolName: "info.circle",
                             accessibilityDescription: "Info")

        tabViewItems = [chart, comments, moves, info]
    }
}
