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
    /// Drives the pre-ready board-pane status caption (P5-T9). Threaded down from
    /// the window controller alongside `readiness`.
    let engineLaunchStatus: EngineLaunchStatus
    /// Title of the model currently launching, shown under the caption. A snapshot
    /// captured at construction — relaunch rebuilds the host chain, so this is
    /// re-read then.
    let activeModelTitle: String

    init(session: GameSession,
         navigationContext: NavigationContext,
         audioModel: AudioModel,
         readiness: BoardReadiness,
         engineLaunchStatus: EngineLaunchStatus,
         activeModelTitle: String) {
        self.session = session
        self.navigationContext = navigationContext
        self.audioModel = audioModel
        self.readiness = readiness
        self.engineLaunchStatus = engineLaunchStatus
        self.activeModelTitle = activeModelTitle
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let host = NSHostingController(
            rootView: MacBoardHostView(
                session: session,
                navigationContext: navigationContext,
                audioModel: audioModel,
                readiness: readiness,
                engineLaunchStatus: engineLaunchStatus,
                activeModelTitle: activeModelTitle
            )
        )
        addChild(host)
        view = host.view
    }
}
