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
        // Wrap the SwiftUI hosting view in a container that accepts first
        // responder, so the window can land keyboard focus on the board pane —
        // not the sidebar `NSSearchField` — at launch. That keeps the LizzieYzy
        // board shortcuts (Space / `,` / `P`) live from the first frame: they're
        // gated on the first responder NOT being an `NSText`
        // (`MainWindowController.isTextInputActive`), and an empty search field
        // grabbing focus would otherwise swallow them as typed text. Board input
        // itself still flows through the SwiftUI gesture overlay inside `host`.
        let container = BoardContainerView()
        host.view.frame = container.bounds
        host.view.autoresizingMask = [.width, .height]
        container.addSubview(host.view)
        view = container
    }
}

/// Board-pane container that accepts first responder. It deliberately handles no
/// keys itself — the LizzieYzy shortcuts run through the window's local key
/// monitor and board clicks through the SwiftUI overlay; this only exists so the
/// window has a concrete, non-`NSText` view to hold keyboard focus on launch
/// (see `BoardViewController.loadView`).
private final class BoardContainerView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
