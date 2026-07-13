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
                    engineLaunchStatus: engineLaunchStatus
                )
            }
        }
    }
}

/// Pre-ready board-pane loading screen: the spinning circular KataGo icon, a
/// ticking "Loading…" headline, and an optional Core ML compile-status caption —
/// matching the iOS `LoadingView` design (the tvOS `TVLoadingView` is the same
/// port). The icon rotates continuously until
/// the engine is ready — a first-launch Core ML compile can outlast a single
/// turn — and is pinned when Reduce Motion is on. The MLX/GPU default path never
/// advances the phase, so `secondaryLine` is `nil` there and the ticking
/// headline carries the "Loading…" text.
private struct EngineLaunchStatusView: View {
    let engineLaunchStatus: EngineLaunchStatus

    @State private var degreesRotating = 0.0
    @State private var dotCount = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            VStack {
                Text("Loading" + String(repeating: ".", count: dotCount))
                    .font(.largeTitle)
                    .bold()
                    .contentTransition(.numericText())
                    .padding()

                if let line = secondaryLine {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .accessibilityAddTraits(.updatesFrequently)
                }

                Image(.loadingIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: iconDiameter(in: geo.size),
                           maxHeight: iconDiameter(in: geo.size))
                    .clipShape(.circle)
                    .rotationEffect(.degrees(degreesRotating))
                    .shadow(radius: 8, x: 16, y: 16)
                    .padding(.top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(0.5))
                withAnimation {
                    dotCount = (dotCount + 1) % 4
                }
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 20).repeatForever(autoreverses: false)) {
                degreesRotating = 360
            }
        }
    }

    /// Diameter for the spinning icon: up to 80% of the board pane's smaller
    /// side, so it reads large while leaving room for the headline and captions
    /// stacked above it. `scaledToFit` keeps the image from exceeding this box.
    private func iconDiameter(in size: CGSize) -> CGFloat {
        min(size.width, size.height) * 0.8
    }

    /// Core ML compile-status caption (iOS/tvOS `secondaryLine`). `nil` on the
    /// MLX/GPU default path (`.idle`), where the ticking headline already reads
    /// "Loading…".
    private var secondaryLine: String? {
        switch engineLaunchStatus.phase {
        case .compilingMissFirstLaunch: "Compiling Core ML model — first launch only"
        case .awaitingPrecompile:       "Finishing Core ML compile…"
        case .idle:                     nil
        @unknown default:               nil
        }
    }
}
