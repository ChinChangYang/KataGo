//
//  KataGoModel.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2023/10/1.
//

import SwiftUI
import SwiftData
import KataGoInterface

@Observable
class BoardSize {
    var width: CGFloat = 19
    var height: CGFloat = 19

    func locationToMove(location: Location) -> String? {
        guard !location.pass else { return "pass" }
        let x = location.x
        let y = Int(height) - location.y

        guard (1...Int(height)).contains(y), (0..<Int(width)).contains(x) else { return nil }

        return Coordinate.xLabelMap[x].map { "\($0)\(y)" }
    }
}

struct BoardPoint: Hashable, Comparable {
    let x: Int
    let y: Int

    func isPass(width: Int, height: Int) -> Bool {
        self == BoardPoint.pass(width: width, height: height)
    }

    static func passY(height: Int) -> Int {
        return height + 1
    }

    static func pass(width: Int, height: Int) -> BoardPoint {
        return BoardPoint(x: width - 1, y: passY(height: height))
    }

    static func < (lhs: BoardPoint, rhs: BoardPoint) -> Bool {
        return (lhs.y, lhs.x) < (rhs.y, rhs.x)
    }
}

extension BoardPoint {
    static func getPositionY(y: Int, height: CGFloat, verticalFlip: Bool) -> CGFloat {
        return verticalFlip ? CGFloat(y) : (height - CGFloat(y) - 1)
    }

    // This function calculates the vertical position (Y-coordinate) for a given board point.
    // It takes into account the height of the board and whether the board is flipped vertically.
    // The pass area is always located at the bottom of the board, regardless of the vertical orientation.
    // If the board is flipped and the current point represents a pass, we adjust the vertical flip condition accordingly.
    func getPositionY(height: CGFloat, verticalFlip: Bool) -> CGFloat {
        // Determine if the vertical flip condition should account for the pass area
        let verticalFlipWithPass = verticalFlip || (y == BoardPoint.passY(height: Int(height)))
        // Compute and return the Y-coordinate based on the current board point, height, and adjusted vertical flip state
        return BoardPoint.getPositionY(y: y, height: height, verticalFlip: verticalFlipWithPass)
    }
}

@Observable
class Stones {
    var blackPoints: [BoardPoint] = []
    var whitePoints: [BoardPoint] = []
    var moveOrder: [BoardPoint: Character] = [:]
    var blackStonesCaptured: Int = 0
    var whiteStonesCaptured: Int = 0
    var isReady: Bool = true
}

enum PlayerColor {
    case black
    case white
    case unknown

    var symbol: String? {
        if self == .black {
            return "b"
        } else if self == .white {
            return "w"
        } else {
            return nil
        }
    }
}

@Observable
class Turn {
    var nextColorForPlayCommand = PlayerColor.black
    var nextColorFromShowBoard = PlayerColor.black
}

extension Turn {
    func toggleNextColorForPlayCommand() {
        if nextColorForPlayCommand == .black {
            nextColorForPlayCommand = .white
        } else {
            nextColorForPlayCommand = .black
        }
    }

    var nextColorSymbolForPlayCommand: String? {
        nextColorForPlayCommand.symbol
    }
}

struct AnalysisInfo {
    let visits: Int
    let winrate: Float
    let scoreLead: Float
    let utilityLcb: Float
}

struct OwnershipUnit: Identifiable {
    let point: BoardPoint
    let whiteness: Float
    let scale: Float
    let opacity: Float

    var id: Int {
        point.hashValue
    }
}

@Observable
class Analysis {
    var nextColorForAnalysis = PlayerColor.white
    var info: [BoardPoint: AnalysisInfo] = [:]
    var ownershipUnits: [OwnershipUnit] = []

    // Get maximum winrate in the analysis info
    var maxWinrate: Float? {
        let winrates = info.values.map(\.winrate)
        return winrates.max()
    }

    private var maxScoreLead: Float? {
        let scoreLeads = info.values.map(\.scoreLead)
        return scoreLeads.max()
    }

    var blackWinrate: Float? {
        guard let maxWinrate = maxWinrate else { return nil }
        let blackWinrate = (nextColorForAnalysis == .black) ? maxWinrate : (1 - maxWinrate)
        return blackWinrate
    }

    var blackScore: Float? {
        guard let maxScore = maxScoreLead else { return nil }
        let blackScore = (nextColorForAnalysis == .black) ? maxScore : -maxScore
        return blackScore
    }

    func clear() {
        info = [:]
        ownershipUnits = []
    }
}

struct Dimensions {
    let squareLength: CGFloat
    let squareLengthDiv2: CGFloat
    let squareLengthDiv4: CGFloat
    let squareLengthDiv8: CGFloat
    let squareLengthDiv16: CGFloat
    let boardLineStartX: CGFloat
    let boardLineStartY: CGFloat
    let stoneLength: CGFloat
    let width: CGFloat
    let height: CGFloat
    let gobanWidth: CGFloat
    let gobanHeight: CGFloat
    let boardLineBoundWidth: CGFloat
    let boardLineBoundHeight: CGFloat
    let gobanStartX: CGFloat
    let gobanStartY: CGFloat
    let coordinate: Bool
    let capturedStonesWidth: CGFloat = 80
    let capturedStonesHeight: CGFloat
    let capturedStonesStartY: CGFloat
    let totalWidth: CGFloat
    let totalHeight: CGFloat
    let drawHeight: CGFloat

    init(size: CGSize,
         width: CGFloat,
         height: CGFloat,
         showCoordinate coordinate: Bool = false,
         showPass: Bool = true,
         isDrawingCapturedStones: Bool = true) {
        self.width = width
        self.height = height
        self.coordinate = coordinate
        self.capturedStonesHeight = isDrawingCapturedStones ? 20 : 0

        totalWidth = size.width
        totalHeight = size.height
        let coordinateEntity: CGFloat = coordinate ? 1 : 0
        let gobanWidthEntity = width + coordinateEntity
        let gobanHeightEntity = height + coordinateEntity
        let passHeightEntity = showPass ? 1.5 : 0
        let squareWidth = totalWidth / (gobanWidthEntity + 1)
        let squareHeight = max(0, totalHeight - capturedStonesHeight) / (gobanHeightEntity + passHeightEntity + 1)
        squareLength = min(squareWidth, squareHeight)
        squareLengthDiv2 = squareLength / 2
        squareLengthDiv4 = squareLength / 4
        squareLengthDiv8 = squareLength / 8
        squareLengthDiv16 = squareLength / 16
        let gobanPadding = squareLength / 2
        stoneLength = squareLength * 0.95
        gobanWidth = (gobanWidthEntity * squareLength) + gobanPadding
        gobanHeight = (gobanHeightEntity * squareLength) + gobanPadding
        gobanStartX = (totalWidth - gobanWidth) / 2
        let passHeight = passHeightEntity * squareLength
        gobanStartY = max(capturedStonesHeight, (totalHeight - passHeight - gobanHeight) / 2)
        boardLineBoundWidth = (width - 1) * squareLength
        boardLineBoundHeight = (height - 1) * squareLength
        let coordinateLength = coordinateEntity * squareLength
        boardLineStartX = (totalWidth - boardLineBoundWidth + coordinateLength) / 2
        boardLineStartY = (gobanStartY == capturedStonesHeight) ? (capturedStonesHeight + coordinateLength + (squareLength + gobanPadding) / 2) : (totalHeight - passHeight - boardLineBoundHeight + coordinateLength) / 2
        capturedStonesStartY = gobanStartY - capturedStonesHeight
        drawHeight = gobanHeight + capturedStonesHeight + (passHeight * 2)
    }

    func getCapturedStoneStartX(xOffset: CGFloat) -> CGFloat {
        gobanStartX + (gobanWidth / 2) + ((-3 + (6 * xOffset)) * max(gobanWidth / 2, capturedStonesWidth) / 4)
    }
}

/// Message with a text and an ID
struct Message: Identifiable, Equatable, Hashable {
    /// Default maximum message characters
    static let defaultMaxMessageCharacters = 5000

    /// Identification of this message
    let id = UUID()

    /// Text of this message
    let text: String

    /// Initialize a message with a text and a max length
    /// - Parameters:
    ///   - text: a text
    ///   - maxLength: a max length
    init(text: String, maxLength: Int = defaultMaxMessageCharacters) {
        self.text = String(text.prefix(maxLength))
    }
}

@Observable
class MessageList {
    static let defaultMaxMessageLines = 1000

    var messages: [Message] = []

    func shrink() {
        while messages.count > MessageList.defaultMaxMessageLines {
            messages.removeFirst()
        }
    }

    private func append(command: String) {
        messages.append(Message(text: "> \(command)"))
    }

    func appendAndSend(command: String) {
        append(command: command)
        KataGoHelper.sendCommand(command)
    }

    func appendAndSend(commands: [String]) {
        commands.forEach(appendAndSend)
    }

    func maybeLoadSgf(sgf: String) {
        let supportDirectory = try? FileManager.default.url(for: .documentDirectory,
                                                            in: .userDomainMask,
                                                            appropriateFor: nil,
                                                            create: true)

        if let supportDirectory {
            let file = supportDirectory.appendingPathComponent("temp.sgf")
            do {
                try sgf.write(to: file, atomically: false, encoding: .utf8)
                let path = file.path()
                appendAndSend(command: "loadsgf \(path)")
            } catch {
                // Do nothing
            }
        }
    }
}

enum AnalysisStatus {
    case clear
    case pause
    case run
}

extension String {
    static let inActiveSgf = ""

    var isActiveSgf: Bool {
        return self != .inActiveSgf
    }
}

extension Int {
    static let inActiveCurrentIndex = -1

    var isActiveSgfIndex: Bool {
        return self > .inActiveCurrentIndex
    }
}

enum EyeStatus {
    case opened
    case closed
}

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
        if (!isAutoPlaying) &&
            (nextColorForPlayCommand == .black) &&
            (config.blackMaxTime > 0) &&
            (passCount < 2) {
            return config.getKataGenMoveAnalyzeCommands(maxTime: config.blackMaxTime)
        } else if (!isAutoPlaying) &&
                    (nextColorForPlayCommand == .white) &&
                    (config.whiteMaxTime > 0) &&
                    (passCount < 2) {
            return config.getKataGenMoveAnalyzeCommands(maxTime: config.whiteMaxTime)
        } else {
            return [config.getKataFastAnalyzeCommand()]
        }
    }

    private func requestAnalysis(config: Config, messageList: MessageList, nextColorForPlayCommand: PlayerColor?) {
        let commands = getRequestAnalysisCommands(config: config, nextColorForPlayCommand: nextColorForPlayCommand)
        messageList.appendAndSend(commands: commands)
        waitingForAnalysis = true
    }

    func maybeRequestAnalysis(config: Config, nextColorForPlayCommand: PlayerColor?, messageList: MessageList) {
        if (shouldRequestAnalysis(config: config, nextColorForPlayCommand: nextColorForPlayCommand)) {
            requestAnalysis(config: config,
                            messageList: messageList,
                            nextColorForPlayCommand: nextColorForPlayCommand)
        }
    }

    func maybeRequestAnalysis(config: Config, messageList: MessageList) {
        return maybeRequestAnalysis(config: config, nextColorForPlayCommand: nil, messageList: messageList)
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
            (analysisStatus != .clear) &&
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

    func sendPostExecutionCommands(config: Config, messageList: MessageList, player: Turn) {
        sendShowBoardCommand(messageList: messageList)

        maybeRequestAnalysis(config: config,
                             nextColorForPlayCommand: player.nextColorForPlayCommand,
                             messageList: messageList)

        maybeRequestClearAnalysisData(config: config,
                                      nextColorForPlayCommand: player.nextColorForPlayCommand)
    }

    func maybeUpdateScoreLeads(gameRecord: GameRecord, analysis: Analysis) {
        if isEditing && (analysisStatus != .clear),
           let scoreLead = analysis.blackScore {
            withAnimation(.spring) {
                gameRecord.scoreLeads?[gameRecord.currentIndex] = scoreLead
            }
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

    func play(turn: String, move: String, messageList: MessageList) {
        messageList.appendAndSend(command: "play \(turn) \(move)")

        if move == "pass" {
            passCount = passCount + 1
        } else {
            passCount = 0
        }
    }

    func undo(messageList: MessageList) {
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
        gameRecord: GameRecord?,
        messageList: MessageList,
        player: Turn
    ) {
        guard let sgf = getSgf(gameRecord: gameRecord) else {
            return
        }

        let sgfHelper = SgfHelper(sgf: sgf)
        var movesExecuted = 0

        while let currentIndex = getCurrentIndex(gameRecord: gameRecord),
            sgfHelper.getMove(at: currentIndex - 1) != nil {
            undoIndex(gameRecord: gameRecord)
            undo(messageList: messageList)
            player.toggleNextColorForPlayCommand()

            movesExecuted += 1
            if let limit = limit, movesExecuted >= limit {
                break
            }
        }
    }

    func forwardMoves(
        limit: Int?,
        gameRecord: GameRecord,
        board: BoardSize,
        messageList: MessageList,
        player: Turn,
        audioModel: AudioModel

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
                play(turn: nextPlayer, move: move, messageList: messageList)
                player.toggleNextColorForPlayCommand()

                movesExecuted += 1
                if let limit = limit, movesExecuted >= limit {
                    break
                }
            }
        }

        if movesExecuted > 0 {
            audioModel.playPlaySound(soundEffect: gameRecord.concreteConfig.soundEffect)
        }
    }
}

@Observable
class Winrate {
    var black: Float = 0.5

    var white: Float {
        1 - black
    }
}

@Observable
class Score {
    var black: Float = 0.0

    var white: Float {
        -black
    }
}

struct Coordinate {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    var xLabel: String? {
        return Coordinate.xLabelMap[x]
    }

    var yLabel: String {
        return String(y)
    }

    var move: String? {
        if let point, point.isPass(width: width, height: height) {
            return "pass"
        } else if let xLabel {
            return "\(xLabel)\(yLabel)"
        } else {
            return nil
        }
    }

    var point: BoardPoint? {
        BoardPoint(x: x, y: y - 1)
    }

    // Mapping letters A-AZ (without I) to numbers 0-49
    static let xMap: [String: Int] = [
        "A": 0, "B": 1, "C": 2, "D": 3, "E": 4,
        "F": 5, "G": 6, "H": 7, "J": 8, "K": 9,
        "L": 10, "M": 11, "N": 12, "O": 13, "P": 14,
        "Q": 15, "R": 16, "S": 17, "T": 18, "U": 19,
        "V": 20, "W": 21, "X": 22, "Y": 23, "Z": 24,
        "AA": 25, "AB": 26, "AC": 27, "AD": 28, "AE": 29,
        "AF": 30, "AG": 31, "AH": 32, "AJ": 33, "AK": 34,
        "AL": 35, "AM": 36, "AN": 37, "AO": 38, "AP": 39,
        "AQ": 40, "AR": 41, "AS": 42, "AT": 43, "AU": 44,
        "AV": 45, "AW": 46, "AX": 47, "AY": 48, "AZ": 49
    ]

    static let xLabelMap: [Int: String] = [
        0: "A", 1: "B", 2: "C", 3: "D", 4: "E",
        5: "F", 6: "G", 7: "H", 8: "J", 9: "K",
        10: "L", 11: "M", 12: "N", 13: "O", 14: "P",
        15: "Q", 16: "R", 17: "S", 18: "T", 19: "U",
        20: "V", 21: "W", 22: "X", 23: "Y", 24: "Z",
        25: "AA", 26: "AB", 27: "AC", 28: "AD", 29: "AE",
        30: "AF", 31: "AG", 32: "AH", 33: "AJ", 34: "AK",
        35: "AL", 36: "AM", 37: "AN", 38: "AO", 39: "AP",
        40: "AQ", 41: "AR", 42: "AS", 43: "AT", 44: "AU",
        45: "AV", 46: "AW", 47: "AX", 48: "AY", 49: "AZ"
    ]

    init?(x: Int, y: Int, width: Int, height: Int) {
        guard ((1...height).contains(y) && (0..<width).contains(x)) || BoardPoint(x: x, y: y - 1).isPass(width: width, height: height) else { return nil }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init?(xLabel: String, yLabel: String) {
        self.init(xLabel: xLabel, yLabel: yLabel, width: 19, height: 19)
    }

    init?(xLabel: String, yLabel: String, width: Int, height: Int) {
        if let x = Coordinate.xMap[xLabel.uppercased()],
           let y = Int(yLabel) {
            self.init(x: x, y: y, width: width, height: height)
        } else {
            return nil
        }
    }
}

@Observable
class TopUIState {
    var importing = false
    var confirmingDeletion = false
}
