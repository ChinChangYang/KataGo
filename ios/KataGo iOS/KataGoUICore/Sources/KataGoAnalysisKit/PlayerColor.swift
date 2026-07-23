//
//  PlayerColor.swift
//  KataGoAnalysisKit
//
//  Moved verbatim from KataGoGameStore's GameRules.swift so the analysis
//  tier's perspective flip (AnalysisLineParser.nextColor) stays Foundation-only
//  instead of dragging the SwiftData store into extension link graphs.
//  KataGoGameStore re-exports this module, so every existing
//  `import KataGoGameStore` consumer keeps seeing PlayerColor unchanged.
//

import Foundation

public enum PlayerColor: Sendable {
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
