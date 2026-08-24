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
        BoardSize.locationToMove(location: location,
                                 width: Int(width),
                                 height: Int(height))
    }

    /// The GTP vertex an SGF `Location` names on a `width`×`height` board, or
    /// nil when it falls outside. Static so callers that hold plain sizes —
    /// `RecordStoneCache`, which writes the per-index move cache from a record
    /// and its replayed position — need not build a `BoardSize` to ask.
    public static func locationToMove(location: Location, width: Int, height: Int) -> String? {
        guard !location.pass else { return "pass" }
        let x = location.x
        let y = height - location.y

        guard (1...height).contains(y), (0..<width).contains(x) else { return nil }

        return Coordinate.xLabelMap[x].map { "\($0)\(y)" }
    }
}

// BoardPoint's core definition lives in KataGoAnalysisKit (BoardPoint.swift)
// and is re-exported here via KataGoUICore's @_exported import
// KataGoAnalysisKit. The UI-facing helpers stay behind as extensions.

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
            self.init(x: width - 1, y: BoardPoint.passY(height: height))
        } else {
            // Subtract 1 from y to make it 0-indexed
            self.init(x: location.x, y: height - location.y - 1)
        }
    }
}

extension BoardPoint {

    /// GTP vertex for this point ("A1", "J9", "Q16", …; letter I skipped), or
    /// nil when the point lies outside the board. The pass point yields
    /// "pass" — kept for contract completeness, though grid-clamped callers
    /// (the tvOS play cursor) can never reach it.
    public func gtpVertex(width: Int, height: Int) -> String? {
        Coordinate(x: x, y: y + 1, width: width, height: height)?.move
    }

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
            // Letters-only column group: `\w` also matches digits, so a greedy
            // `(\w+)` swallows the first digit of two-digit rows ("Q16" →
            // xLabel "Q1" → xMap miss → nil, silently dropping rows 10+).
            // Same pattern AnalysisLineParser.moveToPoint uses.
            let pattern = /([^\d\W]+)(\d+)/
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
    /// Whether the ENGINE is in sync with the position on screen — it has
    /// acknowledged the record position with a `showboard` reply. It is NOT
    /// "are there stones to draw": the board is record-owned and always draws,
    /// engine or no engine. Only in-sync positions collect analysis, accept
    /// stone taps, step auto-play and persist per-index analysis.
    ///
    /// Starts false: nothing has acknowledged anything yet, and a true default
    /// would open the tap gate against an engine that is still loading.
    public var isReady: Bool = false
    /// Bumped by `RecordPositionProjector` every time it publishes a position.
    /// Drives everything that must react to "the board changed" rather than to
    /// "the engine caught up" — the placement haptic, for one. Compared for
    /// inequality only, so its wrap-around is harmless.
    public var positionGeneration: Int = 0

    public static func == (lhs: Stones, rhs: Stones) -> Bool {
        lhs.blackPoints == rhs.blackPoints &&
        lhs.whitePoints == rhs.whitePoints &&
        lhs.moveOrder == rhs.moveOrder &&
        lhs.blackStonesCaptured == rhs.blackStonesCaptured &&
        lhs.whiteStonesCaptured == rhs.whiteStonesCaptured &&
        lhs.isReady == rhs.isReady
    }
}

// PlayerColor is defined in KataGoAnalysisKit (PlayerColor.swift) and
// re-exported here via KataGoUICore's @_exported import KataGoAnalysisKit.

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

// AnalysisInfo and OwnershipUnit live in KataGoAnalysisKit
// (AnalysisInfo.swift), re-exported here via KataGoUICore's @_exported import
// KataGoAnalysisKit.

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
    /// The position these numbers were collected for — the projector's
    /// `currentKey` at the moment the `info` lines landed. Nil means "nothing
    /// collected yet". `GobanState.maybeUpdateAnalysisData` refuses to persist
    /// analysis into an index this does not match, so navigating away before
    /// the engine answers can never stamp the old position's numbers onto the
    /// new one.
    public var collectedForKey: RecordPositionKey?

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

    /// One entry of the live candidate-move ranking, ready for a list UI: the
    /// GTP vertex ("Q16" / "pass") both labels the row and is the exact string
    /// a play/kata-check-move command takes. `winrate`/`scoreLead` stay in the
    /// side-to-move perspective `info` uses, so a list shows the same numbers
    /// as the on-board overlay circles.
    public struct CandidateMove: Identifiable, Sendable {
        public let vertex: String
        public let point: BoardPoint
        public let visits: Int
        public let winrate: Float
        public let scoreLead: Float
        public let utilityLcb: Float
        public var id: String { vertex }

        public init(vertex: String, point: BoardPoint, visits: Int,
                    winrate: Float, scoreLead: Float, utilityLcb: Float) {
            self.vertex = vertex
            self.point = point
            self.visits = visits
            self.winrate = winrate
            self.scoreLead = scoreLead
            self.utilityLcb = utilityLcb
        }
    }

    /// The current candidates ordered strongest-first: by visits (the search's
    /// own ranking), tie-broken by utilityLcb then vertex so equal-visit
    /// entries from the Dictionary come out deterministically. Entries whose
    /// point does not convert to a vertex on this board are dropped.
    public func candidateMoves(width: Int, height: Int, limit: Int = 5) -> [CandidateMove] {
        info.compactMap { point, moveInfo -> CandidateMove? in
            guard let vertex = Coordinate(x: point.x, y: point.y + 1,
                                          width: width, height: height)?.move else { return nil }
            return CandidateMove(vertex: vertex,
                                 point: point,
                                 visits: moveInfo.visits,
                                 winrate: moveInfo.winrate,
                                 scoreLead: moveInfo.scoreLead,
                                 utilityLcb: moveInfo.utilityLcb)
        }
        .sorted {
            if $0.visits != $1.visits { return $0.visits > $1.visits }
            if $0.utilityLcb != $1.utilityLcb { return $0.utilityLcb > $1.utilityLcb }
            return $0.vertex < $1.vertex
        }
        .prefix(limit)
        .map { $0 }
    }

    public func clear() {
        info = [:]
        ownershipUnits = []
        visitsPerSecond = 0
        collectedForKey = nil
        lastRootVisits = nil
        sessionStartVisits = nil
        sessionStartTime = nil
    }

    /// Drops the candidate moves and the collection stamp, and nothing else —
    /// the ownership map stays on the board (ADR 0011). A territory map one
    /// stone out of date is approximately right, which is the whole job of a
    /// territory map; a candidate ranking is computed for one specific side to
    /// move, so after a move it ranks the wrong player's options and can put a
    /// circle on the stone that was just played. Absent beats wrong.
    ///
    /// Nilling the stamp is half the point, not bookkeeping:
    /// `GobanState.maybeUpdateAnalysisData` persists per-index analysis only
    /// while `collectedForKey` names the displayed position, and a held map
    /// belongs to the position being left. Keeping the stamp would let a
    /// navigation round trip re-file the previous position's numbers into the
    /// index the board has just arrived at.
    ///
    /// The visits/s session is deliberately left alone: `updateVisitsPerSecond`
    /// re-anchors itself when cumulative root visits drop, which is exactly what
    /// a new search does, so re-anchoring here would only flash a zero in the
    /// status line for one report.
    public func clearCandidates() {
        info = [:]
        collectedForKey = nil
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
        // Pass-area space reservation. Non-macOS reserves VERTICAL room BELOW the
        // board for the pass tile (`passHeightEntity`). macOS instead places the
        // pass tile to the RIGHT of the board's bottom row, so it reserves
        // HORIZONTAL room on the right (`passWidthEntity`) and lets the board
        // reclaim the bottom space and grow taller. The board is then shifted left
        // by half the reserved width so the reserved room lands on the right — see
        // `macPassTileCenter()` and `BoardLineView.drawPassArea`.
        #if os(macOS)
        let passHeightEntity: CGFloat = 0
        let passWidthEntity: CGFloat = showPass ? 3 : 0
        #else
        let passHeightEntity: CGFloat = showPass ? 1.5 : 0
        let passWidthEntity: CGFloat = 0
        #endif
        let squareWidth = totalWidth / (gobanWidthEntity + 1 + passWidthEntity)
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
        // On macOS this is `passWidthEntity * squareLength` and shifts the board
        // left so the pass tile has room on the right; elsewhere it is 0 (no-op).
        let passWidth = passWidthEntity * squareLength
        gobanStartX = ((totalWidth - gobanWidth) / 2) - (passWidth / 2)
        let passHeight = passHeightEntity * squareLength
        gobanStartY = max(capturedStonesHeight, (totalHeight - passHeight - gobanHeight) / 2)
        boardLineBoundWidth = (width - 1) * squareLength
        boardLineBoundHeight = (height - 1) * squareLength
        let coordinateLength = coordinateEntity * squareLength
        boardLineStartX = ((totalWidth - boardLineBoundWidth + coordinateLength) / 2) - (passWidth / 2)
        boardLineStartY = (gobanStartY == capturedStonesHeight) ? (capturedStonesHeight + coordinateLength + (squareLength + gobanPadding) / 2) : (totalHeight - passHeight - boardLineBoundHeight + coordinateLength) / 2
        capturedStonesStartY = gobanStartY - capturedStonesHeight
        drawHeight = gobanHeight + capturedStonesHeight + passHeight
        emptyHeight = totalHeight - drawHeight
    }

    public func getCapturedStoneStartX(xOffset: CGFloat) -> CGFloat {
        gobanStartX + (gobanWidth / 2) + ((-3 + (6 * xOffset)) * max(gobanWidth / 2, capturedStonesWidth) / 4)
    }

    #if os(macOS)
    /// Screen center of the macOS pass tile — to the RIGHT of the board's bottom
    /// row (two columns past the rightmost line, aligned with the bottom line).
    /// The SINGLE source of truth for both `BoardLineView.drawPassArea`'s render
    /// and `MacBoardInteractionLayer`'s click hit-test, so the visible tile and
    /// the clickable region can never drift. `Dimensions.init` reserves the
    /// horizontal room this needs (`passWidthEntity`).
    public func macPassTileCenter() -> CGPoint {
        CGPoint(x: boardLineStartX + (width + 1) * squareLength,
                y: boardLineStartY + (height - 1) * squareLength)
    }
    #endif

    /// Screen center for any board point's on-board overlay (analysis circle,
    /// book move, next-move ring, focus ring, …). On macOS the pass tile is
    /// relocated to the right of the board (`macPassTileCenter`), so the pass
    /// point must render there too rather than at `getPositionY`'s pinned
    /// below-board row (which is off-canvas once the board reclaims that space).
    /// For every non-pass point — and for all points on non-macOS platforms —
    /// this returns the exact standard formula, so behavior is unchanged except
    /// for the pass point on macOS.
    public func screenCenter(for point: BoardPoint, verticalFlip: Bool) -> CGPoint {
        #if os(macOS)
        if point.isPass(width: Int(width), height: Int(height)) {
            return macPassTileCenter()
        }
        #endif
        return CGPoint(
            x: boardLineStartX + CGFloat(point.x) * squareLength,
            y: boardLineStartY + point.getPositionY(height: height, verticalFlip: verticalFlip) * squareLength)
    }
}

// Synthesized memberwise equality (all stored properties are CGFloat/Bool) —
// lets `BoardAccessibilityOverlay.==` detect board relayouts. Sendable so that
// nonisolated `==` can read a MainActor view's stored copy.
extension Dimensions: Equatable, Sendable {}

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

    /// Whether the engine can take GTP commands right now — it has answered
    /// the handshake and has not been torn down.
    ///
    /// `appendAndSend` DROPS (and logs) everything while this is false, so a
    /// board that is on screen before the engine is (the whole point of the
    /// change) cannot push commands into a pre-loop buffer that would replay
    /// them at the wrong moment. Lifecycle commands — `version`, `stop`,
    /// `quit` — deliberately bypass this by going through
    /// `GameSession.engine.sendCommand` directly.
    ///
    /// Defaults FALSE: a session that has handshaken with nothing has, by
    /// definition, no engine to send to. `GameSession.handshake` is the ONLY
    /// thing that opens it (on the `= ` reply, via `beginEngineSession`), and
    /// `endEngineSession` is the only thing that shuts it again — which is what
    /// keeps `BoardView.onAppear` from `showboard`ing into a pre-loop buffer
    /// and the tap gate from opening against a still-loading net.
    public var isAcceptingCommands = false

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

    /// Echo a command into the transcript WITHOUT sending it. The one caller is
    /// `GameSession.sendLifecycleCommand`, which writes to the transport itself
    /// so `version`/`stop`/`quit` bypass the gate — the transcript still has to
    /// show them, and it must show them in the same shape as everything else.
    public func appendCommandEcho(_ command: String) {
        append(command: command)
    }

    /// - Returns: whether the command actually reached the engine. Callers that
    ///   keep bookkeeping about what the engine was told — `sendShowBoardCommand`
    ///   above all — must branch on this, because a dropped command changes
    ///   nothing on the engine side.
    @discardableResult
    public func appendAndSend(command: String) -> Bool {
        guard isAcceptingCommands else {
            // Logged, not silent: a dropped command is exactly the kind of
            // thing that shows up much later as "the engine is on the wrong
            // position", and the transcript is where that gets diagnosed.
            //
            // Dropped, never buffered: the in-process bridge's command buffer
            // is process-global and would replay a stale burst into the NEXT
            // engine; the macOS pipe throws the write away anyway. The resync
            // after the handshake re-states the LIVE position instead.
            messages.append(Message(text: "> (dropped — engine unavailable) \(command)"))
            return false
        }
        append(command: command)
        session?.engine.sendCommand(command)
        return true
    }

    /// - Returns: whether EVERY command reached the engine. A partial send is
    ///   possible only if the gate shuts mid-bundle.
    @discardableResult
    public func appendAndSend(commands: [String]) -> Bool {
        var allSent = true
        for command in commands {
            let sent = appendAndSend(command: command)
            allSent = allSent && sent
        }
        return allSent
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

// Coordinate's core definition (labels, GTP-vertex mapping, xMap/xLabelMap)
// lives in KataGoAnalysisKit (Coordinate.swift), re-exported here via
// KataGoUICore's @_exported import KataGoAnalysisKit. The Dimensions-based
// screen-point mapping below stays behind as an extension.

extension Coordinate {
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

/// A picked board image awaiting recognition + confirmation in the photo-import
/// preview sheet. `Identifiable` so it can drive a `.sheet(item:)`.
public struct PendingPhotoImport: Identifiable, Equatable {
    /// Where the picked image came from. Lets the preview/retry UX adapt to the
    /// entry point (e.g. re-open the camera vs. re-open the picker) without the
    /// sheet host having to track it separately.
    public enum Source: Sendable, Equatable {
        case fileOrLibrary
        case camera
    }

    public let id = UUID()
    /// Encoded image bytes (JPEG/PNG/HEIC) handed to the recognizer.
    public let imageData: Data
    /// Default game name (file basename, or "Board Photo <date>").
    public let suggestedName: String
    /// The entry point that produced this image. Defaults to `.fileOrLibrary`
    /// so existing file/library call sites are unchanged.
    public let source: Source

    public init(imageData: Data, suggestedName: String, source: Source = .fileOrLibrary) {
        self.imageData = imageData
        self.suggestedName = suggestedName
        self.source = source
    }
}

@Observable
public class TopUIState {
    public init() {}

    public var importing = false

    /// Presents the system Photos picker (PhotosUI) for importing a board
    /// photo. Distinct from `importing`, which drives the document/file
    /// importer.
    public var importingPhoto = false

    /// When non-nil, the photo-import preview sheet is shown for this picked
    /// image (from the Photos picker or a picked image file). Setting it back
    /// to nil dismisses the sheet. Carried here (rather than as view `@State`)
    /// so the picker/file entry points and the sheet host share it.
    public var pendingPhotoImport: PendingPhotoImport?

    /// Presents the full-screen manual board-photo camera (Import ▸ Camera).
    /// iOS/iPadOS only; the entry point and cover are gated behind `os(iOS)`.
    public var capturingBoardPhoto = false

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

    /// Presents the model picker over the (always-mounted) board. Owned by
    /// `TopUIState` rather than by the root view's own `@State` because three
    /// unrelated places ask for it: the launch decision (DEBUG), the engine
    /// analysis sparkle's remedy tap, and Global Settings ▸ Change model.
    /// iOS only; nothing else mutates it.
    public var presentingModelPicker = false

    /// The analysis control opened the picker while the engine was down, so
    /// the tap expressed "I want analysis": a model picked from THIS open arms
    /// a cleared preference back to run. Set by the sparkle's remedy tap,
    /// consumed by the selection handler, dropped when the picker is dismissed
    /// without a pick. The Settings route never sets it — arming is
    /// sparkle-scoped by design.
    public var analysisArmOnPick = false

    /// Global Settings asked for the picker and is about to dismiss itself.
    /// Two flags rather than one because presenting a sheet in the same
    /// transaction that dismisses another one gets DROPPED: the settings
    /// sheet's `onDismiss` reads this and only then sets
    /// `presentingModelPicker` (the same present-after-dismiss hop
    /// `GameSplitView` uses between the camera cover and the photo sheet).
    public var requestingModelPicker = false

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
        // version (mirrors GameSession.handshake's "= " success gate), so
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
