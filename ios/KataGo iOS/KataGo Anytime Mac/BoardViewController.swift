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
    let thumbnailModel: ThumbnailModel
    let topUIState: TopUIState

    init(session: GameSession,
         navigationContext: NavigationContext,
         audioModel: AudioModel,
         thumbnailModel: ThumbnailModel,
         topUIState: TopUIState) {
        self.session = session
        self.navigationContext = navigationContext
        self.audioModel = audioModel
        self.thumbnailModel = thumbnailModel
        self.topUIState = topUIState
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let host = NSHostingController(
            rootView: MacBoardHostView(
                session: session,
                navigationContext: navigationContext,
                audioModel: audioModel,
                thumbnailModel: thumbnailModel,
                topUIState: topUIState
            )
        )
        addChild(host)
        view = host.view
    }
}
