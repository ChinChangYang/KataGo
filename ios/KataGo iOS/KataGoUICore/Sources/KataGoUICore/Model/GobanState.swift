//
//  GobanState.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/11/17.
//

import SwiftUI
import SwiftData
import GoRulesKit

/// "The engine owes this position a feed." Stashed by `GobanState` whenever a
/// send was DROPPED because no engine was listening, and drained by
/// `resyncEngineAfterHandshake` once one is.
///
/// The payload is diagnostic: the resync always feeds the LIVE selection at the
/// LIVE index, because the user may have switched games four times while the
/// model compiled. What the payload proves is that a feed is owed at all.
public struct EngineSyncRequest: Equatable, Sendable {
    public let recordID: PersistentIdentifier?
    public let index: Int

    public init(recordID: PersistentIdentifier?, index: Int) {
        self.recordID = recordID
        self.index = index
    }
}

@Observable
public class GobanState {
    public init() {}

    /// Deferred engine feeds. `ReadinessGate` is reused verbatim from the macOS
    /// cold-launch deep-link path (`KataGoGameStore/ReadinessGate.swift`): last
    /// request wins, and draining is one-shot so a later readiness cycle cannot
    /// replay it.
    public var engineSyncGate = ReadinessGate<EngineSyncRequest>()

    /// True when the record on screen is one the C++ SGF parser rejected: no
    /// position could be replayed from it, so the board shows an empty grid and
    /// the engine is fed nothing. A RECORD state, not an engine state — hence a
    /// flag here rather than a sixth `EngineAvailability` case. Written by
    /// `RecordPositionProjector`, the one thing that knows whether a projection
    /// succeeded.
    public var isRecordUnreadable = false

    public var waitingForAnalysis = false
    public var requestingClearAnalysis = false
    public var analysisStatus = AnalysisStatus.run
    public var showBoardCount: Int = 0
    public var isEditing = false
    /// Set by `commitBranch` so the board reload it triggers (via branch
    /// deactivation) lands in unlocked (editing) mode — replacing the original
    /// game with the branch is an explicit edit. Consumed (reset) by `loadGame`.
    public var unlockEditingOnReload = false
    public var isShownBoard: Bool = false
    public var eyeStatus = EyeStatus.opened
    public var isAutoPlaying: Bool = false
    public var passCount: Int = 0
    /// The largest board length the RUNNING engine can serve — its Max Board
    /// Size / NN buffer. `loadGame` refuses to feed a record wider or taller
    /// than this (the engine aborts fatally on the first analysis of an
    /// oversized board); the board itself still draws, because the board never
    /// waits for the engine.
    ///
    /// nil = not known yet, which is treated as "fits": C4 wires the launched
    /// value in from `EngineStatus.launchedMaxBoardLength`, and until then
    /// nothing must start refusing to feed.
    public var engineMaxBoardLength: Int? = nil
    /// When true, a side whose config says "engine plays" (maxTime > 0) still
    /// gets plain continuous analysis instead of a gen-move — the whole screen
    /// is a spectator. The tvOS review screen sets it (a synced game configured
    /// AI-vs-AI on another device must not start playing itself when merely
    /// reviewed on TV); the tvOS self-play screen clears it. Transient view
    /// state, never persisted; defaults false so iOS/macOS are unchanged.
    public var suppressesGenMove = false
    /// While true, the per-turn asymmetric human-SL command bundles are not
    /// sent. The tvOS review REPLAY sets this for its broadcast's lifetime:
    /// a synced Human-vs-9d config is asymmetric, and the bundle's `=`/`?`
    /// acks landing between a report cycle's probes would desync the
    /// ReportCollector FIFO (see BroadcastController's header). Default
    /// false — iOS/macOS/visionOS behavior is untouched.
    public var suppressesHumanSLTurnCommands = false
    /// The tvOS broadcast's one-shot gen-move license. The broadcast keeps
    /// `suppressesGenMove` true for its whole lifetime (the turn observer
    /// must never free-run the game), so its single per-cycle gen-move reply
    /// would be dropped by postProcessAIMove's guard — this flag licenses
    /// exactly one reply through it; postProcessAIMove consumes it.
    public var broadcastGenMovePending = false
    /// Gate for the tvOS root's analysisStatus observer: it sends the GTP
    /// "stop" whenever the status transitions to .clear, but SwiftUI's
    /// onChange fires one MainActor update pass AFTER the write — by then
    /// issueGenMove has already sent the licensed
    /// kata-search_analyze_cancellable, and a trailing "stop" would cancel
    /// it (the engine prints "play cancelled", no stone lands, and the
    /// broadcast parks in .awaitingMove forever — the pause→resume stall).
    /// Sound because the .clear flip and the license arm execute in the
    /// same synchronous MainActor job (issueGenMove →
    /// requestBroadcastGenMove): whenever the observer fires for that
    /// flip, the license is still armed. If requestBroadcastGenMove
    /// early-returns without arming (unknown side, maxTime 0), this stays
    /// true and the stop goes out — safe degradation.
    public var shouldStopEngineOnAnalysisClear: Bool { !broadcastGenMovePending }
    /// tvOS: stream continuous kata-analyze at `config.analysisInterval`
    /// instead of the fast 0.1 s first-report interval. iOS/macOS keep
    /// fastAnalyzeCommand plus their own re-arm at the config interval
    /// (GameSplitView / MainWindowController); defaults false so their
    /// command stream is byte-identical.
    public var continuousAnalysisUsesConfigInterval = false
    /// tvOS review: every locked-game play starts (or extends) a branch, even
    /// one that matches the next recorded move — the mainline shortcut would
    /// advance the synced record's `currentIndex`, and TV picks must never
    /// write a synced record (variations are discarded silently on exit).
    /// Defaults false so the iOS/macOS mainline-step behavior is unchanged.
    public var forcesBranchOnPlay = false
    /// True while a Deep Analysis Report is probing the engine. GameSession
    /// bypasses live-analysis collection for `info` lines (probe replies are
    /// consumed via `lineObserver` by the report's collector instead), so the
    /// board overlay, charts, and the `waitingForAnalysis` edge machinery stay
    /// frozen mid-report. Menu/board interaction gates on it belt-and-suspenders
    /// (the modal report sheet is the primary lock). Transient; never persisted.
    public var reportGenerationActive = false
    /// iPad full-screen board mode: hides the chart/comments pane so the board
    /// takes all the space it can. Toggled by the diagonal-arrows button in the
    /// game toolbar (iPad only, so every other platform keeps this false and is
    /// unchanged). Transient view state, never persisted — the user's
    /// `showCharts`/`showComments` settings are untouched, so exiting restores
    /// exactly the prior pane state.
    public var isBoardFullScreen = false
    public var branchSgf: String = .inActiveSgf
    public var branchIndex: Int = .inActiveCurrentIndex
    public var confirmingAIOverwrite: Bool = false
    public var pendingMoveTurn: String? = nil
    public var pendingMoveVertex: String? = nil
    public var confirmingIllegalMove: Bool = false
    public var confirmingBranchDeactivation: Bool = false
    public var confirmingBranchReplace: Bool = false
    public var confirmingBranchDiscard: Bool = false
    public var illegalMoveReason: String? = nil
    public var pendingMoveTimestamp: Date? = nil
    public var soundEffect: Bool = false
    public var hapticFeedback: Bool = false
    public var showVisitsPerSecond: Bool = false

    // App-wide display preferences. These mirror GlobalSettings.* @AppStorage
    // (synced in GameSplitView) so they apply across all games instead of being
    // stored per-game. The matching Config fields are now unused — left in place
    // because the SwiftData model must not change. Defaults reuse the Config
    // constants to preserve the previous behavior exactly.
    public var showCoordinate: Bool = Config.defaultShowCoordinate
    public var showPass: Bool = Config.defaultShowPass
    public var verticalFlip: Bool = Config.compatibleVerticalFlip
    public var showOwnership: Bool = Config.defaultShowOwnership
    public var showWinrateBar: Bool = Config.defaultShowWinrateBar
    public var showCharts: Bool = Config.defaultShowCharts
    public var showComments: Bool = Config.defaultShowComments
    public var stoneStyle: Int = Config.defaultStoneStyle
    public var analysisStyle: Int = Config.defaultAnalysisStyle
    public var analysisInformation: Int = Config.defaultAnalysisInformation
    public var moveNumberStyle: Int = Config.defaultMoveNumberStyle

    /// Whether the chart/comments pane above the board should be shown: the
    /// user wants it (settings) AND full-screen mode isn't overriding it.
    public var isInfoPaneVisible: Bool {
        (showCharts || showComments) && !isBoardFullScreen
    }

    @ObservationIgnored private var nextMoveCacheKey: (String, Int)? = nil
    @ObservationIgnored private var nextMoveCacheResult: Move? = nil
    @ObservationIgnored private var moveNumbersCacheKey: (String, Int, Int)? = nil
    @ObservationIgnored private var moveNumbersCacheResult: MoveNumbers = .empty
    @ObservationIgnored private var lastPlayedVertexCacheKey: (String, Int)? = nil
    @ObservationIgnored private var lastPlayedVertexCacheResult: String? = nil

    public func sendShowBoardCommand(messageList: MessageList) {
        // Count only the showboards that actually go out. `appendAndSend` drops
        // commands while the engine is unavailable, and an uncounted-but-
        // incremented showboard would leave `showBoardCount` permanently above
        // zero — which is the condition that says "the engine has not caught up
        // yet", so every later ack would be treated as an intermediate one and
        // the board would never report in sync again.
        //
        // The decision is `appendAndSend`'s return value, NOT a pre-flight
        // check on the gate: going through it is what puts the drop in the
        // transcript, and a showboard that vanished with no trace is exactly
        // the drop hardest to diagnose later ("the board never went in sync").
        guard messageList.appendAndSend(command: "showboard") else { return }
        showBoardCount = showBoardCount + 1
    }

    public func consumeShowBoardResponse(response: String) -> Bool {
        if response.hasPrefix("= MoveNum") {
            // Clamp at zero: a stray response (count desync) must parse as a
            // harmless extra board, not push the count negative and silently
            // drop every future board parse.
            showBoardCount = max(0, showBoardCount - 1)
            isShownBoard = true
            return showBoardCount == 0
        } else {
            return false
        }
    }

    func getRequestAnalysisCommands(config: Config, nextColorForPlayCommand: PlayerColor?) -> [String] {

        if (analysisStatus == .run) && (!isAutoPlaying) && (!suppressesGenMove) && (passCount < 2) {
            if (nextColorForPlayCommand == .black) && (config.blackMaxTime > 0) {
                return GtpCommandBuilder.genMoveAnalyzeCommands(effectiveProfile: config.effectiveHumanProfileForBlack, maxTime: config.blackMaxTime, interval: config.analysisInterval, maxMoves: config.maxAnalysisMoves)
            } else if (nextColorForPlayCommand == .white) && (config.whiteMaxTime > 0) {
                return GtpCommandBuilder.genMoveAnalyzeCommands(effectiveProfile: config.effectiveHumanProfileForWhite, maxTime: config.whiteMaxTime, interval: config.analysisInterval, maxMoves: config.maxAnalysisMoves)
            }
        }

        // Continuous analysis: the bundle embeds the maxVisits reset so a
        // prior human gen-move's maxVisits=400 never leaks into (and caps)
        // analysis — structural, not a per-site convention.
        return continuousAnalysisUsesConfigInterval
            ? GtpCommandBuilder.continuousAnalyzeCommands(interval: config.analysisInterval, maxMoves: config.maxAnalysisMoves)
            : GtpCommandBuilder.fastContinuousAnalyzeCommands(maxMoves: config.maxAnalysisMoves)
    }

    public func requestAnalysis(config: Config, messageList: MessageList, nextColorForPlayCommand: PlayerColor?) {
        let commands = getRequestAnalysisCommands(config: config, nextColorForPlayCommand: nextColorForPlayCommand)
        messageList.appendAndSend(commands: commands)
        waitingForAnalysis = true
    }

    /// Issue the broadcast's single gen-move for the side to move. Mirrors
    /// getRequestAnalysisCommands' gen-move branch but bypasses the
    /// suppressesGenMove gate via the one-shot license instead of clearing it
    /// (which would re-enter the free-running loop at the next turn change).
    public func requestBroadcastGenMove(config: Config,
                                        messageList: MessageList,
                                        nextColorForPlayCommand: PlayerColor?) {
        guard passCount < 2 else { return }
        let commands: [String]
        if nextColorForPlayCommand == .black, config.blackMaxTime > 0 {
            commands = GtpCommandBuilder.genMoveAnalyzeCommands(
                effectiveProfile: config.effectiveHumanProfileForBlack,
                maxTime: config.blackMaxTime,
                interval: config.analysisInterval,
                maxMoves: config.maxAnalysisMoves)
        } else if nextColorForPlayCommand == .white, config.whiteMaxTime > 0 {
            commands = GtpCommandBuilder.genMoveAnalyzeCommands(
                effectiveProfile: config.effectiveHumanProfileForWhite,
                maxTime: config.whiteMaxTime,
                interval: config.analysisInterval,
                maxMoves: config.maxAnalysisMoves)
        } else {
            return
        }
        broadcastGenMovePending = true
        messageList.appendAndSend(commands: commands)
        waitingForAnalysis = true
    }

    public func maybeRequestAnalysis(
        config: Config,
        nextColorForPlayCommand: PlayerColor?,
        messageList: MessageList
    ) {
        if (shouldRequestAnalysis(config: config, nextColorForPlayCommand: nextColorForPlayCommand)) {
            requestAnalysis(config: config,
                            messageList: messageList,
                            nextColorForPlayCommand: nextColorForPlayCommand)
        }
    }

    public func maybeRequestAnalysis(
        config: Config,
        messageList: MessageList
    ) {
        return maybeRequestAnalysis(
            config: config,
            nextColorForPlayCommand: nil,
            messageList: messageList)
    }

    public func shouldRequestAnalysis(config: Config, nextColorForPlayCommand: PlayerColor?) -> Bool {
        if let nextColorForPlayCommand {
            return (analysisStatus != .clear)
                && config.isAnalysisForCurrentPlayer(nextColorForPlayCommand: nextColorForPlayCommand)
                && !isAnalysisHiddenForPowerSaving(config: config, nextColorForPlayCommand: nextColorForPlayCommand)
        } else {
            return (analysisStatus != .clear)
        }
    }

    /// True when the on-board analysis overlay (`AnalysisView`) is rendering.
    /// Single source of truth for "is analysis visible on the board", so overlays
    /// layered on top of `BoardView` — the macOS hover preview — cannot drift from
    /// what `AnalysisView` itself shows. This is overlay VISIBILITY, not engine
    /// state: the eye hides the overlay without stopping analysis (and on macOS
    /// `isAnalysisHiddenForPowerSaving` is a no-op, so analysis really does keep
    /// running behind a closed eye).
    ///
    /// Deliberately excludes `isAnalysisInformationNone`: the overlay still draws
    /// the ownership heatmap under this gate when Information = None. Callers that
    /// only care about the per-move win%/score TEXT add that term themselves.
    public func isAnalysisOverlayVisible(config: Config,
                                         nextColorForPlayCommand: PlayerColor?) -> Bool {
        return shouldRequestAnalysis(config: config, nextColorForPlayCommand: nextColorForPlayCommand)
            && (eyeStatus == .opened)
            && !isAutoPlaying
    }

    /// Continuous analysis is hidden AND pointless to run, so it can be paused
    /// to save power: a human-vs-AI game (exactly one side has a positive
    /// per-move thinking time), the analysis overlay is not visible
    /// (eye `.book`/`.closed`), and it is the human's turn. The AI's own turn is
    /// never suppressed — the engine must still `genmove` — and both-human /
    /// both-AI games are unaffected. No-op on macOS, whose always-on analysis is
    /// intentionally left unchanged.
    public func isAnalysisHiddenForPowerSaving(config: Config,
                                               nextColorForPlayCommand: PlayerColor?) -> Bool {
        #if os(macOS)
        return false
        #else
        guard eyeStatus != .opened, let nextColorForPlayCommand else { return false }
        switch nextColorForPlayCommand {
        case .black: return config.blackMaxTime == 0 && config.whiteMaxTime > 0
        case .white: return config.whiteMaxTime == 0 && config.blackMaxTime > 0
        case .unknown: return false
        }
        #endif
    }

    /// Stop a running analysis when the overlay has just been hidden in the
    /// power-saving case. The continuous-analysis loop only sends "stop" on a
    /// `waitingForAnalysis` true→false edge, which does not occur on its own
    /// while `kata-analyze` streams; forcing the flag true makes the next
    /// streamed line drive that edge (the same trick `maybePauseAnalysis()`
    /// uses), without disturbing the user's `analysisStatus` intent. No-op on
    /// macOS, where `isAnalysisHiddenForPowerSaving` returns false.
    public func maybeStopAnalysisForPowerSaving(config: Config, nextColorForPlayCommand: PlayerColor?) {
        if (analysisStatus == .run) &&
            isAnalysisHiddenForPowerSaving(config: config, nextColorForPlayCommand: nextColorForPlayCommand) {
            waitingForAnalysis = true
        }
    }

    public func maybeRequestClearAnalysisData(config: Config, nextColorForPlayCommand: PlayerColor?) {
        if !shouldRequestAnalysis(config: config, nextColorForPlayCommand: nextColorForPlayCommand) {
            requestingClearAnalysis = true
        }
    }

    public func maybeRequestClearAnalysisData(config: Config) {
        maybeRequestClearAnalysisData(config: config, nextColorForPlayCommand: nil)
    }

    public func maybePauseAnalysis() {
        if analysisStatus == .run {
            analysisStatus = .pause
            waitingForAnalysis = true
        }
    }

    /// Re-arm live analysis after a Deep Report closes. The report's probes
    /// cancel the user's live `kata-analyze` and its restore intentionally does
    /// NOT re-arm (so nothing runs under the still-open sheet), leaving the
    /// engine idle. Called unconditionally on dismissal: it re-arms only when
    /// analysis is enabled (`.run`) — which also revives a human-vs-AI opponent
    /// (gated on `.run` via `shouldGenMove`) — and leaves paused/off untouched.
    /// The report never changes `analysisStatus`, so `.run` here means analysis
    /// was running when the report opened.
    public func resumeAnalysisAfterReport(config: Config,
                                          nextColorForPlayCommand: PlayerColor?,
                                          messageList: MessageList) {
        guard analysisStatus == .run else { return }
        maybeRequestAnalysis(config: config,
                             nextColorForPlayCommand: nextColorForPlayCommand,
                             messageList: messageList)
    }

    public func shouldGenMove(config: Config, player: Turn) -> Bool {
        if (!isAutoPlaying) &&
            (!suppressesGenMove) &&
            (analysisStatus == .run) &&
            (passCount < 2) &&
            (((config.blackMaxTime > 0) && (player.nextColorForPlayCommand == .black)) ||
             ((config.whiteMaxTime > 0) && (player.nextColorForPlayCommand == .white))) {
            // One of black and white is enabled for AI play.
            return true
        } else {
            // All of black and white are disabled for AI play.
            return false
        }
    }

    public func sendPostExecutionCommands(
        config: Config,
        messageList: MessageList,
        player: Turn
    ) {
        sendShowBoardCommand(messageList: messageList)

        maybeRequestAnalysis(
            config: config,
            nextColorForPlayCommand: player.nextColorForPlayCommand,
            messageList: messageList
        )

        maybeRequestClearAnalysisData(config: config,
                                      nextColorForPlayCommand: player.nextColorForPlayCommand)
    }

    private func generateConditionalStonesText(
        analysis: Analysis,
        board: BoardSize,
        boardPoints: [BoardPoint],
        condition: (OwnershipUnit) -> Bool
    ) -> String? {
        guard !analysis.ownershipUnits.isEmpty else {
            return nil
        }

        let points = boardPoints.filter { point in
            if let ownershipUnit = analysis.ownershipUnits.first(where: { $0.point == point }) {
                return condition(ownershipUnit)
            } else {
                return false
            }
        }

        if let text = BoardPoint.toString(
            points,
            width: Int(board.width),
            height: Int(board.height)
        ) {
            return text
        } else {
            return "None"
        }
    }

    /// The identity of the position this state is currently displaying, or nil
    /// when there is nothing to display. Built from the same three sources the
    /// board reads — the active line's SGF, its index, and whether that line is
    /// a branch — so an equal key means an identical board.
    public func recordPositionKey(gameRecord: GameRecord?) -> RecordPositionKey? {
        guard let sgf = getSgf(gameRecord: gameRecord),
              let currentIndex = getCurrentIndex(gameRecord: gameRecord) else { return nil }
        return RecordPositionKey(recordID: gameRecord?.persistentModelID,
                                 sgf: sgf,
                                 index: currentIndex,
                                 isBranchActive: isBranchActive)
    }

    public func maybeUpdateAnalysisData(
        gameRecord: GameRecord,
        analysis: Analysis,
        board: BoardSize,
        stones: Stones,
        all: Bool = true
    ) {
        // Per-index analysis is only ever written for a position that is BOTH
        // acknowledged by the engine and the one these numbers were collected
        // for. Navigating twice before an ack arrives used to stamp the first
        // position's win rate onto the second index.
        guard stones.isReady,
              analysis.collectedForKey == recordPositionKey(gameRecord: gameRecord) else {
            return
        }

        if isEditing && (analysisStatus != .clear) {
            let currentIndex = gameRecord.currentIndex

            if let scoreLead = analysis.blackScore {
                withAnimation(.spring) {
                    gameRecord.scoreLeads?[currentIndex] = scoreLead
                }
            }

            if let bestMove = analysis.getBestMove(
                width: Int(board.width),
                height: Int(board.height)
            ) {
                gameRecord.bestMoves?[currentIndex] = bestMove
            }
            
            if let winRate = analysis.blackWinrate {
                gameRecord.winRates?[currentIndex] = winRate
            }

            let width = Int(board.width)
            let height = Int(board.height)
            var ownershipWhiteness: [Float] = Array(repeating: 0.5, count: width * height)
            var ownershipScales: [Float] = Array(repeating: 0.0, count: width * height)

            for ownershipUnit in analysis.ownershipUnits {
                if let coordinate = Coordinate(
                    x: ownershipUnit.point.x,
                    y: ownershipUnit.point.y + 1,
                    width: width,
                    height: height
                ) {
                    let index = coordinate.index
                    ownershipWhiteness[index] = ownershipUnit.whiteness
                    ownershipScales[index] = ownershipUnit.scale
                }
            }

            gameRecord.ownershipWhiteness?[currentIndex] = ownershipWhiteness
            gameRecord.ownershipScales?[currentIndex] = ownershipScales

            // Bound the persisted ownership so a long analyzed game can't grow
            // this GameRecord past CloudKit's ~1 MB per-record limit and wedge
            // iCloud sync. The schema is frozen, so we cap the data (evict the
            // oldest move-indices) rather than the field's storage class. Only
            // re-assign when something was actually evicted, to avoid dirtying
            // the record (and re-uploading) on every analyzed move.
            // See OwnershipBudget / project_mac_icloud_list_live_refresh.
            if let whiteness = gameRecord.ownershipWhiteness,
               let scales = gameRecord.ownershipScales {
                let trimmed = OwnershipBudget.pruned(
                    whiteness: whiteness,
                    scales: scales,
                    pointsPerMove: width * height,
                    keeping: currentIndex
                )
                if trimmed.whiteness.count != whiteness.count {
                    gameRecord.ownershipWhiteness = trimmed.whiteness
                    gameRecord.ownershipScales = trimmed.scales
                }
            }
        }
    }

    public func maybeSendAsymmetricHumanAnalysisCommands(nextColorForPlayCommand: PlayerColor,
                                                  config: Config,
                                                  messageList: MessageList) {
        if !config.isEqualBlackWhiteEffectiveHumanSettings && !isAutoPlaying
            && !suppressesHumanSLTurnCommands {
            if nextColorForPlayCommand == .black,
               let humanSLModel = HumanSLModel(profile: config.effectiveHumanProfileForBlack) {
                messageList.appendAndSend(commands: humanSLModel.commands)
            } else if nextColorForPlayCommand == .white,
                      let humanSLModel = HumanSLModel(profile: config.effectiveHumanProfileForWhite) {
                messageList.appendAndSend(commands: humanSLModel.commands)
            }
        }
    }

    /// The side to move changed: re-establish that side's human-SL profile,
    /// ask for whatever should stream next (the gen-move bundle on an AI turn,
    /// otherwise continuous analysis), and clear stale overlay data when
    /// nothing will stream.
    ///
    /// Extracted from `BoardView`'s `.onChange(of: player.nextColorForPlayCommand)`
    /// so the visionOS root — which never mounts `BoardView` and had to carry a
    /// hand-copied duplicate of the same three calls — runs the same code. This
    /// is also the path that re-arms analysis after a game load: the load parks
    /// the turn at `.unknown`, and the feed's `showboard` reply resolves it to a
    /// colour, which lands here.
    public func handleTurnChange(to newColor: PlayerColor,
                                 config: Config,
                                 messageList: MessageList) {
        maybeSendAsymmetricHumanAnalysisCommands(nextColorForPlayCommand: newColor,
                                                 config: config,
                                                 messageList: messageList)
        maybeRequestAnalysis(config: config,
                             nextColorForPlayCommand: newColor,
                             messageList: messageList)
        maybeRequestClearAnalysisData(config: config, nextColorForPlayCommand: newColor)
    }

    public func sendCheckMoveCommand(turn: String, move: String, messageList: MessageList) {
        pendingMoveTurn = turn
        pendingMoveVertex = move
        pendingMoveTimestamp = Date()
        messageList.appendAndSend(command: "kata-check-move \(turn) \(move)")
    }

    public func clearPendingMove() {
        pendingMoveTurn = nil
        pendingMoveVertex = nil
        pendingMoveTimestamp = nil
        confirmingIllegalMove = false
        illegalMoveReason = nil
    }

    private static let pendingMoveTimeout: TimeInterval = 5.0

    public var isPendingMoveStale: Bool {
        guard pendingMoveTurn != nil, let timestamp = pendingMoveTimestamp else {
            return false
        }
        return Date().timeIntervalSince(timestamp) > GobanState.pendingMoveTimeout
    }

    public func resetPendingStatesOnError(stones: Stones) {
        clearPendingMove()
        waitingForAnalysis = false
        stones.isReady = true
    }

    public func playPendingHumanMove(
        gameRecord: GameRecord,
        analysis: Analysis,
        board: BoardSize,
        stones: Stones,
        messageList: MessageList,
        player: Turn,
        audioModel: AudioModel
    ) {
        guard let turn = pendingMoveTurn,
              let move = pendingMoveVertex else { return }

        // forcesBranchOnPlay outranks isEditing: the tvOS review screen must
        // never take the editing path (it truncates the record and lets
        // printsgf overwrite the synced SGF) even if a defaultSgf game
        // slipped through loadGame unlocked.
        if isEditing && !forcesBranchOnPlay {
            gameRecord.clearData(after: gameRecord.currentIndex)

            maybeUpdateAnalysisData(
                gameRecord: gameRecord,
                analysis: analysis,
                board: board,
                stones: stones
            )
        } else if !isBranchActive {
            if !forcesBranchOnPlay,
               matchesNextRecordedMove(turn: turn, move: move, gameRecord: gameRecord, board: board) {
                playMainlineStep(turn: turn, move: move, gameRecord: gameRecord, stones: stones, messageList: messageList, player: player, audioModel: audioModel)
                clearPendingMove()
                return
            }

            branchSgf = gameRecord.sgf
            branchIndex = gameRecord.currentIndex
        }

        play(turn: turn, move: move, messageList: messageList, stones: stones)
        player.toggleNextColorForPlayCommand()
        // `printsgf` BEFORE `showboard`: the record owns the board, so the
        // reply that updates the record (and therefore puts the stone on
        // screen) has to land before the sync ack that says the engine caught
        // up. GTP replies are FIFO, so ordering the sends orders the replies.
        messageList.appendAndSend(command: "printsgf")
        sendShowBoardCommand(messageList: messageList)
        audioModel.playPlaySound(soundEffect: soundEffect)

        clearPendingMove()
    }

    public func play(turn: String, move: String, messageList: MessageList, stones: Stones) {
        stones.isReady = false
        messageList.appendAndSend(command: "play \(turn) \(move)")

        if move == "pass" {
            passCount = passCount + 1
        } else {
            passCount = 0
        }
    }

    public func playAIMove(
        aiMove: String?,
        gameRecord: GameRecord,
        turn: String,
        analysis: Analysis,
        board: BoardSize,
        stones: Stones,
        messageList: MessageList,
        player: Turn,
        audioModel: AudioModel
    ) {
        guard let aiMove = aiMove else { return }

        // Same review guard as playPendingHumanMove: never the editing path
        // while the spectator screen forces branches.
        if isEditing && !forcesBranchOnPlay {
            gameRecord.clearData(after: gameRecord.currentIndex)

            maybeUpdateAnalysisData(
                gameRecord: gameRecord,
                analysis: analysis,
                board: board,
                stones: stones
            )
        } else if !isBranchActive {
            if !forcesBranchOnPlay,
               matchesNextRecordedMove(turn: turn, move: aiMove, gameRecord: gameRecord, board: board) {
                playMainlineStep(turn: turn, move: aiMove, gameRecord: gameRecord, stones: stones, messageList: messageList, player: player, audioModel: audioModel)
                return
            }

            branchSgf = gameRecord.sgf
            branchIndex = gameRecord.currentIndex
        }

        play(turn: turn, move: aiMove, messageList: messageList, stones: stones)
        player.toggleNextColorForPlayCommand()
        // `printsgf` before `showboard` — see `playPendingHumanMove`.
        messageList.appendAndSend(command: "printsgf")
        sendShowBoardCommand(messageList: messageList)
        audioModel.playPlaySound(soundEffect: soundEffect)
    }

    public func undo(messageList: MessageList, stones: Stones) {
        stones.isReady = false
        messageList.appendAndSend(command: "undo")

        if passCount > 0 {
            passCount = passCount - 1
        }
    }

    public var isBranchActive: Bool {
        return (branchSgf.isActiveSgf) && (branchIndex.isActiveSgfIndex)
    }

    public func deactivateBranch() {
        branchSgf = .inActiveSgf
        branchIndex = .inActiveCurrentIndex
    }

    /// Replaces the saved game with the active branch line. Per-index data
    /// past the divergence point (where the original and branch lines stop
    /// sharing moves) is dropped; clearData must run before currentIndex is
    /// reassigned because gameRecord.currentIndex IS the divergence point
    /// while a branch is active (branch navigation moves branchIndex only).
    /// Also unlocks editing (`isEditing = true`): choosing to replace the
    /// original game is an explicit intent to change it.
    public func commitBranch(gameRecord: GameRecord) {
        guard isBranchActive else { return }

        gameRecord.clearData(after: gameRecord.currentIndex)
        gameRecord.sgf = branchSgf
        gameRecord.currentIndex = branchIndex
        gameRecord.lastModificationDate = Date.now
        // Replacing the original game with the branch is an explicit edit, so
        // unlock the game (a branch only ever forms while isEditing == false).
        // Two writes are deliberate, not redundant:
        //   * `isEditing = true` is the immediate post-condition (and a guard
        //     for any future caller that commits without a reload).
        //   * `unlockEditingOnReload` is what SURVIVES the reload that the
        //     deactivateBranch() below triggers: flipping branchSgf inactive
        //     drives loadGame — the last writer of isEditing — which would
        //     otherwise relock this (now non-default) game.
        isEditing = true
        unlockEditingOnReload = true
        deactivateBranch()
    }

    /// Clones the game truncated to the position currently on screen. When a
    /// branch is active the viewed line is `branchSgf`/`branchIndex` (not the
    /// saved `gameRecord.sgf`/`currentIndex`, which stay frozen at the
    /// divergence point), so clone from the live branch line; per-index data is
    /// only valid up to the divergence point (`gameRecord.currentIndex`), as in
    /// `commitBranch`. Off-branch it is the saved mainline position.
    public func cloneCurrentPosition(gameRecord: GameRecord) -> GameRecord {
        if isBranchActive {
            return gameRecord.clone(
                upToMove: branchIndex,
                fromSgf: branchSgf,
                dataValidUpTo: min(gameRecord.currentIndex, branchIndex)
            )
        } else {
            return gameRecord.clone(upToMove: gameRecord.currentIndex)
        }
    }

    /// The earliest index navigation may reach: the divergence while a branch is
    /// active (gameRecord.currentIndex stays frozen there), else 0. Stepping
    /// below it would undo pre-branch moves that belong to the saved mainline.
    ///
    /// Nil-record-with-active-branch is unreachable: every navigation caller
    /// guards a non-nil record before consulting the floor. The `?? 0` fallback
    /// therefore never fires in practice, and it deliberately differs from
    /// `getMoveNumbers`' nil-record fallback (which uses `currentIndex`, yielding
    /// empty branch numbering) — neither fallback is load-bearing. They are NOT
    /// interchangeable: naively aligning this floor to the cursor would freeze
    /// navigation (the floor would equal the cursor, so `canStepBackward` /
    /// `undoIndex` could never step), so the 0 default must stay as-is.
    public func navigationFloor(gameRecord: GameRecord?) -> Int {
        isBranchActive ? (gameRecord?.currentIndex ?? 0) : 0
    }

    /// Whether navigation may step one move back from the cursor: a recorded
    /// move exists behind it AND it sits above the floor. Callers that send the
    /// engine `undo` THEMSELVES (rather than routing through backwardMoves) must
    /// gate on this — at the branch floor the engine still holds the pre-branch
    /// moves it would undo, so an ungated `undo` desyncs board vs engine.
    public func canStepBackward(gameRecord: GameRecord?) -> Bool {
        guard let sgf = getSgf(gameRecord: gameRecord),
              let currentIndex = getCurrentIndex(gameRecord: gameRecord) else {
            return false
        }
        return currentIndex > navigationFloor(gameRecord: gameRecord)
            && SgfOperations(sgf: sgf).getMove(at: currentIndex - 1) != nil
    }

    public func undoIndex(gameRecord: GameRecord?) {
        if isBranchActive {
            // Stop at the divergence floor: the branch numbers only its own
            // moves, and the pre-branch moves below it belong to the saved
            // mainline (an undo past them would desync board vs engine).
            if branchIndex > navigationFloor(gameRecord: gameRecord) {
                branchIndex = branchIndex - 1
            }
        } else {
            gameRecord?.undo()
        }
    }

    public func getSgf(gameRecord: GameRecord?) -> String? {
        isBranchActive ? branchSgf : gameRecord?.sgf
    }

    public func getCurrentIndex(gameRecord: GameRecord?) -> Int? {
        isBranchActive ? branchIndex : gameRecord?.currentIndex
    }

    // MARK: - Engine feed accounting
    //
    // The engine is fed move by move (`EngineFeed`), so navigation has to know
    // which recorded moves it was actually GIVEN: a move the replay refused —
    // an occupied point, an off-board point, a single-stone suicide — was never
    // sent, so there is no `play` to repeat and no `undo` to take it back. The
    // index still moves, because the display counts it.

    /// The replay behind the record's index space, cached for the SGF it was
    /// built from.
    ///
    /// Deliberately a SECOND instance from `RecordPositionProjector`'s: the
    /// navigation methods below are nonisolated and cannot touch the main-actor
    /// projector. Both are built by `RecordReplayBuilder.replay(from:)` out of
    /// the same C++ parse, so they are identical by construction — decision 3
    /// asks for one PARSER, not one instance.
    @ObservationIgnored private var feedReplaySgf: String? = nil
    @ObservationIgnored private var feedReplay: SgfReplay? = nil

    /// The `play` the engine was given for the recorded move at `index` — turn
    /// and vertex — or nil when the replay refused it.
    ///
    /// THE one predicate. Everything that has to agree about which indices the
    /// engine holds goes through it: the forward step that sends a `play`, the
    /// auto-play step, and the backward walk that decides how many `undo`s to
    /// take back. The vertex comes from the REPLAY, never from `BoardSize`, so
    /// the send and the bookkeeping cannot disagree — a `BoardSize` that lagged
    /// the record used to silence the `play` while the refusal accounting still
    /// counted the move as sent, which is one `undo` too many and permanent
    /// board/engine skew.
    ///
    /// `operations` lets a caller that has already parsed the SGF hand the
    /// parse over instead of paying for a second one.
    public func engineMove(sgf: String,
                           at index: Int,
                           operations: SgfOperations? = nil) -> (turn: String, vertex: String)? {
        withFeedReplay(sgf: sgf, operations: operations) {
            EngineFeed.playArguments(replay: &$0, at: index)
        } ?? nil
    }

    /// Whether the engine was given the recorded move at `index`.
    ///
    /// True for a record the parser rejects: an unreadable SGF has no refusals
    /// to honour, and refusing to feed it would be a silent behaviour change
    /// where there is nothing to gain — so the nil-replay case answers the way
    /// the pre-feed code behaved.
    public func isMoveFedToEngine(sgf: String, at index: Int, operations: SgfOperations? = nil) -> Bool {
        guard index >= 0 else { return false }
        guard feedReplay(forSgf: sgf, operations: operations) != nil else { return true }
        return engineMove(sgf: sgf, at: index, operations: operations) != nil
    }

    /// Runs `body` on the cached replay for `sgf` and writes back whatever it
    /// memoized (`SgfReplay` is a value type). Nil when the record cannot be
    /// parsed. The navigation-side twin of
    /// `RecordPositionProjector.withReplay(for:_:)`.
    private func withFeedReplay<T>(sgf: String,
                                   operations: SgfOperations?,
                                   _ body: (inout SgfReplay) -> T) -> T? {
        guard var replay = feedReplay(forSgf: sgf, operations: operations) else { return nil }
        let result = body(&replay)
        feedReplaySgf = sgf
        feedReplay = replay
        return result
    }

    /// Whether an `undo` would actually take back the move the cursor is
    /// standing on — i.e. the engine was given the recorded move at
    /// `currentIndex - 1`. Callers that send `undo` themselves (the
    /// backward-frame toolbar button) gate on this, exactly as they already
    /// gate on `canStepBackward`.
    public func isStepBackwardFedToEngine(gameRecord: GameRecord?) -> Bool {
        guard let sgf = getSgf(gameRecord: gameRecord),
              let currentIndex = getCurrentIndex(gameRecord: gameRecord),
              currentIndex > 0 else { return false }
        return isMoveFedToEngine(sgf: sgf, at: currentIndex - 1)
    }

    private func feedReplay(forSgf sgf: String, operations: SgfOperations?) -> SgfReplay? {
        if feedReplaySgf == sgf, let feedReplay { return feedReplay }
        guard let built = RecordReplayBuilder.replay(from: operations ?? SgfOperations(sgf: sgf)) else {
            return nil
        }
        feedReplaySgf = sgf
        feedReplay = built
        return built
    }

    public func backwardMoves(
        limit: Int?,
        gameRecord: GameRecord,
        messageList: MessageList,
        player: Turn,
        stones: Stones
    ) {
        guard let sgf = getSgf(gameRecord: gameRecord) else {
            return
        }

        let sgfHelper = SgfOperations(sgf: sgf)
        // Never rewind below the branch floor (the divergence); off-branch it is
        // 0, so mainline rewind is unchanged.
        let floor = navigationFloor(gameRecord: gameRecord)
        let startIndex = getCurrentIndex(gameRecord: gameRecord)
        var movesExecuted = 0

        // The cursor first: it steps over every recorded index, refused or not,
        // because the display counted them all.
        while let currentIndex = getCurrentIndex(gameRecord: gameRecord),
            currentIndex > floor,
            sgfHelper.getMove(at: currentIndex - 1) != nil {
            undoIndex(gameRecord: gameRecord)

            movesExecuted += 1
            if let limit = limit, movesExecuted >= limit {
                break
            }
        }

        // Then exactly as many `undo`s as the engine has moves to give back
        // across the span just walked. `EngineFeed.undoCount` is the same rule
        // the feed used to decide what to SEND, so the two can never disagree
        // about how many moves the engine is holding. A record the parser
        // rejects has no refusals to honour, so it falls back to one undo per
        // index — what the pre-feed code did.
        if let startIndex, let endIndex = getCurrentIndex(gameRecord: gameRecord), startIndex > endIndex {
            let undos = withFeedReplay(sgf: sgf, operations: sgfHelper) {
                EngineFeed.undoCount(replay: &$0, from: startIndex, to: endIndex)
            } ?? (startIndex - endIndex)
            for _ in 0..<undos {
                undo(messageList: messageList, stones: stones)
                player.toggleNextColorForPlayCommand()
            }
        }

        sendPostExecutionCommands(
            config: gameRecord.concreteConfig,
            messageList: messageList,
            player: player
        )

        // Navigation moves the board whether or not an engine can hear about
        // it. When it could not, record the debt so the handshake's resync
        // re-states the position the board actually ended on.
        if !messageList.isAcceptingCommands {
            noteEngineSendDropped(recordID: gameRecord.persistentModelID,
                                  index: getCurrentIndex(gameRecord: gameRecord)
                                      ?? gameRecord.currentIndex)
        }
    }

    public func matchesNextRecordedMove(turn: String, move: String, gameRecord: GameRecord, board: BoardSize) -> Bool {
        guard let nextMove = getNextMove(gameRecord: gameRecord),
              let nextMoveString = board.locationToMove(location: nextMove.location) else {
            return false
        }

        let nextTurn = nextMove.player == Player.black ? "b" : "w"
        return nextMoveString == move && nextTurn == turn
    }

    /// Steps the mainline cursor over the recorded move the player just
    /// reproduced. Only reachable off-branch, so the cursor IS
    /// `gameRecord.currentIndex`.
    ///
    /// The `play` is skipped for an index the replay refused: the engine never
    /// received that move, so re-sending it here would put the engine one move
    /// ahead of the board it is meant to be analysing.
    public func playMainlineStep(
        turn: String,
        move: String,
        gameRecord: GameRecord,
        stones: Stones,
        messageList: MessageList,
        player: Turn,
        audioModel: AudioModel
    ) {
        let index = gameRecord.currentIndex
        let fed = getSgf(gameRecord: gameRecord).map {
            isMoveFedToEngine(sgf: $0, at: index)
        } ?? true
        if fed {
            play(turn: turn, move: move, messageList: messageList, stones: stones)
            player.toggleNextColorForPlayCommand()
        }
        gameRecord.currentIndex += 1
        sendShowBoardCommand(messageList: messageList)
        audioModel.playPlaySound(soundEffect: soundEffect)
    }

    public func getNextMove(gameRecord: GameRecord) -> Move? {
        guard let sgf = getSgf(gameRecord: gameRecord),
              let currentIndex = getCurrentIndex(gameRecord: gameRecord) else {
            return nil
        }

        if let key = nextMoveCacheKey, key == (sgf, currentIndex) {
            return nextMoveCacheResult
        }

        let sgfHelper = SgfOperations(sgf: sgf)
        let result = sgfHelper.getMove(at: currentIndex)

        nextMoveCacheKey = (sgf, currentIndex)
        nextMoveCacheResult = result

        return result
    }

    public func getMoveNumbers(gameRecord: GameRecord?) -> MoveNumbers {
        guard resolvedMoveNumberStyle != .lastThreeMoves,
              let sgf = getSgf(gameRecord: gameRecord),
              let currentIndex = getCurrentIndex(gameRecord: gameRecord) else {
            return .empty
        }

        // A branch numbers only its own stones (1..N from the divergence point,
        // which stays frozen at gameRecord.currentIndex while the branch is
        // active); off-branch the numbering is absolute from the root.
        let startIndex = isBranchActive ? (gameRecord?.currentIndex ?? currentIndex) : 0

        // startIndex is part of the key: after commitBranch the (sgf, index)
        // pair equals a prior branch-active call's, but the numbering base
        // changes from the divergence point to the root.
        if let key = moveNumbersCacheKey, key == (sgf, currentIndex, startIndex) {
            return moveNumbersCacheResult
        }

        let result = MoveNumbers.derive(sgf: sgf, currentIndex: currentIndex, startIndex: startIndex)

        moveNumbersCacheKey = (sgf, currentIndex, startIndex)
        moveNumbersCacheResult = result

        return result
    }

    /// GTP vertex of the move played into the current position, or nil when
    /// there is none or it was a pass — the same point the board's own
    /// last-move marker sits on (`MoveNumberView.lastMoveMarker`).
    ///
    /// Separate from `getMoveNumbers` on purpose. That one short-circuits to
    /// `.empty` when the move-number style is `.lastThreeMoves`, which is
    /// correct for the label it feeds but wrong for anything that just wants
    /// the last move: the watch mirror would lose its marker whenever the
    /// phone's user happened to pick that display style.
    ///
    /// Cached on `(sgf, currentIndex)` because the watch snapshot asks at
    /// ~2 Hz while the answer only changes when a move is played.
    public func lastPlayedVertex(gameRecord: GameRecord?) -> String? {
        guard let sgf = getSgf(gameRecord: gameRecord),
              let currentIndex = getCurrentIndex(gameRecord: gameRecord) else { return nil }
        if let key = lastPlayedVertexCacheKey, key == (sgf, currentIndex) {
            return lastPlayedVertexCacheResult
        }
        let vertex = MoveNumbers.lastPlayedVertex(sgf: sgf, currentIndex: currentIndex)
        lastPlayedVertexCacheKey = (sgf, currentIndex)
        lastPlayedVertexCacheResult = vertex
        return vertex
    }

    /// Steps the cursor forward, feeding the engine each recorded move the
    /// replay accepted.
    ///
    /// - Parameter board: no longer read. The played vertex comes from the
    ///   replay (see `engineMove`), which is what makes the send and the undo
    ///   bookkeeping one rule. Kept on the signature because eleven call sites
    ///   across five app targets pass it, and `go(to:)` threads it through;
    ///   dropping it is a mechanical cleanup for a commit that is already
    ///   touching those hosts.
    public func forwardMoves(
        limit: Int?,
        gameRecord: GameRecord,
        board: BoardSize,
        messageList: MessageList,
        player: Turn,
        audioModel: AudioModel?,
        stones: Stones
    ) {
        guard let sgf = getSgf(gameRecord: gameRecord) else {
            return
        }

        let sgfHelper = SgfOperations(sgf: sgf)
        var movesExecuted = 0

        while let currentIndex = getCurrentIndex(gameRecord: gameRecord),
              sgfHelper.getMove(at: currentIndex) != nil {
            // The cursor advances FIRST and unconditionally. A move the replay
            // refused still occupies an index (the board skipped it and moved
            // on), and the old `if let move = …` shape could not advance past a
            // vertex it could not name — it spun forever on one.
            if isBranchActive {
                branchIndex += 1
            } else {
                gameRecord.currentIndex += 1
            }

            // Turn AND vertex from `engineMove`, i.e. from the replay — the same
            // source `backwardMoves` counts undos from, so a forward step and
            // the undo that reverses it can never disagree about whether the
            // engine was given this index.
            if let move = engineMove(sgf: sgf, at: currentIndex, operations: sgfHelper) {
                play(turn: move.turn, move: move.vertex, messageList: messageList, stones: stones)
                player.toggleNextColorForPlayCommand()
            }

            movesExecuted += 1
            if let limit = limit, movesExecuted >= limit {
                break
            }
        }

        if movesExecuted > 0 {
            audioModel?.playPlaySound(soundEffect: soundEffect)
        }

        sendPostExecutionCommands(
            config: gameRecord.concreteConfig,
            messageList: messageList,
            player: player
        )

        // Navigation moves the board whether or not an engine can hear about
        // it. When it could not, record the debt so the handshake's resync
        // re-states the position the board actually ended on.
        if !messageList.isAcceptingCommands {
            noteEngineSendDropped(recordID: gameRecord.persistentModelID,
                                  index: getCurrentIndex(gameRecord: gameRecord)
                                      ?? gameRecord.currentIndex)
        }
    }

    public func go(to targetIndex: Int,
            gameRecord: GameRecord,
            board: BoardSize,
            messageList: MessageList,
            player: Turn,
            audioModel: AudioModel?,
            stones: Stones
    ) {
        guard let currentIndex = getCurrentIndex(gameRecord: gameRecord) else {
            return
        }

        // Clamp a below-floor target up to the divergence: while a branch is
        // active navigation may reach the divergence but never earlier.
        let clampedTarget = max(targetIndex, navigationFloor(gameRecord: gameRecord))

        guard currentIndex != clampedTarget else {
            return
        }

        if clampedTarget < currentIndex {
            let limit = currentIndex - clampedTarget

            backwardMoves(
                limit: limit,
                gameRecord: gameRecord,
                messageList: messageList,
                player: player,
                stones: stones
            )
        } else {
            let limit = clampedTarget - currentIndex

            forwardMoves(
                limit: limit,
                gameRecord: gameRecord,
                board: board,
                messageList: messageList,
                player: player,
                audioModel: audioModel,
                stones: stones
            )
        }
    }

    public func isOverwriting(gameRecord: GameRecord) -> Bool {
        guard let sgf = getSgf(gameRecord: gameRecord),
              let moveSize = SgfOperations(sgf: sgf).moveSize,
              let currentIndex = getCurrentIndex(gameRecord: gameRecord) else {
            return false
        }

        return (currentIndex < moveSize) && (isEditing || isBranchActive)
    }

    public func maybeUpdateMoves(gameRecord: GameRecord, board: BoardSize, sgfHelper: SgfOperations? = nil) {
        if gameRecord.moves == nil { gameRecord.moves = [:] }
        let currentIndex = gameRecord.currentIndex
        let previousIndex = currentIndex - 1

        if isEditing || gameRecord.moves?[currentIndex] == nil ||
            (previousIndex >= 0 && gameRecord.moves?[previousIndex] == nil) {
            let sgfHelper = sgfHelper ?? SgfOperations(sgf: gameRecord.sgf)

            if let location = sgfHelper.getMove(at: currentIndex)?.location {
                gameRecord.moves?[currentIndex] = board.locationToMove(location: location)
            }

            if previousIndex >= 0,
               let location = sgfHelper.getMove(at: previousIndex)?.location {
                gameRecord.moves?[previousIndex] = board.locationToMove(location: location)
            }
        }
    }

    /// Decides the editing (unlock) state after a board (re)load. A brand-new
    /// default game starts unlocked for immediate play; a committed-branch
    /// reload requests unlock (replacing the original game is an explicit edit);
    /// any other loaded game starts locked.
    static func editingAfterLoad(sgf: String, unlockRequested: Bool) -> Bool {
        // The rule itself lives in the bridge-free store, because the macOS
        // draft machinery decides from it too and its test target cannot link
        // this module. See `GameRecord.editingAfterLoad`.
        GameRecord.editingAfterLoad(sgf: sgf, unlockRequested: unlockRequested)
    }

    /// Reads and clears the one-shot unlock-on-reload intent set by
    /// `commitBranch`, returning whether the upcoming load should land unlocked.
    /// Clearing on read ensures the intent can never leak into a later,
    /// unrelated load.
    func consumeUnlockEditingOnReload() -> Bool {
        let requested = unlockEditingOnReload
        unlockEditingOnReload = false
        return requested
    }

    /// Reloads the board for a newly selected game.
    ///
    /// The switched game's position is projected SYNCHRONOUSLY here, so it is
    /// on screen before the engine has been told anything — the board never
    /// waits for the engine. The engine is then FED that same position move by
    /// move (`syncEngine(to:)`), which is why the record's saved cursor is
    /// honoured everywhere now: there is no `loadsgf` echo left to reset it and
    /// no undo loop that has to start from the tip.
    @MainActor
    public func loadGame(gameRecord newGameRecord: GameRecord?,
                         player: Turn,
                         bookLookup: BookLookup,
                         messageList: MessageList,
                         board: BoardSize,
                         stones: Stones,
                         analysis: Analysis,
                         projector: RecordPositionProjector) {
        player.nextColorForPlayCommand = .unknown
        // Consume the one-shot unlock intent set by commitBranch up front, so it
        // can never leak into a later, unrelated game load.
        let unlockRequested = consumeUnlockEditingOnReload()
        deactivateBranch()
        clearPendingMove()
        withAnimation {
            bookLookup.resetToRoot()
        }

        guard let newGameRecord else { return }

        let bookConfig = newGameRecord.concreteConfig
        if bookConfig.isBookEligible {
            bookLookup.loadIfNeeded(boardSize: bookConfig.boardWidth)
        }
        // Drop book view unless this board has a downloaded book (it may
        // still be loading; the overlay gates on the book being in-book).
        if eyeStatus == .book,
           !(bookConfig.isBookEligible && bookLookup.isAvailable(forBoardSize: bookConfig.boardWidth)) {
            eyeStatus = .opened
        }
        newGameRecord.updateToLatestVersion()
        isAutoPlaying = false
        isEditing = Self.editingAfterLoad(sgf: newGameRecord.sgf,
                                          unlockRequested: unlockRequested)
        let sgfHelper = SgfOperations(sgf: newGameRecord.sgf)
        let moveCount = sgfHelper.moveSize ?? 0
        // Where the game must END UP: the saved cursor, clamped into the
        // record's own move range. A record saved past its move count (a
        // re-imported or truncated SGF) would otherwise sit off the end.
        let targetIndex = min(max(newGameRecord.currentIndex, 0), moveCount)
        // Settle the cursor before anything reads it. Assign only on a real
        // change: SwiftData dirties (and re-uploads) a record written even to
        // its existing value.
        if newGameRecord.currentIndex != targetIndex {
            newGameRecord.currentIndex = targetIndex
        }

        // The engine is not in sync with anything yet.
        stones.isReady = false
        // Loading a game ALWAYS invalidates what was on screen, so clear
        // here rather than leaning on the projector's key-change rule: a
        // host whose own driver already projected this key would make that
        // rule a no-op, and the previous game's win rate would survive the
        // switch.
        analysis.clear()

        // Show the switched game AT ONCE — engine-free.
        projector.project(key: RecordPositionKey(recordID: newGameRecord.persistentModelID,
                                                 sgf: newGameRecord.sgf,
                                                 index: targetIndex,
                                                 isBranchActive: isBranchActive),
                          into: stones,
                          board: board,
                          analysis: analysis,
                          gobanState: self,
                          engineIsAcceptingCommands: messageList.isAcceptingCommands)

        // The record is the authority on its own rules; adopt them before the
        // feed states them to the engine.
        //
        // Each assignment is guarded. `Config` is its own @Model, and SwiftData
        // dirties (then saves, then exports to CloudKit) a model written even to
        // the value it already holds — so writing all seven unconditionally
        // pushed an identical Config to iCloud every time a game was opened,
        // which is the same churn the retired `printsgf` load echo caused.
        let config = newGameRecord.concreteConfig
        let rules = sgfHelper.rules
        if config.koRule != rules.koRule { config.koRule = rules.koRule }
        if config.scoringRule != rules.scoringRule { config.scoringRule = rules.scoringRule }
        if config.taxRule != rules.taxRule { config.taxRule = rules.taxRule }
        if config.multiStoneSuicideLegal != rules.multiStoneSuicideLegal {
            config.multiStoneSuicideLegal = rules.multiStoneSuicideLegal
        }
        if config.hasButton != rules.hasButton { config.hasButton = rules.hasButton }
        if config.whiteHandicapBonusRule != rules.whiteHandicapBonusRule {
            config.whiteHandicapBonusRule = rules.whiteHandicapBonusRule
        }
        if config.komi != rules.komi { config.komi = rules.komi }

        // The pass counter is a running one, so a game resumed on a pass has to
        // be seeded from the position we are standing on. Refused moves are
        // looked through — the engine never saw them, so they do not break a
        // run of passes. Reset first: the previous game's count must never
        // survive a switch, not even when the new record cannot be replayed.
        passCount = 0
        passCount = projector.withReplay(for: newGameRecord.sgf) {
            $0.trailingPassCount(at: targetIndex)
        } ?? 0

        guard messageList.isAcceptingCommands else {
            // The board switched; the engine could not be told. Record the debt
            // so the handshake's resync knows a feed is owed (it will feed the
            // LIVE selection, which may be a different game by then).
            noteEngineSendDropped(recordID: newGameRecord.persistentModelID,
                                  index: targetIndex)
            return
        }
        guard boardFitsEngine(width: sgfHelper.xSize, height: sgfHelper.ySize) else { return }
        syncEngine(to: targetIndex,
                   sgf: newGameRecord.sgf,
                   config: config,
                   messageList: messageList,
                   stones: stones,
                   // Already parked at the top of this function, unconditionally:
                   // the record changed, so the turn is stale whether or not the
                   // feed goes out.
                   player: nil,
                   projector: projector)
    }

    /// Whether the running engine can serve a board this big. Unknown
    /// (`engineMaxBoardLength == nil`) counts as "fits" — see the property.
    /// A 0-sized record (the parser rejected it) never fits: there is no board
    /// to state to the engine.
    public func boardFitsEngine(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        guard let cap = engineMaxBoardLength else { return true }
        return width <= cap && height <= cap
    }

    /// Feeds the engine the record position at `targetIndex`: a reset to the
    /// record's own board size, its rules, its setup stones, then one `play`
    /// per ACCEPTED recorded move, then the `showboard` whose reply is the
    /// in-sync acknowledgement.
    ///
    /// Analysis is not requested here. It re-arms itself off the turn change:
    /// the turn is parked at `.unknown`, and this showboard's "Next player" line
    /// resolves it to a colour, which the hosts' turn-change hook turns into
    /// `handleTurnChange`.
    ///
    /// - Parameter player: parked at `.unknown` immediately before the feed goes
    ///   out — and ONLY then. Pass nil when the caller has already parked for
    ///   its own reasons (`loadGame` does: the record changed, so the turn is
    ///   stale whether or not a feed follows). A park that no `showboard` will
    ///   ever resolve is worse than no park at all — the edge that re-arms
    ///   analysis would simply never fire again.
    @MainActor
    public func syncEngine(to targetIndex: Int,
                           sgf: String,
                           config: Config,
                           messageList: MessageList,
                           stones: Stones,
                           player: Turn?,
                           projector: RecordPositionProjector) {
        // Reuse the replay the board was just drawn from — same instance, so
        // the feed inherits its checkpoints and its discovered refusals.
        let commands = projector.withReplay(for: sgf) { replay in
            EngineFeed.openingCommands(replay: &replay, config: config, targetIndex: targetIndex)
        }
        guard let commands, !commands.isEmpty else { return }
        stones.isReady = false
        // After the decision to feed, before the feed: this park is resolved by
        // the `showboard` two lines below, and by nothing else.
        player?.nextColorForPlayCommand = .unknown
        messageList.appendAndSend(commands: commands)
        sendShowBoardCommand(messageList: messageList)
    }

    /// Records that a position change could not be sent to the engine.
    /// Last request wins — the gate keeps only the newest.
    func noteEngineSendDropped(recordID: PersistentIdentifier?, index: Int) {
        _ = engineSyncGate.request(EngineSyncRequest(recordID: recordID, index: index),
                                   isReady: false)
    }

    /// The engine came up. Feed it the position the board is showing NOW.
    ///
    /// The gate is drained for its diagnostic payload, but the feed is built
    /// from the LIVE record at the LIVE cursor: while the model was loading the
    /// user may have switched games, scrubbed, or both, and every one of those
    /// sends was dropped. Latest selection wins — replaying the first dropped
    /// request would put the engine on a position nobody is looking at.
    ///
    /// The turn is parked at `.unknown` as part of the feed (`syncEngine`), and
    /// only when a feed actually goes out. That park is load-bearing: a relaunch
    /// does not change whose move it is, analysis re-arms only off the turn
    /// EDGE, and without the park the fresh engine's `showboard` would restate
    /// the colour the board already held — no edge, no analysis, on a perfectly
    /// healthy engine.
    ///
    /// - Parameter player: the session's turn, parked as described above.
    /// - Returns: the drained request, if one was owed (diagnostics/tests).
    @MainActor
    @discardableResult
    public func resyncEngineAfterHandshake(gameRecord: GameRecord?,
                                           player: Turn,
                                           messageList: MessageList,
                                           stones: Stones,
                                           projector: RecordPositionProjector) -> EngineSyncRequest? {
        // Only drain once we can actually act: draining while still unavailable
        // would throw the debt away and leave the engine permanently unfed.
        guard messageList.isAcceptingCommands else { return engineSyncGate.pending }
        let drained = engineSyncGate.drainWhenReady()

        guard let gameRecord else { return drained }
        let sgf = getSgf(gameRecord: gameRecord) ?? gameRecord.sgf
        let sgfHelper = SgfOperations(sgf: sgf)
        guard boardFitsEngine(width: sgfHelper.xSize, height: sgfHelper.ySize) else { return drained }
        let moveCount = sgfHelper.moveSize ?? 0
        let targetIndex = min(max(getCurrentIndex(gameRecord: gameRecord) ?? 0, 0), moveCount)

        syncEngine(to: targetIndex,
                   sgf: sgf,
                   config: gameRecord.concreteConfig,
                   messageList: messageList,
                   stones: stones,
                   player: player,
                   projector: projector)
        return drained
    }

    /// `BoardView.onAppear`: re-park the turn at `.unknown` and ask the engine
    /// where it stands, so the turn edge re-arms analysis (the iPhone push-pop
    /// restore after `maybePauseAnalysis` is exactly this path).
    ///
    /// Against an engine that is not ready it is a NO-OP — parking the turn with
    /// nothing able to resolve it would leave the board waiting on a `showboard`
    /// that was dropped.
    public func resyncOnAppear(engineReady: Bool, player: Turn, messageList: MessageList) {
        guard engineReady else { return }
        player.nextColorForPlayCommand = .unknown
        sendShowBoardCommand(messageList: messageList)
    }

    /// Everything that claims the ENGINE agrees with the board, back to zero,
    /// because a fresh engine agrees with nothing. Called on every handshake and
    /// on every teardown.
    ///
    /// Deliberately touches nothing the board DRAWS: stones, board size and the
    /// cursor are record-owned and survive an engine that comes and goes.
    public func resetForFreshEngine(stones: Stones) {
        showBoardCount = 0
        waitingForAnalysis = false
        clearPendingMove()
        stones.isReady = false
        passCount = 0
        // The tvOS broadcast's one-shot gen-move license belongs to the engine
        // that was asked; a new engine must not inherit permission to play.
        broadcastGenMovePending = false
    }

    /// One auto-play replay step: move the cursor onto the next recorded move
    /// and tell the engine about it.
    ///
    /// The cursor advances IMMEDIATELY — the board is record-owned, so the
    /// stone is on screen before the engine answers, and the step no longer
    /// hangs off a `stones.isReady` edge that could double-fire or go missing.
    /// A move the replay refused is skipped in the feed and stepped over in the
    /// same call, so the loop cannot stall on one waiting for a turn change
    /// that will never come. Clears `isAutoPlaying` when the record runs out,
    /// which is what ends the loop.
    public func autoPlayStep(
        gameRecord: GameRecord,
        messageList: MessageList,
        player: Turn,
        stones: Stones,
        audioModel: AudioModel?
    ) {
        // ONE index space: the record's own SGF and its own cursor. Auto-play
        // always runs with the branch deactivated (both hosts call
        // `deactivateBranch()` on the `isAutoPlaying` true edge), so the
        // branch-aware `getSgf`/`getCurrentIndex` pair would answer identically
        // — but reading the SGF through the branch while writing
        // `gameRecord.currentIndex` directly is two spaces on paper, and the
        // day a caller starts auto-play on a branch it would replay the wrong
        // line into the record.
        let sgf = gameRecord.sgf
        let sgfHelper = SgfOperations(sgf: sgf)
        var played = false

        while sgfHelper.getMove(at: gameRecord.currentIndex) != nil {
            let index = gameRecord.currentIndex
            gameRecord.currentIndex = index + 1

            if let move = engineMove(sgf: sgf, at: index, operations: sgfHelper) {
                play(turn: move.turn, move: move.vertex, messageList: messageList, stones: stones)
                player.toggleNextColorForPlayCommand()
                played = true
                break
            }
            // A refused move produces no `play`, so no turn change, so nothing
            // would ever wake the loop again — step straight onto the next one.
        }

        guard played else {
            isAutoPlaying = false
            return
        }
        sendShowBoardCommand(messageList: messageList)
        audioModel?.playPlaySound(soundEffect: soundEffect)
    }
}

// MARK: - Global display-preference helpers
// Mirror the equivalent Config computed helpers, reading the app-wide values
// above so render code can switch from `config.isX` to `gobanState.isX`.
extension GobanState {
    public var isClassicStoneStyle: Bool {
        guard (0..<Config.stoneStyles.count).contains(stoneStyle) else { return false }
        return Config.stoneStyles[stoneStyle] == Config.classicStoneStyle
    }

    public var isClassicAnalysisStyle: Bool {
        guard (0..<Config.analysisStyles.count).contains(analysisStyle) else { return false }
        return Config.analysisStyles[analysisStyle] == Config.classicAnalysisStyle
    }

    public var isAnalysisInformationWinrate: Bool {
        guard (0..<Config.analysisInformations.count).contains(analysisInformation) else { return false }
        return Config.analysisInformations[analysisInformation] == Config.analysisInformationWinrate
    }

    public var isAnalysisInformationScore: Bool {
        guard (0..<Config.analysisInformations.count).contains(analysisInformation) else { return false }
        return Config.analysisInformations[analysisInformation] == Config.analysisInformationScore
    }

    public var isAnalysisInformationAll: Bool {
        guard (0..<Config.analysisInformations.count).contains(analysisInformation) else { return false }
        return Config.analysisInformations[analysisInformation] == Config.analysisInformationAll
    }

    public var isAnalysisInformationNone: Bool {
        guard (0..<Config.analysisInformations.count).contains(analysisInformation) else { return false }
        return Config.analysisInformations[analysisInformation] == Config.analysisInformationNone
    }

    public var stoneStyleText: String {
        guard (0..<Config.stoneStyles.count).contains(stoneStyle) else { return Config.defaultStoneStyleText }
        return Config.stoneStyles[stoneStyle]
    }

    public var analysisStyleText: String {
        guard (0..<Config.analysisStyles.count).contains(analysisStyle) else { return Config.defaultAnalysisStyleText }
        return Config.analysisStyles[analysisStyle]
    }

    public var analysisInformationText: String {
        guard (0..<Config.analysisInformations.count).contains(analysisInformation) else { return Config.defaultAnalysisInformationText }
        return Config.analysisInformations[analysisInformation]
    }

    public var moveNumberStyleText: String {
        guard (0..<Config.moveNumberStyles.count).contains(moveNumberStyle) else { return Config.defaultMoveNumberStyleText }
        return Config.moveNumberStyles[moveNumberStyle]
    }

    public var moveNumberStyleChoice: MoveNumberStyle {
        MoveNumberStyle(rawValue: moveNumberStyle) ?? .lastThreeMoves
    }

    /// The move-number style actually used to render the board. An active branch
    /// always numbers its stones 1..N (allMoves, relative to the divergence),
    /// overriding the user's global preference; off-branch it is that preference.
    public var resolvedMoveNumberStyle: MoveNumberStyle {
        isBranchActive ? .allMoves : moveNumberStyleChoice
    }
}
