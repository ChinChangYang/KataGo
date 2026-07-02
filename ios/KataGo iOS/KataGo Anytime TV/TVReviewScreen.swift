//
//  TVReviewScreen.swift
//  KataGo Anytime TV
//
//  Read-only review/spectate of a saved game: a large, unobstructed vector board
//  (the shared BoardView with the captured-stone strip and pass row hidden so the
//  goban fills the screen) plus a legible 10-foot side panel — player labels,
//  captures, win rate and score — with a focusable transport row. The Siri-Remote
//  D-pad steps moves. There is no auto-play (nothing advances it on tvOS).
//

import SwiftUI
import KataGoUICore

struct TVReviewScreen: View {
    let game: GameRecord

    @Environment(GobanState.self) private var gobanState
    @Environment(Turn.self) private var player
    @Environment(BookLookup.self) private var bookLookup
    @Environment(MessageList.self) private var messageList
    @Environment(BoardSize.self) private var board
    @Environment(Stones.self) private var stones
    @Environment(AudioModel.self) private var audioModel
    @Environment(Winrate.self) private var rootWinrate
    @Environment(Score.self) private var rootScore

    @FocusState private var commentFocused: Bool
    @State private var didLoad = false

    private var config: Config { game.concreteConfig }

    var body: some View {
        HStack(spacing: 56) {
            // The board fills the height; suppressing the captured-stone strip and
            // pass row reclaims that vertical space for a bigger grid. It is the
            // only focusable in its section, so the D-pad reaches `.onMoveCommand`.
            BoardView(gameRecord: game,
                      interactive: false,
                      showsCapturedStones: false,
                      showsPass: false,
                      commentIsFocused: $commentFocused)
                .focusable(true)
                .onMoveCommand(perform: step)
                .focusSection()

            panel
                .frame(width: 500)
                .focusSection()
        }
        .padding(.horizontal, 60)
        .padding(.vertical, 40)
        .onAppear(perform: loadIfNeeded)
        .onDisappear { gobanState.maybePauseAnalysis() }
    }

    // MARK: - Analysis + transport panel

    private var panel: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(game.name.isEmpty ? "Untitled" : game.name)
                .font(.title.bold())
                .lineLimit(2)
                // Wrap to the second line instead of truncating the first.
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 14) {
                playerRow(.black)
                playerRow(.white)
            }

            VStack(alignment: .leading, spacing: 10) {
                // Sized to fit "Black 100%   White 0%" in the panel without
                // auto-shrinking below the secondary score line.
                Text(winRateText)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text("Score \(scoreText)")
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)

                // Score-lead history synced from iPhone/iPad/Mac reviews; the
                // red rule tracks the current move as the D-pad steps. Hidden
                // (zero height) when the game has no history or the overlay
                // is off.
                TVScoreChart(gameRecord: game)
                    .padding(.top, 8)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 26))

            Spacer()

            navRow
            toggleRow
        }
    }

    /// One color's label ("AI" / "9d" / "Human") and captured-stone count, shown
    /// large in the panel instead of as a tiny on-board strip.
    private func playerRow(_ color: PlayerColor) -> some View {
        let isBlack = color == .black
        let captures = isBlack ? stones.blackStonesCaptured : stones.whiteStonesCaptured
        return HStack(spacing: 18) {
            Circle()
                .fill(isBlack ? Color.black : Color.white)
                .frame(width: 30, height: 30)
                .overlay(Circle().stroke(Color.primary.opacity(0.4), lineWidth: 2))
            Text(config.playerLabel(for: color))
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 12)
            Text("captured \(captures)")
                .font(.title3.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var winRateText: String {
        let b = Int((rootWinrate.black * 100).rounded())
        return "Black \(b)%   White \(100 - b)%"
    }

    private var scoreText: String {
        let s = rootScore.black
        let side = s >= 0 ? "B" : "W"
        return String(format: "%@+%.1f", side, abs(s))
    }

    // MARK: - Transport

    private var navRow: some View {
        HStack(spacing: 14) {
            TVNavButton(systemName: "backward.end") { goToStart() }
            TVNavButton(systemName: "backward.frame") { stepBy(-1) }
            TVNavButton(systemName: "forward.frame") { stepBy(1) }
            TVNavButton(systemName: "forward.end") { goToEnd() }
        }
    }

    private var toggleRow: some View {
        // Stacked, not side-by-side: tvOS bordered buttons pad their content
        // generously, and two half-width buttons truncate their titles.
        VStack(spacing: 14) {
            TVToggleButton(systemName: "sparkles", title: "Analysis",
                           isOn: gobanState.analysisStatus == .run) {
                if gobanState.analysisStatus == .run {
                    // Setting .clear is observed at the TVRootView, which sends
                    // GTP "stop" to actually halt the streaming engine.
                    gobanState.analysisStatus = .clear
                } else {
                    gobanState.analysisStatus = .run
                    reanalyze()
                }
            }
            TVToggleButton(systemName: "eye", title: "Overlay",
                           isOn: gobanState.eyeStatus == .opened) {
                gobanState.eyeStatus = (gobanState.eyeStatus == .opened) ? .closed : .opened
            }
        }
    }

    // MARK: - Actions

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        gobanState.loadGame(gameRecord: game, previous: nil, player: player,
                            bookLookup: bookLookup, messageList: messageList,
                            board: board, stones: stones)
        reanalyze()
    }

    private func reanalyze() {
        guard gobanState.analysisStatus == .run else { return }
        gobanState.requestAnalysis(config: game.concreteConfig,
                                   messageList: messageList,
                                   nextColorForPlayCommand: player.nextColorForPlayCommand)
    }

    private func goToStart() {
        gobanState.backwardMoves(limit: nil, gameRecord: game, messageList: messageList,
                                 player: player, stones: stones)
        reanalyze()
    }

    private func goToEnd() {
        gobanState.forwardMoves(limit: nil, gameRecord: game, board: board,
                                messageList: messageList, player: player,
                                audioModel: audioModel, stones: stones)
        reanalyze()
    }

    private func stepBy(_ delta: Int) {
        if delta < 0 {
            gobanState.backwardMoves(limit: -delta, gameRecord: game, messageList: messageList,
                                     player: player, stones: stones)
        } else {
            gobanState.forwardMoves(limit: delta, gameRecord: game, board: board,
                                    messageList: messageList, player: player,
                                    audioModel: audioModel, stones: stones)
        }
        reanalyze()
    }

    private func step(_ direction: MoveCommandDirection) {
        switch direction {
        case .left:  stepBy(-1)
        case .right: stepBy(1)
        case .up:    stepBy(10)
        case .down:  stepBy(-10)
        default:     break
        }
    }
}

/// One move-navigation transport button (icon-only, fixed 56 pt height).
private struct TVNavButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title2)
                .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.bordered)
    }
}

/// A labelled toggle whose state reads at 10 feet without relying on a valid
/// "slash" glyph: ON is a filled prominent (green) button, OFF a plain outline.
private struct TVToggleButton: View {
    let systemName: String
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        let content = HStack(spacing: 10) {
            Image(systemName: systemName)
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .font(.title3)
        .frame(maxWidth: .infinity, minHeight: 56)

        if isOn {
            Button(action: action) { content }
                .buttonStyle(.borderedProminent)
                .tint(.green)
        } else {
            Button(action: action) { content }
                .buttonStyle(.bordered)
        }
    }
}

// MARK: - Previews

#if DEBUG
/// Injects a pre-staged GameSession's models the same way TVRootView does, so
/// the review screen (and the shared BoardView inside it) resolves every
/// @Environment object without an engine.
private struct TVReviewPreviewHost: View {
    let game: GameRecord
    let session: GameSession

    var body: some View {
        TVReviewScreen(game: game)
            .environment(session.stones)
            .environment(session.messageList)
            .environment(session.board)
            .environment(session.player)
            .environment(session.analysis)
            .environment(session.gobanState)
            .environment(session.rootWinrate)
            .environment(session.rootScore)
            .environment(session.bookLookup)
            .environment(AudioModel())
    }
}

// Analysis ON: green filled toggles, overlay visible, Black ahead (B+ score),
// Human (black) vs AI (white) player labels, captures in the panel.
#Preview("Review — analysis on, B+") {
    let game = TVPreviewData.openingGame()
    let session = TVPreviewData.reviewSession(game: game,
                                              blackWinrate: 0.62,
                                              blackScore: 3.5)
    session.gobanState.analysisStatus = .run
    session.gobanState.eyeStatus = .opened
    return TVReviewPreviewHost(game: game, session: session)
}

// Analysis OFF: plain bordered toggles, overlay hidden, White ahead (W+ score
// branch), untitled game (falls back to "Untitled").
#Preview("Review — analysis off, W+") {
    let game = TVPreviewData.untitledFallbackGame()
    let session = TVPreviewData.reviewSession(game: game,
                                              blackWinrate: 0.31,
                                              blackScore: -12.5)
    session.gobanState.analysisStatus = .clear
    session.gobanState.eyeStatus = .closed
    return TVReviewPreviewHost(game: game, session: session)
}
#endif
