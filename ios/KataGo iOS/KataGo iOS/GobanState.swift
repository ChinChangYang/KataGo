//
//  GobanState.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/11/17.
//

import SwiftUI
import KataGoInterface

@Observable
class GobanState {
    var waitingForAnalysis = false
    var requestingClearAnalysis = false
    var analysisStatus = AnalysisStatus.run
    var showBoardCount: Int = 0
    var isEditing = false
    var isShownBoard: Bool = false
    var eyeStatus = EyeStatus.opened
    var isAutoPlaying: Bool = false
    var passCount: Int = 0
    var branchSgf: String = .inActiveSgf
    var branchIndex: Int = .inActiveCurrentIndex
    var confirmingAIOverwrite: Bool = false

    func sendShowBoardCommand(messageList: MessageList) {
        messageList.appendAndSend(command: "showboard")
        showBoardCount = showBoardCount + 1
    }

    func consumeShowBoardResponse(response: String) -> Bool {
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
                return config.getKataGenMoveAnalyzeCommands(maxTime: config.blackMaxTime)
            } else if (nextColorForPlayCommand == .white) && (config.whiteMaxTime > 0) {
                return config.getKataGenMoveAnalyzeCommands(maxTime: config.whiteMaxTime)
            }
        }

        return [config.getKataFastAnalyzeCommand()]
    }

    func requestAnalysis(config: Config, messageList: MessageList, nextColorForPlayCommand: PlayerColor?) {
        let commands = getRequestAnalysisCommands(config: config, nextColorForPlayCommand: nextColorForPlayCommand)
        messageList.appendAndSend(commands: commands)
        waitingForAnalysis = true
    }

    func maybeRequestAnalysis(
        config: Config,
        nextColorForPlayCommand: PlayerColor?,
        messageList: MessageList,
        gameRecord: GameRecord
    ) {
        if (shouldRequestAnalysis(config: config, nextColorForPlayCommand: nextColorForPlayCommand)) {
            requestAnalysis(config: config,
                            messageList: messageList,
                            nextColorForPlayCommand: nextColorForPlayCommand)
        }
    }

    func maybeRequestAnalysis(
        config: Config,
        messageList: MessageList,
        gameRecord: GameRecord
    ) {
        return maybeRequestAnalysis(
            config: config,
            nextColorForPlayCommand: nil,
            messageList: messageList,
            gameRecord: gameRecord)
    }

    func shouldRequestAnalysis(config: Config, nextColorForPlayCommand: PlayerColor?) -> Bool {
        if let nextColorForPlayCommand {
            return (analysisStatus != .clear) && config.isAnalysisForCurrentPlayer(nextColorForPlayCommand: nextColorForPlayCommand)
        } else {
            return (analysisStatus != .clear)
        }
    }

    func maybeRequestClearAnalysisData(config: Config, nextColorForPlayCommand: PlayerColor?) {
        if !shouldRequestAnalysis(config: config, nextColorForPlayCommand: nextColorForPlayCommand) {
            requestingClearAnalysis = true
        }
    }

    func maybeRequestClearAnalysisData(config: Config) {
        maybeRequestClearAnalysisData(config: config, nextColorForPlayCommand: nil)
    }

    func maybePauseAnalysis() {
        if analysisStatus == .run {
            analysisStatus = .pause
            waitingForAnalysis = true
        }
    }

    func shouldGenMove(config: Config, player: Turn) -> Bool {
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

    func sendPostExecutionCommands(
        config: Config,
        messageList: MessageList,
        player: Turn,
        gameRecord: GameRecord
    ) {
        sendShowBoardCommand(messageList: messageList)

        maybeRequestAnalysis(
            config: config,
            nextColorForPlayCommand: player.nextColorForPlayCommand,
            messageList: messageList,
            gameRecord: gameRecord
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

    func
    maybeUpdateAnalysisData(
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
        }
    }

    func maybeSendAsymmetricHumanAnalysisCommands(nextColorForPlayCommand: PlayerColor,
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

    func play(turn: String, move: String, messageList: MessageList, stones: Stones) {
        stones.isReady = false
        messageList.appendAndSend(command: "play \(turn) \(move)")

        if move == "pass" {
            passCount = passCount + 1
        } else {
            passCount = 0
        }
    }

    func undo(messageList: MessageList, stones: Stones) {
        stones.isReady = false
        messageList.appendAndSend(command: "undo")

        if passCount > 0 {
            passCount = passCount - 1
        }
    }

    var isBranchActive: Bool {
        return (branchSgf.isActiveSgf) && (branchIndex.isActiveSgfIndex)
    }

    func deactivateBranch() {
        branchSgf = .inActiveSgf
        branchIndex = .inActiveCurrentIndex
    }

    func undoBranchIndex() {
        if (branchIndex > 0) {
            branchIndex = branchIndex - 1
        }
    }

    func undoIndex(gameRecord: GameRecord?) {
        if isBranchActive {
            undoBranchIndex()
        } else {
            gameRecord?.undo()
        }
    }

    func getSgf(gameRecord: GameRecord?) -> String? {
        isBranchActive ? branchSgf : gameRecord?.sgf
    }

    func getCurrentIndex(gameRecord: GameRecord?) -> Int? {
        isBranchActive ? branchIndex : gameRecord?.currentIndex
    }

    func backwardMoves(
        limit: Int?,
        gameRecord: GameRecord,
        messageList: MessageList,
        player: Turn,
        stones: Stones
    ) {
        guard let sgf = getSgf(gameRecord: gameRecord) else {
            return
        }

        let sgfHelper = SgfHelper(sgf: sgf)
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
            player: player,
            gameRecord: gameRecord
        )
    }

    func getNextMove(gameRecord: GameRecord) -> Move? {
        guard let sgf = getSgf(gameRecord: gameRecord),
              let currentIndex = getCurrentIndex(gameRecord: gameRecord) else {
            return nil
        }

        let sgfHelper = SgfHelper(sgf: sgf)
        let nextMove = sgfHelper.getMove(at: currentIndex)

        return nextMove
    }

    func forwardMoves(
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

        let sgfHelper = SgfHelper(sgf: sgf)
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
            audioModel?.playPlaySound(soundEffect: gameRecord.concreteConfig.soundEffect)
        }

        sendPostExecutionCommands(
            config: gameRecord.concreteConfig,
            messageList: messageList,
            player: player,
            gameRecord: gameRecord
        )
    }

    func go(to targetIndex: Int,
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

    func isOverwriting(gameRecord: GameRecord) -> Bool {
        guard let sgf = getSgf(gameRecord: gameRecord),
              let moveSize = SgfHelper(sgf: sgf).moveSize,
              let currentIndex = getCurrentIndex(gameRecord: gameRecord) else {
            return false
        }

        return (currentIndex < moveSize) && (isEditing || isBranchActive)
    }

    func maybeUpdateMoves(gameRecord: GameRecord, board: BoardSize, sgfHelper: SgfHelper? = nil) {
        if gameRecord.moves == nil { gameRecord.moves = [:] }
        let currentIndex = gameRecord.currentIndex
        let previousIndex = currentIndex - 1

        if isEditing || gameRecord.moves?[currentIndex] == nil ||
            (previousIndex >= 0 && gameRecord.moves?[previousIndex] == nil) {
            let sgfHelper = sgfHelper ?? SgfHelper(sgf: gameRecord.sgf)

            if let location = sgfHelper.getMove(at: currentIndex)?.location {
                gameRecord.moves?[currentIndex] = board.locationToMove(location: location)
            }

            if previousIndex >= 0,
               let location = sgfHelper.getMove(at: previousIndex)?.location {
                gameRecord.moves?[previousIndex] = board.locationToMove(location: location)
            }
        }
    }
}
