//
//  MoveLegality.swift
//  GoRulesKit
//
//  STRICT legality for a NEW move at a record position, decided in Swift so
//  a human can put a stone down with no KataGo engine loaded. It is the
//  read-only counterpart of `SgfReplay`'s TOLERANT replay: the replay keeps
//  accepting ko retakes and multi-stone suicide because the engine's `play`
//  does and the two must skip the same recorded moves; this layer answers
//  the different question `kata-check-move` answers — would the configured
//  rules allow this move now? — with the same reasons, in the same order
//  (cpp/program/playutils.cpp checkMoveLegality: out of bounds → occupied →
//  ko → suicide → superko; a pass is always legal).
//

import Foundation
import KataGoAnalysisKit
import KataGoGameStore

/// Why a NEW move at a record position is or is not legal under the record's
/// rules — KataGo's `kata-check-move` reasons, decided in Swift so a human can
/// play with no engine loaded.
public enum MoveLegality: Equatable, Sendable {
    case legal
    case outOfBounds
    case occupied
    /// The simple-ko point.
    case ko
    /// Illegal suicide. `multiStone` is true when the played stone would join
    /// friendly stones (a chain of two or more), false for a lone stone.
    case suicide(multiStone: Bool)
    case superko

    /// KataGo's `kata-check-move` reason string; nil when legal.
    public var reason: String? {
        switch self {
        case .legal: nil
        case .outOfBounds: "out_of_bounds"
        case .occupied: "occupied"
        case .ko: "ko"
        case .suicide: "suicide"
        case .superko: "superko"
        }
    }

    /// Whether the app may offer "Play Anyway": ko, superko and MULTI-stone
    /// suicide (the engine's tolerant `play` accepts all three), never a
    /// single-stone suicide (the tolerant replay refuses it at that index) and
    /// never occupied / out of bounds.
    public var canPlayAnyway: Bool {
        switch self {
        case .ko, .superko: true
        case .suicide(let multiStone): multiStone
        case .legal, .outOfBounds, .occupied: false
        }
    }
}

/// The strict-legality view of one record position: the board with its real
/// simple-ko point, the side to move, and the ko-hash history of the line.
public struct MoveLegalityContext: Sendable {
    public let board: GoBoard
    /// The replay's side to move at this index (.black or .white).
    public let toMove: PlayerColor
    public let koRule: KoRule
    public let multiStoneSuicideLegal: Bool
    /// Ko hashes of the initial position and of the position after every
    /// accepted move up to this index. Empty under `.simple` (never consulted).
    public let koHashes: Set<UInt64>

    public init(board: GoBoard, toMove: PlayerColor, koRule: KoRule,
                multiStoneSuicideLegal: Bool, koHashes: Set<UInt64>) {
        self.board = board
        self.toMove = toMove
        self.koRule = koRule
        self.multiStoneSuicideLegal = multiStoneSuicideLegal
        self.koHashes = koHashes
    }

    /// `toMove` as a board colour, for `check(point:color:)`.
    public var toMoveColor: GoColor { GoColor(stone: toMove) }

    /// Legality of `color` playing at `point` (nil = pass, always legal), in
    /// KataGo's short-circuit order: out of bounds → occupied → ko → suicide → superko.
    public func check(point: GoPoint?, color: GoColor) -> MoveLegality {
        guard let point else { return .legal }
        // `GoColor.empty` is not a mover; treat it as White, the convention
        // every reader of a recorded colour in this package follows.
        let stone: GoColor = color == .black ? .black : .white
        guard let index = board.index(of: point) else { return .outOfBounds }
        guard board.grid[index] == .empty else { return .occupied }
        // `board.koLoc` is the point the LAST accepted move made a simple-ko
        // retake of, exactly `Board::isKoBanned` — the replay's own moves
        // clear it before playing (tolerance), but the context keeps it.
        if board.koLoc == index { return .ko }
        if board.isIllegalSuicide(at: index, color: stone,
                                  multiStoneSuicideLegal: multiStoneSuicideLegal) {
            let joinsFriends = board.neighbors(of: index).contains { board.grid[$0] == stone }
            return .suicide(multiStone: joinsFriends)
        }
        if koRule != .simple {
            // Legality below the superko layer is already established, so the
            // trial play cannot throw; the hash compared is the position AFTER
            // the move with the OPPONENT to move (BoardHistory::
            // makeBoardMoveAssumeLegal's getKoHash(..., getOpp(movePla))).
            var next = board
            if (try? next.play(at: point, color: stone,
                               multiStoneSuicideLegal: multiStoneSuicideLegal)) != nil,
               koHashes.contains(Self.koHash(of: next, toMove: stone.opponent, koRule: koRule)) {
                return .superko
            }
        }
        return .legal
    }

    /// The hash the ko history stores for a position: stones only under
    /// positional, stones plus the side to move under situational. Simple ko
    /// never consults the history, but hashing as positional keeps the
    /// function total.
    static func koHash(of board: GoBoard, toMove: GoColor, koRule: KoRule) -> UInt64 {
        switch koRule {
        case .situational: board.situationalHash(toMove: toMove)
        case .simple, .positional: board.posHash
        }
    }
}

extension GoColor {
    /// A recorded colour as a stone. `PlayerColor` also has an `unknown` case
    /// no mover should carry; anything that is not Black is White, as every
    /// other reader of a recorded colour in this package does.
    init(stone player: PlayerColor) {
        self = player == .black ? .black : .white
    }
}
