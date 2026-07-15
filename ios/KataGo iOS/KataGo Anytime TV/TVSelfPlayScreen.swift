//
//  TVSelfPlayScreen.swift
//  KataGo Anytime TV
//
//  "KataGo vs KataGo" — a lean spectate screen where the engine plays both
//  sides. The move loop is the shared machinery, not a timer: BoardView's
//  turn-change observer issues a gen-move whenever the side to move has
//  maxTime > 0, the engine replies `play <vertex>`, GameSession plays it and
//  toggles the turn, which re-fires the observer for the other color. Both
//  sides of the demo config are engine-played, so the game simply runs.
//
//  The demo record lives in the in-memory TVSampleGameStore container — every
//  move mutates it (sgf, currentIndex, scoreLeads), and none of that may ever
//  reach the CloudKit store. Two passes end a game; a result interstitial
//  shows briefly, then a fresh record starts the next game (endless loop).
//  Entered manually (library cards) or by the idle attract mode, which exits
//  on any remote press. Thermal pressure ends the demo in either mode.
//

import SwiftUI
import KataGoUICore

/// Navigation token for the self-play screen (the stack otherwise carries
/// GameRecord values for the review screen).
struct SelfPlayRoute: Hashable {
    enum Entry: Hashable {
        /// User chose the card — Menu exits, other presses are ignored.
        case manual
        /// Idle attract mode started it — ANY remote press exits.
        case attract
    }

    let entry: Entry
}

struct TVSelfPlayScreen: View {
    let route: SelfPlayRoute
    #if DEBUG
    /// Preview seam: render this record as-is and skip the whole driver
    /// (whose entry sequence would reset the staged fixture state and swap in
    /// a fresh empty record). Never set in production.
    var previewGame: GameRecord?
    #endif

    private var stagedPreviewGame: GameRecord? {
        #if DEBUG
        previewGame
        #else
        nil
        #endif
    }

    @Environment(GobanState.self) private var gobanState
    @Environment(Turn.self) private var player
    @Environment(BookLookup.self) private var bookLookup
    @Environment(MessageList.self) private var messageList
    @Environment(BoardSize.self) private var board
    @Environment(Stones.self) private var stones
    @Environment(Winrate.self) private var rootWinrate
    @Environment(Score.self) private var rootScore
    @Environment(NavigationContext.self) private var navigationContext
    @Environment(Analysis.self) private var analysis
    @Environment(TVEngineController.self) private var engine
    @Environment(\.dismiss) private var dismiss

    @FocusState private var commentFocused: Bool
    /// The board itself, when the play cursor is aiming (manual mode only —
    /// in attract the board is not focusable, so any press still exits).
    /// While focused, the D-pad steps the ghost stone and Select injects the
    /// move; Menu hops focus back to the Pause button.
    @FocusState private var boardFocused: Bool
    /// The Pause/Resume button: the entry landing spot (defaultFocus) and the
    /// Menu hop target when leaving cursor mode.
    @FocusState private var pauseFocused: Bool
    /// The play cursor's grid logic (shared with the visionOS ghost stone).
    /// Its point is non-nil only between board focus and unfocus, so passing
    /// it straight into BoardView shows the marker exactly while aiming.
    @State private var ghost = GhostCursorModel()
    @State private var didLoad = false
    @State private var game: GameRecord?
    @State private var restartTask: Task<Void, Never>?
    /// The user's analysis-OFF preference from the review screen, restored on
    /// exit (self-play forces analysis ON — the overlay is the show).
    @State private var analysisWasUserOff = false
    /// The Top Moves row under remote focus, ringed on the board.
    @State private var highlightedPoint: BoardPoint?

    private var isGameOver: Bool { gobanState.passCount >= 2 }

    /// Pause = the shared spectator flag (no gen-move). togglePause also stops
    /// the analysis stream so the fanless Apple TV idles while paused; the Top
    /// Moves list freezes at its last candidates (still pickable). One source
    /// of truth — previews stage it directly on the session.
    private var isPaused: Bool { gobanState.suppressesGenMove }

    var body: some View {
        // Attract is a screensaver: the root owns focus and ANY press exits.
        // Manual is interactive: the root must NOT be focusable and must not
        // handle move commands (a root-level onMoveCommand swallows child
        // focus navigation — the TVLibraryView gotcha), so the D-pad reaches
        // the panel's pause button and Top Moves rows.
        if route.entry == .attract {
            content
                .focusable(true)
                .onMoveCommand { _ in dismiss() }
                .onPlayPauseCommand { dismiss() }
                .onTapGesture { dismiss() }
        } else {
            content
                .onPlayPauseCommand { togglePause() }
                // The panel held the only focusables before the board became
                // one; keep the entry landing on Pause — the giant top-left
                // board must not steal initial focus (deterministic even
                // while analysis warms and the Top Moves rows are
                // placeholders).
                .defaultFocus($pauseFocused, true)
        }
    }

    private var content: some View {
        Group {
            if let game {
                HStack(spacing: 0) {
                    // Same hero-board geometry as the review screen. In
                    // manual mode the board is a focusable leaf (one left
                    // press from the panel): the D-pad steps the ghost
                    // cursor, Select injects the move (the engine answers),
                    // Menu hops focus back to Pause. In attract it stays
                    // unfocusable so the screen root keeps owning the remote
                    // (any press exits).
                    BoardView(gameRecord: game,
                              interactive: false,
                              showsCapturedStones: false,
                              showsPass: false,
                              showsWinrateBar: false,
                              highlightedPoint: highlightedPoint,
                              cursorPoint: ghost.point,
                              commentIsFocused: $commentFocused)
                        // Same full-screen-height pin as the review screen
                        // (tvOS is always 1920×1080 pt; the NavigationStack's
                        // safe-area insets survive ignoresSafeArea and would
                        // otherwise shrink the fitted square). Also keeps the
                        // board independent of the panel's ideal height.
                        .frame(width: 1080, height: 1080)
                        // Stays focusable through the game-over interstitial
                        // so focus never loses its home mid-interstitial;
                        // submit is guarded by !isGameOver, and restart()
                        // drops board focus for the fresh board.
                        .focusable(route.entry == .manual)
                        .focused($boardFocused)
                        .onMoveCommand(perform: boardMove)
                        .onTapGesture(perform: playAtCursor)
                        .overlay {
                            // Focus affordance (the timeline-ring pattern):
                            // no system focus lift on a bare board.
                            Rectangle()
                                .stroke(boardFocused ? Color.tvWoodAccent : .clear,
                                        lineWidth: 4)
                        }
                        .onChange(of: boardFocused) { _, focused in
                            if focused {
                                ghost.activate(width: Int(board.width),
                                               height: Int(board.height))
                            } else {
                                ghost.reset()
                            }
                        }

                    Spacer(minLength: 24)

                    panel(for: game)
                        // Hard ceiling: the 1080 pt screen minus the 40 pt
                        // vertical margins. A fixed frame reports this size
                        // to the HStack no matter how tall the content wants
                        // to be, so panel growth can never inflate the HStack
                        // and push the 1080 pt board off-screen — content
                        // that outgrows the budget overflows inside this
                        // slot, top-aligned. No .clipped(): it would shear
                        // the focus lift/shadow on the rows at the edges.
                        .frame(width: 500, height: 1000, alignment: .top)
                        .padding(.vertical, 40)
                        // While the cursor is aiming, EVERY panel control
                        // must be unfocusable: onMoveCommand is only a
                        // fallback on tvOS (a focusable target in the pressed
                        // direction wins and moves focus before the handler
                        // fires — device finding 2026-07-16), so a focusable
                        // row to the board's right would swallow right
                        // presses. Dimming doubles as the aiming affordance.
                        .disabled(boardFocused)
                        .focusSection()
                }
                // Full-bleed hero board (matches the review screen): all safe
                // areas ignored, explicit paddings are the only margins, so
                // the square reaches the full 1080 pt height.
                .padding(.leading, 24)
                .padding(.trailing, 40)
                .ignoresSafeArea()
                .overlay {
                    if isGameOver {
                        interstitial(for: game)
                    }
                }
            } else {
                // The in-memory store failed (entry points are hidden when
                // unavailable, so this is a race at worst) — nothing to show.
                Color.clear
            }
        }
        // Attached ⇒ replaces the default Menu pop; reproduce it for BOTH
        // modes so Menu always leaves the demo — except while the play
        // cursor is aiming (manual only; attract never focuses the board),
        // where Menu leaves cursor mode instead: a focused board consumes
        // every D-pad press, so this is the one way out.
        .onExitCommand {
            if boardFocused {
                boardFocused = false   // ghost resets via the focus onChange
                pauseFocused = true
            } else {
                dismiss()
            }
        }
        .onReceive(NotificationCenter.default
            .publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: RunLoop.main)) { _ in
                // Read the state fresh from ProcessInfo — the Notification
                // itself is non-Sendable and stays out of the handler.
                if SelfPlayAttract.shouldStop(thermalState: ProcessInfo.processInfo.thermalState) {
                    dismiss()
                }
            }
        .onAppear(perform: startIfNeeded)
        .onDisappear(perform: tearDown)
        .onChange(of: gobanState.passCount) { _, newCount in
            if newCount >= 2 {
                scheduleRestart()
            }
        }
    }

    // MARK: - Panel

    private func panel(for game: GameRecord) -> some View {
        // Spacing/padding, the 3-row Top Moves list, and the always-reserved
        // chart slot are a 1000 pt vertical budget (the capped panel frame) —
        // the full manual-mode stack must fit with the chart visible or the
        // bottom items clip inside the panel.
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Text(SelfPlayGame.demoName)
                    .font(.title2.bold())
                    .lineLimit(1)
                    // Shrinks a touch so the full name fits beside the badge
                    // in the 500 pt panel.
                    .minimumScaleFactor(0.7)
                liveBadge
            }

            VStack(spacing: 14) {
                playerRow(.black)
                playerRow(.white)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(winRateText)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text("Score \(scoreText)")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("Move \(game.currentIndex) — \(player.nextColorForPlayCommand == .black ? "Black" : "White") to play")
                    .font(.body)
                    .foregroundStyle(.secondary)

                // Fills live: the demo game is in editing mode, so every AI
                // move persists a score lead into the (in-memory) record.
                // The chart slot is reserved from move 0 (empty plot area) so
                // the panel never reflows — and never pushes the board off
                // screen — when the second score lead lands mid-game; the
                // review screen's sync guidance would be wrong here.
                TVScoreChart(gameRecord: game, noHistoryMessage: nil,
                             reservesSpaceWhenEmpty: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 26))

            // Clickable candidates: a pick plays that move for the side to
            // move (the in-memory record is in editing mode — no branch).
            // While the game runs, the pick's legality check cancels the
            // in-flight gen-move and the AI answers the user's move; while
            // paused, alternate picks explore a line. In attract mode the
            // rows are placeholders (not focusable) so any press still exits.
            TVBestMovesList(candidates: analysis.candidateMoves(width: Int(board.width),
                                                                height: Int(board.height),
                                                                limit: 3),
                            isEnabled: route.entry == .manual && !isGameOver,
                            rowCount: 3,
                            onFocus: { highlightedPoint = $0?.point },
                            onPick: pick)

            Spacer()

            if route.entry == .manual {
                HStack(spacing: 16) {
                    stepBackButton(for: game)
                    pauseResumeButton
                }
            }

            Text(route.entry == .attract
                 ? "Press any button to exit"
                 : "Press Back to exit")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// Pause/resume the live game (manual mode only — in attract, any press
    /// exits instead). Mirrors the remote's Play/Pause key; disabled during
    /// the interstitial, whose restart owns that phase.
    private var pauseResumeButton: some View {
        Button(action: togglePause) {
            HStack(spacing: 10) {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                Text(isPaused ? "Resume" : "Pause")
            }
            .font(.title3)
            .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.bordered)
        .focused($pauseFocused)
        .disabled(isGameOver)
    }

    /// Step back one move (undo). Pauses first so the engines stop refilling
    /// the position, then steps the shared history back one. Disabled at the
    /// game start (nothing to undo) and during the interstitial. Labeled
    /// "Undo" (not "Back") to avoid colliding with the remote's Menu/Back
    /// button, which the exit hint calls "Back".
    private func stepBackButton(for game: GameRecord) -> some View {
        Button(action: stepBack) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.uturn.backward")
                Text("Undo")
            }
            .font(.title3)
            .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.bordered)
        .disabled(isGameOver || game.currentIndex == 0)
    }

    private var liveBadge: some View {
        Text(isPaused ? "Paused" : "Live")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isPaused ? Color(white: 0.75) : Color.tvWoodAccent,
                        in: Capsule())
    }

    private func playerRow(_ color: PlayerColor) -> some View {
        let isBlack = color == .black
        return TVPlayerRow(isBlack: isBlack,
                           name: "KataGo",
                           captures: isBlack ? stones.blackStonesCaptured
                                             : stones.whiteStonesCaptured)
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

    // MARK: - Interstitial

    private func interstitial(for game: GameRecord) -> some View {
        VStack(spacing: 16) {
            Text("Game over")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(resultText(for: game))
                .font(.system(size: 44, weight: .bold, design: .rounded))
            Text("Next game starting…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(60)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 32))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.4))
        .ignoresSafeArea()
    }

    /// The engine's anticipated result lands as RE[…] in the post-pass
    /// printsgf; until that reply arrives, fall back to the live score sign.
    private func resultText(for game: GameRecord) -> String {
        let parsed = SelfPlayGame.result(fromSgf: game.sgf)
        if parsed != .unknown {
            return SelfPlayGame.resultText(parsed)
        }
        return rootScore.black >= 0 ? "Black wins" : "White wins"
    }

    // MARK: - Lifecycle

    private func startIfNeeded() {
        guard !didLoad else { return }
        didLoad = true

        if let stagedPreviewGame {
            game = stagedPreviewGame
            return
        }

        guard let newGame = TVSampleGameStore.newSelfPlayGame(maxBoardLength: engine.maxBoardLength) else {
            dismiss()
            return
        }
        game = newGame

        // This screen is the player, not a spectator of a synced record —
        // and entry is always un-paused. Picks play directly into the
        // in-memory record (editing mode), never via a branch.
        gobanState.suppressesGenMove = false
        gobanState.forcesBranchOnPlay = false
        // Required or postProcessAIMove drops every engine reply; also routes
        // each move's printsgf into the in-memory record.
        navigationContext.selectedGameRecord = newGame
        // A prior review session stepping through recorded passes leaves this
        // nonzero, which would veto the first gen-move.
        gobanState.passCount = 0
        // Analysis ON is the show; remember a user OFF to restore on exit.
        analysisWasUserOff = (gobanState.analysisStatus == .clear)
        gobanState.eyeStatus = .opened
        gobanState.analysisStatus = .run

        // defaultSgf → loads unlocked (editing), so moves persist into the
        // record. Never rewind this game (a rewound editing position would
        // trip the AI-overwrite confirmation instead of playing).
        gobanState.loadGame(gameRecord: newGame, previous: nil, player: player,
                            bookLookup: bookLookup, messageList: messageList,
                            board: board, stones: stones)

        // Keep the system screensaver from covering the demo (spectating is
        // lean-back, input-free viewing — the video-app pattern).
        UIApplication.shared.isIdleTimerDisabled = true

        // First gen-move: BoardView's onAppear resets the turn to .unknown and
        // sends showboard; the reply sets the real color — a guaranteed change
        // that fires the turn observer.
    }

    private func scheduleRestart() {
        guard restartTask == nil else { return }
        restartTask = Task {
            try? await Task.sleep(for: .seconds(SelfPlayGame.interstitialSeconds))
            guard !Task.isCancelled else { return }
            restartTask = nil
            restart()
        }
    }

    private func restart() {
        guard let finished = game,
              let next = TVSampleGameStore.newSelfPlayGame(maxBoardLength: engine.maxBoardLength) else {
            dismiss()
            return
        }
        game = next
        navigationContext.selectedGameRecord = next
        gobanState.passCount = 0
        gobanState.analysisStatus = .run
        // A paused game can still end (two picked passes) — the next game
        // always starts live.
        gobanState.suppressesGenMove = false
        // A cursor aimed at the finished game must not survive onto the
        // fresh (possibly different-size) board; dropping focus also resets
        // the ghost via the focus onChange.
        boardFocused = false

        // loadsgf inherently cancels the continuous analysis of the finished
        // position; the rest of the setup mirrors first entry.
        gobanState.loadGame(gameRecord: next, previous: finished, player: player,
                            bookLookup: bookLookup, messageList: messageList,
                            board: board, stones: stones)

        // BoardView stays mounted across the swap, so its onAppear kick never
        // re-fires — and the new game's showboard may report the SAME side to
        // move as the finished one, which would not fire the turn observer.
        // Reset to .unknown (BoardView.onAppear's own trick): the showboard
        // reply then always produces a change, which issues the gen-move.
        player.nextColorForPlayCommand = .unknown

        TVSampleGameStore.discard(finished)
    }

    private func tearDown() {
        guard stagedPreviewGame == nil else { return }
        restartTask?.cancel()
        restartTask = nil
        // A late `play` reply after this is dropped harmlessly; the session's
        // autoCreatesGameOnEmptyLibrary opt-out covers the printsgf race.
        navigationContext.selectedGameRecord = nil
        UIApplication.shared.isIdleTimerDisabled = false

        if analysisWasUserOff {
            // Restore the user's OFF: .clear is observed at the root, which
            // sends the GTP "stop".
            gobanState.analysisStatus = .clear
            gobanState.eyeStatus = .closed
        }
        // Otherwise BoardView's onDisappear → maybePauseAnalysis plus the
        // root's pause observer stop the engine stream.

        if let game {
            TVSampleGameStore.discard(game)
        }
        game = nil
    }

    /// Pause: raise the spectator flag and stop the analysis stream so the
    /// fanless Apple TV goes idle. maybePauseAnalysis() sets analysisStatus =
    /// .pause and arms waitingForAnalysis, so the in-flight stream's next line
    /// drives the true->false edge and TVRootView's pause observer sends GTP
    /// "stop"; the cancelled search's trailing "play" is dropped by
    /// postProcessAIMove's suppressesGenMove guard, so the pause is crisp. Top
    /// Moves freezes at its last candidates (still pickable).
    /// Resume: clear the flag, restore analysisStatus = .run (the gen-move
    /// gate requires it), then re-request — with both maxTimes > 0 that emits
    /// the gen-move command directly and the loop continues from the current
    /// (possibly user-explored) position.
    private func togglePause() {
        guard let game, !isGameOver else { return }
        gobanState.suppressesGenMove.toggle()
        if gobanState.suppressesGenMove {
            gobanState.maybePauseAnalysis()
        } else {
            gobanState.analysisStatus = .run
            gobanState.requestAnalysis(config: game.concreteConfig,
                                       messageList: messageList,
                                       nextColorForPlayCommand: player.nextColorForPlayCommand)
        }
    }

    /// Play a Top Moves candidate — same submit path as the cursor.
    private func pick(_ candidate: Analysis.CandidateMove) {
        submit(vertex: candidate.vertex)
    }

    /// Play at the cursor's intersection (remote Select while the board is
    /// focused). Occupied points are rejected here — the engine's occupied
    /// reply is dropped silently anyway; keeping the cursor in place after a
    /// play relies on it. The ghost survives the submit: the AI answers, the
    /// marker recolors, and the user plays on nearby without re-aiming.
    private func playAtCursor() {
        guard let point = ghost.point,
              !stones.blackPoints.contains(point),
              !stones.whitePoints.contains(point),
              let vertex = point.gtpVertex(width: Int(board.width),
                                           height: Int(board.height)) else { return }
        submit(vertex: vertex)
    }

    /// Play a vertex for the side to move. The kata-check-move line cancels
    /// an in-flight gen-move (its trailing "play" reply is dropped while the
    /// play is pending); the legality reply then plays the move directly into
    /// the in-memory record. If the AI's own move landed first, the reply is
    /// wrong_turn and the play is silently dropped.
    private func submit(vertex: String) {
        guard !isGameOver,
              stones.isReady,
              gobanState.pendingMoveTurn == nil,
              let turn = player.nextColorSymbolForPlayCommand else { return }
        gobanState.sendCheckMoveCommand(turn: turn, move: vertex,
                                        messageList: messageList)
    }

    /// The board's D-pad handler: one intersection per press, clamped at the
    /// edges (Menu is the exit — see the onExitCommand branch). verticalFlip
    /// keeps the mapping honest with the rendering, though tvOS pins it
    /// false at the root.
    private func boardMove(_ direction: MoveCommandDirection) {
        let step: GhostCursorModel.StepDirection?
        switch direction {
        case .up: step = .up
        case .down: step = .down
        case .left: step = .left
        case .right: step = .right
        default: step = nil
        }
        guard let step else { return }
        ghost.step(step, width: Int(board.width), height: Int(board.height),
                   verticalFlip: gobanState.verticalFlip)
    }

    /// Undo the last move. In a live game the gen-move loop would instantly
    /// refill the position, so pause FIRST (raise the spectator flag): then
    /// `backwardMoves`' post-execution re-request AND the turn toggle both fall
    /// through to plain continuous kata-analyze instead of a gen-move, and any
    /// trailing "play" from the cancelled in-flight search is dropped by
    /// postProcessAIMove's suppressesGenMove guard — so the undone position
    /// holds. maybePauseAnalysis() then stops that re-requested stream so the
    /// engine idles (one snapshot of the undone position, then quiet). The
    /// game stays paused; Resume plays forward from here, discarding the undone
    /// moves (a real rewind). Same readiness gating as `pick()` so a press
    /// can't race an in-flight legality check or a just-arrived move.
    private func stepBack() {
        guard let game, !isGameOver,
              stones.isReady,
              gobanState.pendingMoveTurn == nil else { return }
        gobanState.suppressesGenMove = true
        gobanState.backwardMoves(limit: 1,
                                 gameRecord: game,
                                 messageList: messageList,
                                 player: player,
                                 stones: stones)
        gobanState.maybePauseAnalysis()
    }
}

// MARK: - Library card

/// The "KataGo vs KataGo" entry card: a canned opening position with a Live
/// badge. Shown in the library's empty states (beside the sample game) and as
/// the lead card of the populated grid.
struct TVSelfPlayCard: View {
    // A recognizable early position (star-point opening, GTP coords) — enough
    // stones to read as a live game at a glance.
    private static let blackStones = ["Q16", "D4", "Q4", "F3", "R10"]
    private static let whiteStones = ["D16", "Q3", "C6", "R5"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetBoardView(width: 19,
                            height: 19,
                            blackVertices: Self.blackStones,
                            whiteVertices: Self.whiteStones)
                .aspectRatio(1, contentMode: .fit)
                .padding([.top, .horizontal], 20)

            VStack(alignment: .leading, spacing: 6) {
                Text(SelfPlayGame.demoName)
                    .font(.headline)
                    .lineLimit(1)
                Text("The engine plays itself")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .topTrailing) {
            Text("Live")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.tvWoodAccent, in: Capsule())
                .padding(10)
        }
    }
}

// MARK: - Previews

// #Preview bodies still compile in Release, and the TVPreviewData fixtures are
// DEBUG-only — guard the whole section or archiving fails.
#if DEBUG
/// Injects a pre-staged GameSession's models plus the NavigationContext the
/// self-play driver requires (TVRootView does the same).
private struct TVSelfPlayPreviewHost: View {
    let game: GameRecord
    let session: GameSession

    var body: some View {
        TVSelfPlayScreen(route: SelfPlayRoute(entry: .manual), previewGame: game)
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
            .environment(TVEngineController())
    }
}

// Mid-game spectate: board + live panel, no interstitial. The staged record
// bypasses the driver (whose entry would otherwise reset the fixture).
#Preview("Self-play — live") {
    let game = TVPreviewData.denseAnalyzedGame()
    let session = TVPreviewData.reviewSession(game: game,
                                              blackWinrate: 0.55,
                                              blackScore: 1.5)
    session.gobanState.analysisStatus = .run
    session.gobanState.eyeStatus = .opened
    return TVSelfPlayPreviewHost(game: game, session: session)
}

// Opening spectate, no score history yet: the chart slot is reserved (empty
// plot area with the baseline rule), so the panel — and therefore the board —
// holds exactly this geometry when the chart fills in mid-game.
#Preview("Self-play — opening (chart reserved)") {
    let game = TVPreviewData.untitledFallbackGame()
    let session = TVPreviewData.reviewSession(game: game,
                                              blackWinrate: 0.5,
                                              blackScore: 0)
    session.gobanState.analysisStatus = .run
    session.gobanState.eyeStatus = .opened
    return TVSelfPlayPreviewHost(game: game, session: session)
}

// Paused mid-game: the badge reads "Paused", the button offers Resume, and
// the Top Moves rows stay visible (frozen at their last candidates — pausing
// stops the analysis stream, so analysisStatus is .pause, not .run).
#Preview("Self-play — paused") {
    let game = TVPreviewData.denseAnalyzedGame()
    let session = TVPreviewData.reviewSession(game: game,
                                              blackWinrate: 0.55,
                                              blackScore: 1.5)
    session.gobanState.analysisStatus = .pause
    session.gobanState.eyeStatus = .opened
    session.gobanState.suppressesGenMove = true
    return TVSelfPlayPreviewHost(game: game, session: session)
}

// The between-games interstitial: two passes recorded, result parsed from the
// record's RE tag once the post-pass printsgf lands.
#Preview("Self-play — interstitial") {
    let game = TVPreviewData.openingGame()
    game.sgf += "RE[B+3.5]"   // as the engine's post-pass printsgf embeds it
    let session = TVPreviewData.reviewSession(game: game,
                                              blackWinrate: 0.61,
                                              blackScore: 3.5)
    session.gobanState.analysisStatus = .run
    session.gobanState.eyeStatus = .opened
    session.gobanState.passCount = 2
    return TVSelfPlayPreviewHost(game: game, session: session)
}

// The library entry card.
#Preview("Self-play card") {
    TVSelfPlayCard()
        .frame(width: 400)
        .padding(80)
}
#endif
