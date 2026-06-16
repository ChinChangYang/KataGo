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

/// Tracks whether the engine session has finished its initial handshake +
/// board load, so the board pane can defer mounting the live `BoardView`.
///
/// This matters because `BoardView.onAppear` sends a `showboard` (and resets
/// `nextColorForPlayCommand` to `.unknown`). On macOS the board host is built in
/// `MainWindowController.init`, so without this gate `onAppear` fires BEFORE the
/// engine is initialized: that premature `showboard` is dispatched ahead of the
/// GTP handshake, its `= MoveNum` response is lost, and `showBoardCount` is left
/// stuck at 1 — which permanently gates `GameSession.maybeCollectAnalysis` off
/// (`guard showBoardCount == 0`), so the analysis overlay never populates. iOS
/// dodges this by only mounting the board once `isInitialized` is set (after
/// `session.initialize()`); this is the AppKit equivalent of that gate.
@MainActor
@Observable
final class BoardReadiness {
    var isEngineReady = false
}

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
    /// Gates the live board so `BoardView.onAppear` only fires once the engine is
    /// initialized (see `BoardReadiness`); until then the pane shows a spinner.
    let readiness: BoardReadiness
    /// Drives the pre-ready status caption (P5-T9): while the board is gated off,
    /// the spinner shows a phase-specific message (CoreML compile progress, or a
    /// generic MLX/GPU "Loading…"). `@Observable`, so reading `.phase` in `body`
    /// keeps the caption live as the launch path advances it.
    let engineLaunchStatus: EngineLaunchStatus
    /// Title of the model currently being launched, shown under the caption so the
    /// user knows which net is loading. Passed in (not threaded as state) — it is a
    /// snapshot for display only.
    let activeModelTitle: String

    /// `BoardView` takes a `FocusState<Bool>.Binding` for its comment field.
    /// Phase 1 has no comment editor on macOS, so this is a private focus state
    /// the board can drive harmlessly.
    @FocusState private var commentIsFocused: Bool

    var body: some View {
        Group {
            if let gameRecord = navigationContext.selectedGameRecord, readiness.isEngineReady {
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
                }
            } else {
                EngineLaunchStatusView(
                    engineLaunchStatus: engineLaunchStatus,
                    activeModelTitle: activeModelTitle
                )
            }
        }
    }
}

/// Pre-ready board-pane placeholder: a spinner plus a caption driven by
/// `engineLaunchStatus.phase`. Replaces the bare `ProgressView()` so a cache-miss
/// CoreML compile (which can take a while on first launch) surfaces a reassuring
/// message instead of an unexplained wait. The MLX/GPU path emits no phase, so
/// `.idle` falls back to a generic "Loading…". Mirrors the iOS `LoadingView`
/// `secondaryLine`, with an added generic fallback for macOS's MLX default.
private struct EngineLaunchStatusView: View {
    let engineLaunchStatus: EngineLaunchStatus
    let activeModelTitle: String

    /// Phase-specific caption. Unlike iOS (`secondaryLine` is `nil` for `.idle`,
    /// because the iOS LoadingView already shows its own primary text), macOS
    /// shows a generic "Loading…" for `.idle` so the spinner is never caption-less
    /// on the MLX/GPU default path (which never advances the phase).
    private var caption: String {
        switch engineLaunchStatus.phase {
        case .compilingMissFirstLaunch: "Compiling Core ML model — first launch only"
        case .awaitingPrecompile:       "Finishing Core ML compile…"
        case .idle:                     "Loading…"
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(caption)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !activeModelTitle.isEmpty {
                Text(activeModelTitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
