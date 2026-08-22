//
//  SgfHelper.swift
//  KataGoInterface
//
//  Created by Chin-Chang Yang on 2024/7/8.
//

import Foundation
import CKataGoBridge

public struct Location {
    public let x: Int
    public let y: Int
    public let pass: Bool

    public init() {
        self.x = -1
        self.y = -1
        self.pass = true
    }

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
        self.pass = false
    }
}

public enum Player {
    case black
    case white
}

public struct Move {
    public let location: Location
    public let player: Player

    public init(location: Location, player: Player) {
        self.location = location
        self.player = player
    }
}


/// One setup instruction from an SGF root node: a Black stone (`AB`), a White
/// stone (`AW`), or a cleared point (`AE`). Coordinates are 0-based with the
/// origin at the TOP-LEFT (x right, y down), matching `Location`. This is the
/// position the engine is set up with before the first move is played, and
/// the seed the engine-free replay starts from.
public struct Placement: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case black
        case white
        case removal
    }

    public let x: Int
    public let y: Int
    public let kind: Kind

    public init(x: Int, y: Int, kind: Kind) {
        self.x = x
        self.y = y
        self.kind = kind
    }
}

public struct Rules {
    public let koRule: KoRule
    public let scoringRule: ScoringRule
    public let taxRule: TaxRule
    public let multiStoneSuicideLegal: Bool
    public let hasButton: Bool
    public let whiteHandicapBonusRule: WhiteHandicapBonusRule
    public let friendlyPassOk: Bool
    public let komi: Float

    public init(koRule: KoRule,
                scoringRule: ScoringRule,
                taxRule: TaxRule,
                multiStoneSuicideLegal: Bool,
                hasButton: Bool,
                whiteHandicapBonusRule: WhiteHandicapBonusRule,
                friendlyPassOk: Bool,
                komi: Float) {
        self.koRule = koRule
        self.scoringRule = scoringRule
        self.taxRule = taxRule
        self.multiStoneSuicideLegal = multiStoneSuicideLegal
        self.hasButton = hasButton
        self.whiteHandicapBonusRule = whiteHandicapBonusRule
        self.friendlyPassOk = friendlyPassOk
        self.komi = komi
    }
}

/// The stones standing on the board at the final position of an SGF's main line
/// (handicap/setup stones included, captures resolved), as GTP vertex strings
/// such as "Q16". Used to give an imported-but-never-opened game a renderable
/// position for the Saved Game widget without running the engine.
public struct FinalPosition {
    public let blackStones: [String]
    public let whiteStones: [String]

    public init(blackStones: [String], whiteStones: [String]) {
        self.blackStones = blackStones
        self.whiteStones = whiteStones
    }
}

/// One animation frame of a game: the stones standing after some number of moves
/// (captures resolved) plus the move that produced the position, as GTP vertex
/// strings. `lastMove` is nil for the starting position; a pass is left as
/// "pass", which the board renderer draws no highlight for. Used to build a GIF
/// of the game move by move without running the engine.
public struct GifFrame: Sendable {
    public let blackStones: [String]
    public let whiteStones: [String]
    public let lastMove: String?

    public init(blackStones: [String], whiteStones: [String], lastMove: String?) {
        self.blackStones = blackStones
        self.whiteStones = whiteStones
        self.lastMove = lastMove
    }
}

public class SgfHelper {
    let sgfCpp: SgfCpp

    public init(sgf: String) {
        sgfCpp = SgfCpp(std.string(sgf))
    }

    /// Replays the SGF main line in C++ (battle-tested board rules) and returns
    /// the final on-board stones as GTP vertices. Empty for an invalid SGF.
    public func finalPosition() -> FinalPosition {
        let pos = sgfCpp.getFinalPosition()
        return FinalPosition(blackStones: SgfHelper.vertices(from: String(pos.blackStones)),
                             whiteStones: SgfHelper.vertices(from: String(pos.whiteStones)))
    }

    /// Splits a space-joined vertex string ("Q16 D4") into ["Q16", "D4"].
    private static func vertices(from joined: String) -> [String] {
        joined.split(separator: " ").map(String.init)
    }

    /// One `GifFrame` per position along the main line, from the starting
    /// position (index 0) through the final position (index `moveSize`), so the
    /// result has `moveSize + 1` frames. Each frame replays the SGF in C++ with
    /// captures resolved; empty for an invalid SGF.
    ///
    /// Cost is O(N²) in the move count (each frame re-replays from the start),
    /// which is negligible for real games (a few hundred moves of cheap board
    /// ops); swap in a single-pass bridge method only if profiling ever demands.
    public func gifFrames() -> [GifFrame] {
        guard let moveSize else { return [] }
        return (0...moveSize).map { index in
            let frame = sgfCpp.getFrameAt(Int32(index))
            let lastMove = String(frame.lastMove)
            return GifFrame(blackStones: SgfHelper.vertices(from: String(frame.blackStones)),
                            whiteStones: SgfHelper.vertices(from: String(frame.whiteStones)),
                            lastMove: lastMove.isEmpty ? nil : lastMove)
        }
    }

    public func getMove(at index: Int) -> Move? {
        guard sgfCpp.isValidMoveIndex(Int32(index)) else { return nil }
        let moveCpp = sgfCpp.getMoveAt(Int32(index))
        let location = moveCpp.pass ? Location() : Location(x: Int(moveCpp.x), y: Int(moveCpp.y))
        let player: Player = (moveCpp.player == PlayerCpp.black) ? .black : .white
        return Move(location: location, player: player)
    }

    /// The root node's `AB`/`AW`/`AE` setup, compressed point ranges expanded,
    /// in the order the engine accumulates them (AB, then AW, then AE). Empty
    /// for an invalid SGF, and for placements on nodes after the root — the
    /// engine's own parser refuses those records outright.
    public func placements() -> [Placement] {
        (0..<Int(sgfCpp.placementsSize)).map { index in
            let placement = sgfCpp.getPlacementAt(Int32(index))
            let kind: Placement.Kind
            if placement.color == PlacementColorCpp.black {
                kind = .black
            } else if placement.color == PlacementColorCpp.white {
                kind = .white
            } else {
                kind = .removal
            }
            return Placement(x: Int(placement.x), y: Int(placement.y), kind: kind)
        }
    }

    public func getComment(at index: Int) -> String? {
        guard sgfCpp.isValidCommentIndex(Int32(index)) else { return nil }
        let commentCpp = sgfCpp.getCommentAt(Int32(index))
        return String(commentCpp)
    }

    public var moveSize: Int? {
        guard sgfCpp.valid else { return nil }
        return Int(sgfCpp.movesSize)
    }

    public var xSize: Int {
        return Int(sgfCpp.xSize)
    }

    public var ySize: Int {
        return Int(sgfCpp.ySize)
    }

    public var rules: Rules {
        let rulesCpp = sgfCpp.getRules()
        let koRule = KoRule(rawValue: Int(rulesCpp.koRule)) ?? .simple
        let scoringRule = ScoringRule(rawValue: Int(rulesCpp.scoringRule)) ?? .area
        let taxRule = TaxRule(rawValue: Int(rulesCpp.taxRule)) ?? .none
        let whiteHandicapBonusRule = WhiteHandicapBonusRule(rawValue: Int(rulesCpp.whiteHandicapBonusRule)) ?? .zero

        return Rules(koRule: koRule,
                     scoringRule: scoringRule,
                     taxRule: taxRule,
                     multiStoneSuicideLegal: rulesCpp.multiStoneSuicideLegal,
                     hasButton: rulesCpp.hasButton,
                     whiteHandicapBonusRule: whiteHandicapBonusRule,
                     friendlyPassOk: rulesCpp.friendlyPassOk,
                     komi: rulesCpp.komi)
    }
}
