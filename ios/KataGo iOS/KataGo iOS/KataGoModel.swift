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
}

struct BoardPoint: Hashable, Comparable {
    let x: Int
    let y: Int

    func isPass(width: Int, height: Int) -> Bool {
        self == BoardPoint.pass(width: width, height: height)
    }

    static func pass(width: Int, height: Int) -> BoardPoint {
        return BoardPoint(x: width - 1, y: height + 1)
    }

    static func < (lhs: BoardPoint, rhs: BoardPoint) -> Bool {
        return (lhs.y, lhs.x) < (rhs.y, rhs.x)
    }
}

@Observable
class Stones {
    var blackPoints: [BoardPoint] = []
    var whitePoints: [BoardPoint] = []
    var moveOrder: [BoardPoint: Character] = [:]
    var blackStonesCaptured: Int = 0
    var whiteStonesCaptured: Int = 0
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

struct Ownership {
    let mean: Float
    let stdev: Float?

    init(mean: Float, stdev: Float?) {
        self.mean = mean
        self.stdev = stdev
    }
}

@Observable
class Analysis {
    var nextColorForAnalysis = PlayerColor.white
    var info: [BoardPoint: AnalysisInfo] = [:]
    var rootInfo: AnalysisInfo?
    var ownership: [BoardPoint: Ownership] = [:]

    func clear() {
        info = [:]
        ownership = [:]
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
    let capturedStonesHeight: CGFloat = 20
    let capturedStonesStartY: CGFloat

    init(size: CGSize, width: CGFloat, height: CGFloat, showCoordinate coordinate: Bool = false) {
        self.width = width
        self.height = height
        self.coordinate = coordinate

        let totalWidth = size.width
        let totalHeight = size.height
        let coordinateEntity: CGFloat = coordinate ? 1 : 0
        let gobanWidthEntity = width + coordinateEntity
        let gobanHeightEntity = height + coordinateEntity
        let passHeightEntity = 1.5
        let squareWidth = totalWidth / (gobanWidthEntity + 1)
        let squareHeight = max(0, totalHeight) / (gobanHeightEntity + passHeightEntity + 1)
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
        boardLineStartY = max(capturedStonesHeight + (squareLength + coordinateLength) / 2, (totalHeight - passHeight - boardLineBoundHeight + coordinateLength) / 2)
        capturedStonesStartY = gobanStartY - capturedStonesHeight
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
}

enum AnalysisStatus {
    case clear
    case pause
    case run
}

@Observable
class GobanState {
    var waitingForAnalysis = false
    var requestingClearAnalysis = false
    var analysisStatus = AnalysisStatus.run

    private func requestAnalysis(config: Config) {
        KataGoHelper.sendCommand(config.getKataFastAnalyzeCommand())
        waitingForAnalysis = true
    }

    func maybeRequestAnalysis(config: Config, nextColorForPlayCommand: PlayerColor?) {
        if (shouldRequestAnalysis(config: config, nextColorForPlayCommand: nextColorForPlayCommand)) {
            requestAnalysis(config: config)
        }
    }

    func maybeRequestAnalysis(config: Config) {
        return maybeRequestAnalysis(config: config, nextColorForPlayCommand: nil)
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

    func maybeSendAsymmetricHumanAnalysisCommands(config: Config, nextColorForPlayCommand: PlayerColor) {
        if !config.isEqualBlackWhiteHumanSettings {
            if nextColorForPlayCommand == .black {
                KataGoHelper.sendCommand("kata-set-param humanSLProfile \(config.humanSLProfile)")
                KataGoHelper.sendCommand("kata-set-param humanSLRootExploreProbWeightful \(config.humanSLRootExploreProbWeightful)")
            } else if nextColorForPlayCommand == .white {
                KataGoHelper.sendCommand("kata-set-param humanSLProfile \(config.humanProfileForWhite)")
                KataGoHelper.sendCommand("kata-set-param humanSLRootExploreProbWeightful \(config.humanRatioForWhite)")
            }
        }
    }

    func maybeSendSymmetricHumanAnalysisCommands(config: Config) {
        if config.isEqualBlackWhiteHumanSettings {
            KataGoHelper.sendCommand("kata-set-param humanSLProfile \(config.humanSLProfile)")
            KataGoHelper.sendCommand("kata-set-param humanSLRootExploreProbWeightful \(config.humanSLRootExploreProbWeightful)")
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

    // Mapping letters A-AD (without I) to numbers 0-28
    static let xMap: [String: Int] = [
        "A": 0, "B": 1, "C": 2, "D": 3, "E": 4,
        "F": 5, "G": 6, "H": 7, "J": 8, "K": 9,
        "L": 10, "M": 11, "N": 12, "O": 13, "P": 14,
        "Q": 15, "R": 16, "S": 17, "T": 18, "U": 19,
        "V": 20, "W": 21, "X": 22, "Y": 23, "Z": 24,
        "AA": 25, "AB": 26, "AC": 27, "AD": 28
    ]

    static let xLabelMap: [Int: String] = [
        0: "A", 1: "B", 2: "C", 3: "D", 4: "E",
        5: "F", 6: "G", 7: "H", 8: "J", 9: "K",
        10: "L", 11: "M", 12: "N", 13: "O", 14: "P",
        15: "Q", 16: "R", 17: "S", 18: "T", 19: "U",
        20: "V", 21: "W", 22: "X", 23: "Y", 24: "Z",
        25: "AA", 26: "AB", 27: "AC", 28: "AD"
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
