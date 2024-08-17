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

    static func < (lhs: BoardPoint, rhs: BoardPoint) -> Bool {
        return (lhs.y, lhs.x) < (rhs.y, rhs.x)
    }
}

@Observable
class Stones {
    var blackPoints: [BoardPoint] = []
    var whitePoints: [BoardPoint] = []
    var moveOrder: [Character: BoardPoint] = [:]
}

enum PlayerColor {
    case black
    case white

    var symbol: String {
        if self == .black {
            return "b"
        } else {
            return "w"
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

    var nextColorSymbolForPlayCommand: String {
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

    init(size: CGSize, width: CGFloat, height: CGFloat, showCoordinate coordinate: Bool = false) {
        self.width = width
        self.height = height
        self.coordinate = coordinate

        let totalWidth = size.width
        let totalHeight = size.height
        let coordinateEntity: CGFloat = coordinate ? 1 : 0
        let gobanWidthEntity = width + coordinateEntity
        let gobanHeightEntiry = height + coordinateEntity
        let squareWidth = totalWidth / (gobanWidthEntity + 1)
        let squareHeight = totalHeight / (gobanHeightEntiry + 1)
        squareLength = min(squareWidth, squareHeight)
        squareLengthDiv2 = squareLength / 2
        squareLengthDiv4 = squareLength / 4
        squareLengthDiv8 = squareLength / 8
        squareLengthDiv16 = squareLength / 16
        let gobanPadding = squareLength / 2
        stoneLength = squareLength * 0.95
        gobanWidth = (gobanWidthEntity * squareLength) + gobanPadding
        gobanHeight = (gobanHeightEntiry * squareLength) + gobanPadding
        gobanStartX = (totalWidth - gobanWidth) / 2
        gobanStartY = (totalHeight - gobanHeight) / 2
        boardLineBoundWidth = (width - 1) * squareLength
        boardLineBoundHeight = (height - 1) * squareLength
        let coordinateLength = coordinateEntity * squareLength
        boardLineStartX = (totalWidth - boardLineBoundWidth + coordinateLength) / 2
        boardLineStartY = (totalHeight - boardLineBoundHeight + coordinateLength) / 2
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
class MessagesObject {
    static private let defaultMaxMessageLines = 1000

    var messages: [Message] = []

    func shrink() {
        while messages.count > MessagesObject.defaultMaxMessageLines {
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

    var xLabel: String? {
        return Coordinate.xLabelMap[x]
    }

    var yLabel: String {
        return String(y)
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

    init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    init?(xLabel: String, yLabel: String) {
        if let x = Coordinate.xMap[xLabel.uppercased()],
           let y = Int(yLabel) {
            self.x = x
            self.y = y
        } else {
            return nil
        }
    }
}

extension ModelContext {
    @MainActor
    func safelyDelete(gameRecord: GameRecord) {
        Task {
            // Yield control to prevent potential race conditions caused by
            // simultaneous access to the game record.
            await Task.yield()

            // Perform the deletion of the game record on the main actor to
            // ensure thread safety.
            await MainActor.run {
                delete(gameRecord)
            }
        }
    }
}
