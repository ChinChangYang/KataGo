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

extension BoardPoint {
    init(location: Location, width: Int, height: Int) {
        if location.pass {
            x = width - 1
            y = BoardPoint.passY(height: height)
        } else {
            x = location.x
            // Subtract 1 from y to make it 0-indexed
            y = height - location.y - 1
        }
    }
}

extension BoardPoint {

    static func toString(
        _ points: [BoardPoint],
        width: Int,
        height: Int
    ) -> String? {

        guard !points.isEmpty else { return nil }

        let text = points.reduce("") {
            let coordinate = Coordinate(
                x: $1.x,
                y: $1.y + 1,
                width: width,
                height: height
            )

            if let move = coordinate?.move {
                return $0 == "" ? move : "\($0) \(move)"
            } else {
                return $0
            }
        }

        return text
    }
}

extension BoardPoint {
    init?(move: String, width: Int, height: Int) {
        if move == "pass" {
            self = BoardPoint.pass(width: width, height: height)
        } else {
            let pattern = /(\w+)(\d+)/
            guard let match = move.firstMatch(of: pattern) else { return nil }

            let xLabel = String(match.1)
            let yLabel = String(match.2)

            let coordinate = Coordinate(
                xLabel: xLabel,
                yLabel: yLabel,
                width: width,
                height: height
            )

            guard let boardPoint = coordinate?.point else { return nil }

            self = boardPoint
        }
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

    var name: String {
        if self == .black {
            "Black"
        } else if self == .white {
            "White"
        } else {
            "Unknown"
        }
    }

    var other: PlayerColor {
        switch self {
        case .black: .white
        case .white: .black
        case .unknown: .unknown
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

    var isBlack: Bool {
        whiteness < 0.1
    }

    var isWhite: Bool {
        whiteness > 0.9
    }

    var isSchrodinger: Bool {
        (abs(whiteness - 0.5) < 0.2) && scale > 0.4
    }

    var nearBlack: Bool {
        whiteness < 0.3
    }

    var nearWhite: Bool {
        whiteness > 0.7
    }
}

@Observable
class Analysis {
    var nextColorForAnalysis = PlayerColor.white
    var info: [BoardPoint: AnalysisInfo] = [:]
    var ownershipUnits: [OwnershipUnit] = []

    var maxVisits: Int? {
        let visits = info.values.map(\.visits)
        return visits.max()
    }

    var maxWinrate: Float? {
        guard let maxVisits else { return nil }
        return info.values.first(where: { $0.visits == maxVisits })?.winrate
    }

    private var maxScoreLead: Float? {
        guard let maxVisits else { return nil }
        return info.values.first(where: { $0.visits == maxVisits })?.scoreLead
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

    func getBestMove(width: Int, height: Int) -> String? {
        guard let firstInfo = info.first else { return nil }

        let bestMoveInfo = info.reduce(firstInfo) {
            if $0.value.utilityLcb < $1.value.utilityLcb {
                $1
            } else {
                $0
            }
        }

        let coordinate = Coordinate(
            x: bestMoveInfo.key.x,
            y: bestMoveInfo.key.y + 1,
            width: width,
            height: height
        )

        return coordinate?.move
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
    let emptyHeight: CGFloat

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
        drawHeight = gobanHeight + capturedStonesHeight + passHeight
        emptyHeight = totalHeight - drawHeight
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

    var index: Int {
        x + ((y - 1) * width)
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

extension Coordinate {
    init?(move: String, width: Int, height: Int) {
        let pattern = /(\w+)(\d+)/
        guard let match = move.firstMatch(of: pattern) else { return nil }

        let xLabel = String(match.1)
        let yLabel = String(match.2)

        guard let coordinate = Coordinate(
            xLabel: xLabel,
            yLabel: yLabel,
            width: width,
            height: height
        ) else {
            return nil
        }

        self = coordinate
    }
}

@Observable
class TopUIState {
    var importing = false
    var confirmingDeletion = false
}
