//
//  InspectorTabs.swift
//  KataGo Anytime Mac
//
//  Phase 4 Task 1: SwiftUI bridges that host the package's `LinePlotView`,
//  `MovesListView`, and `CommentView` inside the AppKit Inspector tabs (via
//  `NSHostingController`), fed from the engine-driven `GameSession`. Analogous
//  to `MacBoardHostView`: each mounts as soon as a game is SELECTED (else a
//  spinner) and injects exactly the `@Environment` objects the wrapped view
//  reads — nothing more.
//
//  None of the three waits for the engine any more. The chart, the move list
//  and the comment field are all read off the record — the same SGF the board
//  replays — so gating them on a GTP handshake only hid data that was already
//  there. The spinner is now what "nothing is selected" looks like, and
//  nothing else.
//

import SwiftUI
import KataGoUICore

/// Top pane of the combined Chart tab: hosts the package's `LinePlotView`
/// (win-rate / score chart). Stacked over `MovesPaneView` by the native
/// `ChartMovesSplitViewController`.
///
/// `LinePlotView` reads EXACTLY `GobanState`, `BoardSize`, `MessageList`,
/// `Turn`, `Stones` — it does NOT declare `Analysis`, so that is intentionally
/// not injected here.
struct ChartPaneView: View {
    let session: GameSession
    let navigationContext: NavigationContext

    var body: some View {
        if let gameRecord = navigationContext.selectedGameRecord {
            LinePlotView(gameRecord: gameRecord)
                .environment(session.gobanState)
                .environment(session.board)
                .environment(session.player)
                .environment(session.messageList)
                .environment(session.stones)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Bottom pane of the combined Chart tab: hosts the package's `MovesListView`
/// (flat list of the active line with per-move win% / score). Stacked under
/// `ChartPaneView` by the native `ChartMovesSplitViewController`.
///
/// `MovesListView` reads EXACTLY `GobanState`, `BoardSize`, `MessageList`,
/// `Turn`, `Stones` — the same set `GobanState.go(to:)` needs to navigate — so
/// those are the only environment objects injected here.
struct MovesPaneView: View {
    let session: GameSession
    let navigationContext: NavigationContext

    var body: some View {
        if let gameRecord = navigationContext.selectedGameRecord {
            MovesListView(gameRecord: gameRecord)
                .environment(session.gobanState)
                .environment(session.board)
                .environment(session.player)
                .environment(session.messageList)
                .environment(session.stones)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Comments tab: hosts the package's `CommentView`.
///
/// `CommentView` reads EXACTLY `GobanState`, `Analysis`, `Stones`, `BoardSize`,
/// `Turn` — it does NOT declare `MessageList`, so that is intentionally not
/// injected here. The wrapper owns the `@FocusState` the view's `.focused(_:)`
/// modifier binds to.
struct CommentsTabView: View {
    let session: GameSession
    let navigationContext: NavigationContext

    @FocusState private var commentIsFocused: Bool

    var body: some View {
        if let gameRecord = navigationContext.selectedGameRecord {
            CommentView(gameRecord: gameRecord)
                .focused($commentIsFocused)
                .environment(session.gobanState)
                .environment(session.analysis)
                .environment(session.stones)
                .environment(session.board)
                .environment(session.player)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
