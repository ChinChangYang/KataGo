import AppKit
import SwiftUI
import KataGoUICore

/// Hosts the Go board pane. For Phase 1 Task 3 this shows a placeholder; Task 4
/// swaps the placeholder for `NSHostingController(rootView: MacBoardHostView(session:))`
/// driven by the real engine.
final class BoardViewController: NSViewController {
    let session: GameSession

    init(session: GameSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        // Task 4 swaps this placeholder for NSHostingController(rootView: MacBoardHostView(session:)).
        let host = NSHostingController(rootView: BoardPlaceholderView())
        addChild(host)
        view = host.view
    }
}

private struct BoardPlaceholderView: View {
    var body: some View {
        Text("Board (Phase 4)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
