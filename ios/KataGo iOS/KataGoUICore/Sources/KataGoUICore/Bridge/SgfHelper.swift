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

    public func getMove(at index: Int) -> Move? {
        guard sgfCpp.isValidMoveIndex(Int32(index)) else { return nil }
        let moveCpp = sgfCpp.getMoveAt(Int32(index))
        let location = moveCpp.pass ? Location() : Location(x: Int(moveCpp.x), y: Int(moveCpp.y))
        let player: Player = (moveCpp.player == PlayerCpp.black) ? .black : .white
        return Move(location: location, player: player)
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
