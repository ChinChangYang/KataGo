//
//  InspectorTabs.swift
//  KataGo Anytime Mac
//
//  Phase 4 Task 1: SwiftUI bridges that host the package's `LinePlotView` and
//  `CommentView` inside the AppKit Inspector tabs (via `NSHostingController`),
//  fed from the engine-driven `GameSession`. Analogous to `MacBoardHostView`:
//  each gates on `navigationContext.selectedGameRecord != nil &&
//  readiness.isEngineReady` (else a spinner) and injects exactly the
//  `@Environment` objects the wrapped view reads — nothing more.
//

import SwiftUI
import KataGoUICore

/// Chart tab: hosts the package's `LinePlotView` (win rate / score chart).
///
/// `LinePlotView` reads EXACTLY `GobanState`, `BoardSize`, `MessageList`,
/// `Turn`, `Stones` — it does NOT declare `Analysis`, so that is intentionally
/// not injected here.
struct ChartTabView: View {
    let session: GameSession
    let navigationContext: NavigationContext
    let readiness: BoardReadiness

    var body: some View {
        if let gameRecord = navigationContext.selectedGameRecord, readiness.isEngineReady {
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

/// Comments tab: hosts the package's `CommentView`.
///
/// `CommentView` reads EXACTLY `GobanState`, `Analysis`, `Stones`, `BoardSize`,
/// `Turn` — it does NOT declare `MessageList`, so that is intentionally not
/// injected here. The wrapper owns the `@FocusState` the view's `.focused(_:)`
/// modifier binds to.
struct CommentsTabView: View {
    let session: GameSession
    let navigationContext: NavigationContext
    let readiness: BoardReadiness

    @FocusState private var commentIsFocused: Bool

    var body: some View {
        if let gameRecord = navigationContext.selectedGameRecord, readiness.isEngineReady {
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
