//
//  ForcePlay.swift
//  GoRulesKit
//
//  Force-play: how a HYPOTHETICAL line is laid out on a position. The engine
//  proposes continuations (a principal variation, a broadcast beat's acted-out
//  stones) that must be drawn even when our rules cannot reproduce them, so
//  this refuses nothing. Every on-board empty point accepts a stone, and every
//  liberty-less group is lifted — the opponent's, and the played stone's own.
//
//  This is deliberately MORE permissive than `GoBoard.play`, which is a rules
//  layer: `play` refuses simple-ko recapture and single-stone suicide, and the
//  C++ GTP `play` refuses the latter too (cpp/game/board.cpp isIllegalSuicide
//  falls through for a lone stone even when multi-stone suicide is legal). A
//  renderer has no such luxury — it must draw something, and the one thing it
//  must never draw is a position the rules could not produce.
//
//  Ko, superko and turn order are never consulted: a variation is not a game.
//  Nothing here touches capture counters, because nothing here happened.
//

import Foundation
import KataGoGameStore

/// One move of a hypothetical line: an EXPLICIT color, never inferred from
/// position in the list. A principal variation alternates and adapts itself
/// into this; a beat's stones do not alternate at all (the tenuki beat plays
/// two of the same color in a row, by design), and a resolver that inferred
/// color by index would get that wrong.
public struct ForcePlayMove: Sendable, Equatable {
    public let vertex: String
    public let color: GoColor

    public init(vertex: String, color: GoColor) {
        self.vertex = vertex
        self.color = color
    }
}

/// What became of one force-played move. `placed` covers self-capture too —
/// the stone went down and may have come straight back off; final occupancy
/// is the board's business, not the disposition's.
public enum ForcePlayDisposition: Sendable, Equatable {
    case placed(GoPoint)
    /// A stone of this color already stood there: nothing changed, and the
    /// move still owns the point for numbering purposes.
    case alreadyThere(GoPoint)
    /// An enemy stone stands there, so nothing is placed. Unreachable for a
    /// well-formed line — the move that captured it travels ahead of this one
    /// in the same list — which is why it is worth logging when it happens.
    case skippedOccupied(GoPoint)
    /// The vertex names no intersection on this board (an out-of-bounds token;
    /// the PV lexer does not bounds-check against the board size).
    case skippedUnplaceable
    /// A pass: places nothing, skips nothing.
    case passed

    /// The point this move owns for numbering, or nil when it placed nothing.
    /// A skipped move owns no point: numbering an enemy stone with our move
    /// number would be a worse lie than the missing number.
    public var point: GoPoint? {
        switch self {
        case .placed(let point), .alreadyThere(let point): point
        case .skippedOccupied, .skippedUnplaceable, .passed: nil
        }
    }

    /// Whether the move asked for a stone and did not get one.
    public var isSkipped: Bool {
        switch self {
        case .skippedOccupied, .skippedUnplaceable: true
        case .placed, .alreadyThere, .passed: false
        }
    }
}

public struct ForcePlayResult: Sendable {
    /// The resolved position. Every group on it has at least one liberty.
    public let board: GoBoard
    /// One entry per input move, in order.
    public let dispositions: [ForcePlayDisposition]

    public var skippedCount: Int {
        dispositions.reduce(0) { $0 + ($1.isSkipped ? 1 : 0) }
    }
}

public enum ForcePlay {
    /// Lays out `moves` on the position described by `setupBlack`/`setupWhite`.
    ///
    /// Moves are applied IN ORDER and the order is load-bearing: a beat places
    /// the capturing stone and then a stone inside the shape it just cleared,
    /// so resolving the list per-color — or out of order — would find the
    /// second point still occupied and drop it.
    ///
    /// Returns nil only for a degenerate board size; `GoBoard.init`
    /// preconditions on it, and a renderer must not trap.
    public static func resolve(width: Int, height: Int,
                               setupBlack: [String], setupWhite: [String],
                               moves: [ForcePlayMove]) -> ForcePlayResult? {
        guard width >= 1, height >= 1 else { return nil }
        var board = GoBoard(width: width, height: height)

        // Setup stones carry no captures: the base is already a real position.
        // First writer wins, black before white, matching how SGF AB/AW
        // collisions resolve in SgfReplay.
        for vertex in setupBlack { place(&board, vertex: vertex, color: .black) }
        for vertex in setupWhite { place(&board, vertex: vertex, color: .white) }

        var dispositions: [ForcePlayDisposition] = []
        dispositions.reserveCapacity(moves.count)
        for move in moves {
            dispositions.append(apply(&board, move: move))
        }
        return ForcePlayResult(board: board, dispositions: dispositions)
    }

    private static func place(_ board: inout GoBoard, vertex: String, color: GoColor) {
        guard let point = point(vertex, width: board.width, height: board.height),
              board.color(at: point) == .empty else { return }
        board.placeSetupStone(at: point, color: color)
    }

    private static func apply(_ board: inout GoBoard, move: ForcePlayMove) -> ForcePlayDisposition {
        guard !isPass(move.vertex) else { return .passed }
        guard let point = point(move.vertex, width: board.width, height: board.height),
              let index = board.index(of: point) else { return .skippedUnplaceable }

        let existing = board.grid[index]
        if existing == move.color { return .alreadyThere(point) }
        if existing != .empty { return .skippedOccupied(point) }

        board.placeSetupStone(at: point, color: move.color)

        // The opponent's groups die first: a capture can hand the played stone
        // the liberty that saves it, and the reverse is never true.
        let opponent = move.color.opponent
        var doomed: [Int] = []
        for adjacent in board.neighbors(of: index)
        where board.grid[adjacent] == opponent && board.libertyCount(ofChainAt: adjacent) == 0 {
            doomed.append(contentsOf: board.chain(at: adjacent))
        }
        if !doomed.isEmpty {
            board = board.removingStones(at: doomed)
        }

        // Then the played stone's own group, if it still has no liberties.
        // Single- and multi-stone suicide are the same event here.
        if board.libertyCount(ofChainAt: index) == 0 {
            board = board.removingStones(at: board.chain(at: index))
        }
        return .placed(point)
    }

    /// GTP vertex → `GoPoint`, or nil for anything that names no intersection.
    /// `parseVertex` already returns GoPoint's convention (0-based, top-left)
    /// and bounds-checks both axes, so there is no flip to get wrong here.
    private static func point(_ vertex: String, width: Int, height: Int) -> GoPoint? {
        guard let parsed = parseVertex(vertex, width: width, height: height) else { return nil }
        return GoPoint(x: parsed.x, y: parsed.y)
    }

    private static func isPass(_ vertex: String) -> Bool {
        vertex.caseInsensitiveCompare("pass") == .orderedSame
    }
}
