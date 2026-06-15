//
//  MacBoardHostView.swift
//  KataGo Anytime Mac
//
//  Phase 1 Task 4: render the reused SwiftUI `BoardView` (from `KataGoUICore`)
//  inside the AppKit window via `NSHostingController`, fed from the
//  engine-driven `GameSession` plus the Mac-side UI collaborators.
//

import SwiftUI
import KataGoUICore

/// SwiftUI bridge that hosts the package's `BoardView`. It injects exactly the
/// `@Environment` objects `BoardView` and its subviews
/// (`StoneView`/`AnalysisView`/`WinrateBarView`/`BookAnalysisView`/
/// `MoveNumberView`/`BoardLineView`) read; nothing more.
///
/// The collaborators `NavigationContext`, `ThumbnailModel` and `TopUIState` are
/// owned by the window controller and passed in so the host can resolve the
/// currently-selected `GameRecord` (which `BoardView.init` requires) and so the
/// set is ready for later phases — but they are *not* environment dependencies
/// of `BoardView` itself, so they are intentionally not injected here.
struct MacBoardHostView: View {
    let session: GameSession
    let navigationContext: NavigationContext
    let audioModel: AudioModel
    let thumbnailModel: ThumbnailModel
    let topUIState: TopUIState

    /// `BoardView` takes a `FocusState<Bool>.Binding` for its comment field.
    /// Phase 1 has no comment editor on macOS, so this is a private focus state
    /// the board can drive harmlessly.
    @FocusState private var commentIsFocused: Bool

    var body: some View {
        Group {
            if let gameRecord = navigationContext.selectedGameRecord {
                BoardView(gameRecord: gameRecord, commentIsFocused: $commentIsFocused)
                    // Exactly the environment set BoardView + its subviews read:
                    .environment(session.stones)
                    .environment(session.board)
                    .environment(session.player)
                    .environment(session.analysis)
                    .environment(session.gobanState)
                    .environment(session.rootWinrate)
                    .environment(session.rootScore)
                    .environment(session.bookLookup)
                    .environment(session.messageList)
                    .environment(audioModel)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
