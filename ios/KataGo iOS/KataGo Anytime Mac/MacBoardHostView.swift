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
/// `MoveNumberView`/`BoardLineView`/`EngineStatusView`) read; nothing more.
///
/// The board never waits for the engine. It mounts as soon as a game is
/// selected — the position it draws is replayed from that record's SGF, which
/// needs no engine at all — and whether anything can ANALYSE it is a state,
/// carried by the inline `EngineStatusView` inside `BoardView`
/// (`.environment(session.engineStatus)` below). The engine-readiness gate that
/// used to replace this whole pane with a spinner until the GTP handshake
/// landed is gone, and so is the premature-`showboard` hazard that justified it
/// (`GobanState.resyncOnAppear` now asks nothing of an engine that is not
/// ready, and `MessageList`'s command gate drops what it cannot deliver).
///
/// `EngineLaunchStatus` is deliberately NOT injected. On macOS the Core ML
/// compile happens inside the `katago-engine` CHILD process, and there is no
/// helper -> app channel to report it (ADR 0007); the app's own
/// `EngineLaunchStatus` therefore never leaves `.idle`, and injecting it would
/// only promise a compile caption that can never arrive. `BoardView` reads it
/// optionally, so the macOS line says "Loading engine…" and nothing more.
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
                // The interaction overlay is Z-stacked ON TOP of BoardView so it
                // is the single native input handler (left-click play /
                // right-click menu / hover). It replicates BoardView's
                // `VStack { Spacer(minLength: 20); GeometryReader }` outer layout
                // so the ZStack sizes both identically and they share one
                // coordinate space (see MacBoardInteractionLayer).
                ZStack {
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
                        // Engine availability, shown inline over the board:
                        // "Loading engine…" during a launch, the failure reason
                        // + Retry after a helper exit, "Board larger than Max
                        // Board Size N" while held. Renders nothing at all once
                        // the engine is ready.
                        .environment(session.engineStatus)

                    MacBoardInteractionLayer(gameRecord: gameRecord)
                        // The same environment objects the overlay reads
                        // (BoardSize / Turn / GobanState / Stones / MessageList /
                        // Analysis — the last drives T9's hover preview), injected
                        // exactly as BoardView's are.
                        .environment(session.board)
                        .environment(session.player)
                        .environment(session.gobanState)
                        .environment(session.stones)
                        .environment(session.messageList)
                        .environment(session.analysis)
                        // The status line is drawn INSIDE `BoardView`, i.e.
                        // UNDER this overlay — and this overlay owns every
                        // click in the board area (its `Color.clear` is
                        // hit-testable edge to edge). So when the status offers
                        // a way out (Retry), stand aside, or that button could
                        // never be clicked. Nothing is lost: a board whose
                        // engine is failed or absent refuses plays anyway
                        // (`stones.isReady` is false), so the only thing given
                        // up is the right-click menu, for exactly as long as
                        // the button is up. A plain "Loading engine…" carries
                        // no actions and leaves the overlay live.
                        .allowsHitTesting(session.engineStatus.actions.isEmpty)
                }
            } else {
                // No game selected — not an engine state, so no status line:
                // there is simply nothing to draw.
                Color.clear
            }
        }
    }
}
