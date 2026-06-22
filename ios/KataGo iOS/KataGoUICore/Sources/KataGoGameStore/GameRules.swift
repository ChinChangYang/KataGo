//
//  GameRules.swift
//  KataGo iOS
//
//  Shared rule enums used by ConfigModel (KataGoGameStore) and SgfHelper
//  (KataGoUICore). Moved here so KataGoGameStore stays bridge-free.
//

import Foundation

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

public enum CommentTone: Int {
    case technical = 0
    case educational = 1
    case encouraging = 2
    case enthusiastic = 3
    case poetic = 4
}

public enum PlayerColor {
    case black
    case white
    case unknown

    public var symbol: String? {
        if self == .black {
            return "b"
        } else if self == .white {
            return "w"
        } else {
            return nil
        }
    }

    public var name: String {
        if self == .black {
            "Black"
        } else if self == .white {
            "White"
        } else {
            "Unknown"
        }
    }

    public var other: PlayerColor {
        switch self {
        case .black: .white
        case .white: .black
        case .unknown: .unknown
        }
    }
}
