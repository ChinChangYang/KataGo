//
//  Config+PlayerLabel.swift
//  KataGoUICore
//
//  The player label as the board shows it. `Config.playerLabel(for:)` lives in
//  the bridge-free `KataGoGameStore` and returns the stored profile string raw;
//  it cannot see `HumanSLModel`, so the canonical reading is layered on here.
//

import KataGoAnalysisKit
import KataGoGameStore

extension Config {
    /// "Human" for a side a person plays, else the side's canonical profile key
    /// ("AI", "5k 2019", "Pro 1997"), so a record saved before the style year
    /// (a bare "5k") reads with the year it has always played at.
    public func displayPlayerLabel(for color: PlayerColor) -> String {
        switch color {
        case .black:
            return blackMaxTime > 0 ? HumanSLModel.canonicalProfile(humanProfileForBlack) : Config.humanPlayerLabel
        case .white:
            return whiteMaxTime > 0 ? HumanSLModel.canonicalProfile(humanProfileForWhite) : Config.humanPlayerLabel
        case .unknown:
            return ""
        }
    }
}
