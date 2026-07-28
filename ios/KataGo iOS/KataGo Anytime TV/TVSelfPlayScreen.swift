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
//  on any remote press. A third entry — Auto-Play's hand-off at the end of an
//  unfinished recorded game — seeds the position instead of an empty board and
//  pops back to the review screen when the game ends, rather than looping.
//  Thermal pressure ends the demo in every mode.
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
    /// Set when Auto-Play handed off at the end of an unfinished recorded game:
    /// the continuation starts from that position instead of an empty board,
    /// and pops back to review when it ends instead of restarting.
    ///
    /// `var` with a default (not `let`): a stored property with a default is
    /// dropped from the synthesized memberwise init ENTIRELY when declared
    /// `let`, so the initializer would never accept a `seed:` argument and the
    /// handoff could never construct a seeded route. (The four `entry:`-only
    /// call sites compile either way — they never pass a seed.)
    var seed: SelfPlaySeed? = nil
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
    @Environment(TVControllerInput.self) private var controllerInput
    @Environment(\.dismiss) private var dismiss

    /// This screen's slot in the controller's LIFO handler stack. Pushed over
    /// the review screen's, which resurfaces when this one pops.
    @State private var controllerToken = UUID()

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
    /// Aiming mode as PLAIN state (synced from boardFocused): the panel's
    /// suppression keys off this — not off boardFocused — so the Menu exit
    /// can flip it and hop focus in one transaction. A FocusState write is
    /// only a request processed after render; gating on boardFocused left
    /// the hop target unfocusable and Menu appeared dead (see
    /// TVReviewScreen.isAiming).
    @State private var isAiming = false
    @State private var didLoad = false
    @State private var game: GameRecord?
    @State private var restartTask: Task<Void, Never>?
    /// The user's analysis-OFF preference from the review screen, restored on
    /// exit (self-play forces analysis ON — the overlay is the show).
    @State private var analysisWasUserOff = false
    /// The Top Moves row under remote focus, ringed on the board.
    @State private var highlightedPoint: BoardPoint?
    /// The broadcast loop driver (created at entry — it needs the session's
    /// environment objects). nil only before startIfNeeded runs.
    @State private var broadcast: BroadcastController?

    private var isGameOver: Bool { gobanState.passCount >= 2 }

    /// Paused = the broadcast handed the screen to the interactive UI.
    /// (suppressesGenMove is no longer the pause signal — it stays true for
    /// the whole broadcast; the licensed gen-move plays the moves.)
    private var isPaused: Bool { broadcast?.phase == .paused }

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
                // Select exits via the UIKit catcher: the root is the same
                // bare-focusable + .onTapGesture pattern that dropped first
                // Selects on device (see TVSelectPressCatcher). Always armed
                // here — attract has no other Select target.
                .tvSelectPress(isEnabled: true, perform: { dismiss() })
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
                    ZStack {
                        BoardView(gameRecord: game,
                                  interactive: false,
                                  showsCapturedStones: false,
                                  showsPass: false,
                                  showsWinrateBar: false,
                                  highlightedPoint: highlightedPoint,
                                  cursorPoint: ghost.point,
                                  commentIsFocused: $commentFocused)
                            // Stays focusable through the game-over interstitial
                            // so focus never loses its home mid-interstitial;
                            // submit is guarded by !isGameOver, and restart()
                            // drops board focus for the fresh board. Reachable
                            // only while the broadcast has handed the screen to
                            // the interactive UI (paused) — watch-first,
                            // play-on-pause.
                            .focusable(route.entry == .manual && isPaused)
                            .focused($boardFocused)
                            .onMoveCommand(perform: boardMove)
                            // Select plays via the UIKit catcher (see
                            // TVSelectPressCatcher — .onTapGesture dropped every
                            // first Select on device). !isGameOver disarms it
                            // under the interstitial instead of leaning on
                            // submit's guard alone (the window-wide recognizer
                            // must not stay live beneath an overlay).
                            .tvSelectPress(isEnabled: isAiming && !isGameOver,
                                           perform: playAtCursor)
                            .overlay {
                                // Focus affordance (the timeline-ring pattern):
                                // no system focus lift on a bare board.
                                Rectangle()
                                    .stroke(boardFocused ? Color.tvWoodAccent : .clear,
                                            lineWidth: 4)
                            }
                            .onChange(of: boardFocused) { _, focused in
                                isAiming = focused
                                if focused {
                                    ghost.activate(width: Int(board.width),
                                                   height: Int(board.height))
                                } else {
                                    ghost.reset()
                                }
                            }

                        if let broadcast, broadcast.currentSlide != nil,
                           let frame = broadcast.currentFrame,
                           let model = broadcast.reportModel {
                            TVBroadcastSlideBoard(frame: frame, model: model)
                                // Skip controls: right/Select advance the
                                // slide; past the last one the move plays
                                // immediately. Attract stays unfocusable so
                                // any press exits at the root.
                                .focusable(route.entry == .manual)
                                .onMoveCommand { direction in
                                    if direction == .right { broadcast.skipSlide() }
                                }
                                .tvSelectPress(isEnabled: route.entry == .manual,
                                               perform: { broadcast.skipSlide() })
                        }
                    }
                    // Same full-screen-height pin as the review screen
                    // (tvOS is always 1920×1080 pt; the NavigationStack's
                    // safe-area insets survive ignoresSafeArea and would
                    // otherwise shrink the fitted square). Also keeps the
                    // board independent of the panel's ideal height.
                    .frame(width: 1080, height: 1080)

                    Spacer(minLength: 24)

                    Group {
                        if let broadcast, let slide = broadcast.currentSlide {
                            TVBroadcastSlidePanel(title: slide.title,
                                                  text: broadcast.typedText,
                                                  slideNumber: broadcast.slideNumber,
                                                  slideCount: broadcast.slideCount)
                        } else {
                            panel(for: game)
                        }
                    }
                        // Hard ceiling: 752 pt is the max width that keeps
                        // the Spacer at its 24 pt floor (24 + 1080 + 24 + 752
                        // + 40 = 1920); the 1000 pt height is the screen
                        // minus the 40 pt vertical margins. A fixed frame
                        // reports this size to the HStack no matter how tall
                        // the content wants to be, so panel growth can never
                        // inflate the HStack and push the 1080 pt board
                        // off-screen — content that outgrows the budget
                        // overflows inside this slot, top-aligned. No
                        // .clipped(): it would shear the focus lift/shadow on
                        // the rows at the edges.
                        .frame(width: 752, height: 1000, alignment: .top)
                        .padding(.vertical, 40)
                        // While the cursor is aiming, EVERY panel control
                        // must be unfocusable: onMoveCommand is only a
                        // fallback on tvOS (a focusable target in the pressed
                        // direction wins and moves focus before the handler
                        // fires — device finding 2026-07-16), so a focusable
                        // row to the board's right would swallow right
                        // presses. Dimming doubles as the aiming affordance.
                        .disabled(isAiming)
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
        // every D-pad press, so this is the one way out. During the
        // game-over interstitial the pause button is disabled (no legal hop
        // target), so an aiming Menu falls through to dismiss — "Menu always
        // leaves the demo" holds there.
        .onExitCommand {
            if boardFocused, !isGameOver {
                // isAiming is plain state: flipping it re-enables the panel
                // in THIS transaction so the focus hop finds a legal target
                // (a FocusState write is only a post-render request — see
                // TVReviewScreen's Menu handler). Ghost resets via the focus
                // onChange.
                isAiming = false
                pauseFocused = true
            } else {
                // A seeded route pops back to TVReviewScreen, whose didLoad was
                // reset — so its loadIfNeeded() re-runs, and SwiftUI runs that
                // destination normalization BEFORE this screen's onDisappear
                // (the same ordering scheduleRestart's result-pop documents).
                // Left to tearDown, the lift would arrive too late and
                // loadIfNeeded would read the still-`.clear` broadcast status
                // as "the user turned analysis OFF", so Menu-ing out of a
                // continuation would come back to review with the eye shut.
                // tearDown's later call is then a no-op (see the method's
                // idempotency note). Gated on the seed so the demo/attract
                // paths keep exactly today's behavior: they pop to the
                // library, which reads no analysis state on entry, so
                // tearDown's single call stays their only restore.
                if route.seed != nil { restoreAnalysisForExit() }
                dismiss()
            }
        }
        .onReceive(NotificationCenter.default
            .publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: RunLoop.main)) { _ in
                // Read the state fresh from ProcessInfo — the Notification
                // itself is non-Sendable and stays out of the handler.
                if SelfPlayAttract.shouldStop(thermalState: ProcessInfo.processInfo.thermalState) {
                    // Restore before the pop for the same pop-ordering reason
                    // as the Menu exit above.
                    if route.seed != nil { restoreAnalysisForExit() }
                    dismiss()
                }
            }
        .onAppear {
            startIfNeeded()
            controllerInput.pushHandler(controllerToken) { event in
                handleControllerEvent(event)
            }
        }
        .onDisappear {
            tearDown()
            controllerInput.popHandler(controllerToken)
        }
        .onChange(of: gobanState.passCount) { _, newCount in
            if newCount >= 2 {
                scheduleRestart()
            }
        }
        .onChange(of: player.nextColorForPlayCommand) { _, newValue in
            // The broadcast's cycle trigger — mirrors BoardView's turn
            // observer signal. BoardView's own observer is inert while the
            // broadcast runs (analysisStatus .clear), so this is the only
            // reaction to a landed stone.
            guard newValue != .unknown, let game, !isGameOver else { return }
            broadcast?.noteTurnChanged(game: game)
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
                Text(game.name.isEmpty ? SelfPlayGame.demoName : game.name)
                    .font(.title2.bold())
                    .lineLimit(1)
                    // Shrinks a touch so the full name fits beside the badge
                    // in the 752 pt panel.
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
            if isPaused {
                // Interactive pause: picks explore (suppression keeps the AI
                // from answering), exactly the old paused semantics.
                TVBestMovesList(candidates: analysis.candidateMoves(width: Int(board.width),
                                                                    height: Int(board.height),
                                                                    limit: 3),
                                isEnabled: route.entry == .manual && !isGameOver,
                                rowCount: 3,
                                onFocus: { highlightedPoint = $0?.point },
                                onPick: pick)
            } else if broadcast?.phase == .generating {
                Label("Analyzing…", systemImage: "sparkles")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if route.entry == .manual {
                HStack(spacing: 16) {
                    if isPaused {
                        stepBackButton(for: game)
                    }
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
        ScoreLeadText.sideAnnotated(blackScore: rootScore.black)
    }

    // MARK: - Interstitial

    private func interstitial(for game: GameRecord) -> some View {
        VStack(spacing: 16) {
            Text("Game over")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(resultText(for: game))
                .font(.system(size: 44, weight: .bold, design: .rounded))
            Text(route.seed == nil ? "Next game starting…" : "Returning to review…")
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
    /// printsgf; until that reply arrives, fall back to the live score sign
    /// (draw-aware: a dead-even score must not read as a Black win).
    private func resultText(for game: GameRecord) -> String {
        let parsed = SelfPlayGame.result(fromSgf: game.sgf)
        if parsed != .unknown {
            return SelfPlayGame.resultText(parsed)
        }
        return SelfPlayGame.anticipatedResultText(blackScore: rootScore.black)
    }

    // MARK: - Lifecycle

    private func startIfNeeded() {
        guard !didLoad else { return }
        didLoad = true

        if let stagedPreviewGame {
            game = stagedPreviewGame
            return
        }

        let created = route.seed.map { TVSampleGameStore.newSelfPlayGame(seed: $0) }
            ?? TVSampleGameStore.newSelfPlayGame(maxBoardLength: engine.maxBoardLength)
        guard let newGame = created else {
            dismiss()
            return
        }
        game = newGame

        // This screen is the player, not a spectator of a synced record —
        // and entry is always un-paused. Picks play directly into the
        // in-memory record (editing mode), never via a branch.
        // Broadcast protocol: suppression stays TRUE forever (the licensed
        // gen-move plays the moves) and analysisStatus stays .clear so
        // BoardView's turn observer never races an analyze command against a
        // report cycle's collector swap. The .clear transition fires the TV
        // root's "stop"; its ack drains long before the first cycle (FIFO:
        // stop-ack < showboard reply < turn change < first probe).
        gobanState.suppressesGenMove = true
        gobanState.forcesBranchOnPlay = false
        // Required or postProcessAIMove drops every engine reply; also routes
        // each move's printsgf into the in-memory record.
        navigationContext.selectedGameRecord = newGame
        // A prior review session stepping through recorded passes leaves this
        // nonzero, which would veto the first gen-move. A SEEDED game must not
        // be zeroed blindly either: its position may legitimately carry one
        // trailing pass, and the engine's loaded history has it.
        // Depends on the seed sitting at its SGF's tip (SelfPlaySeed.moveCount
        // == moveSize, which that type documents): only then are the SGF's
        // trailing passes the passes actually on the board.
        gobanState.passCount = route.seed.map {
            SelfPlayGame.trailingPassCount(inSgf: $0.sgf)
        } ?? 0
        // Analysis ON is the show; remember a user OFF to restore on exit.
        analysisWasUserOff = (gobanState.analysisStatus == .clear)
        gobanState.eyeStatus = .opened
        gobanState.analysisStatus = .clear
        broadcast = BroadcastController(messageList: messageList,
                                        gobanState: gobanState,
                                        player: player,
                                        rootWinrate: rootWinrate,
                                        rootScore: rootScore)

        // The demo must load unlocked (editing) so moves persist into the
        // record — but editingAfterLoad only auto-unlocks the 19×19
        // defaultSgf, and a sub-19 Max Board Size swaps in a small-board
        // default. Loaded locked, the first AI move silently activates a
        // branch and every printsgf reply — including the final RE[…] —
        // routes into branchSgf, so the interstitial's score-sign fallback
        // (wrong for draws) shows all 8 s, "Move N" freezes at 0, and the
        // chart stays empty. Request the one-shot unlock (the
        // VisionRootView.startNewGame precedent; loadGame consumes it).
        // Never rewind this game (a rewound editing position would trip the
        // AI-overwrite confirmation instead of playing).
        gobanState.unlockEditingOnReload = true
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
            // A seeded continuation is a finite excursion from one reviewed
            // game: show the result, then hand the user back to review. Only
            // the demo loops into a fresh game.
            if route.seed != nil {
                // Restore BEFORE the pop, not in tearDown: SwiftUI runs the
                // destination's entry normalization before the source's
                // onDisappear, so TVReviewScreen.loadIfNeeded would otherwise
                // read the still-`.clear` broadcast status as user-OFF and
                // come back with analysis off.
                restoreAnalysisForExit()
                dismiss()
            } else {
                restart()
            }
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
        // A paused game can still end (two picked passes) — the next game
        // always starts fresh under the broadcast protocol (cancel any
        // in-flight cycle, back to .clear/suppressed).
        broadcast?.cancelAll()
        gobanState.analysisStatus = .clear
        gobanState.suppressesGenMove = true
        // A cursor aimed at the finished game must not survive onto the
        // fresh (possibly different-size) board. Re-enable the panel first
        // (plain state, same transaction) so the focus hop off the board has
        // a legal target; reset the ghost directly too in case the hop is
        // ever rejected and the board keeps focus.
        if boardFocused {
            isAiming = false
            pauseFocused = true
        }
        ghost.reset()

        // loadsgf inherently cancels the continuous analysis of the finished
        // position; the rest of the setup mirrors first entry — including
        // the one-shot unlock (see startIfNeeded: a Max-Board-Size-clamped
        // demo would otherwise load locked and branch-route every printsgf).
        gobanState.unlockEditingOnReload = true
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
        broadcast?.cancelAll()
        restartTask?.cancel()
        restartTask = nil
        // A late `play` reply after this is dropped harmlessly; the session's
        // autoCreatesGameOnEmptyLibrary opt-out covers the printsgf race.
        navigationContext.selectedGameRecord = nil
        UIApplication.shared.isIdleTimerDisabled = false

        // A seeded route already ran this immediately before EVERY dismiss()
        // (the result pop, Menu, the thermal dismissal); this second call is a
        // no-op (see the method's idempotency note).
        restoreAnalysisForExit()
        // Otherwise BoardView's onDisappear → maybePauseAnalysis plus the
        // root's pause observer stop the engine stream.

        // Seeded exits return to TVReviewScreen, whose spectator protections
        // this screen switched off. Restore them here so EVERY exit path (the
        // result pop, Menu, a thermal dismiss) is covered, not just the happy
        // one. The review screen re-asserts them too, in loadIfNeeded — this is
        // belt and braces, and it is what keeps the window between the pop and
        // the reload safe.
        if route.seed != nil {
            gobanState.passCount = 0
            gobanState.isEditing = false
            gobanState.forcesBranchOnPlay = true
        }

        if let game {
            TVSampleGameStore.discard(game)
        }
        game = nil
    }

    /// Lift the broadcast's protocol-`.clear` back to a state the NEXT screen
    /// reads correctly: a user OFF stays OFF, a protocol `.clear` becomes
    /// `.pause` (system-paused, resumable). Called from `tearDown` AND, for a
    /// seeded route, immediately before `dismiss()` — the pop returns to
    /// TVReviewScreen, which re-runs its own entry normalization and would
    /// otherwise read a still-`.clear` status as user-OFF and come back with
    /// the eye shut. Idempotent: a second call either re-asserts the identical
    /// user OFF or finds the status already lifted off `.clear`, so it writes
    /// no new value and the root's `.onChange` stop observer never re-fires.
    private func restoreAnalysisForExit() {
        if analysisWasUserOff {
            // Restore the user's OFF: .clear is observed at the root, which
            // sends the GTP "stop".
            gobanState.analysisStatus = .clear
            gobanState.eyeStatus = .closed
        } else if gobanState.analysisStatus == .clear {
            // Lift the broadcast's protocol-.clear so other screens read it
            // as system-paused (resumable on entry normalization), not
            // user-OFF. A paused-interactive exit leaves .run for BoardView's
            // onDisappear machinery, which this branch then skips.
            gobanState.analysisStatus = .pause
        }
    }

    /// Pause = cancel the broadcast cycle (probes cancel → restore) and hand
    /// the screen to the interactive UI with continuous analysis running so
    /// Top Moves fills. Resume = re-enter the loop (report first, then the
    /// licensed gen-move). suppressesGenMove stays TRUE in both states —
    /// the broadcast invariant; NEVER call maybePauseAnalysis around the
    /// report (the round-7 stray-ack gotcha).
    private func togglePause() {
        guard let game, let broadcast, !isGameOver else { return }
        if broadcast.phase == .paused {
            broadcast.resume(game: game)
        } else {
            Task { await broadcast.pause(game: game) }
        }
    }

    // MARK: - Controller

    /// Focus-safe controller buttons. X is the transport on BOTH game screens;
    /// L1/R1 mean "move things along" on both. Inert while aiming.
    private func handleControllerEvent(_ event: TVControllerEvent) {
        guard !isAiming else { return }
        // Attract is a screensaver: ANY press exits, which is the contract the
        // root's move/play-pause/Select handlers already implement. Without
        // this, gamepad X would call togglePause() and freeze the demo behind
        // a "Paused" badge whose resume button is only rendered in manual mode.
        guard route.entry == .manual else {
            dismiss()
            return
        }
        switch event {
        case .buttonX:
            togglePause()
        case .rightShoulder:
            broadcast?.skipSlide()
        case .leftShoulder:
            // stepBack() guards on `game`, `!isGameOver`, `stones.isReady` and
            // `pendingMoveTurn == nil` (see stepBack below) but NOT on
            // isPaused — Undo is a paused-interactive action, so the gate
            // belongs here rather than inside stepBack, whose existing callers
            // are already paused-only. Also mirror the Undo button's own
            // disable (game.currentIndex == 0): stepBack() still runs
            // backwardMoves at index 0 (zero undos) but unconditionally calls
            // sendPostExecutionCommands — a redundant showboard plus an
            // analysis re-arm on a fanless box.
            guard isPaused, game?.currentIndex != 0 else { return }
            stepBack()
        case .buttonY, .leftTrigger, .rightTrigger:
            break
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
        guard isPaused,
              !isGameOver,
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

    /// Paused-interactive undo — the button renders only while the broadcast
    /// is paused, so this is reached with no cycle running. Steps the shared
    /// history back one move. The `suppressesGenMove = true` here is
    /// redundant-but-defensive (the broadcast keeps it true for its whole
    /// lifetime): with it set, `backwardMoves`' post-execution re-request AND
    /// the turn toggle both fall through to plain continuous kata-analyze
    /// instead of a gen-move, and any trailing "play" from a cancelled
    /// in-flight search is dropped by postProcessAIMove's suppression guard —
    /// so the undone position holds. maybePauseAnalysis() then stops that
    /// re-requested stream so the engine idles (one snapshot of the undone
    /// position, then quiet). The game stays paused; Resume runs a fresh
    /// report on the rewound position. Same readiness gating as `pick()` so a
    /// press can't race an in-flight legality check or a just-arrived move.
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
                            whiteVertices: Self.whiteStones,
                            style: .appGoban(drawsOwnWood: true))
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
            // Required since the screen subscribes to it — a preview without
            // it traps at runtime resolving the @Environment.
            .environment(TVControllerInput())
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

// Mid-broadcast: slide board over the hero slot, streaming panel.
#Preview("Self-play — broadcast slide") {
    let game = TVPreviewData.denseAnalyzedGame()
    let session = TVPreviewData.reviewSession(game: game,
                                              blackWinrate: 0.55,
                                              blackScore: 1.5)
    return TVSelfPlayPreviewHost(game: game, session: session)
}

// The library entry card.
#Preview("Self-play card") {
    TVSelfPlayCard()
        .frame(width: 400)
        .padding(80)
}
#endif
