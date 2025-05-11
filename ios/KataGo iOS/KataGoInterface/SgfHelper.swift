//
//  SgfHelper.swift
//  KataGoInterface
//
//  Created by Chin-Chang Yang on 2024/7/8.
//

import Foundation

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

public enum KoRule: Int {
    case simple = 0
    case positional = 1
    case situational = 2
}

public enum ScoringRule: Int {
    case area = 0
    case territory = 1
}

public enum TaxRule: Int {
    case none = 0
    case seki = 1
    case all = 2
}

public enum WhiteHandicapBonusRule: Int {
    case zero = 0
    case n = 1
    case n_minus_one = 2
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

public class SgfHelper {
    let sgfCpp: SgfCpp

    public init(sgf: String) {
        sgfCpp = SgfCpp(std.string(sgf))
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
        guard ((sgfCpp.valid) && (sgfCpp.movesSize > 0)) else { return nil }
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
