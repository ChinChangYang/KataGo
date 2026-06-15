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
/// `NavigationContext` is needed to resolve the currently-selected `GameRecord`
/// (which `BoardView.init` requires); `AudioModel` is an environment dependency
/// of the board. The window controller owns other collaborators
/// (`ThumbnailModel`/`TopUIState`) for later phases, but they are neither read
/// nor injected here, so they are not threaded into the host chain.
struct MacBoardHostView: View {
    let session: GameSession
    let navigationContext: NavigationContext
    let audioModel: AudioModel

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
