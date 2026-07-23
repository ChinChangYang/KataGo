//
//  GameRules.swift
//  KataGo iOS
//
//  Shared rule enums used by ConfigModel (KataGoGameStore) and SgfHelper
//  (KataGoUICore). Moved here so KataGoGameStore stays bridge-free.
//

import Foundation

public enum KoRule: Int, Sendable {
    case simple = 0
    case positional = 1
    case situational = 2
}

public enum ScoringRule: Int, Sendable {
    case area = 0
    case territory = 1
}

public enum TaxRule: Int, Sendable {
    case none = 0
    case seki = 1
    case all = 2
}

public enum WhiteHandicapBonusRule: Int, Sendable {
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

// PlayerColor moved to KataGoAnalysisKit (PlayerColor.swift) so the
// Foundation-only analysis tier can express the parser's perspective flip;
// it stays visible to every `import KataGoGameStore` consumer via this
// target's @_exported import KataGoAnalysisKit (AnalysisKitReexport.swift).
