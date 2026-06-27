//
//  KataGoModel.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2023/10/1.
//

import SwiftUI
import SwiftData

@Observable
public class BoardSize {
    public init() {}

    public var width: CGFloat = 19
    public var height: CGFloat = 19

    public func locationToMove(location: Location) -> String? {
        guard !location.pass else { return "pass" }
        let x = location.x
        let y = Int(height) - location.y

        guard (1...Int(height)).contains(y), (0..<Int(width)).contains(x) else { return nil }

        return Coordinate.xLabelMap[x].map { "\($0)\(y)" }
    }
}

public struct BoardPoint: Hashable, Comparable, Sendable {
    public let x: Int
    public let y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    public func isPass(width: Int, height: Int) -> Bool {
        self == BoardPoint.pass(width: width, height: height)
    }

    public static func passY(height: Int) -> Int {
        return height + 1
    }

    public static func pass(width: Int, height: Int) -> BoardPoint {
        return BoardPoint(x: width - 1, y: passY(height: height))
    }

    public static func < (lhs: BoardPoint, rhs: BoardPoint) -> Bool {
        return (lhs.y, lhs.x) < (rhs.y, rhs.x)
    }
}

extension BoardPoint {
    public static func getPositionY(y: Int, height: CGFloat, verticalFlip: Bool) -> CGFloat {
        return verticalFlip ? CGFloat(y) : (height - CGFloat(y) - 1)
    }

    // This function calculates the vertical position (Y-coordinate) for a given board point.
    // It takes into account the height of the board and whether the board is flipped vertically.
    // The pass area is always located at the bottom of the board, regardless of the vertical orientation.
    // If the board is flipped and the current point represents a pass, we adjust the vertical flip condition accordingly.
    public func getPositionY(height: CGFloat, verticalFlip: Bool) -> CGFloat {
        // Determine if the vertical flip condition should account for the pass area
        let verticalFlipWithPass = verticalFlip || (y == BoardPoint.passY(height: Int(height)))
        // Compute and return the Y-coordinate based on the current board point, height, and adjusted vertical flip state
        return BoardPoint.getPositionY(y: y, height: height, verticalFlip: verticalFlipWithPass)
    }
}

extension BoardPoint {
    public init(location: Location, width: Int, height: Int) {
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

    public static func toString(
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

    /// Like `toString`, but never nil: an empty side yields "" instead of nil.
    /// A per-index refill writes into a `[Int: String]` dict, where `dict[i] = nil`
    /// REMOVES the key — diverging from the SGF-import path (which writes "" via
    /// `joined`) and breaking the widget's `lastIndex` / `getCapturedStones` logic,
    /// which distinguish "no entry" from "empty entry". See `GameEntity.init`.
    public static func refillString(_ points: [BoardPoint], width: Int, height: Int) -> String {
        toString(points, width: width, height: height) ?? ""
    }
}

extension BoardPoint {
    public init?(move: String, width: Int, height: Int) {
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
public class Stones: Equatable {
    public init() {}

    public var blackPoints: [BoardPoint] = []
    public var whitePoints: [BoardPoint] = []
    public var moveOrder: [BoardPoint: Character] = [:]
    public var blackStonesCaptured: Int = 0
    public var whiteStonesCaptured: Int = 0
    public var isReady: Bool = true

    public static func == (lhs: Stones, rhs: Stones) -> Bool {
        lhs.blackPoints == rhs.blackPoints &&
        lhs.whitePoints == rhs.whitePoints &&
        lhs.moveOrder == rhs.moveOrder &&
        lhs.blackStonesCaptured == rhs.blackStonesCaptured &&
        lhs.whiteStonesCaptured == rhs.whiteStonesCaptured &&
        lhs.isReady == rhs.isReady
    }
}

// PlayerColor is defined in KataGoGameStore (GameRules.swift) and
// re-exported here via KataGoUICore's @_exported import KataGoGameStore.

@Observable
public class Turn {
    public init() {}

    public var nextColorForPlayCommand = PlayerColor.black
    public var nextColorFromShowBoard = PlayerColor.black
}

extension Turn {
    public func toggleNextColorForPlayCommand() {
        if nextColorForPlayCommand == .black {
            nextColorForPlayCommand = .white
        } else {
            nextColorForPlayCommand = .black
        }
    }

    public var nextColorSymbolForPlayCommand: String? {
        nextColorForPlayCommand.symbol
    }
}

public struct AnalysisInfo {
    public let visits: Int
    public let winrate: Float
    public let scoreLead: Float
    public let utilityLcb: Float

    public init(visits: Int, winrate: Float, scoreLead: Float, utilityLcb: Float) {
        self.visits = visits
        self.winrate = winrate
        self.scoreLead = scoreLead
        self.utilityLcb = utilityLcb
    }
}

public struct OwnershipUnit: Identifiable {
    public let point: BoardPoint
    public let whiteness: Float
    public let scale: Float
    public let opacity: Float

    public init(point: BoardPoint, whiteness: Float, scale: Float, opacity: Float) {
        self.point = point
        self.whiteness = whiteness
        self.scale = scale
        self.opacity = opacity
    }

    public var id: Int {
        point.hashValue
    }

    public var isBlack: Bool {
        whiteness < 0.1
    }

    public var isWhite: Bool {
        whiteness > 0.9
    }

    public var isSchrodinger: Bool {
        (abs(whiteness - 0.5) < 0.2) && scale > 0.4
    }

    public var nearBlack: Bool {
        whiteness < 0.3
    }

    public var nearWhite: Bool {
        whiteness > 0.7
    }
}

public func convertToSIUnits(_ number: Int) -> String {
    let prefixes: [(prefix: String, value: Int)] = [
        ("T", 1_000_000_000_000),
        ("G", 1_000_000_000),
        ("M", 1_000_000),
        ("k", 1_000)
    ]

    for (prefix, threshold) in prefixes {
        if number >= threshold {
            let result = Double(number) / Double(threshold)
            return String(format: "%.1f%@", result, prefix)
        }
    }

    return "\(number)"
}

@Observable
public class Analysis {
    public init() {}

    public var nextColorForAnalysis = PlayerColor.white
    public var info: [BoardPoint: AnalysisInfo] = [:]
    public var ownershipUnits: [OwnershipUnit] = []
    public var visitsPerSecond: Double = 0

    @ObservationIgnored private var lastRootVisits: Int?
    @ObservationIgnored private var sessionStartVisits: Int?
    @ObservationIgnored private var sessionStartTime: TimeInterval?

    public var maxVisits: Int? {
        let visits = info.values.map(\.visits)
        return visits.max()
    }

    public var maxWinrate: Float? {
        guard let maxVisits else { return nil }
        return info.values.first(where: { $0.visits == maxVisits })?.winrate
    }

    private var maxScoreLead: Float? {
        guard let maxVisits else { return nil }
        return info.values.first(where: { $0.visits == maxVisits })?.scoreLead
    }

    public var blackWinrate: Float? {
        guard let maxWinrate = maxWinrate else { return nil }
        let blackWinrate = (nextColorForAnalysis == .black) ? maxWinrate : (1 - maxWinrate)
        return blackWinrate
    }

    public var blackScore: Float? {
        guard let maxScore = maxScoreLead else { return nil }
        let blackScore = (nextColorForAnalysis == .black) ? maxScore : -maxScore
        return blackScore
    }

    public func getBestMove(width: Int, height: Int) -> String? {
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

    public func clear() {
        info = [:]
        ownershipUnits = []
        visitsPerSecond = 0
        lastRootVisits = nil
        sessionStartVisits = nil
        sessionStartTime = nil
    }

    /// Updates `visitsPerSecond` as the average rate over the current analysis session
    /// (the continuous search for the current position). Averaging from the start of the
    /// session keeps the number stable as the search runs, instead of jumping with each
    /// report's instantaneous delta.
    ///
    /// `time` must be a monotonic timestamp in seconds (e.g. `ProcessInfo.processInfo.systemUptime`).
    /// A drop in cumulative `rootVisits` marks a new session (new move / new position).
    public func updateVisitsPerSecond(rootVisits: Int, at time: TimeInterval) {
        // Continue the current session only when visits keep accumulating.
        if let lastRootVisits, rootVisits >= lastRootVisits,
           let sessionStartVisits, let sessionStartTime {
            let deltaVisits = rootVisits - sessionStartVisits
            let deltaTime = time - sessionStartTime
            if deltaVisits > 0, deltaTime > 0 {
                visitsPerSecond = Double(deltaVisits) / deltaTime
            }
            self.lastRootVisits = rootVisits
            return
        }

        // First sample, or visits dropped (new search/position): anchor a new session.
        lastRootVisits = rootVisits
        sessionStartVisits = rootVisits
        sessionStartTime = time
        visitsPerSecond = 0
    }

    /// Re-anchors the visits/s session so the rate is measured from the next sample
    /// onward, without disturbing the displayed analysis (`info`/`ownershipUnits`).
    ///
    /// Call this when analysis is (re-)enabled. KataGo keeps its search tree across a
    /// pause, so cumulative `rootVisits` does not drop on resume and the session would
    /// otherwise keep its pre-pause start time — dividing accumulated visits by an
    /// elapsed time that includes the idle pause, which makes the rate plunge.
    public func resetVisitsPerSecondSession() {
        visitsPerSecond = 0
        lastRootVisits = nil
        sessionStartVisits = nil
        sessionStartTime = nil
    }

    /// SI-formatted display string, e.g. "1.2k visits/s". Reuses `convertToSIUnits`.
    public var visitsPerSecondText: String {
        convertToSIUnits(Int(visitsPerSecond.rounded())) + " visits/s"
    }

    /// Parses the cumulative root visit count from a kata-analyze line, if present.
    /// `rootInfo` (capital I) is unaffected by the lowercase "info" split used elsewhere.
    public static func parseRootVisits(from message: String) -> Int? {
        let pattern = /rootInfo visits (\d+)/
        if let match = message.firstMatch(of: pattern) {
            return Int(match.1)
        }
        return nil
    }
}

public struct Dimensions {
    public let squareLength: CGFloat
    public let squareLengthDiv2: CGFloat
    public let squareLengthDiv4: CGFloat
    public let squareLengthDiv8: CGFloat
    public let squareLengthDiv16: CGFloat
    public let boardLineStartX: CGFloat
    public let boardLineStartY: CGFloat
    public let stoneLength: CGFloat
    public let width: CGFloat
    public let height: CGFloat
    public let gobanWidth: CGFloat
    public let gobanHeight: CGFloat
    public let boardLineBoundWidth: CGFloat
    public let boardLineBoundHeight: CGFloat
    public let gobanStartX: CGFloat
    public let gobanStartY: CGFloat
    public let coordinate: Bool
    // Wide enough to hold the captured-stone count plus the player-name label
    // ("AI" / a human-SL profile / "Human"). On real boards gobanWidth/2 governs
    // the left/right cluster spread, so this only sizes the text frame.
    public let capturedStonesWidth: CGFloat = 120
    public let capturedStonesHeight: CGFloat
    public let capturedStonesStartY: CGFloat
    public let totalWidth: CGFloat
    public let totalHeight: CGFloat
    public let drawHeight: CGFloat
    public let emptyHeight: CGFloat

    public init(size: CGSize,
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

    public func getCapturedStoneStartX(xOffset: CGFloat) -> CGFloat {
        gobanStartX + (gobanWidth / 2) + ((-3 + (6 * xOffset)) * max(gobanWidth / 2, capturedStonesWidth) / 4)
    }
}

/// Message with a text and an ID
public struct Message: Identifiable, Equatable, Hashable {
    /// Default maximum message characters
    public static let defaultMaxMessageCharacters = 5000

    /// Identification of this message
    public let id = UUID()

    /// Text of this message
    public let text: String

    /// Initialize a message with a text and a max length
    /// - Parameters:
    ///   - text: a text
    ///   - maxLength: a max length
    public init(text: String, maxLength: Int = defaultMaxMessageCharacters) {
        self.text = String(text.prefix(maxLength))
    }
}

@Observable
public class MessageList {
    public static let defaultMaxMessageLines = 1000

    public init() {}

    public var messages: [Message] = []

    /// Back-reference to the owning `GameSession`. `appendAndSend` routes
    /// commands through `session?.engine` so `GameSession` is the sole engine
    /// owner. `@ObservationIgnored` — it is wiring, not observable UI state.
    ///
    /// `weak`: breaks the `GameSession → messageList → session` retain cycle.
    /// `GameSession` owns `messageList` as a `let`, so `session` always
    /// outlives `messageList`; the reference is never nil during a live session.
    @ObservationIgnored
    public weak var session: GameSession?

    public func shrink() {
        while messages.count > MessageList.defaultMaxMessageLines {
            messages.removeFirst()
        }
    }

    private func append(command: String) {
        messages.append(Message(text: "> \(command)"))
    }

    public func appendAndSend(command: String) {
        append(command: command)
        session?.engine.sendCommand(command)
    }

    public func appendAndSend(commands: [String]) {
        commands.forEach(appendAndSend)
    }
}

public enum AnalysisStatus {
    case clear
    case pause
    case run
}

extension String {
    public static let inActiveSgf = ""

    public var isActiveSgf: Bool {
        return self != .inActiveSgf
    }
}

extension Int {
    public static let inActiveCurrentIndex = -1

    public var isActiveSgfIndex: Bool {
        return self > .inActiveCurrentIndex
    }
}

public enum EyeStatus {
    case opened
    case book
    case closed
}

@Observable
public class Winrate {
    public init() {}

    public var black: Float = 0.5

    public var white: Float {
        1 - black
    }
}

@Observable
public class Score {
    public init() {}

    public var black: Float = 0.0

    public var white: Float {
        -black
    }
}

public struct Coordinate {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public var xLabel: String? {
        return Coordinate.xLabelMap[x]
    }

    public var yLabel: String {
        return String(y)
    }

    public var move: String? {
        if let point, point.isPass(width: width, height: height) {
            return "pass"
        } else if let xLabel {
            return "\(xLabel)\(yLabel)"
        } else {
            return nil
        }
    }

    public var point: BoardPoint? {
        BoardPoint(x: x, y: y - 1)
    }

    public var index: Int {
        x + ((y - 1) * width)
    }

    // Mapping letters A-AZ (without I) to numbers 0-49
    public static let xMap: [String: Int] = [
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

    public static let xLabelMap: [Int: String] = [
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

    public init?(x: Int, y: Int, width: Int, height: Int) {
        guard ((1...height).contains(y) && (0..<width).contains(x)) || BoardPoint(x: x, y: y - 1).isPass(width: width, height: height) else { return nil }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init?(xLabel: String, yLabel: String) {
        self.init(xLabel: xLabel, yLabel: yLabel, width: 19, height: 19)
    }

    public init?(xLabel: String, yLabel: String, width: Int, height: Int) {
        if let x = Coordinate.xMap[xLabel.uppercased()],
           let y = Int(yLabel) {
            self.init(x: x, y: y, width: width, height: height)
        } else {
            return nil
        }
    }

    /// Maps a point in the board's `Dimensions` coordinate space to a board
    /// `Coordinate` (nil when the point falls outside the board / pass area, via
    /// the failable `init`). Extracted verbatim from `BoardView.locationToCoordinate`
    /// so non-SwiftUI callers (the macOS right-click menu + hover preview) map a
    /// point to a vertex IDENTICALLY to the board's tap gesture — a single source
    /// of truth keeps them from drifting. Callers supply the live board size and
    /// `verticalFlip` (the values `BoardView` reads from `BoardSize`/`GobanState`).
    public static func from(location: CGPoint,
                            dimensions: Dimensions,
                            boardWidth: Int,
                            boardHeight: Int,
                            verticalFlip: Bool) -> Coordinate? {
        func calculateCoordinate(from point: CGFloat, margin: CGFloat, length: CGFloat) -> Int {
            return Int(round((point - margin) / length))
        }

        let boardY = calculateCoordinate(from: location.y, margin: dimensions.boardLineStartY, length: dimensions.squareLength) + 1
        let boardX = calculateCoordinate(from: location.x, margin: dimensions.boardLineStartX, length: dimensions.squareLength)
        let verticalFlipWithPass = verticalFlip || ((boardY - 1) == BoardPoint.passY(height: boardHeight))
        let adjustedY = verticalFlipWithPass ? boardY : (boardHeight - boardY + 1)
        return Coordinate(x: boardX, y: adjustedY, width: boardWidth, height: boardHeight)
    }
}

extension Coordinate {
    public init?(move: String, width: Int, height: Int) {
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
public class TopUIState {
    public init() {}

    public var importing = false
    public var confirmingDeletion = false

    /// True while the game list is in multi-select mode (circles shown per row).
    public var isSelecting = false

    /// Persistent IDs of the games currently checked in multi-select mode.
    /// Keyed by stable persistent ID so the set survives `@Query` refreshes.
    public var selectedGameIDs: Set<PersistentIdentifier> = []

    /// Drives the bulk-deletion confirmation dialog (distinct from the
    /// single-game `confirmingDeletion`).
    public var confirmingBulkDeletion = false

    /// Number of games currently checked.
    public var selectionCount: Int { selectedGameIDs.count }

    /// Toggle one game's membership in the selection.
    public func toggle(_ id: PersistentIdentifier) {
        if selectedGameIDs.contains(id) {
            selectedGameIDs.remove(id)
        } else {
            selectedGameIDs.insert(id)
        }
    }

    /// Leave multi-select mode and clear all checks.
    public func exitSelection() {
        isSelecting = false
        selectedGameIDs.removeAll()
    }

    /// Drives the app's quit lifecycle (was a `@State` binding threaded down to
    /// the toolbar's `QuitButton`). Now that quitting is triggered by tapping
    /// the Model/Version row in the Configurations sheet — which only sees
    /// `TopUIState` through the environment, not the binding — the status lives
    /// here. `ContentView` observes it to stop the session loop. iOS/visionOS
    /// only; inert on macOS (which never mutates it).
    public var quitStatus: QuitStatus = .none

    /// The currently-loaded model's friendly name (e.g. "Official KataGo
    /// Network"). Surfaced in the Configurations sheet now that the launch
    /// screen no longer lingers for a few seconds to show it. nil until the
    /// engine has been initialized.
    public var modelName: String?

    /// The raw engine `version` GTP reply, e.g.
    /// "= 1.16.3+b18c384nbt-s…+b18c384nbt-humanv0-s…" — the KataGo version
    /// concatenated (with "+") to the abbreviated internal net names
    /// (`gtp.cpp`'s `version` command). nil until the engine handshake
    /// completes. Use `engineVersionDisplay` for presentation.
    public var engineVersion: String?

    /// `engineVersion` cleaned for display: the leading GTP success token
    /// ("= ") and surrounding whitespace stripped. nil when no version has
    /// been captured yet or nothing meaningful remains after stripping.
    public var engineVersionDisplay: String? {
        guard let engineVersion else { return nil }
        var cleaned = engineVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        // A GTP failure reply ("? …") means the version handshake produced no
        // version (mirrors GameSession.initialize's "= " success gate), so
        // show nothing rather than leaking the raw error text.
        if cleaned.hasPrefix("?") {
            return nil
        }
        // Drop the GTP success token, then re-trim: stripping the "=" first
        // (rather than matching "= ") also collapses a bare "=" / "= " reply
        // to empty, so nothing meaningless leaks into the UI.
        if cleaned.hasPrefix("=") {
            cleaned.removeFirst()
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned.isEmpty ? nil : cleaned
    }
}
