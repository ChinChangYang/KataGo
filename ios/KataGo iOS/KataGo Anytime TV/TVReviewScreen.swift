//
//  TVReviewScreen.swift
//  KataGo Anytime TV
//
//  Read-only review/spectate of a saved game: a large, unobstructed vector board
//  (the shared BoardView with the captured-stone strip, pass row, and winrate bar
//  hidden so the goban fills the screen) plus a legible 10-foot side panel —
//  player labels, captures, win rate, score, and a move/komi/rules info row —
//  with a focusable transport row. The Siri-Remote D-pad steps moves. There is
//  no auto-play (nothing advances it on tvOS).
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
    @Environment(NavigationContext.self) private var navigationContext
    @Environment(Analysis.self) private var analysis

    @FocusState private var commentFocused: Bool
    @FocusState private var boardFocused: Bool
    @State private var didLoad = false
    // Parsed once from the SGF at load (a C++ parse — never per body eval).
    @State private var totalMoves = 0

    private var config: Config { game.concreteConfig }

    var body: some View {
        // The board runs full-bleed vertically (only the panel keeps a vertical
        // margin) so the goban is never shorter than the panel beside it —
        // hero-content treatment, like video. Suppressing the captured-stone
        // strip and pass row reclaims more grid, and the winrate bar is
        // redundant with the panel's 34 pt readout.
        HStack(spacing: 0) {
            // Constrained square so the drawing fills its frame and the focus
            // ring hugs the board. It is the only focusable in its section, so
            // the D-pad reaches `.onMoveCommand`; the ring says so on screen.
            BoardView(gameRecord: game,
                      interactive: false,
                      showsCapturedStones: false,
                      showsPass: false,
                      showsWinrateBar: false,
                      commentIsFocused: $commentFocused)
                .aspectRatio(1, contentMode: .fit)
                // Greedy height pins the board size to the screen, not to the
                // panel's ideal height — the board must never resize when the
                // panel's content (analysis toggle states) changes.
                .frame(maxHeight: .infinity)
                .focusable(true)
                .focused($boardFocused)
                .onMoveCommand(perform: step)
                .focusSection()
                .overlay {
                    if boardFocused {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(.white.opacity(0.35), lineWidth: 3)
                    }
                }

            Spacer(minLength: 40)

            panel
                .frame(width: 500)
                .padding(.vertical, 22)
                .focusSection()
        }
        .padding(.horizontal, 60)
        .ignoresSafeArea(edges: .vertical)
        .onAppear(perform: loadIfNeeded)
        .onDisappear {
            // Silent discard (user decision): variations explored here are
            // throwaway — the synced record was never written. Selection is
            // cleared FIRST so a late printsgf reply finds no writer.
            navigationContext.selectedGameRecord = nil
            gobanState.deactivateBranch()
            gobanState.forcesBranchOnPlay = false
            gobanState.maybePauseAnalysis()
        }
    }

    // MARK: - Analysis + transport panel

    private var panel: some View {
        // Spacing/padding and the title/chart sizes are a 1080 pt vertical
        // budget — the full analysis-on stack (2-line title through both
        // toggles) clips at the original 24/24/200/.title values, and the
        // Top Moves rows squeezed the block spacing from 20 to 10.
        VStack(alignment: .leading, spacing: 10) {
            Text(game.name.isEmpty ? "Untitled" : game.name)
                .font(.title2.bold())
                // One line, shrinking to fit: a second title line was
                // affordable before the Top Moves rows, but now it overflows
                // the 1080 budget (title clips at the top, the analysis
                // toggle at the bottom).
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            VStack(spacing: 14) {
                playerRow(.black)
                playerRow(.white)
            }

            VStack(alignment: .leading, spacing: 8) {
                // Always rendered at fixed metrics so the analysis toggle
                // never reflows the panel. Analysis ON shows the live engine
                // outputs; OFF falls back to the per-move values recorded on
                // iPhone/iPad/Mac (valid for the displayed mainline position),
                // or an em-dash when none exist / a variation is shown.
                // Sized to fit "Black 100%   White 0%" in the panel without
                // auto-shrinking below the secondary score line.
                Text(winRateText)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                // Clearly subordinate to the 34 pt winrate headline above.
                Text("Score \(scoreText)")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("\(player.nextColorForPlayCommand == .black ? "Black" : "White") to play")
                    .font(.body)
                    .foregroundStyle(.secondary)

                // Score-lead history synced from iPhone/iPad/Mac reviews; an
                // amber rule tracks the current move as the D-pad steps
                // (branch-aware via displayIndex). Persisted data, so it stays
                // up when analysis is off; explains itself when the game has
                // no recorded history.
                TVScoreChart(gameRecord: game, currentIndex: displayIndex)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 26))

            // The engine's live candidates, clickable: a pick plays that move
            // as a variation (forced branch — the synced record is never
            // written; Menu discards it). After a pick the turn flips and the
            // stream re-arms, so the list refreshes for the other color —
            // alternate picks walk a line.
            // Three rows: the review panel also carries the info row and two
            // transport rows — a fourth candidate row clips the 1080 budget.
            TVBestMovesList(candidates: analysis.candidateMoves(width: Int(board.width),
                                                                height: Int(board.height),
                                                                limit: 3),
                            isEnabled: gobanState.eyeStatus != .closed,
                            rowCount: 3,
                            onPick: pick)

            infoRow

            Spacer()

            navRow
            analysisToggle
        }
    }

    /// Move / komi / rules facts under the stats card. (The chart's
    /// current-move legend lives inside the card next to the chart, and the
    /// to-play line lives with winrate/score; this row is plain navigation
    /// fact, always neutral.)
    private var infoRow: some View {
        // Columns hug their content (equal thirds truncated "Chinese", let
        // alone "New Zealand"); the trailing Spacer keeps them left-grouped.
        // A 4th column doesn't fit at full size — don't add one.
        HStack(alignment: .top, spacing: 28) {
            infoItem("Move", "\(displayIndex) / \(max(totalMoves, displayIndex))")
            infoItem("Komi", String(format: "%.1f", config.komi))
            infoItem("Rules", ruleText)
            Spacer(minLength: 0)
        }
    }

    private func infoItem(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var ruleText: String {
        // A synced Config could carry an out-of-range rule; never crash on it.
        guard Config.rules.indices.contains(config.rule) else { return "Custom" }
        let raw = Config.rules[config.rule]
        if raw == "aga" || raw == "bga" { return raw.uppercased() }
        return raw.replacingOccurrences(of: "-", with: " ").capitalized
    }

    /// One color's label ("AI" / "9d" / "Human") and captured-stone count, shown
    /// large in the panel instead of as a tiny on-board strip.
    private func playerRow(_ color: PlayerColor) -> some View {
        let isBlack = color == .black
        let captures = isBlack ? stones.blackStonesCaptured : stones.whiteStonesCaptured
        return HStack(spacing: 18) {
            TVStoneIndicator(isBlack: isBlack)
            Text(config.playerLabel(for: color))
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 12)
            Text("captured \(captures)")
                .font(.title3.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// The move the panel is showing: the variation position while a branch is
    /// active, the record's mainline position otherwise.
    private var displayIndex: Int {
        gobanState.getCurrentIndex(gameRecord: game) ?? game.currentIndex
    }

    /// Analysis OFF falls back to the persisted per-move values. They are
    /// mainline-indexed, so a branch position has none — nil means em-dash.
    private var persistedBlackWinrate: Float? {
        guard gobanState.eyeStatus == .closed else { return nil }
        guard !gobanState.isBranchActive else { return nil }
        return game.winRates?[displayIndex]
    }

    private var persistedBlackScore: Float? {
        guard gobanState.eyeStatus == .closed else { return nil }
        guard !gobanState.isBranchActive else { return nil }
        return game.scoreLeads?[displayIndex]
    }

    private var winRateText: String {
        let winrate: Float
        if gobanState.eyeStatus == .closed {
            guard let persisted = persistedBlackWinrate else { return "Black —   White —" }
            winrate = persisted
        } else {
            winrate = rootWinrate.black
        }
        let b = Int((winrate * 100).rounded())
        return "Black \(b)%   White \(100 - b)%"
    }

    private var scoreText: String {
        let s: Float
        if gobanState.eyeStatus == .closed {
            guard let persisted = persistedBlackScore else { return "—" }
            s = persisted
        } else {
            s = rootScore.black
        }
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

    /// The one control: analysis ON = the engine runs and everything it
    /// produces is visible; OFF = the engine stops and nothing analysis-
    /// flavored stays on screen. The merged states kill the two traps a
    /// separate Overlay toggle allowed — a stale board overlay with the
    /// engine stopped, and an invisible engine heating the fanless box.
    private var analysisToggle: some View {
        TVToggleButton(systemName: "sparkles", title: "Analysis",
                       isOn: gobanState.analysisStatus == .run) {
            if gobanState.analysisStatus == .run {
                // .clear is observed at the TVRootView, which sends GTP "stop";
                // closing the eye hides the board overlay and switches the
                // panel's winrate/score to the persisted per-move values. The
                // chart and the panel layout stay put — persisted data never
                // goes stale, and the board/panel must not reflow on toggle.
                gobanState.analysisStatus = .clear
                gobanState.eyeStatus = .closed
            } else {
                gobanState.eyeStatus = .opened
                gobanState.analysisStatus = .run
                reanalyze()
            }
        }
    }

    // MARK: - Actions

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        // Review is a SPECTATOR: a synced game configured AI-vs-AI on another
        // device must not start playing itself here — suppress the gen-move
        // branch so such a game streams plain analysis instead (this flag
        // also drops a cancelled search's stray "play" reply at
        // postProcessAIMove). No record is selected at LOAD: a printsgf
        // reply still queued from the previous screen's last move could
        // otherwise land after the selection swap — with no branch active,
        // maybeCollectSgf would write it into this synced record. The first
        // Top Moves pick selects the record instead (see pick()) — by then
        // every pre-review reply has drained while the selection was nil.
        gobanState.suppressesGenMove = true
        gobanState.forcesBranchOnPlay = true
        navigationContext.selectedGameRecord = nil
        gobanState.loadGame(gameRecord: game, previous: nil, player: player,
                            bookLookup: bookLookup, messageList: messageList,
                            board: board, stones: stones)
        totalMoves = SgfOperations(sgf: game.sgf).moveSize ?? game.currentIndex
        // Keep the one-bit invariant across screen entries: a user OFF
        // (.clear) persists until re-toggled; the .pause that leaving the
        // previous screen set (onDisappear → maybePauseAnalysis) resumes here
        // — without this, analysis silently never restarts on re-entry
        // because reanalyze() guards on .run.
        if gobanState.analysisStatus == .clear {
            gobanState.eyeStatus = .closed
        } else {
            gobanState.eyeStatus = .opened
            gobanState.analysisStatus = .run
        }
        reanalyze()
    }

    private func reanalyze() {
        guard gobanState.analysisStatus == .run else { return }
        gobanState.requestAnalysis(config: game.concreteConfig,
                                   messageList: messageList,
                                   nextColorForPlayCommand: player.nextColorForPlayCommand)
    }

    /// Play a Top Moves candidate. The kata-check-move legality round-trip is
    /// the same path a board tap takes on iOS: its reply plays the move via
    /// playPendingHumanMove, which (forced branch) captures the variation
    /// before requesting printsgf — so with the record selected here, every
    /// printsgf reply routes into branchSgf and the synced record is never
    /// written (isEditing == false keeps maybeUpdateAnalysisData inert too).
    /// The turn flip then re-fires BoardView's observer, the suppressed
    /// stream re-arms as plain kata-analyze for the new position, and the
    /// list refills for the other color.
    private func pick(_ candidate: Analysis.CandidateMove) {
        guard gobanState.analysisStatus == .run,
              stones.isReady,
              !gobanState.waitingForAnalysis,     // candidates are for the shown position
              gobanState.pendingMoveTurn == nil,  // one pick in flight at a time
              let turn = player.nextColorSymbolForPlayCommand else { return }
        // Selected lazily (not at load) so a stale printsgf reply from the
        // previous screen can never find a writable selection here;
        // maybeCollectCheckMove needs it set when the legality reply lands.
        navigationContext.selectedGameRecord = game
        gobanState.sendCheckMoveCommand(turn: turn, move: candidate.vertex,
                                        messageList: messageList)
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
/// "slash" glyph, on color alone, or on an ambiguous state glyph (a checkmark
/// reads as "confirmed", not "currently active"): the label says the state in
/// words — "Analysis On" / "Analysis Off" — with the identity icon constant.
/// ON is a wood-amber-filled prominent button, OFF a plain outline. (A tinted
/// `.bordered` ON state is not viable: on tvOS the tint fills the pill and
/// the label disappears into it.) The system white focus lift draws over the
/// tint either way.
private struct TVToggleButton: View {
    let systemName: String
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        let content = HStack(spacing: 10) {
            Image(systemName: systemName)
            Text("\(title) \(isOn ? "On" : "Off")")
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .font(.title3)
        .frame(maxWidth: .infinity, minHeight: 56)

        if isOn {
            // Dark label on the wood fill unfocused; the focused white lift
            // also takes a dark label, so forcing black is safe in both states.
            Button(action: action) { content.foregroundStyle(.black) }
                .buttonStyle(.borderedProminent)
                .tint(.tvWoodAccent)
        } else {
            Button(action: action) { content }
                .buttonStyle(.bordered)
        }
    }
}

/// A stone-like shaded indicator matching the app's fast stone style
/// (StoneView.drawFastStoneBase): base fill with a radial highlight offset
/// toward the top-left (the classic shader's white→stone mix at −1/8,−1/8 of
/// the diameter) and a soft lower-right shadow. Replaces a flat circle that
/// read as a radio button rather than a Go stone. Internal (not private):
/// the self-play screen's player rows reuse it.
struct TVStoneIndicator: View {
    let isBlack: Bool
    private static let diameter: CGFloat = 36

    var body: some View {
        // The black stone sheens gray, not white — a white core reads glassy.
        let base: Color = isBlack ? .black : Color(white: 0.9)
        let highlight: Color = isBlack ? Color(white: 0.45) : .white
        Circle()
            .fill(RadialGradient(colors: [highlight, base],
                                 center: UnitPoint(x: 0.375, y: 0.375),
                                 startRadius: 0,
                                 endRadius: Self.diameter * 0.7))
            .frame(width: Self.diameter, height: Self.diameter)
            .shadow(color: .black.opacity(0.5),
                    radius: Self.diameter / 16,
                    x: Self.diameter / 16, y: Self.diameter / 16)
    }
}

extension Color {
    /// Sampled average of the goban texture (KataGoUICore Wood.imageset) —
    /// warm amber #F4C270. Luminance is high enough for dark label text.
    static let tvWoodAccent = Color(red: 0.957, green: 0.762, blue: 0.438)
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
            .environment(NavigationContext())
    }
}

// Analysis ON: single amber checkmark toggle, overlay + live numbers + chart
// visible, Black ahead (B+ score), Human (black) vs AI (white) player labels,
// captures in the panel.
#Preview("Review — analysis on, B+") {
    let game = TVPreviewData.openingGame()
    let session = TVPreviewData.reviewSession(game: game,
                                              blackWinrate: 0.62,
                                              blackScore: 3.5)
    session.gobanState.analysisStatus = .run
    session.gobanState.eyeStatus = .opened
    return TVReviewPreviewHost(game: game, session: session)
}

// Analysis OFF (the one-bit off state, persisted through entry normalization
// because the status is .clear): the panel keeps its full layout — winrate/
// score fall back to the persisted per-move values (em-dash here: this
// fixture records none at the shown index), the chart placeholder stays, and
// the Top Moves rows render as non-focusable placeholders. Only the board
// overlay and live numbers are gone. Untitled game (falls back to
// "Untitled").
#Preview("Review — analysis off, W+") {
    let game = TVPreviewData.untitledFallbackGame()
    let session = TVPreviewData.reviewSession(game: game,
                                              blackWinrate: 0.31,
                                              blackScore: -12.5)
    session.gobanState.analysisStatus = .clear
    session.gobanState.eyeStatus = .closed
    return TVReviewPreviewHost(game: game, session: session)
}

// Analysis OFF on a move whose winrate/score WERE recorded on iPhone/iPad/Mac:
// the panel shows those persisted values (not em-dashes) plus the full chart —
// the layout is byte-identical to analysis ON.
#Preview("Review — analysis off, persisted values") {
    let game = TVPreviewData.openingGame()
    game.winRates = [5: 0.58]
    let session = TVPreviewData.reviewSession(game: game,
                                              blackWinrate: 0.62,
                                              blackScore: 3.5)
    session.gobanState.analysisStatus = .clear
    session.gobanState.eyeStatus = .closed
    return TVReviewPreviewHost(game: game, session: session)
}

// The common freshly-synced-game state: analysis on but no scoreLeads history
// → the card shows the explanatory placeholder instead of a hole.
#Preview("Review — no score history") {
    let game = TVPreviewData.untitledFallbackGame()
    let session = TVPreviewData.reviewSession(game: game,
                                              blackWinrate: 0.48,
                                              blackScore: -0.5)
    session.gobanState.analysisStatus = .run
    session.gobanState.eyeStatus = .opened
    return TVReviewPreviewHost(game: game, session: session)
}
#endif
