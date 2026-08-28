//
//  TVPlayScreen.swift
//  KataGo Anytime TV
//
//  Play a human-vs-AI game on the Apple TV: the same full-bleed hero board as
//  the review screen, but UNLOCKED and interactive — the D-pad aims a ghost
//  stone, Select plays it, and the engine answers for the side whose per-move
//  thinking time is positive.
//
//  This screen deliberately shares NO state machinery with its two neighbours.
//  Review is a locked spectator (suppressesGenMove + forcesBranchOnPlay), and
//  self-play runs the broadcast protocol (analysisStatus .clear + a licensed
//  gen-move). Here the move loop is simply the shared turn observer: BoardView
//  mounts on this screen and its `.onChange(of: player.nextColorForPlayCommand)`
//  hook sends the asymmetric human-SL bundles and the gen-move for the AI side.
//  No new engine protocol, and NO extra per-move driver in this file — a second
//  one would double every request.
//
//  THE LOAD-BEARING PAIR: `analysisStatus = .run` with `eyeStatus = .closed`.
//  The sparkle (analysisStatus) is the ENGINE and the eye (eyeStatus) is the
//  DISPLAY. Ranked play wants the engine on and the overlay off, and the
//  power-saving rule (GobanState.isAnalysisHiddenForPowerSaving) then suppresses
//  continuous analysis on the human's turn while leaving the AI's gen-move turns
//  untouched. NEVER reach for `.clear` to hide the overlay here: `shouldGenMove`
//  and `getRequestAnalysisCommands` both require `.run`, so `.clear` would stop
//  the opponent from moving at all.
//

import SwiftUI
import KataGoUICore

struct TVPlayScreen: View {
    let game: GameRecord

    /// The session itself, for `session.recordPosition` — the one projector
    /// that turns the record's SGF into the board this screen draws.
    @Environment(GameSession.self) private var session
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
    @Environment(TVEngineController.self) private var engine
    @Environment(TVControllerInput.self) private var controllerInput
    /// Engine availability, read OPTIONALLY (a preview that injects none reads
    /// as ready). Its one short line takes the panel's analysis slot until the
    /// engine acknowledges the position.
    @Environment(EngineStatus.self) private var engineStatus: EngineStatus?
    /// Whether a Core ML compile is part of the wait — the tvLine spends its
    /// one line on the more informative caption when it is.
    @Environment(EngineLaunchStatus.self) private var launchStatus: EngineLaunchStatus?
    @Environment(\.dismiss) private var dismiss

    /// This screen's slot in the controller's LIFO handler stack.
    @State private var controllerToken = UUID()

    /// BoardView's comment-field handle. Unused here (the TV board has no
    /// comment editor), but the initializer requires the binding.
    @FocusState private var commentFocused: Bool
    /// The board itself: focused ⇒ the play cursor is aiming.
    @FocusState private var boardFocused: Bool
    /// The Menu-exit hop target. Deliberately the analysis-display toggle and
    /// not Pass/Undo: it is the one panel control that is NEVER disabled, so
    /// the hop always finds a legal target (a disabled target would leave the
    /// focus engine with nowhere to go and Menu would read as dead — the
    /// TVReviewScreen device finding of 2026-07-16).
    @FocusState private var toggleFocused: Bool
    /// The play cursor's grid logic (shared with the visionOS ghost stone).
    /// Non-nil only between board focus and unfocus, so passing it straight
    /// into BoardView shows the marker exactly while aiming.
    @State private var ghost = GhostCursorModel()
    /// Aiming mode as PLAIN state (synced from boardFocused): the panel's
    /// `.disabled` keys off this — NOT off boardFocused — so the Menu exit can
    /// flip it and hop focus in one transaction. A FocusState write is only a
    /// request processed after render (see TVReviewScreen.isAiming).
    @State private var isAiming = false
    @State private var didLoad = false
    /// The Top Moves row under remote focus, ringed on the board.
    @State private var highlightedPoint: BoardPoint?

    private var config: Config { game.concreteConfig }

    /// Two passes end the game. The gen-move loop stops itself (`passCount < 2`
    /// guards in `shouldGenMove` / `getRequestAnalysisCommands`); this only
    /// drives the result overlay and disarms move entry.
    private var isGameOver: Bool { gobanState.passCount >= 2 }

    var body: some View {
        // A board larger than the running engine's NN buffer is a *Held*
        // status, not a screen: the record position draws, the panel's analysis
        // slot says "Board larger than Max Board Size N", and the engine is
        // never told this board exists. `noteBoardMounted` (in `loadIfNeeded`,
        // BEFORE anything is sent) decides that and shuts the command gate.
        //
        // Play stays refused there for a different reason: a move can only be
        // submitted from an in-sync board (`stones.isReady`), which a held
        // engine never grants.
        playContent
    }

    // MARK: - Content

    private var playContent: some View {
        // Full-bleed hero board (the review-screen geometry): safe areas
        // ignored on every edge, explicit paddings are the only margins, so the
        // square reaches the screen's full 1080 pt height.
        HStack(spacing: 0) {
            BoardView(gameRecord: game,
                      interactive: false,
                      showsCapturedStones: false,
                      showsPass: false,
                      showsWinrateBar: false,
                      highlightedPoint: highlightedPoint,
                      cursorPoint: ghost.point,
                      commentIsFocused: $commentFocused)
                // Always focusable — including under the result overlay, so
                // focus never loses its home mid-overlay. There is no timeline
                // here to protect from left-presses (the review screen's only
                // reason to ever make the board unfocusable).
                .focusable(true)
                .focused($boardFocused)
                .onMoveCommand(perform: boardMove)
                // Select plays via the UIKit catcher (see TVSelectPressCatcher
                // — .onTapGesture dropped every first Select on device). Armed
                // off plain isAiming so the Menu exit disarms it in the same
                // transaction that re-enables the panel, and disarmed at game
                // over rather than leaning on submit's guard alone (the
                // window-wide recognizer must not stay live under an overlay).
                .tvSelectPress(isEnabled: isAiming && !isGameOver,
                               perform: playAtCursor)
                .overlay {
                    // Focus affordance: the board has no system focus lift, so
                    // say "you are aiming" here.
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
                // tvOS is always exactly 1920×1080 pt, so pin the square to the
                // full screen height outright: inside the NavigationStack the
                // safe-area insets survive ignoresSafeArea on this subtree and
                // silently shrink the fitted square. A fixed frame also keeps
                // the board independent of the panel's ideal height (it must
                // never resize on a toggle).
                .frame(width: TVBoardLayout.boardSide, height: TVBoardLayout.boardSide)

            Spacer(minLength: TVBoardLayout.gapFloor)

            panel
                // Shared geometry (TVBoardLayout): 752 pt is the widest panel
                // that keeps the Spacer above at its 24 pt floor, and the
                // 1000 pt height is the 1080 pt screen minus the 40 pt
                // vertical margins. This screen used to hardcode a 500 pt
                // panel, which left the Spacer absorbing 276 pt of dead space
                // between board and panel. A fixed frame reports this size to
                // the HStack no matter how tall the content wants to be, so
                // panel growth can never inflate the HStack and push the
                // 1080 pt board off-screen. No .clipped(): it would shear the
                // focus lift/shadow on the rows at the edges.
                .frame(width: TVBoardLayout.panelWidth,
                       height: TVBoardLayout.panelHeight,
                       alignment: .top)
                .padding(.vertical, TVBoardLayout.panelVerticalPadding)
                // While the cursor is aiming, EVERY panel control must be
                // unfocusable: onMoveCommand is only a FALLBACK on tvOS (a
                // focusable target in the pressed direction wins and moves
                // focus before the handler fires — device finding 2026-07-16),
                // so a focusable row to the board's right would swallow
                // right-presses and the cursor could step every direction
                // except right. Dimming doubles as the aiming affordance.
                .disabled(isAiming)
                .focusSection()
        }
        .padding(.leading, TVBoardLayout.leadingMargin)
        .padding(.trailing, TVBoardLayout.trailingMargin)
        .ignoresSafeArea()
        .overlay {
            if isGameOver {
                resultOverlay
            }
        }
        // Playing is the primary action, so entry lands on the BOARD. An
        // accidental immediate Select is harmless: the cursor reveals at the
        // last move, which is occupied and therefore rejected by playAtCursor.
        .defaultFocus($boardFocused, true)
        // Ghost anchor: reveal (and follow) the cursor at the board's last
        // move — players expect to answer near it, and after an undo the
        // cursor re-anchors on the new tip. The O(moves) SGF walk runs once
        // per position change, never per body eval.
        .onChange(of: lastMoveKey, initial: true) { _, newValue in
            ghost.setAnchor(newValue?.lastPoint,
                            width: Int(board.width),
                            height: Int(board.height))
        }
        // A focused board consumes every D-pad press (edges clamp, Select
        // plays), so Menu is the one way out of cursor mode. Attaching an
        // onExitCommand replaces the default NavigationStack pop; reproduce it
        // in the unfocused branch (the TVReviewScreen pattern).
        .onExitCommand {
            if boardFocused {
                // Order matters: isAiming is plain state, so flipping it
                // re-enables the panel in THIS transaction and the focus hop
                // that follows finds a legal target. (Writing boardFocused =
                // false first left focus with nowhere to go — FocusState writes
                // are requests processed after render.) The ghost resets via
                // the focus onChange.
                isAiming = false
                toggleFocused = true
            } else {
                dismiss()
            }
        }
        // The board is record-owned: publish the record position whenever it
        // moves — a played move, a scrub, a game switch — without waiting for
        // the engine. Keyed on THIS SCREEN'S game, not on
        // `navigationContext.selectedGameRecord`: on tvOS the selection is a
        // write-target that these screens deliberately park at nil while a
        // reload or a variation teardown is in flight, and following it would
        // blank a board the user is still looking at.
        .recordPositionSync(session: session, gameRecord: game)
        .onAppear {
            loadIfNeeded()
            controllerInput.pushHandler(controllerToken) { event in
                handleControllerEvent(event)
            }
        }
        .onDisappear {
            controllerInput.popHandler(controllerToken)
            // Identity-guarded: SwiftUI can run a pushed destination's
            // onAppear BEFORE this, and that screen has already pointed the
            // selection at its own record — an unconditional nil would strand
            // its engine replies (the TVReviewScreen precedent).
            if navigationContext.selectedGameRecord === game {
                navigationContext.selectedGameRecord = nil
            }
            // Release *Held* with the board that caused it, identity-guarded
            // for the same reason as the line above.
            engine.noteBoardDismissed(game)
            // Stop the stream on the way out (the root's waitingForAnalysis
            // observer turns the .pause into a GTP "stop").
            gobanState.maybePauseAnalysis()
            // Hand the next screen a clean counter. This one is a RUNNING
            // counter that no other screen seeds: TVReviewScreen never sets it,
            // and BroadcastController.startCycle parks .idle on passCount >= 2
            // — so backing out of a finished game would silently refuse to
            // start Auto-Play on the next game reviewed. loadIfNeeded re-seeds
            // from the SGF on every entry, so clearing here costs nothing.
            gobanState.passCount = 0
            // Re-arm the entry protocol for the next appearance.
            didLoad = false
        }
    }

    // MARK: - Panel

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(game.name.isEmpty ? "Untitled" : game.name)
                .font(.title2.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            VStack(spacing: 14) {
                playerRow(.black)
                playerRow(.white)
            }

            VStack(alignment: .leading, spacing: 8) {
                // Always rendered at fixed metrics so the display toggle never
                // reflows the panel. Overlay visible ⇒ the live engine outputs;
                // hidden ⇒ the per-move values recorded into this game (valid
                // for the displayed position), or an em-dash when none exist.
                analysisHeadline
                Text("Score \(scoreText)")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(moveAndTurnText)
                    .font(.body)
                    .foregroundStyle(.secondary)

                // Read-only here (the review screen's scrubbing timeline is
                // navigation, and this screen has none): the amber rule just
                // marks where the game stands. Fills in live — the record is
                // unlocked, so every analysed move persists a score lead.
                //
                // And because it fills in live, it is gated: this screen forces
                // the eye shut for ranked play and blanks its winrate/score
                // text to em-dashes, so an ungated chart plotted the very
                // dictionary that text was hiding. Mirrors iOS LinePlotView.
                TVScoreChart(gameRecord: game,
                             hidesHistoryWhenAnalysisOff: true,
                             currentIndex: displayIndex,
                             noHistoryMessage: nil,
                             reservesSpaceWhenEmpty: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 26))

            // The engine's live candidates, clickable: a pick plays that move
            // for the human side. Gated on the OVERLAY being visible, not on
            // analysisStatus — with the eye shut, power saving stops analysis
            // on the human's turn and the rows would show a stale position.
            TVBestMovesList(candidates: analysis.candidateMoves(width: Int(board.width),
                                                                height: Int(board.height),
                                                                limit: 3),
                            isEnabled: isAnalysisVisible,
                            rowCount: 3,
                            onFocus: { highlightedPoint = $0?.point },
                            onPick: pick)

            infoRow

            Spacer()

            buttonsRow

            Text("Press Back to exit")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// Move / komi / rules facts under the stats card. Columns hug their
    /// content (equal thirds truncated "Chinese", let alone "New Zealand");
    /// the trailing Spacer keeps them left-grouped. A 4th column does not fit.
    private var infoRow: some View {
        HStack(alignment: .top, spacing: 28) {
            infoItem("Move", "\(displayIndex)")
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
        // The persisted index names a preset; the -1 Custom sentinel and any
        // out-of-range synced value render as "Custom" (never crash).
        // The raw read is safe here: the entry protocol's `loadGame`
        // reconciles this index from the record's RU[] components on every
        // appearance, so a stale imported label never survives to this row.
        NewGameRuleset.preset(fromConfigRule: config.rule)?.displayName ?? "Custom"
    }

    /// One color's label ("Human" for the side with zero thinking time, the
    /// engine's rank profile for the other) and captured-stone count.
    private func playerRow(_ color: PlayerColor) -> some View {
        let isBlack = color == .black
        return TVPlayerRow(isBlack: isBlack,
                           name: config.playerLabel(for: color),
                           captures: isBlack ? stones.blackStonesCaptured
                                             : stones.whiteStonesCaptured)
    }

    /// Pass, Undo, and the analysis-DISPLAY toggle. Ordinary focusable buttons
    /// — one left press from Pass reaches the board. The toggle is never
    /// disabled, which is what makes it a safe Menu hop target and guarantees
    /// the screen always keeps a focusable control (result overlay included).
    private var buttonsRow: some View {
        HStack(spacing: 16) {
            Button(action: playPass) {
                buttonLabel(systemName: "hand.raised.fill", title: "Pass")
            }
            .buttonStyle(.bordered)
            .disabled(isGameOver)

            Button(action: undoOneMove) {
                buttonLabel(systemName: "arrow.uturn.backward", title: "Undo")
            }
            .buttonStyle(.bordered)
            // Cheap gate only: `canStepBackward` parses the SGF (a C++ call),
            // which must never run per body eval — undoOneMove() checks it at
            // action time instead.
            .disabled(displayIndex == 0)

            TVPlayIconButton(systemName: isAnalysisVisible ? "eye.fill" : "eye.slash",
                             accessibilityLabel: "Analysis Overlay",
                             isOn: isAnalysisVisible,
                             action: toggleAnalysisDisplay)
                .focused($toggleFocused)
        }
    }

    private func buttonLabel(systemName: String, title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemName)
            Text(title)
        }
        .font(.title3)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, minHeight: 56)
    }

    // MARK: - Result

    /// Two passes: the game is over. The record persists as it stands (there is
    /// no resign on any platform), and Undo stays live underneath so a
    /// mis-clicked pass is recoverable — an undo decrements `passCount`, which
    /// dismisses this overlay and re-arms the engine.
    private var resultOverlay: some View {
        VStack(spacing: 16) {
            Text("Game over")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(resultText)
                .font(.system(size: 44, weight: .bold, design: .rounded))
            Text("Press Back to leave, or Undo to keep playing.")
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
    private var resultText: String {
        let parsed = SelfPlayGame.result(fromSgf: game.sgf)
        if parsed != .unknown {
            return SelfPlayGame.resultText(parsed)
        }
        return SelfPlayGame.anticipatedResultText(blackScore: rootScore.black)
    }

    // MARK: - Readouts

    /// The position the panel is showing. Branch-aware for safety even though
    /// this screen never forces a branch (plays extend the record directly).
    private var displayIndex: Int {
        gobanState.getCurrentIndex(gameRecord: game) ?? game.currentIndex
    }

    /// Branch-aware ghost-anchor inputs (the VisionRootView hook, shared via
    /// LastMoveKey). Reading them in body keeps the onChange armed for plays,
    /// passes, undos, and the AI's replies alike.
    private var lastMoveKey: LastMoveKey? {
        guard let sgf = gobanState.getSgf(gameRecord: game),
              let index = gobanState.getCurrentIndex(gameRecord: game) else { return nil }
        return LastMoveKey(sgf: sgf, index: index)
    }

    /// The single source of truth for "is analysis on screen right now" — eye
    /// AND engine, never analysisStatus alone (the sparkle stays `.run` for the
    /// whole game here, so reading it would claim the overlay is always up).
    private var isAnalysisVisible: Bool {
        gobanState.isAnalysisOverlayVisible(config: config,
                                            nextColorForPlayCommand: player.nextColorForPlayCommand)
    }

    /// With the overlay hidden, fall back to the per-move values recorded into
    /// this game. They are mainline-indexed, so a branch position has none —
    /// nil means em-dash.
    private var persistedBlackWinrate: Float? {
        guard !isAnalysisVisible, !gobanState.isBranchActive else { return nil }
        return game.winRates?[displayIndex]
    }

    private var persistedBlackScore: Float? {
        guard !isAnalysisVisible, !gobanState.isBranchActive else { return nil }
        return game.scoreLeads?[displayIndex]
    }

    /// The analysis slot's headline: the engine's ONE short line while it is
    /// not ready (loading, failed, or *Held*), the win rate once it is.
    ///
    /// Replacing rather than adding: a win rate is an engine output, and while
    /// nothing can analyse this position the live numbers read 0% — a wrong
    /// answer where the reason belongs. Never the raw failure reason (no length
    /// bound, and this screen may not truncate); Settings carries that.
    @ViewBuilder
    private var analysisHeadline: some View {
        if let engineStatus, !engineStatus.isReady {
            EngineStatusView(status: engineStatus,
                             launchStatus: launchStatus,
                             style: .tvLine)
                // Stand in for the win rate's own height (a 34 pt rounded line
                // measures ~40 pt) so the panel does not reflow when the engine
                // lands. Pinned on THIS branch only: the win-rate branch keeps
                // its natural layout, because the panel's 1000 pt budget is
                // already tight enough to clip if anything below it grows.
                .frame(height: 40, alignment: .leading)
        } else {
            // Always rendered at fixed metrics so the display toggle never
            // reflows the panel. Overlay visible ⇒ the live engine outputs;
            // hidden ⇒ the per-move values recorded into this game (valid for
            // the displayed position), or an em-dash when none exist.
            Text(winRateText)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    /// Where the game stands, and whose move it is as the ENGINE last reported
    /// it. `.unknown` — parked between a position change and the `showboard`
    /// that answers it, and for as long as there is no engine to answer at all
    /// — says so instead of defaulting to White.
    private var moveAndTurnText: String {
        switch player.nextColorForPlayCommand {
        case .black: return "Move \(displayIndex) — Black to play"
        case .white: return "Move \(displayIndex) — White to play"
        case .unknown: return "Move \(displayIndex) — waiting for the engine"
        }
    }

    private var winRateText: String {
        let winrate: Float
        if isAnalysisVisible {
            winrate = rootWinrate.black
        } else {
            guard let persisted = persistedBlackWinrate else { return "Black —   White —" }
            winrate = persisted
        }
        let b = Int((winrate * 100).rounded())
        return "Black \(b)%   White \(100 - b)%"
    }

    private var scoreText: String {
        let s: Float
        if isAnalysisVisible {
            s = rootScore.black
        } else {
            guard let persisted = persistedBlackScore else { return "—" }
            s = persisted
        }
        return ScoreLeadText.sideAnnotated(blackScore: s)
    }

    // MARK: - Lifecycle

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        // The play protocol, opposite to review's spectator one on every flag:
        // the engine MAY gen-move, plays extend the record instead of branching,
        // and the asymmetric human-SL bundles must reach the engine (they are
        // what makes the ranked opponent play at its rank).
        gobanState.suppressesGenMove = false
        gobanState.forcesBranchOnPlay = false
        gobanState.suppressesHumanSLTurnCommands = false
        // BEFORE the load: the engine's play replies and printsgf echoes must
        // land in THIS record (GameSession routes by selectedGameRecord).
        navigationContext.selectedGameRecord = game
        // Register this board with the engine controller BEFORE anything is
        // sent: a board larger than the running engine's NN buffer becomes
        // *Held* here, which shuts the command gate so nothing this entry does
        // can reach an engine that would abort on it — and a restart while this
        // screen is up knows which record to re-feed when its handshake lands.
        // The size comes from the RECORD's SGF, never from `Config`.
        let sgfHelper = SgfOperations(sgf: game.sgf)
        engine.noteBoardMounted(game,
                                width: sgfHelper.xSize,
                                height: sgfHelper.ySize)
        // Land at the tip — a tvOS PRODUCT rule, not an engine recipe. tvOS
        // renders no overwrite dialog, and continuing a game means continuing
        // from its last move: a record synced mid-review
        // (currentIndex < moveSize) opened where it was left would sit on
        // GobanState.isOverwriting with an unlocked record, so the first
        // gen-move reply would latch confirmingAIOverwrite with nothing on
        // screen to confirm it, and the game would park before the user played
        // a move. Every other platform honours the saved cursor.
        game.currentIndex = sgfHelper.moveSize ?? 0
        // A game the user plays is theirs to edit: editingAfterLoad only
        // auto-unlocks the 19×19 defaultSgf, so a 9×9 or an already-played game
        // would land LOCKED and every move would branch-route — never
        // persisting. The one-shot seam is exactly for a reload that should
        // land unlocked; loadGame consumes it.
        gobanState.unlockEditingOnReload = true
        gobanState.loadGame(gameRecord: game, player: player,
                            bookLookup: bookLookup, messageList: messageList,
                            board: board, stones: stones,
                            analysis: analysis, projector: session.recordPosition)
        // AFTER the load (loadGame can rewrite eyeStatus when a book game
        // loads). Ranked-play defaults: engine ON, overlay OFF — see this
        // file's header for why `.clear` is never an option here.
        gobanState.analysisStatus = .run
        gobanState.eyeStatus = .closed
        // No analysis request here: loadGame ends with showboard, whose reply
        // sets player.nextColorForPlayCommand, and BoardView's turn observer
        // fires from .unknown — so a game resumed on the AI's turn moves
        // immediately with no extra driver.
    }

    // MARK: - Moves

    /// Pure config check (the VisionRootView.isAITurn rule): a positive
    /// per-move time marks the engine's side. `.unknown` — the engine has not
    /// replied to showboard yet — counts as AI, so input is rejected until the
    /// real turn lands.
    private var isAITurn: Bool {
        switch player.nextColorForPlayCommand {
        case .black: return config.blackMaxTime > 0
        case .white: return config.whiteMaxTime > 0
        default: return true
        }
    }

    /// Play at the cursor's intersection (Select while the board is focused).
    /// Occupied points are rejected here — the engine's occupied reply is
    /// dropped silently, so without this a Select on a stone would do nothing
    /// invisibly anyway. The ghost survives the submit: the AI answers, the
    /// marker recolors, and the user plays on nearby without re-aiming.
    private func playAtCursor() {
        guard let point = ghost.point,
              !stones.blackPoints.contains(point),
              !stones.whitePoints.contains(point),
              let vertex = point.gtpVertex(width: Int(board.width),
                                           height: Int(board.height)) else { return }
        submit(vertex: vertex)
    }

    /// Play a Top Moves candidate — same submit path as the cursor, but gated
    /// on a settled analysis: between a re-request and its first reply,
    /// analysis.info still holds the PREVIOUS position's candidates, so an
    /// ungated pick could play a stale vertex. (The cursor needs no such gate —
    /// kata-check-move validates against the engine's own position.)
    private func pick(_ candidate: Analysis.CandidateMove) {
        guard !gobanState.waitingForAnalysis else { return }
        submit(vertex: candidate.vertex)
    }

    /// The one write path for a human move. Legality stays engine-side: the
    /// kata-check-move reply plays the move via playPendingHumanMove (the same
    /// path an iOS board tap takes) and an illegal vertex is rejected there.
    private func submit(vertex: String) {
        guard !isGameOver,
              stones.isReady,
              gobanState.pendingMoveTurn == nil,   // one play in flight at a time
              !isAITurn,                           // never on the engine's turn
              let turn = player.nextColorSymbolForPlayCommand else { return }
        gobanState.sendCheckMoveCommand(turn: turn, move: vertex,
                                        messageList: messageList)
    }

    /// Pass (VisionRootView.playPass). A pass changes no stones, so the
    /// board-diff sound never fires for it — click here instead; a pass is
    /// always legal, so the kata-check-move round cannot retract it.
    private func playPass() {
        guard !isGameOver,
              stones.isReady,
              gobanState.pendingMoveTurn == nil,
              !isAITurn,
              let turn = player.nextColorSymbolForPlayCommand else { return }
        audioModel.playPlaySound(soundEffect: gobanState.soundEffect)
        gobanState.sendCheckMoveCommand(turn: turn, move: "pass",
                                        messageList: messageList)
    }

    /// Step one move back. Deliberately NOT gated on `!isAITurn` (unlike every
    /// other action here): one undo flips the turn to the engine, which answers
    /// immediately, so a take-back of the user's OWN move is undo TWICE — hold
    /// L1 and TVControllerInput's auto-repeat delivers the second press while
    /// the engine is still thinking. Gating on the turn would make the second
    /// undo unreachable and the take-back impossible. That second press is safe
    /// precisely because the AI's move is a `kata-search_analyze_cancellable`:
    /// queueing ANY line cancels it and the reply becomes the literal "play
    /// cancelled", which postProcessAIMove's vertex regex drops — so the
    /// in-flight search can never land as a move of the wrong color after the
    /// undo has already flipped the turn back.
    ///
    /// Because editing is unlocked and forcesBranchOnPlay is false, an undo
    /// REPLACES the tail: the `printsgf` below adopts the shortened line as the
    /// game's line, which is both the intended take-back semantic and the thing
    /// that keeps the engine's answer playable — see the resync note inside.
    ///
    /// Deliberately NOT routed through `GobanState.backwardMoves` (which the
    /// review screen uses): that helper ends with `sendPostExecutionCommands`,
    /// so the AI's gen-move bundle would be QUEUED AHEAD of any `printsgf` sent
    /// afterwards, and GTP replies come back in order — the "play" reply would
    /// arrive while the record still held the undone tail. Sending the three
    /// commands here (the VisionRootView.undoOneMove shape) is what puts the
    /// resync before the gen-move. It also removes a double-issue: the helper
    /// requests the bundle itself AND BoardView's turn observer requests it
    /// again on the same toggle; here the observer is the only issuer.
    private func undoOneMove() {
        // Persist the position's analysis before leaving it (the iOS
        // StatusToolbarItems / VisionRootView back-step precedent): the chart's
        // history comes from these writes.
        gobanState.maybeUpdateAnalysisData(gameRecord: game,
                                           analysis: analysis,
                                           board: board,
                                           stones: stones,
                                           all: false)
        // Drop presses while a previous batch's board refresh is in flight, and
        // never step on top of a play awaiting its legality reply.
        guard stones.isReady,
              gobanState.pendingMoveTurn == nil,
              // MANDATORY, not an optimization: this path sends the engine
              // `undo` itself, so it must stop at the branch floor / move 0
              // (GobanState.canStepBackward's own contract).
              gobanState.canStepBackward(gameRecord: game) else { return }
        gobanState.undoIndex(gameRecord: game)
        gobanState.undo(messageList: messageList, stones: stones)
        // THE RESYNC, and it must be sent HERE — after `undo`, before the turn
        // flip that triggers the AI's gen-move. An undo leaves the record's SGF
        // holding the undone move while its currentIndex steps back, which is
        // exactly `GobanState.isOverwriting` — and an unlocked (isEditing)
        // record in that state makes GameSession.postProcessAIMove latch
        // `confirmingAIOverwrite` INSTEAD of playing the engine's answer. No
        // tvOS view renders that confirmation dialog, so the reply would be
        // swallowed, the turn would park on the AI, and every input guarded by
        // `!isAITurn` would refuse. The printsgf reply rewrites sgf +
        // currentIndex to the shortened line (GameSession.maybeCollectSgf),
        // so isOverwriting is false again by the time the "play" line lands.
        messageList.appendAndSend(command: "printsgf")
        player.toggleNextColorForPlayCommand()
        // The turn flip is what re-arms analysis (and the AI's gen-move) via
        // BoardView's observer; this only refreshes the board — the shape
        // VisionRootView.undoOneMove uses.
        gobanState.sendShowBoardCommand(messageList: messageList)
    }

    /// The board's D-pad handler: one intersection per press, clamped at the
    /// edges (the cursor never walks off the board — Menu is the exit).
    /// verticalFlip keeps the mapping honest with the rendering, though tvOS
    /// pins it false at the root.
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

    // MARK: - Analysis display

    /// The eye ONLY. Deliberately not the review screen's toggleAnalysis, which
    /// flips analysisStatus: `.clear` would stop the opponent from moving (see
    /// the file header).
    private func toggleAnalysisDisplay() {
        if gobanState.eyeStatus == .closed {
            gobanState.eyeStatus = .opened
            // Revealing the overlay resumes the continuous analysis that power
            // saving stopped while it was hidden — but NEVER while the engine
            // is generating its move, or the gen-move bundle would be issued a
            // second time (the iOS GameSplitView.processEyeStatusChange gate).
            guard !isAITurn else { return }
            gobanState.maybeRequestAnalysis(config: config,
                                            nextColorForPlayCommand: player.nextColorForPlayCommand,
                                            messageList: messageList)
        } else {
            gobanState.eyeStatus = .closed
            // Mid-human-turn a kata-analyze may be streaming; stop it. Never
            // send "stop" on the engine's turn — that cancels its move.
            if !isAITurn {
                messageList.appendAndSend(command: "stop")
            }
        }
    }

    // MARK: - Controller

    /// Focus-safe controller buttons. X and L1 are both Undo (L1 auto-repeats
    /// while held — the take-back), Y passes. The timeline buttons are review's
    /// and stay unbound here: this screen has no navigation.
    private func handleControllerEvent(_ event: TVControllerEvent) {
        switch event {
        case .buttonX, .leftShoulder:
            undoOneMove()
        case .buttonY:
            playPass()
        case .rightShoulder, .leftTrigger, .rightTrigger:
            return
        }
    }
}

/// A compact icon-only pill for the panel's control row: the label-carrying
/// pills are 56 pt tall and greedy, and three greedy pills did not fit when
/// this panel was 500 pt wide. At the shared 752 pt width
/// (TVBoardLayout.panelWidth) a third labelled pill would probably fit, but
/// icon-only stays on purpose — it mirrors the review screen's control row so
/// the pills read as a set across screens, and it leaves Pass and Undo the
/// room to render their labels unshrunk. The SYMBOL carries the state
/// (eye ⇄ eye.slash — the app's own display-toggle idiom), so there is no
/// "On/Off" label to shrink;
/// `accessibilityLabel` names the control for VoiceOver. Styling mirrors the
/// review screen's toggles so the pills read as a set. (Its TVIconToggleButton
/// is file-private, and widening review's access for one button is not worth
/// the coupling.)
private struct TVPlayIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        let content = Image(systemName: systemName)
            .font(.title3)
            // A fixed 36 pt width (min == max) is what makes this one NOT
            // greedy; the height stays a minimum so the glyph is never
            // squeezed.
            .frame(minWidth: 36, maxWidth: 36, minHeight: 56)

        if isOn {
            // Dark glyph on the wood fill unfocused; the focused white lift
            // also takes a dark glyph, so forcing black is safe in both states.
            Button(action: action) { content.foregroundStyle(.black) }
                .buttonStyle(.borderedProminent)
                .tint(.tvWoodAccent)
                .accessibilityLabel(accessibilityLabel)
        } else {
            Button(action: action) { content }
                .buttonStyle(.bordered)
                .accessibilityLabel(accessibilityLabel)
        }
    }
}
