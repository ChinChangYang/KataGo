//
//  SgfReplay.swift
//  GoRulesKit
//
//  Engine-free replay of an SGF's mainline to any move index. It is the one
//  source of the record position the board draws: the board never waits for
//  the KataGo engine, and a process that cannot link the engine at all — the
//  watch app — draws saved games from this alone. The record's cached
//  blackStones/whiteStones dictionaries are NOT a substitute: they only cover
//  indices the phone actually visited, so an imported game has nothing but
//  its final position.
//
//  Legality here is KataGo's TOLERANT legality — what the GTP `play` command
//  accepts (cpp/game/boardhistory.cpp isLegalTolerant + board.cpp
//  isIllegalSuicide): only an occupied point, an off-board point and
//  single-stone suicide are refused; ko and superko are ignored, multi-stone
//  suicide is allowed, and either colour may move at any time. That has to
//  match exactly, because the engine is fed the same moves one at a time and
//  has to skip precisely what this replay skipped.
//

import Foundation
import KataGoAnalysisKit

public struct SgfReplay: Sendable {
    /// A drawn position: stones as GTP vertices, plus everything `showboard`
    /// used to be the only source of.
    public struct Position: Sendable, Equatable {
        public let blackVertices: [String]
        public let whiteVertices: [String]
        /// The recorded move that lands on this index; nil at index 0 and
        /// after a pass. Read from the record even when the move was refused,
        /// so the board still points at where the record said it was.
        public let lastMoveVertex: String?
        /// The colour to move: the opposite of the last ACCEPTED move, so a
        /// refusal leaves the turn where the engine leaves it. See
        /// `SgfReplay.init(width:height:...)` for the index-0 rule.
        public let toMove: PlayerColor
        /// How many BLACK stones have been removed from the board — captured
        /// by White, or lost to Black's own multi-stone suicide. Same meaning
        /// as KataGo's `Board::numBlackCaptures` (cpp/game/board.h), which
        /// `showboard` prints as "B stones captured: N"
        /// (cpp/game/boardhistory.cpp printBasicInfo).
        public let blackCaptures: Int
        /// How many WHITE stones have been removed. See `blackCaptures`.
        public let whiteCaptures: Int
        /// The move-number digits `showboard` prints on the board, as
        /// (vertex, 1...3) with 1 the oldest. Passes and refused moves mark
        /// nothing, and a point keeps its digit even after the stone standing
        /// there was captured. See `SgfReplay` for the window rules.
        public let lastThreeMoves: [(vertex: String, order: Int)]

        public init(blackVertices: [String], whiteVertices: [String],
                    lastMoveVertex: String?, toMove: PlayerColor,
                    blackCaptures: Int = 0, whiteCaptures: Int = 0,
                    lastThreeMoves: [(vertex: String, order: Int)] = []) {
            self.blackVertices = blackVertices
            self.whiteVertices = whiteVertices
            self.lastMoveVertex = lastMoveVertex
            self.toMove = toMove
            self.blackCaptures = blackCaptures
            self.whiteCaptures = whiteCaptures
            self.lastThreeMoves = lastThreeMoves
        }

        // Hand-written because a tuple array is not Equatable-synthesizable.
        public static func == (lhs: Position, rhs: Position) -> Bool {
            lhs.blackVertices == rhs.blackVertices
                && lhs.whiteVertices == rhs.whiteVertices
                && lhs.lastMoveVertex == rhs.lastMoveVertex
                && lhs.toMove == rhs.toMove
                && lhs.blackCaptures == rhs.blackCaptures
                && lhs.whiteCaptures == rhs.whiteCaptures
                && lhs.lastThreeMoves.count == rhs.lastThreeMoves.count
                && zip(lhs.lastThreeMoves, rhs.lastThreeMoves).allSatisfy { $0 == $1 }
        }
    }

    /// One move as the record wrote it, before the board has any say: a nil
    /// `point` is a pass.
    public struct RecordedMove: Sendable, Equatable {
        public let color: PlayerColor
        public let point: GoPoint?

        public init(color: PlayerColor, point: GoPoint?) {
            self.color = color
            self.point = point
        }
    }

    /// Boards are memoized every this many moves so scrubbing backwards in a
    /// long game does not replay from zero on watch hardware.
    public static let checkpointStride = 25

    public let width: Int
    public let height: Int
    public let moveCount: Int

    /// Every mainline index the board refused. Refusals are discovered
    /// lazily, by replaying: an index is only in here once the replay has
    /// actually reached it, so read this after forcing the replay far enough
    /// (`position(at:)`, `acceptedMoveCount(upTo:)` and `trailingPassCount(at:)`
    /// all do that). A refused move is skipped, never fatal.
    public private(set) var refusedIndices: Set<Int> = []

    /// The first mainline move the board refused, if any. Diagnostic only —
    /// the watch gates a whole game unreadable on it.
    public var anomalyIndex: Int? { refusedIndices.min() }

    private let moves: [RecordedMove]
    private var checkpoints: [Int: State]

    /// Everything the replay carries forward from one index to the next.
    private struct State {
        var board: GoBoard
        /// The accepted moves KataGo's `BoardHistory.moveHistory` would hold,
        /// trimmed to the last three — all `Board::printBoard` ever reads
        /// (cpp/game/board.cpp). A nil element is a pass: it occupies a slot
        /// and marks no point.
        var window: [GoPoint?]
        /// The side the engine expects to move, i.e. `Search::rootPla`.
        var toMove: PlayerColor
        /// Recorded moves accepted so far.
        var acceptedCount: Int
    }

    /// Builds a replay from plain values, so a caller that parsed the SGF
    /// some other way — the app parses it in C++, through `SgfHelper` — feeds
    /// the same replay the scan-based initialiser produces.
    ///
    /// Setup stones are applied in AB, AW, AE order at index 0; a placement
    /// on an already-occupied point is dropped, and a removal of an empty
    /// point is a no-op.
    ///
    /// The side to move before any move is accepted is White when there are
    /// setup stones and every one of them is Black (KataGo's
    /// `set_free_handicap` leaves White to move), and Black otherwise
    /// (`set_position`, or a bare empty board). The root's `PL[]` property is
    /// deliberately ignored: the engine is fed setup stones and moves, never
    /// a player override, so honouring PL[] here would put the display and
    /// the engine on different turns.
    public init(width: Int, height: Int,
                setupBlack: [GoPoint] = [],
                setupWhite: [GoPoint] = [],
                setupEmpty: [GoPoint] = [],
                moves: [RecordedMove]) {
        self.width = max(width, 1)
        self.height = max(height, 1)
        self.moves = moves
        self.moveCount = moves.count

        var board = GoBoard(width: self.width, height: self.height)
        for point in setupBlack where board.color(at: point) == .empty {
            board.placeSetupStone(at: point, color: .black)
        }
        for point in setupWhite where board.color(at: point) == .empty {
            board.placeSetupStone(at: point, color: .white)
        }
        // AE removals apply AFTER both placements, matching the order
        // SgfNode::accumPlacements accumulates them in (cpp/dataio/sgf.cpp).
        // removingStones(at:) is a no-op for an already-empty index, so an
        // AE on a point nothing ever placed is harmless.
        if !setupEmpty.isEmpty {
            board = board.removingStones(at: setupEmpty.compactMap { board.index(of: $0) })
        }

        let toMove: PlayerColor = (!setupBlack.isEmpty && setupWhite.isEmpty) ? .white : .black
        checkpoints = [0: State(board: board, window: [], toMove: toMove, acceptedCount: 0)]
    }

    /// Builds a replay from the bridge-free `SgfHeaderScan` — the only parser
    /// available to targets that cannot link the C++ engine (the watch).
    ///
    /// NOTE (inherited scope limit): the scan collects every AB/AW/AE it finds
    /// anywhere on the mainline into one flat list, so a mid-game setup node
    /// is applied at index 0. See `SgfHeaderScan.setupEmpty`.
    public init(scan: SgfHeaderScan) {
        self.init(width: scan.boardWidth, height: scan.boardHeight,
                  setupBlack: scan.setupBlack.map { GoPoint(x: $0.x, y: $0.y) },
                  setupWhite: scan.setupWhite.map { GoPoint(x: $0.x, y: $0.y) },
                  setupEmpty: scan.setupEmpty.map { GoPoint(x: $0.x, y: $0.y) },
                  moves: scan.moves.map {
                      RecordedMove(color: $0.color,
                                   point: $0.point.map { GoPoint(x: $0.x, y: $0.y) })
                  })
    }

    /// The position after `index` moves. Out-of-range values clamp.
    public mutating func position(at index: Int) -> Position {
        let target = clamped(index)
        let state = state(at: target)
        var last: String?
        if target > 0, let point = moves[target - 1].point {
            last = point.gtpVertex(boardHeight: height)
        }
        return Position(blackVertices: state.board.gtpVertices(of: .black),
                        whiteVertices: state.board.gtpVertices(of: .white),
                        lastMoveVertex: last,
                        toMove: state.toMove,
                        blackCaptures: state.board.numBlackCaptures,
                        whiteCaptures: state.board.numWhiteCaptures,
                        lastThreeMoves: marks(in: state.window))
    }

    /// The move the record holds at `index`, refused or not. Nil out of range.
    public func move(at index: Int) -> RecordedMove? {
        moves.indices.contains(index) ? moves[index] : nil
    }

    /// Whether the board refused the mainline move at `index`. Only meaningful
    /// once the replay has reached `index` — see `refusedIndices`.
    public func isRefused(_ index: Int) -> Bool {
        refusedIndices.contains(index)
    }

    /// How many recorded moves before `index` the board accepted — the number
    /// of moves the engine was actually fed, which is what an undo count has
    /// to be built from. Forces the replay up to `index`.
    public mutating func acceptedMoveCount(upTo index: Int) -> Int {
        state(at: clamped(index)).acceptedCount
    }

    /// How many accepted passes run consecutively into `index`. Refused moves
    /// are looked through: the engine never saw them, so they do not break a
    /// run of passes. Forces the replay up to `index`.
    public mutating func trailingPassCount(at index: Int) -> Int {
        let target = clamped(index)
        _ = state(at: target)
        var count = 0
        var cursor = target - 1
        while cursor >= 0 {
            if !refusedIndices.contains(cursor) {
                guard moves[cursor].point == nil else { break }
                count += 1
            }
            cursor -= 1
        }
        return count
    }

    private func clamped(_ index: Int) -> Int {
        min(max(index, 0), moveCount)
    }

    private mutating func state(at target: Int) -> State {
        if let cached = checkpoints[target] { return cached }

        // Nearest memoized state at or below the target; index 0 always exists.
        var from = 0
        for key in checkpoints.keys where key <= target && key > from { from = key }
        // `checkpoints[0]` is seeded in `init` and `from` only ever advances to
        // an EXISTING checkpoint key, so this lookup cannot miss. Make that
        // invariant explicit rather than falling back to a fresh empty board:
        // a silent fallback here would replay from a board with no setup
        // stones, corrupting every index onward without any signal that it
        // happened.
        guard var state = checkpoints[from] else {
            preconditionFailure("no checkpoint at \(from); checkpoints[0] is seeded in init and `from` never advances past an existing key")
        }

        var index = from
        while index < target {
            state = apply(moves[index], at: index, to: state)
            index += 1
            if index.isMultiple(of: Self.checkpointStride) {
                checkpoints[index] = state
            }
        }
        return state
    }

    /// Tolerant application: the simple-ko ban is cleared before each move and
    /// multi-stone suicide is allowed, because a recorded game may contain a
    /// position the configured ruleset would forbid and refusing a move
    /// mid-replay would corrupt every later index. What is left — an occupied
    /// point, an off-board point, single-stone suicide — is exactly what the
    /// engine's own `play` refuses, so the two skip the same moves. A refused
    /// move changes nothing at all: not the board, not the turn, not the
    /// window.
    private mutating func apply(_ move: RecordedMove, at index: Int, to state: State) -> State {
        var next = state
        // A pass legitimately clears ko, which is exactly the reset we want.
        next.board.playPass()
        // PlayerColor also has an `unknown` case the recorded move should
        // never carry; treat anything that is not Black as White, as every
        // other reader of a recorded colour in this package does.
        let isBlack = move.color == .black
        let color: PlayerColor = isBlack ? .black : .white
        let stone: GoColor = isBlack ? .black : .white
        if let point = move.point {
            do {
                try next.board.play(at: point, color: stone,
                                    multiStoneSuicideLegal: true)
            } catch {
                refusedIndices.insert(index)
                return state
            }
        }
        // Search::makeMove clears BoardHistory whenever the mover is not the
        // side it expects — a colour repeat — and only then appends
        // (cpp/search/search.cpp setPlayerAndClearHistory). So the repeating
        // move starts a fresh window containing itself.
        if color == next.toMove {
            next.window.append(move.point)
            if next.window.count > 3 {
                next.window.removeFirst(next.window.count - 3)
            }
        } else {
            next.window = [move.point]
        }
        next.toMove = isBlack ? .white : .black
        next.acceptedCount += 1
        return next
    }

    /// The window as `Board::printBoard` prints it: digit `1 + offset`, and
    /// for a point that appears twice the FIRST match wins (printBoard breaks
    /// out of its scan), so a retaken point keeps its oldest digit.
    private func marks(in window: [GoPoint?]) -> [(vertex: String, order: Int)] {
        var result: [(vertex: String, order: Int)] = []
        for (offset, point) in window.enumerated() {
            guard let point else { continue }
            let vertex = point.gtpVertex(boardHeight: height)
            guard !result.contains(where: { $0.vertex == vertex }) else { continue }
            result.append((vertex: vertex, order: offset + 1))
        }
        return result
    }
}
