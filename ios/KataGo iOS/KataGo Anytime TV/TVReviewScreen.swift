//
//  TVReviewScreen.swift
//  KataGo Anytime TV
//
//  Read-only review/spectate of a saved game: a large, unobstructed vector board
//  (the shared BoardView with the captured-stone strip, pass row, and winrate bar
//  hidden so the goban fills the screen) plus a legible 10-foot side panel —
//  player labels, captures, win rate, score, and a move/komi/rules info row —
//  with a focusable transport row. The Siri-Remote D-pad steps moves; the
//  Auto-Play toggle (or the remote's Play/Pause) replays the recorded moves as
//  a spoken, commentated broadcast — the live self-play UX with the recorded
//  moves as the move source — and any manual navigation stops it. Focusing the
//  board itself arms the play cursor: the D-pad aims a ghost stone at any
//  intersection, Select plays it as a variation, Menu returns to the panel.
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

    /// Supplied by the navigationDestination that created this screen, so the
    /// handoff pushes onto the SAME stack the user is looking at. A single
    /// root-level closure would append to the Library path even when the
    /// visible stack is Search.
    var onContinueLive: ((SelfPlaySeed) -> Void)? = nil

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
    @Environment(\.dismiss) private var dismiss

    /// This screen's slot in the controller's LIFO handler stack.
    @State private var controllerToken = UUID()

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
    /// Auto-Play: the recorded moves replayed as a commentated broadcast
    /// (the live self-play UX with the recorded move as the move source).
    /// Plain state, NOT `GobanState.isAutoPlaying` — that flag is the iOS
    /// wand's, is consulted by ~10 live guards (AnalysisView, BoardView, the
    /// asymmetric human-SL sends), is force-cleared by loadGame, and the only
    /// code that restores what it suppresses lives in the iOS target and is
    /// not compiled for tvOS.
    @State private var isAutoPlaying = false
    /// The replay's broadcast driver; non-nil exactly while replaying.
    @State private var replayBroadcast: BroadcastController?
    /// The user's analysis-OFF preference, restored when the replay stops
    /// (the broadcast protocol runs analysisStatus .clear — the
    /// TVSelfPlayScreen.analysisWasUserOff pattern).
    @State private var analysisWasUserOff = false
    /// Whether the recorded game already ended — a full C++ SGF parse,
    /// hoisted at replay start per this file's "never per body eval" rule.
    @State private var recordedIsFinished = false
    /// The "Continuing live…" beat between the last recorded move and the push.
    @State private var isHandingOff = false
    @State private var handoffTask: Task<Void, Never>?

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
            ZStack {
                BoardView(gameRecord: game,
                          interactive: false,
                          showsCapturedStones: false,
                          showsPass: false,
                          showsWinrateBar: false,
                          highlightedPoint: highlightedPoint,
                          cursorPoint: ghost.point,
                          commentIsFocused: $commentFocused)
                    // Focusable whenever the timeline isn't: onMoveCommand is
                    // only a FALLBACK on tvOS (a focusable target in the
                    // pressed direction wins and moves focus before the
                    // handler fires, verified on device 2026-07-16), so a
                    // focusable board to the timeline's left would hijack its
                    // left-scrub presses. No analysis gate — the cursor plays
                    // with the engine silent too; the kata-check-move submit
                    // path never needed candidates. And never while replaying:
                    // the slide layer owns focus then, and a board focus would
                    // flip isAiming, which stops the replay (the self-play
                    // screen's isPaused gate, adapted).
                    .focusable(!timelineFocused && !isAutoPlaying)
                    .focused($boardFocused)
                    .onMoveCommand(perform: boardMove)
                    // Select plays via the UIKit catcher (see
                    // TVSelectPressCatcher — .onTapGesture dropped every first
                    // Select on device). Armed off plain isAiming so the Menu
                    // exit disarms it in the same transaction that re-enables
                    // the panel.
                    .tvSelectPress(isEnabled: isAiming, perform: playAtCursor)
                    .overlay {
                        // Focus affordance (the timeline-ring pattern): the
                        // board has no system focus lift, so say "you are
                        // aiming" here.
                        Rectangle()
                            .stroke(boardFocused ? Color.tvWoodAccent : .clear,
                                    lineWidth: 4)
                    }
                    .onChange(of: boardFocused) { _, focused in
                        isAiming = focused
                        if focused {
                            // Aiming the play cursor is taking over.
                            stopAutoPlay()
                            ghost.activate(width: Int(board.width),
                                           height: Int(board.height))
                        } else {
                            ghost.reset()
                        }
                    }

                if let broadcast = replayBroadcast, broadcast.currentSlide != nil {
                    replaySlideLayer(broadcast: broadcast)
                }
            }
            // tvOS is always exactly 1920×1080 pt, so pin the square to the
            // full screen height outright: inside the NavigationStack the
            // safe-area insets survive ignoresSafeArea on this subtree, which
            // silently shrank the fitted square to ~950 pt. A fixed frame also
            // keeps the board independent of the panel's ideal height (it must
            // never resize on toggles). The frame sits on the ZStack, not on
            // BoardView, so the slide layer shares it (the TVSelfPlayScreen
            // geometry).
            .frame(width: TVBoardLayout.boardSide, height: TVBoardLayout.boardSide)

            Spacer(minLength: TVBoardLayout.gapFloor)

            Group {
                if let broadcast = replayBroadcast, let slide = broadcast.currentSlide {
                    TVBroadcastSlidePanel(title: slide.title,
                                          text: broadcast.typedText,
                                          slideNumber: broadcast.slideNumber,
                                          slideCount: broadcast.slideCount)
                } else {
                    panel
                }
            }
                // Shared geometry (TVBoardLayout): 752 pt is the widest panel
                // that keeps the Spacer above at its 24 pt floor, and the
                // 1000 pt height is the 1080 pt screen minus the 40 pt
                // vertical margins. This screen used to hardcode a 500 pt
                // panel, which left the Spacer absorbing 276 pt of dead space
                // between board and panel. A fixed frame reports this size to
                // the HStack no matter how tall the content wants to be, so
                // panel growth (e.g. the tall no-history placeholder) can
                // never inflate the HStack and push the 1080 pt board
                // off-screen — content that outgrows the budget overflows
                // inside this slot, top-aligned. No .clipped(): it would shear
                // the focus lift/shadow on the rows at the edges.
                .frame(width: TVBoardLayout.panelWidth,
                       height: TVBoardLayout.panelHeight,
                       alignment: .top)
                .padding(.vertical, TVBoardLayout.panelVerticalPadding)
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
        .padding(.leading, TVBoardLayout.leadingMargin)
        .padding(.trailing, TVBoardLayout.trailingMargin)
        .ignoresSafeArea()
        .overlay {
            if isHandingOff {
                // Announce the screen change rather than jump-cutting to it.
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Continuing live…")
                        .font(.title2.bold())
                    Text("KataGo plays on from here.")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .padding(48)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 32))
            }
        }
        // The panel held the only focusables before the board became one;
        // keep the entry landing there — the giant top-left board must not
        // steal initial focus.
        .defaultFocus($timelineFocused, true)
        // The transport button. Attached here — above the panel's
        // `.disabled(isAiming)` subtree and inside the boardFits gate, so the
        // too-large branch stays engine-free. Ignored while aiming: the board
        // cursor owns the screen then, and board focus is itself a stop.
        .onPlayPauseCommand {
            guard !isAiming else { return }
            toggleAutoPlay()
        }
        .onReceive(NotificationCenter.default
            .publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: RunLoop.main)) { _ in
                if SelfPlayAttract.shouldStop(thermalState: ProcessInfo.processInfo.thermalState) {
                    stopAutoPlay()
                    // A device that goes hot DURING the 2 s beat would still
                    // complete the push otherwise — stopAutoPlay() knows
                    // nothing about the handoff. Mirrors onDisappear's cancel.
                    handoffTask?.cancel()
                    handoffTask = nil
                    isHandingOff = false
                }
            }
        // The replay chain: each cycle parks in .awaitingMove; the policy
        // decides whether to run another (the old per-tick decision, now
        // per-cycle). stones.isReady re-enters a .hold once the board
        // refresh lands.
        .onChange(of: replayBroadcast?.phase) { _, newPhase in
            guard newPhase == .awaitingMove else { return }
            continueReplay()
        }
        .onChange(of: stones.isReady) { _, ready in
            guard ready, replayBroadcast?.phase == .awaitingMove else { return }
            continueReplay()
        }
        // Ghost anchor: reveal (and follow) the cursor at the board's last
        // move — players expect to answer near it. The O(moves) SGF walk
        // runs once per position change, never per body eval. lastPoint is
        // nil for a pass or an empty board — the center fallback stays.
        .onChange(of: lastMoveKey, initial: true) { _, newValue in
            ghost.setAnchor(newValue?.lastPoint,
                            width: Int(board.width),
                            height: Int(board.height))
        }
        // A focused board consumes every D-pad press (edges clamp, Select
        // plays), so Menu is the one way out of cursor mode. Attaching an
        // onExitCommand replaces the default NavigationStack pop; reproduce
        // it in the unfocused branch (the TVSelfPlayScreen pattern).
        .onExitCommand {
            stopAutoPlay()
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
            stopAutoPlay()
            controllerInput.popHandler(controllerToken)
            handoffTask?.cancel()
            handoffTask = nil
            isHandingOff = false
            // Silent discard (user decision): variations explored here are
            // throwaway — the synced record was never written.
            //
            // Identity-guarded: on a PUSH (the live handoff) SwiftUI can fire
            // the destination's onAppear BEFORE this, and TVSelfPlayScreen's
            // entry has already pointed the selection at its own seeded record.
            // An unconditional nil would strand its licensed gen-move reply in
            // postProcessAIMove's `if let gameRecord` and park the broadcast in
            // .awaitingMove forever.
            if navigationContext.selectedGameRecord === game {
                navigationContext.selectedGameRecord = nil
            }
            gobanState.deactivateBranch()
            gobanState.forcesBranchOnPlay = false
            gobanState.maybePauseAnalysis()
            // Re-arm the entry protocol for the next appearance. Without this
            // a pop back from the live continuation resumes with isEditing ==
            // true and forcesBranchOnPlay == false inherited from the self-play
            // screen — the editing path on a synced record (build-291).
            didLoad = false
        }
    }

    // MARK: - Replay slides

    /// The replay's slide surface over the hero slot. A choreography slide
    /// mounts the acted-out slide board (the TVSelfPlayScreen pattern); the
    /// Comment slide has no frame — the LIVE board stays visible beneath a
    /// transparent layer that only keeps a focus home and the skip controls
    /// (zero focusables would wedge the tvOS focus engine, see tooLargeView).
    @ViewBuilder
    private func replaySlideLayer(broadcast: BroadcastController) -> some View {
        Group {
            if let frame = broadcast.currentFrame, let model = broadcast.reportModel {
                TVBroadcastSlideBoard(frame: frame, model: model)
            } else {
                Color.clear
            }
        }
        .focusable(true)
        .onMoveCommand { direction in
            if direction == .right { broadcast.skipSlide() }
        }
        // Window-wide catcher invariant: while this is enabled the board's
        // own catcher is off (isAiming is false during a replay) and the
        // panel is the slide panel (no buttons).
        .tvSelectPress(isEnabled: true, perform: { broadcast.skipSlide() })
    }

    // MARK: - Analysis + transport panel

    private var panel: some View {
        // Spacing/padding and the title/chart sizes are a 1000 pt vertical
        // budget — TVBoardLayout.panelHeight, the frame this whole stack is
        // capped to (it was a 1020 pt cap while the numbers lived inline, so
        // the budget got 20 pt TIGHTER, never looser). The full analysis-on
        // stack (2-line title through both toggles) clips at the original
        // 24/24/200/.title values, and the Top Moves rows squeezed the block
        // spacing from 20 to 10.
        VStack(alignment: .leading, spacing: 10) {
            Text(game.name.isEmpty ? "Untitled" : game.name)
                .font(.title2.bold())
                // One line, shrinking to fit: a second title line was
                // affordable before the Top Moves rows, but now it overflows
                // the 1000 pt budget (title clips at the top, the analysis
                // toggle at the bottom). The panel is wider than it used to be
                // (752 vs 500 pt), which only helps here — more of the name
                // fits on the single line before minimumScaleFactor bites.
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
                // NOT gated on the eye, deliberately: this screen inverts the
                // play screen's rule. Closing the eye here is what makes the
                // persisted per-move winrate/score appear as the headline just
                // above, so blanking the plot would contradict the number
                // printed 40 pt higher — and it would blank the scrubber's own
                // playhead, which is this screen's navigation affordance.
                TVScoreChart(gameRecord: game,
                             hidesHistoryWhenAnalysisOff: false,
                             currentIndex: displayIndex)
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

            HStack(spacing: 16) {
                autoPlayToggle

                analysisToggle
                    .focused($toggleFocused)
            }
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
        // The persisted index names a preset; the -1 Custom sentinel and any
        // out-of-range synced value render as "Custom" (never crash).
        NewGameRuleset.preset(fromConfigRule: config.rule)?.displayName ?? "Custom"
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

    /// Branch-aware ghost-anchor inputs (the VisionRootView hook, shared via
    /// LastMoveKey). Reading them in body keeps the onChange armed for
    /// steps, jumps, picks, passes, and branch navigation.
    private var lastMoveKey: LastMoveKey? {
        guard let sgf = gobanState.getSgf(gameRecord: game),
              let index = gobanState.getCurrentIndex(gameRecord: game) else { return nil }
        return LastMoveKey(sgf: sgf, index: index)
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
        return ScoreLeadText.sideAnnotated(blackScore: s)
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

    /// Auto-Play: replay the recorded moves as a commentated broadcast.
    /// Disabled while a variation is active — the mainline is what replays —
    /// which is also why
    /// `$toggleFocused` stays on the Analysis button: it is the timeline's
    /// programmatic down-hop target and must never be unfocusable.
    private var autoPlayToggle: some View {
        TVIconToggleButton(systemName: isAutoPlaying ? "pause.fill" : "play.fill",
                           accessibilityLabel: "Auto-Play",
                           isOn: isAutoPlaying) {
            toggleAutoPlay()
        }
        .disabled(gobanState.isBranchActive)
    }

    /// The one control: analysis ON = the engine runs and everything it
    /// produces is visible; OFF = the engine stops and nothing analysis-
    /// flavored stays on screen. The merged states kill the two traps a
    /// separate Overlay toggle allowed — a stale board overlay with the
    /// engine stopped, and an invisible engine heating the fanless box.
    private func toggleAnalysis() {
        // Any analysis toggle is the user taking over from the replay — and
        // an un-stopped replay must never see a kata-analyze injected into a
        // live report cycle (the controller's .clear protocol). stopAutoPlay
        // restores the pre-replay analysis state synchronously, so the flip
        // below reads it coherently; its post-drain re-arm guard then defers
        // to whatever this toggle decides.
        stopAutoPlay()
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

    private var analysisToggle: some View {
        TVToggleButton(systemName: "sparkles", title: "Analysis",
                       isOn: gobanState.analysisStatus == .run) {
            toggleAnalysis()
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
        gobanState.loadGame(gameRecord: game, player: player,
                            bookLookup: bookLookup, messageList: messageList,
                            board: board, stones: stones,
                            analysis: analysis, projector: session.recordPosition)
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
        // Must precede the guard below: the replay re-arms waitingForAnalysis
        // on every cycle (its report probes, then the next position's
        // requestAnalysis), so gating the stop behind that guard would leave a
        // window after every auto-advanced move where a Select here both does
        // nothing AND fails to stop the replay — a dead-looking remote with
        // stones still appearing.
        stopAutoPlay()
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
        // During the handoff beat the destination screen's entry is about to
        // re-arm a WRITABLE selection (isEditing == true, forcesBranchOnPlay
        // == false), unlike every other exit from this screen, which leaves
        // the selection nil. A kata-check-move reply that lands after the
        // push would therefore play this variation into — and let its
        // printsgf overwrite — the fresh continuation record instead of
        // discarding harmlessly.
        guard !isHandingOff else { return }
        // Playing a variation takes over from the replay.
        stopAutoPlay()
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
        gobanState.loadGame(gameRecord: game, player: player,
                            bookLookup: bookLookup, messageList: messageList,
                            board: board, stones: stones,
                            analysis: analysis, projector: session.recordPosition)
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
        // Any manual step is the user taking over. The replay's own advance
        // calls advanceReplayMove() directly, so this can never stop the
        // broadcast it belongs to.
        stopAutoPlay()
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

    // MARK: - Controller

    /// Focus-safe controller buttons. Navigation (L1/R1/L2/R2) now works
    /// while aiming too — the ghost follows the changing last move via the
    /// anchor hook, so stepping and aiming compose. X and Y stay inert
    /// while aiming: the board cursor owns the screen's modes, and starting
    /// Auto-Play or toggling analysis mid-aim would fight it.
    private func handleControllerEvent(_ event: TVControllerEvent) {
        switch event {
        case .buttonX:
            guard !isAiming else { return }
            toggleAutoPlay()
        case .buttonY:
            guard !isAiming else { return }
            toggleAnalysis()
        case .leftShoulder:
            stepBy(-1)
        case .rightShoulder:
            stepBy(1)
        case .leftTrigger:
            stopAutoPlay()
            guard stones.isReady else { return }
            gobanState.backwardMoves(limit: nil, gameRecord: game,
                                     messageList: messageList,
                                     player: player, stones: stones)
            reanalyze()
        case .rightTrigger:
            stopAutoPlay()
            guard stones.isReady else { return }
            gobanState.forwardMoves(limit: nil, gameRecord: game, board: board,
                                    messageList: messageList, player: player,
                                    audioModel: audioModel, stones: stones)
            reanalyze()
        }
    }

    // MARK: - Auto-Play

    private func toggleAutoPlay() {
        if isAutoPlaying {
            stopAutoPlay()
        } else {
            startAutoPlay()
        }
    }

    /// Start the commentated replay. Already parked at the last move is not
    /// an error: nothing to replay, so report the end immediately — which
    /// finishAutoPlay turns into the live handoff for an unfinished game.
    private func startAutoPlay() {
        guard !gobanState.isBranchActive, !isAutoPlaying else { return }
        guard gobanState.getNextMove(gameRecord: game) != nil else {
            finishAutoPlay(continuesLive: !SelfPlayGame.recordedGameIsFinished(sgf: game.sgf))
            return
        }
        isAutoPlaying = true
        // Lean-back viewing with no remote input: keep the system screensaver
        // from covering the replay (the TVSelfPlayScreen precedent).
        UIApplication.shared.isIdleTimerDisabled = true
        // Invariant for the whole replay (game.sgf is never written here,
        // and a branch stops the loop); a full C++ parse, hoisted once.
        recordedIsFinished = SelfPlayGame.recordedGameIsFinished(sgf: game.sgf)
        // The broadcast engine-state protocol (the TVSelfPlayScreen entry,
        // adapted): remember a user OFF, then run the cycles under
        // analysisStatus .clear. suppressesGenMove is already true (review
        // is a spectator) and replay mode never gen-moves at all. The
        // asymmetric human-SL bundles are silenced for the replay's
        // lifetime — a synced Human-vs-9d config would otherwise inject
        // acks between a cycle's probes (Task 6 / the controller header).
        analysisWasUserOff = (gobanState.analysisStatus == .clear)
        gobanState.eyeStatus = .opened
        gobanState.analysisStatus = .clear
        gobanState.suppressesHumanSLTurnCommands = true
        let broadcast = BroadcastController(
            messageList: messageList,
            gobanState: gobanState,
            player: player,
            rootWinrate: rootWinrate,
            rootScore: rootScore,
            speaker: AVSpeechNarrationSpeaker(),
            isSpeechEnabled: { NarrationSpeechSetting.isEnabled },
            pacing: { TVAutoPlaySpeed.current.broadcastPacing },
            replayAdvance: { advanceReplayMove() })
        replayBroadcast = broadcast
        broadcast.noteTurnChanged(game: game)   // the first cycle
        // The first cycle can refuse to start (turn still .unknown before the
        // entry showboard replies, or a mid-game double pass putting
        // passCount at 2): the controller parks in .idle and no phase edge
        // will ever arrive. Unwind rather than stall silently.
        if broadcast.phase == .idle {
            stopAutoPlay()
        }
    }

    /// Every stop path funnels here (steps, picks, aiming, Play/Pause, Menu,
    /// thermal, onDisappear). Tears the broadcast down (which cancels speech)
    /// and restores the analysis state the replay protocol displaced — the
    /// flags synchronously, the engine's analyze stream only after the
    /// cancelled generator has drained (see below).
    private func stopAutoPlay() {
        guard isAutoPlaying || replayBroadcast != nil else { return }
        isAutoPlaying = false
        let broadcast = replayBroadcast
        replayBroadcast = nil
        gobanState.suppressesHumanSLTurnCommands = false
        UIApplication.shared.isIdleTimerDisabled = false
        // cancelAll deliberately does not touch analysisStatus — the caller
        // owns restoration (its doc comment).
        //
        // Synchronous state restore first, so callers that read or re-toggle
        // the status right after (stepBy's reanalyze, toggleAnalysis) see the
        // pre-replay state — but the actual analyze re-request must wait out
        // the generator's cooperative restore ("stop" + undo tail), which
        // would kill anything armed before it lands.
        if analysisWasUserOff {
            gobanState.analysisStatus = .clear
            gobanState.eyeStatus = .closed
        } else {
            gobanState.eyeStatus = .opened
            gobanState.analysisStatus = .run
        }
        Task { @MainActor in
            await broadcast?.cancelAllAndDrain()
            // The user may have toggled analysis, stepped (its own re-arm is
            // also post-stop and may have died to the same generator stop —
            // this re-arm covers it), or left the screen (maybePauseAnalysis
            // set .pause) while the drain ran. Never fight a newer state:
            // only a still-.run status wants the stream back.
            guard gobanState.analysisStatus == .run else { return }
            reanalyze()
        }
    }

    /// One cycle ended (phase == .awaitingMove): the per-cycle policy gate.
    private func continueReplay() {
        guard isAutoPlaying, let broadcast = replayBroadcast,
              broadcast.phase == .awaitingMove else { return }
        switch TVAutoPlayPolicy.tick(
            hasNextMove: gobanState.getNextMove(gameRecord: game) != nil,
            isBranchActive: gobanState.isBranchActive,
            stonesReady: stones.isReady,
            recordedGameIsFinished: recordedIsFinished,
            thermalState: ProcessInfo.processInfo.thermalState
        ) {
        case .advance:
            broadcast.noteTurnChanged(game: game)
        case .hold:
            break   // the stones.isReady onChange re-enters
        case .finish(let continuesLive):
            finishAutoPlay(continuesLive: continuesLive)
        case .stop:
            // The reason is the policy's testable output, not something this
            // screen acts on differently.
            stopAutoPlay()
        }
    }

    /// The replay's move source: play the next recorded move and hand back
    /// the synced comment for the position it lands on (nil = none). The
    /// comment index is computed BEFORE the advance — the GTP round-trip
    /// updates indices asynchronously.
    private func advanceReplayMove() -> String? {
        let nextIndex = (gobanState.getCurrentIndex(gameRecord: game) ?? game.currentIndex) + 1
        gobanState.forwardMoves(limit: 1, gameRecord: game, board: board,
                                messageList: messageList, player: player,
                                audioModel: audioModel, stones: stones)
        let comment = game.comments?[nextIndex]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (comment?.isEmpty == false) ? comment : nil
    }

    /// Reached the end of the recorded moves. An unfinished game hands off to a
    /// live AI continuation after a short announced beat; a game that already
    /// ended just stops on its final position (continuing it would seed the
    /// engine with a position it answers by passing twice).
    private func finishAutoPlay(continuesLive: Bool) {
        // Re-entrancy guard, FIRST statement: both the panel's Auto-Play
        // toggle and the remote's Play/Pause stay live during the beat, and
        // either one calls toggleAutoPlay() → startAutoPlay(), which sees
        // isAutoPlaying == false and no next move and lands right back here.
        // Without this guard a second call reassigns handoffTask to a new
        // task and orphans the first one — onDisappear can only cancel the
        // CURRENT handle, so the orphaned task still fires ~2 s later and
        // pushes onContinueLive from a screen the user has already left.
        guard !isHandingOff else { return }
        // The tick policy's thermal stop cannot cover this path: it refuses to
        // ADVANCE under .serious/.critical, so a running replay never reaches
        // the end while hot — but Play/Pause pressed while already parked at
        // the last recorded move lands here directly, and a live broadcast is
        // the heaviest workload the box runs. Refuse instead of pushing it.
        guard !SelfPlayAttract.shouldStop(thermalState: ProcessInfo.processInfo.thermalState) else {
            stopAutoPlay()
            return
        }
        stopAutoPlay()
        guard continuesLive,
              let onContinueLive,
              let seed = makeSeed() else { return }
        isHandingOff = true
        handoffTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(TVAutoPlayPolicy.handoffBeatSeconds))
            guard !Task.isCancelled else { return }
            isHandingOff = false
            // Cleared BEFORE the push, not left to onDisappear: SwiftUI fires
            // the destination's onAppear first, and TVSelfPlayScreen's entry
            // points the selection at its own seeded record.
            navigationContext.selectedGameRecord = nil
            onContinueLive(seed)
            // The handle must not outlive its task now that the push landed.
            handoffTask = nil
        }
    }

    /// The value the continuation starts from. Nil while a variation is active
    /// — a branch means the synced record is already selected and the printsgf
    /// routing depends on flags the self-play entry clears.
    private func makeSeed() -> SelfPlaySeed? {
        guard !gobanState.isBranchActive else { return nil }
        return SelfPlaySeed(sgf: game.sgf,
                            moveCount: totalMoves,
                            rule: config.rule,
                            name: game.name.isEmpty ? SelfPlayGame.demoName : game.name,
                            scoreLeads: game.scoreLeads ?? [:],
                            winRates: game.winRates ?? [:])
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

/// The Auto-Play transport. Icon-only, and NOT greedy, so it fits beside the
/// Analysis toggle in the panel's single control row — two full-width toggles
/// stacked overflowed the then-1020 pt panel by 46 pt (measured on tvOS 26.5),
/// and `minHeight` cannot fix that because the bordered style floors a pill at
/// 66 pt. One row costs zero extra height. The panel is now 1000 pt tall
/// (TVBoardLayout.panelHeight), i.e. 20 pt LESS, so stacking them would
/// overflow by ~66 pt — the single row is more necessary, not less. Widening
/// the panel to 752 pt buys nothing here: the overflow is vertical.
///
/// The SYMBOL carries the state (play → pause), so there is no "On/Off" label
/// to shrink; `accessibilityLabel` is what names the control for VoiceOver.
/// Styling otherwise mirrors TVToggleButton so the two pills read as a set.
private struct TVIconToggleButton: View {
    let systemName: String
    let accessibilityLabel: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        let content = Image(systemName: systemName)
            .font(.title3)
            // A fixed 36 pt width (min == max) is what makes this one NOT
            // greedy, unlike TVToggleButton's `maxWidth: .infinity`; the
            // height stays a minimum so the glyph is never squeezed.
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

/// One color's panel row: stone glyph, captured count, player label. The
/// count sits beside the stone as "xN" — the iOS captured-strip idiom
/// (StoneView.drawCapturedStones) — replacing a trailing "captured N"
/// sentence that truncated once the count grew, back when this panel was only
/// 500 pt wide. The panel is 752 pt now (TVBoardLayout.panelWidth), but the
/// compact form stays: it is the shared idiom with the self-play screen, which
/// reuses this row (hence internal, not private), and a long player name still
/// has to give way to the count.
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
            .environment(session)
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
            // Required since the screen subscribes to it — a preview without
            // it traps at runtime resolving the @Environment.
            .environment(TVControllerInput())
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
