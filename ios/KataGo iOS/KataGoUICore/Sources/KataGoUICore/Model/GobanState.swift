//
//  GobanState.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/11/17.
//

import SwiftUI

@Observable
public class GobanState {
    public init() {}

    public var waitingForAnalysis = false
    public var requestingClearAnalysis = false
    public var analysisStatus = AnalysisStatus.run
    public var showBoardCount: Int = 0
    public var isEditing = false
    public var isShownBoard: Bool = false
    public var eyeStatus = EyeStatus.opened
    public var isAutoPlaying: Bool = false
    public var isAutoPlayed: Bool = false
    public var passCount: Int = 0
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

    @ObservationIgnored private var nextMoveCacheKey: (String, Int)? = nil
    @ObservationIgnored private var nextMoveCacheResult: Move? = nil
    @ObservationIgnored private var moveNumbersCacheKey: (String, Int)? = nil
    @ObservationIgnored private var moveNumbersCacheResult: MoveNumbers = .empty

    public func sendShowBoardCommand(messageList: MessageList) {
        messageList.appendAndSend(command: "showboard")
        showBoardCount = showBoardCount + 1
    }

    public func consumeShowBoardResponse(response: String) -> Bool {
        if response.hasPrefix("= MoveNum") {
            showBoardCount = showBoardCount - 1
            isShownBoard = true
            return showBoardCount == 0
        } else {
            return false
        }
    }

    private func getRequestAnalysisCommands(config: Config, nextColorForPlayCommand: PlayerColor?) -> [String] {

        if (analysisStatus == .run) && (!isAutoPlaying) && (passCount < 2) {
            if (nextColorForPlayCommand == .black) && (config.blackMaxTime > 0) {
                return GtpCommandBuilder.genMoveAnalyzeCommands(maxTime: config.blackMaxTime, interval: config.analysisInterval, maxMoves: config.maxAnalysisMoves)
            } else if (nextColorForPlayCommand == .white) && (config.whiteMaxTime > 0) {
                return GtpCommandBuilder.genMoveAnalyzeCommands(maxTime: config.whiteMaxTime, interval: config.analysisInterval, maxMoves: config.maxAnalysisMoves)
            }
        }

        return [GtpCommandBuilder.fastAnalyzeCommand(maxMoves: config.maxAnalysisMoves)]
    }

    public func requestAnalysis(config: Config, messageList: MessageList, nextColorForPlayCommand: PlayerColor?) {
        let commands = getRequestAnalysisCommands(config: config, nextColorForPlayCommand: nextColorForPlayCommand)
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

    public func shouldGenMove(config: Config, player: Turn) -> Bool {
        if (!isAutoPlaying) &&
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

    public func maybeUpdateAnalysisData(
        gameRecord: GameRecord,
        analysis: Analysis,
        board: BoardSize,
        stones: Stones,
        all: Bool = true
    ) {
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
        if !config.isEqualBlackWhiteHumanSettings && !isAutoPlaying {
            if nextColorForPlayCommand == .black,
               let humanSLModel = HumanSLModel(profile: config.humanProfileForBlack) {
                messageList.appendAndSend(commands: humanSLModel.commands)
            } else if nextColorForPlayCommand == .white,
                      let humanSLModel = HumanSLModel(profile: config.humanProfileForWhite) {
                messageList.appendAndSend(commands: humanSLModel.commands)
            }
        }
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

        if isEditing {
            gameRecord.clearData(after: gameRecord.currentIndex)

            maybeUpdateAnalysisData(
                gameRecord: gameRecord,
                analysis: analysis,
                board: board,
                stones: stones
            )
        } else if !isBranchActive {
            if matchesNextRecordedMove(turn: turn, move: move, gameRecord: gameRecord, board: board) {
                playMainlineStep(turn: turn, move: move, gameRecord: gameRecord, stones: stones, messageList: messageList, player: player, audioModel: audioModel)
                clearPendingMove()
                return
            }

            branchSgf = gameRecord.sgf
            branchIndex = gameRecord.currentIndex
        }

        play(turn: turn, move: move, messageList: messageList, stones: stones)
        player.toggleNextColorForPlayCommand()
        sendShowBoardCommand(messageList: messageList)
        messageList.appendAndSend(command: "printsgf")
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

        if isEditing {
            gameRecord.clearData(after: gameRecord.currentIndex)

            maybeUpdateAnalysisData(
                gameRecord: gameRecord,
                analysis: analysis,
                board: board,
                stones: stones
            )
        } else if !isBranchActive {
            if matchesNextRecordedMove(turn: turn, move: aiMove, gameRecord: gameRecord, board: board) {
                playMainlineStep(turn: turn, move: aiMove, gameRecord: gameRecord, stones: stones, messageList: messageList, player: player, audioModel: audioModel)
                return
            }

            branchSgf = gameRecord.sgf
            branchIndex = gameRecord.currentIndex
        }

        play(turn: turn, move: aiMove, messageList: messageList, stones: stones)
        player.toggleNextColorForPlayCommand()
        sendShowBoardCommand(messageList: messageList)
        messageList.appendAndSend(command: "printsgf")
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
    public func commitBranch(gameRecord: GameRecord) {
        guard isBranchActive else { return }

        gameRecord.clearData(after: gameRecord.currentIndex)
        gameRecord.sgf = branchSgf
        gameRecord.currentIndex = branchIndex
        gameRecord.lastModificationDate = Date.now
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

    public func undoBranchIndex() {
        if (branchIndex > 0) {
            branchIndex = branchIndex - 1
        }
    }

    public func undoIndex(gameRecord: GameRecord?) {
        if isBranchActive {
            undoBranchIndex()
        } else {
            gameRecord?.undo()
        }
    }

    public func getSgf(gameRecord: GameRecord?) -> String? {
        isBranchActive ? branchSgf : gameRecord?.sgf
    }

    public func maybeLoadSgf(gameRecord: GameRecord?, messageList: MessageList) {
        if let sgf = getSgf(gameRecord: gameRecord) {
            let file = URL.documentsDirectory.appendingPathComponent("temp.sgf")
            do {
                try sgf.write(to: file, atomically: false, encoding: .utf8)
                let path = file.path()
                messageList.appendAndSend(command: "loadsgf \(path)")
            } catch {
                // Do nothing
            }
        }
    }

    public func getCurrentIndex(gameRecord: GameRecord?) -> Int? {
        isBranchActive ? branchIndex : gameRecord?.currentIndex
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
        var movesExecuted = 0

        while let currentIndex = getCurrentIndex(gameRecord: gameRecord),
            sgfHelper.getMove(at: currentIndex - 1) != nil {
            undoIndex(gameRecord: gameRecord)
            undo(messageList: messageList, stones: stones)
            player.toggleNextColorForPlayCommand()

            movesExecuted += 1
            if let limit = limit, movesExecuted >= limit {
                break
            }
        }

        sendPostExecutionCommands(
            config: gameRecord.concreteConfig,
            messageList: messageList,
            player: player
        )
    }

    public func matchesNextRecordedMove(turn: String, move: String, gameRecord: GameRecord, board: BoardSize) -> Bool {
        guard let nextMove = getNextMove(gameRecord: gameRecord),
              let nextMoveString = board.locationToMove(location: nextMove.location) else {
            return false
        }

        let nextTurn = nextMove.player == Player.black ? "b" : "w"
        return nextMoveString == move && nextTurn == turn
    }

    public func playMainlineStep(
        turn: String,
        move: String,
        gameRecord: GameRecord,
        stones: Stones,
        messageList: MessageList,
        player: Turn,
        audioModel: AudioModel
    ) {
        play(turn: turn, move: move, messageList: messageList, stones: stones)
        player.toggleNextColorForPlayCommand()
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
        guard moveNumberStyleChoice != .lastThreeMoves,
              let sgf = getSgf(gameRecord: gameRecord),
              let currentIndex = getCurrentIndex(gameRecord: gameRecord) else {
            return .empty
        }

        if let key = moveNumbersCacheKey, key == (sgf, currentIndex) {
            return moveNumbersCacheResult
        }

        let result = MoveNumbers.derive(sgf: sgf, currentIndex: currentIndex)

        moveNumbersCacheKey = (sgf, currentIndex)
        moveNumbersCacheResult = result

        return result
    }

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
              let nextMove = sgfHelper.getMove(at: currentIndex) {
            if let move = board.locationToMove(location: nextMove.location) {
                if isBranchActive {
                    branchIndex += 1
                } else {
                    gameRecord.currentIndex += 1
                }

                let nextPlayer = nextMove.player == Player.black ? "b" : "w"
                play(turn: nextPlayer, move: move, messageList: messageList, stones: stones)
                player.toggleNextColorForPlayCommand()

                movesExecuted += 1
                if let limit = limit, movesExecuted >= limit {
                    break
                }
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
    }

    public func go(to targetIndex: Int,
            gameRecord: GameRecord,
            board: BoardSize,
            messageList: MessageList,
            player: Turn,
            audioModel: AudioModel?,
            stones: Stones
    ) {
        guard let currentIndex = getCurrentIndex(gameRecord: gameRecord),
        currentIndex != targetIndex else {
            return
        }

        if targetIndex < currentIndex {
            let limit = currentIndex - targetIndex

            backwardMoves(
                limit: limit,
                gameRecord: gameRecord,
                messageList: messageList,
                player: player,
                stones: stones
            )
        } else {
            let limit = targetIndex - currentIndex

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

    /// Resets the visible board to a blank `width`×`height` grid. Mutates only
    /// the shared `BoardSize`/`Stones` model objects (no SwiftUI view code), so
    /// it lives here in the package rather than in the iOS view. Used by
    /// `loadGame` when switching to a game whose board size differs from the
    /// previous one, so the old stones don't linger while the new SGF loads.
    @MainActor
    private func placeLoadingBoard(width: Int, height: Int, board: BoardSize, stones: Stones) {
        withAnimation {
            board.width = CGFloat(width)
            board.height = CGFloat(height)
            stones.blackPoints.removeAll()
            stones.whitePoints.removeAll()
            stones.moveOrder.removeAll()
            stones.blackStonesCaptured = 0
            stones.whiteStonesCaptured = 0
            stones.isReady = false
        }
    }

    /// Reloads the board for a newly selected game, mirroring the previous
    /// `GameSplitView.processChange(oldGameRecord:newGameRecord:)` exactly. The
    /// iOS-only thumbnail render stays in the view's `onChange` wrapper.
    @MainActor
    public func loadGame(gameRecord newGameRecord: GameRecord?,
                         previous oldGameRecord: GameRecord?,
                         player: Turn,
                         bookLookup: BookLookup,
                         messageList: MessageList,
                         board: BoardSize,
                         stones: Stones) {
        player.nextColorForPlayCommand = .unknown
        deactivateBranch()
        clearPendingMove()
        withAnimation {
            bookLookup.resetToRoot()
        }

        if let newGameRecord {
            if newGameRecord.concreteConfig.isBookCompatible {
                bookLookup.loadIfNeeded()
            } else if eyeStatus == .book {
                eyeStatus = .opened
            }
            newGameRecord.updateToLatestVersion()
            isAutoPlaying = false
            isAutoPlayed = false
            if newGameRecord.sgf == GameRecord.defaultSgf {
                isEditing = true
            } else {
                isEditing = false
            }
            let currentIndex = newGameRecord.currentIndex
            let sgfHelper = SgfOperations(sgf: newGameRecord.sgf)
            newGameRecord.currentIndex = sgfHelper.moveSize ?? 0

            maybeLoadSgf(
                gameRecord: newGameRecord,
                messageList: messageList
            )

            while newGameRecord.currentIndex > currentIndex {
                newGameRecord.undo()
                undo(messageList: messageList, stones: stones)
            }
            let config = newGameRecord.concreteConfig
            config.koRule = sgfHelper.rules.koRule
            config.scoringRule = sgfHelper.rules.scoringRule
            config.taxRule = sgfHelper.rules.taxRule
            config.multiStoneSuicideLegal = sgfHelper.rules.multiStoneSuicideLegal
            config.hasButton = sgfHelper.rules.hasButton
            config.whiteHandicapBonusRule = sgfHelper.rules.whiteHandicapBonusRule
            config.komi = sgfHelper.rules.komi

            if let oldGameRecord,
               oldGameRecord.concreteConfig.boardWidth != config.boardWidth ||
                oldGameRecord.concreteConfig.boardHeight != config.boardHeight {
                placeLoadingBoard(width: config.boardWidth, height: config.boardHeight, board: board, stones: stones)
            }

            messageList.appendAndSend(commands: GtpCommandBuilder.ruleCommandsBundle(ko: config.koRuleText, scoring: config.scoringRuleText, tax: config.taxRuleText, multiStoneSuicide: config.multiStoneSuicideLegal, hasButton: config.hasButton, whiteHandicapBonus: config.whiteHandicapBonusRuleText))
            messageList.appendAndSend(command: GtpCommandBuilder.komiCommand(config.komi))
            messageList.appendAndSend(command: GtpCommandBuilder.playoutDoublingAdvantageCommand(config.playoutDoublingAdvantage))
            messageList.appendAndSend(command: GtpCommandBuilder.analysisWideRootNoiseCommand(config.analysisWideRootNoise))
            messageList.appendAndSend(commands: GtpCommandBuilder.symmetricHumanAnalysisCommands(humanSLProfile: config.humanSLProfile, humanProfileForWhite: config.humanProfileForWhite, humanRatioForBlack: config.humanRatioForBlack, humanRatioForWhite: config.humanRatioForWhite))
            sendShowBoardCommand(messageList: messageList)
        }
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
}
