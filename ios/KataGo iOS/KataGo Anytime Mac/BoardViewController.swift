import AppKit
import SwiftUI
import KataGoUICore

/// Hosts the Go board pane. Renders the reused SwiftUI `BoardView` (via
/// `MacBoardHostView` / `NSHostingController`) driven by the engine-backed
/// `GameSession` and the Mac-side UI collaborators.
final class BoardViewController: NSViewController {
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

    override func loadView() {
        let host = NSHostingController(
            rootView: MacBoardHostView(
                session: session,
                navigationContext: navigationContext,
                audioModel: audioModel,
                readiness: readiness
            )
        )
        addChild(host)
        view = host.view
    }
}
