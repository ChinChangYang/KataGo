//
//  AnalysisInfo.swift
//  KataGoAnalysisKit
//
//  Per-candidate and per-point analysis value types, moved verbatim from
//  KataGoUICore's KataGoModel.swift so AnalysisLineParser's output is fully
//  expressible in the bridge-free analysis tier.
//

import Foundation

public struct AnalysisInfo {
    public let visits: Int
    public let winrate: Float
    public let scoreLead: Float
    public let utilityLcb: Float
    /// Principal variation as GTP vertex strings ("Q16", "pass"). Depth is
    /// capped by the cfg's `analysisPVLen`. Empty when not present in the line.
    public let pv: [String]
    /// Per-candidate ownership grid from this move's search subtree (same
    /// emission order and perspective as the root grid). Only present when the
    /// analyze command requested `movesOwnership true`; nil otherwise.
    public let movesOwnership: [Float]?

    public init(visits: Int, winrate: Float, scoreLead: Float, utilityLcb: Float,
                pv: [String] = [], movesOwnership: [Float]? = nil) {
        self.visits = visits
        self.winrate = winrate
        self.scoreLead = scoreLead
        self.utilityLcb = utilityLcb
        self.pv = pv
        self.movesOwnership = movesOwnership
    }
}

public struct OwnershipUnit: Identifiable {
    public let point: BoardPoint
    public let whiteness: Float
    public let scale: Float
    public let opacity: Float

    public init(point: BoardPoint, whiteness: Float, scale: Float, opacity: Float) {
        self.point = point
        self.whiteness = whiteness
        self.scale = scale
        self.opacity = opacity
    }

    public var id: Int {
        point.hashValue
    }

    public var isBlack: Bool {
        whiteness < 0.1
    }

    public var isWhite: Bool {
        whiteness > 0.9
    }

    public var isSchrodinger: Bool {
        (abs(whiteness - 0.5) < 0.2) && scale > 0.4
    }

    public var nearBlack: Bool {
        whiteness < 0.3
    }

    public var nearWhite: Bool {
        whiteness > 0.7
    }
}
