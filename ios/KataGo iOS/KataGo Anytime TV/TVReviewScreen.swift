//
//  TVReviewScreen.swift
//  KataGo Anytime TV
//
//  Read-only review/spectate of a saved game: a large, unobstructed vector board
//  (the shared BoardView with the captured-stone strip, pass row, and winrate bar
//  hidden so the goban fills the screen) plus a legible 10-foot side panel —
//  player labels, captures, win rate, score, and a move/komi/rules info row —
//  with a focusable transport row. The Siri-Remote D-pad steps moves. There is
//  no auto-play (nothing advances it on tvOS). Focusing the board itself arms
//  the play cursor: the D-pad aims a ghost stone at any intersection, Select
//  plays it as a variation, Menu returns to the panel.
//

import SwiftUI
import KataGoUICore

struct TVReviewScreen: View {
    let game: GameRecord

    #if DEBUG
    /// Preview-only: skip the entry load so staged fixture state (e.g. an
    /// active branch) survives — loadGame would deactivate it. Never set in
    /// production.
    var previewSkipsLoad = false
    #endif

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
    @Environment(\.dismiss) private var dismiss

    @FocusState private var commentFocused: Bool
    /// The chart-timeline scrubber (the one element with an onMoveCommand).
    @FocusState private var timelineFocused: Bool
    /// Programmatic hop targets for the timeline's down press — its
    /// onMoveCommand consumes the D-pad, so leaving it must be explicit.
    @FocusState private var firstTopMoveFocused: Bool
    @FocusState private var toggleFocused: Bool
    /// The board itself, when the play cursor is aiming (one left press from
    /// the panel). While focused, every D-pad press steps the ghost stone and
    /// Select plays it; Menu hops focus back to the timeline.
    @FocusState private var boardFocused: Bool
    /// The play cursor's grid logic (shared with the visionOS ghost stone).
    /// Its point is non-nil only between board focus and unfocus, so passing
    /// it straight into BoardView shows the marker exactly while aiming.
    @State private var ghost = GhostCursorModel()
    /// Aiming mode as PLAIN state (synced from boardFocused): the panel's
    /// suppression and the timeline's focusability key off this — NOT off
    /// boardFocused — so the Menu exit can flip it and hop focus in one
    /// transaction. A FocusState write is only a request processed after
    /// render; gating on boardFocused left the timeline unfocusable at the
    /// moment the hop was processed, so Menu appeared dead (device finding
    /// 2026-07-16).
    @State private var isAiming = false
    @State private var didLoad = false
    /// Click-vs-swipe for the timeline's move commands: fed raw arrow press
    /// down/up by the window-level monitor, queried by timelineMove for the
    /// step magnitude (click = 1, touch-surface swipe = 10).
    @State private var stepClassifier = TimelineStepClassifier()
    // Parsed once from the SGF at load (a C++ parse — never per body eval).
    @State private var totalMoves = 0
    /// The Top Moves row under remote focus, ringed on the board.
    @State private var highlightedPoint: BoardPoint?

    private var config: Config { game.concreteConfig }

    var body: some View {
        // Gate on the size the RUNNING engine was launched with: a board larger
        // than its NN buffer aborts the whole app on the first analysis (see
        // `boardFits`). The too-large branch never runs `loadIfNeeded()`, so no
        // oversized board or analysis request ever reaches the engine.
        if boardFits(width: config.boardWidth,
                     height: config.boardHeight,
                     maxBoardLength: engine.maxBoardLength) {
            reviewContent
        } else {
            tooLargeView
        }
    }

    /// The board is too large for the current Max Board Size. tvOS has no
    /// neural-network picker, so (unlike iOS's copy) the remedy points at
    /// Settings ▸ Board Size. Full-screen, legible at 10 feet. The Go Back
    /// button is load-bearing beyond convenience: with zero focusable
    /// elements the tvOS focus engine can wedge and swallow the Menu press,
    /// dead-ending the screen — and the explicit onExitCommand reproduces
    /// the default pop even if it wedges again. ("Go Back", not "Back to
    /// Library": the Search tab pushes this screen too.)
    private var tooLargeView: some View {
        ContentUnavailableView {
            Label("Board Too Large", systemImage: "rectangle.portrait.and.arrow.forward")
        } description: {
            Text("This \(config.boardWidth)×\(config.boardHeight) game is larger than the current Max Board Size (\(engine.maxBoardLength)×\(engine.maxBoardLength)). Raise Max Board Size in the Settings tab, then reopen the game.")
        } actions: {
            Button("Go Back") { dismiss() }
        }
        .onExitCommand { dismiss() }
    }

    private var reviewContent: some View {
        // Full-bleed hero board: safe areas ignored on every edge, explicit
        // paddings are the only margins, so the square reaches the screen's
        // full 1080 pt height. The board is a focusable leaf (one left press
        // from any panel control except the timeline, whose own scrub owns
        // left): while focused, the D-pad steps the ghost cursor, Select
        // plays at it, and Menu hops focus back to the timeline (see the
        // onExitCommand branch below).
        HStack(spacing: 0) {
            BoardView(gameRecord: game,
                      interactive: false,
                      showsCapturedStones: false,
                      showsPass: false,
                      showsWinrateBar: false,
                      highlightedPoint: highlightedPoint,
                      cursorPoint: ghost.point,
                      commentIsFocused: $commentFocused)
                // tvOS is always exactly 1920×1080 pt, so pin the square to
                // the full screen height outright: inside the NavigationStack
                // the safe-area insets survive ignoresSafeArea on this
                // subtree, which silently shrank the fitted square to ~950 pt.
                // A fixed frame also keeps the board independent of the
                // panel's ideal height (it must never resize on toggles).
                .frame(width: 1080, height: 1080)
                // Focusable whenever the timeline isn't: onMoveCommand is
                // only a FALLBACK on tvOS (a focusable target in the pressed
                // direction wins and moves focus before the handler fires,
                // verified on device 2026-07-16), so a focusable board to the
                // timeline's left would hijack its left-scrub presses. No
                // analysis gate — the cursor plays with the engine silent
                // too; the kata-check-move submit path never needed
                // candidates.
                .focusable(!timelineFocused)
                .focused($boardFocused)
                .onMoveCommand(perform: boardMove)
                // Select plays via the UIKit catcher (see TVSelectPressCatcher
                // — .onTapGesture dropped every first Select on device).
                // Armed off plain isAiming so the Menu exit disarms it in the
                // same transaction that re-enables the panel.
                .tvSelectPress(isEnabled: isAiming, perform: playAtCursor)
                .overlay {
                    // Focus affordance (the timeline-ring pattern): the board
                    // has no system focus lift, so say "you are aiming" here.
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

            Spacer(minLength: 24)

            panel
                // Hard ceiling: the 1080 pt screen minus the 30 pt vertical
                // margins. A fixed frame reports this size to the HStack no
                // matter how tall the content wants to be, so panel growth
                // (e.g. the tall no-history placeholder) can never inflate
                // the HStack and push the 1080 pt board off-screen — content
                // that outgrows the budget overflows inside this slot,
                // top-aligned. No .clipped(): it would shear the focus
                // lift/shadow on the rows at the edges.
                .frame(width: 500, height: 1020, alignment: .top)
                .padding(.vertical, 30)
                // While the cursor is aiming, EVERY panel control must be
                // unfocusable: onMoveCommand is only a fallback (see the
                // board's focusable comment), so a focusable row to the
                // board's right would swallow right-presses — the cursor
                // could step every direction except right. Dimming doubles
                // as the "aiming mode" affordance. The timeline is not a
                // control, so it carries its own !isAiming gate.
                .disabled(isAiming)
                .focusSection()
        }
        .padding(.leading, 24)
        .padding(.trailing, 40)
        .ignoresSafeArea()
        // The panel held the only focusables before the board became one;
        // keep the entry landing there — the giant top-left board must not
        // steal initial focus.
        .defaultFocus($timelineFocused, true)
        // A focused board consumes every D-pad press (edges clamp, Select
        // plays), so Menu is the one way out of cursor mode. Attaching an
        // onExitCommand replaces the default NavigationStack pop; reproduce
        // it in the unfocused branch (the TVSelfPlayScreen pattern).
        .onExitCommand {
            if boardFocused {
                // Order matters: isAiming is plain state, so flipping it
                // makes the timeline focusable in THIS transaction and the
                // focus hop that follows finds a legal target. (Writing
                // boardFocused = false first left focus with nowhere to go —
                // FocusState writes are requests processed after render, so
                // the timeline was still unfocusable and Menu appeared
                // dead.) The ghost resets via the focus onChange.
                isAiming = false
                timelineFocused = true
            } else {
                dismiss()
            }
        }
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

                // The TIMELINE: the score chart doubles as the move scrubber
                // (the amber rule is the playhead). Focus it and click
                // left/right to step one move — holding auto-repeats into a
                // scrub — or swipe the touch surface to jump 10 (the
                // classifier below tells the two apart by their arrow
                // presses). Down hops focus out programmatically (the
                // onMoveCommand consumes the D-pad); entry from below is
                // natural focus movement. Works with analysis off (persisted
                // values) and on the no-history placeholder alike.
                TVScoreChart(gameRecord: game, currentIndex: displayIndex)
                    .padding(8)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(timelineFocused ? Color.tvWoodAccent : .clear,
                                    lineWidth: 3)
                    }
                    .focusable(!isAiming)
                    .focused($timelineFocused)
                    .onMoveCommand(perform: timelineMove)
                    .tvArrowPressMonitor(isEnabled: timelineFocused && !isAiming,
                                         onPressBegan: { stepClassifier.arrowPressBegan(at: Date()) },
                                         onPressEnded: { stepClassifier.arrowPressEnded(at: Date()) })
                    .onChange(of: timelineFocused) { _, _ in
                        // Failsafe: if focus leaves mid-press the monitor is
                        // disarmed before the release arrives, which would
                        // wedge the down-count at "click" forever.
                        stepClassifier.reset()
                    }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 26))

            // The engine's live candidates, clickable: a pick plays that move
            // as a variation (forced branch — the synced record is never
            // written; Menu discards it). After a pick the turn flips and the
            // stream re-arms, so the list refreshes for the other color —
            // alternate picks walk a line. While a variation is active the
            // third row slot becomes the Exit Variation button (constant
            // 3-row footprint, zero layout shift).
            TVBestMovesList(candidates: analysis.candidateMoves(width: Int(board.width),
                                                                height: Int(board.height),
                                                                limit: gobanState.isBranchActive ? 2 : 3),
                            isEnabled: gobanState.eyeStatus != .closed,
                            rowCount: gobanState.isBranchActive ? 2 : 3,
                            onFocus: { highlightedPoint = $0?.point },
                            firstRowFocus: $firstTopMoveFocused,
                            onPick: pick)

            if gobanState.isBranchActive {
                exitVariationRow
            }

            infoRow

            Spacer()

            analysisToggle
                .focused($toggleFocused)
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
        return TVPlayerRow(isBlack: isBlack,
                           name: config.playerLabel(for: color),
                           captures: isBlack ? stones.blackStonesCaptured
                                             : stones.whiteStonesCaptured)
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

    // MARK: - Timeline + branch exit

    /// Leave the variation and return to the recorded mainline position:
    /// loadGame deactivates the branch, reloads the SGF, rewinds to the
    /// record's currentIndex, and sends showboard — one call does it all.
    private var exitVariationRow: some View {
        Button(action: exitVariation) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.uturn.backward")
                Text("Exit Variation")
            }
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 38)
        }
        .buttonStyle(.bordered)
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
        #if DEBUG
        guard !previewSkipsLoad else { return }
        #endif
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
        // CRITICAL: review is ALWAYS locked. loadGame unlocks a game whose
        // SGF equals GameRecord.defaultSgf (a never-played synced game), and
        // an unlocked game routes picks through the EDITING path — which
        // truncates the record and lets printsgf replies overwrite the synced
        // SGF (exported to CloudKit; the build-291 data-corruption bug).
        gobanState.isEditing = false
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

    /// Play a Top Moves candidate — same submit path as the cursor, but
    /// gated on a settled analysis: between a re-request and its first reply,
    /// analysis.info still holds the PREVIOUS position's candidates, so an
    /// ungated pick could play a stale vertex. (The cursor needs no such
    /// gate — kata-check-move validates against the engine's own position.)
    private func pick(_ candidate: Analysis.CandidateMove) {
        guard !gobanState.waitingForAnalysis else { return }
        submit(vertex: candidate.vertex)
    }

    /// Play at the cursor's intersection (remote Select while the board is
    /// focused). Occupied points are rejected here — the engine's occupied
    /// reply is dropped silently, so without this guard a Select on a stone
    /// would just do nothing invisibly anyway; keeping the cursor in place
    /// after a play relies on it. The ghost survives the submit (unlike
    /// visionOS's playAtGhost): the turn flips, the marker recolors, and the
    /// user answers nearby without re-aiming from center.
    private func playAtCursor() {
        guard let point = ghost.point,
              !stones.blackPoints.contains(point),
              !stones.whitePoints.contains(point),
              let vertex = point.gtpVertex(width: Int(board.width),
                                           height: Int(board.height)) else { return }
        submit(vertex: vertex)
    }

    /// Play a vertex as a variation. The kata-check-move legality round-trip
    /// is the same path a board tap takes on iOS: its reply plays the move
    /// via playPendingHumanMove, which (forced branch) captures the variation
    /// before requesting printsgf — so with the record selected here, every
    /// printsgf reply routes into branchSgf and the synced record is never
    /// written (isEditing == false keeps maybeUpdateAnalysisData inert too).
    /// Works with analysis on or off: on, the turn flip re-fires BoardView's
    /// observer, the suppressed stream re-arms as plain kata-analyze for the
    /// new position, and the list refills for the other color; off, the
    /// engine plays quietly (the path never needed candidates — only the
    /// Top Moves picks do, and their rows are placeholders when off). No
    /// waitingForAnalysis gate here: it belongs to pick() alone — on the
    /// cursor path it silently swallowed Select during the warmup after
    /// every move, reading as "double-press required".
    private func submit(vertex: String) {
        guard stones.isReady,
              gobanState.pendingMoveTurn == nil,  // one play in flight at a time
              let turn = player.nextColorSymbolForPlayCommand else { return }
        // Selected lazily (not at load) so a stale printsgf reply from the
        // previous screen can never find a writable selection here;
        // maybeCollectCheckMove needs it set when the legality reply lands.
        navigationContext.selectedGameRecord = game
        gobanState.sendCheckMoveCommand(turn: turn, move: vertex,
                                        messageList: messageList)
    }

    /// The board's D-pad handler: one intersection per press, clamped at the
    /// edges (the cursor never walks off the board — Menu is the exit, see
    /// the onExitCommand branch). verticalFlip keeps the mapping honest with
    /// the rendering, though tvOS pins it false at the root.
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

    private func exitVariation() {
        // A late printsgf from the variation's last pick must not find a
        // writable selection while the branch is being torn down.
        navigationContext.selectedGameRecord = nil
        gobanState.loadGame(gameRecord: game, previous: nil, player: player,
                            bookLookup: bookLookup, messageList: messageList,
                            board: board, stones: stones)
        // Same review lock as loadIfNeeded — loadGame re-evaluates the
        // defaultSgf unlock on every reload.
        gobanState.isEditing = false
        reanalyze()
    }

    /// The timeline's D-pad handler. Left/right step — an edge click steps 1
    /// (holding auto-repeats into a scrub), a touch-surface swipe jumps 10;
    /// the classifier tells them apart by whether an arrow press is down or
    /// just occurred (swipes produce none). Down hops focus out
    /// programmatically — an onMoveCommand consumes every direction, so
    /// without the hop the timeline would trap focus the way the old
    /// focusable board did.
    private func timelineMove(_ direction: MoveCommandDirection) {
        switch direction {
        case .left:
            stepBy(-stepClassifier.stepCount(at: Date()))
        case .right:
            stepBy(stepClassifier.stepCount(at: Date()))
        case .down:
            if gobanState.eyeStatus != .closed, !analysis.info.isEmpty {
                firstTopMoveFocused = true
            } else {
                // Rows are placeholders (not focusable) — land on the toggle.
                toggleFocused = true
            }
        default:
            break
        }
    }

    private func stepBy(_ delta: Int) {
        // Drop ticks while a previous batch's board refresh is in flight
        // (the visionOS undo/forward precedent) — a 10-move jump keeps the
        // engine busy longer than a single step, and ungated flurries would
        // pile GTP batches into the queue. No isAITurn term: review is a
        // spectator (suppressesGenMove) and submit() trusts isReady alone.
        guard stones.isReady else { return }
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

/// One color's panel row: stone glyph, captured count, player label. The
/// count sits beside the stone as "xN" — the iOS captured-strip idiom
/// (StoneView.drawCapturedStones) — replacing a trailing "captured N"
/// sentence that truncated in the 500 pt panel once the count grew. Internal
/// (not private): the self-play screen's player rows reuse it.
struct TVPlayerRow: View {
    let isBlack: Bool
    let name: String
    let captures: Int

    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 8) {
                TVStoneIndicator(isBlack: isBlack)
                Text("x\(captures)")
                    .contentTransition(.numericText())
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(name)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            // Left-align the row: the enclosing player-rows VStacks use the
            // default center alignment, so without this the two rows would
            // center against each other and the stones would drift apart as
            // the counts' widths diverge.
            Spacer(minLength: 0)
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
    var skipsLoad = false

    var body: some View {
        TVReviewScreen(game: game, previewSkipsLoad: skipsLoad)
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
            // Default maxBoardLength is 37, so every preview fixture (≤19×19)
            // takes the normal board branch, not the too-large gate.
            .environment(TVEngineController())
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

// Variation (branch) active: red board border, two candidate rows + the
// Exit Variation row in the third slot (constant 3-row footprint), board
// ringing the staged focused candidate.
#Preview("Review — variation, exit row") {
    let game = TVPreviewData.openingGame()
    let session = TVPreviewData.reviewSession(game: game,
                                              blackWinrate: 0.55,
                                              blackScore: 1.5)
    session.gobanState.analysisStatus = .run
    session.gobanState.eyeStatus = .opened
    session.gobanState.branchSgf = game.sgf
    session.gobanState.branchIndex = 6
    // Skip the entry load: it would deactivate the staged branch.
    return TVReviewPreviewHost(game: game, session: session, skipsLoad: true)
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
