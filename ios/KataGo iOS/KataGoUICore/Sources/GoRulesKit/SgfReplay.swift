//
//  SgfReplay.swift
//  GoRulesKit
//
//  Engine-free replay of an SGF's mainline to any move index. Exists so a
//  process that cannot link the C++ engine — the watch app — can draw the
//  board at an arbitrary position of a saved game. The record's cached
//  blackStones/whiteStones dictionaries are NOT a substitute: they only cover
//  indices the phone actually visited, so an imported game has nothing but
//  its final position.
//

import Foundation
import KataGoAnalysisKit

public struct SgfReplay: Sendable {
    /// A drawn position: stones as GTP vertices, plus what to highlight.
    public struct Position: Sendable, Equatable {
        public let blackVertices: [String]
        public let whiteVertices: [String]
        /// The move that produced this position; nil at index 0 and after a pass.
        public let lastMoveVertex: String?
        public let toMove: PlayerColor

        public init(blackVertices: [String], whiteVertices: [String],
                    lastMoveVertex: String?, toMove: PlayerColor) {
            self.blackVertices = blackVertices
            self.whiteVertices = whiteVertices
            self.lastMoveVertex = lastMoveVertex
            self.toMove = toMove
        }
    }

    /// Boards are memoized every this many moves so scrubbing backwards in a
    /// long game does not replay from zero on watch hardware.
    public static let checkpointStride = 25

    public let width: Int
    public let height: Int
    public let moveCount: Int

    /// The first mainline move the board refused, if any. Diagnostic only —
    /// a refused move is skipped, never fatal.
    public private(set) var anomalyIndex: Int?

    private let scan: SgfHeaderScan
    private var checkpoints: [Int: GoBoard]

    public init(scan: SgfHeaderScan) {
        self.scan = scan
        width = max(scan.boardWidth, 1)
        height = max(scan.boardHeight, 1)
        moveCount = scan.moves.count

        var board = GoBoard(width: width, height: height)
        for point in scan.setupBlack {
            let target = GoPoint(x: point.x, y: point.y)
            guard board.color(at: target) == .empty else { continue }
            board.placeSetupStone(at: target, color: .black)
        }
        for point in scan.setupWhite {
            let target = GoPoint(x: point.x, y: point.y)
            guard board.color(at: target) == .empty else { continue }
            board.placeSetupStone(at: target, color: .white)
        }
        // AE removals apply AFTER both placements, mirroring the scope-limited
        // "everything on the mainline collapses to index 0" simplification
        // setupBlack/setupWhite already make (see SgfHeaderScan.setupEmpty).
        // removingStones(at:) is a no-op for an already-empty index, so an
        // AE on a point nothing ever placed is harmless.
        if !scan.setupEmpty.isEmpty {
            let removals = scan.setupEmpty.compactMap {
                board.index(of: GoPoint(x: $0.x, y: $0.y))
            }
            board = board.removingStones(at: removals)
        }
        checkpoints = [0: board]
    }

    /// The position after `index` moves. Out-of-range values clamp.
    public mutating func position(at index: Int) -> Position {
        let target = min(max(index, 0), moveCount)
        let board = board(at: target)
        var last: String?
        if target > 0, let point = scan.moves[target - 1].point {
            last = GoPoint(x: point.x, y: point.y).gtpVertex(boardHeight: height)
        }
        return Position(blackVertices: board.gtpVertices(of: .black),
                        whiteVertices: board.gtpVertices(of: .white),
                        lastMoveVertex: last,
                        toMove: scan.toMove(atMoveIndex: target))
    }

    private mutating func board(at target: Int) -> GoBoard {
        if let cached = checkpoints[target] { return cached }

        // Nearest memoized board at or below the target; index 0 always exists.
        var from = 0
        for key in checkpoints.keys where key <= target && key > from { from = key }
        // `checkpoints[0]` is seeded in `init` and `from` only ever advances to
        // an EXISTING checkpoint key, so this lookup cannot miss. Make that
        // invariant explicit rather than falling back to a fresh empty board:
        // a silent fallback here would replay from a board with no setup
        // stones, corrupting every index onward without any signal that it
        // happened.
        guard var board = checkpoints[from] else {
            preconditionFailure("no checkpoint at \(from); checkpoints[0] is seeded in init and `from` never advances past an existing key")
        }

        var index = from
        while index < target {
            board = Self.apply(scan.moves[index], to: board,
                               index: index, anomaly: &anomalyIndex)
            index += 1
            if index.isMultiple(of: Self.checkpointStride) {
                checkpoints[index] = board
            }
        }
        return board
    }

    /// Permissive application: the simple-ko ban is cleared before each move
    /// and suicide is allowed, because a recorded game may contain a position
    /// the configured ruleset would forbid, and refusing a move mid-replay
    /// would corrupt every later index. A move the board still refuses is
    /// skipped and its index recorded.
    private static func apply(_ move: SgfMove, to board: GoBoard,
                              index: Int, anomaly: inout Int?) -> GoBoard {
        var candidate = board
        // A pass legitimately clears ko, which is exactly the reset we want.
        candidate.playPass()
        guard let point = move.point else { return candidate }
        do {
            try candidate.play(at: GoPoint(x: point.x, y: point.y),
                               color: move.color == .black ? .black : .white,
                               multiStoneSuicideLegal: true)
            return candidate
        } catch {
            if anomaly == nil { anomaly = index }
            return board
        }
    }
}
