//
//  HumanSLModel.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/5/8.
//

import Foundation

struct HumanSLModel {
    static var allProfiles: [String] {
        let dans = (1...9).reversed().map() { dan in
            return "\(dan)d"
        }

        let kyus = (1...20).map() { kyu in
            return "\(kyu)k"
        }

        let dansKyus = dans + kyus

        let ranks = dansKyus.map() { rank in
            return "rank_\(rank)"
        }

        let preAlphaZeros = dansKyus.map() { rank in
            return "preaz_\(rank)"
        }

        let proYears = (1800...2023).map() { year in
            return "proyear_\(year)"
        }

        return ["AI"] + ranks + preAlphaZeros + proYears
    }

    var internal_profile: String

    var profile: String {
        get {
            return internal_profile
        }

        set(newValue) {
            if HumanSLModel.allProfiles.contains(newValue) {
                self.internal_profile = newValue
            }
        }
    }

    init() {
        internal_profile = "AI"
    }

    init?(profile: String) {
        if HumanSLModel.allProfiles.contains(profile) {
            self.internal_profile = profile
        } else {
            return nil
        }
    }

    var level: Int {
        if (profile == "AI") || profile.hasPrefix("proyear") {
            return 9
        } else if let match = profile.wholeMatch(of: /\w+_(\d+)d/),
                  let levelInt = Int(match.1) {
            return levelInt - 1
        } else if let match = profile.wholeMatch(of: /\w+_(\d+)k/),
                  let levelInt = Int(match.1) {
            return -levelInt
        } else {
            return -30
        }
    }

    /// Choose the "profile" of players that the human SL model will imitate.
    var humanSLProfile: String {
        if profile == "AI" {
            return "rank_9d"
        } else {
            return profile
        }
    }

    /// The probability that we should play a HUMAN-like move, rather than playing KataGo's move.
    var humanSLChosenMoveProp: Float {
        if profile == "AI" {
            return 0.0
        } else {
            return 1.0
        }
    }

    /// Use the human SL policy for exploration during search, only at the root of the search
    var humanSLRootExploreProbWeightful: Float {
        if profile == "AI" {
            return 0.0
        } else {
            return 1.0
        }
    }

    /// Temperature for the early game, randomize between chosen moves with this temperature
    var chosenMoveTemperatureEarly: Float {
        return max(0.85, 0.70 - ((Float(level) - 8.0) * 0.02))
    }

    /// At the end of search after the early game, randomize between chosen moves with this temperature
    var chosenMoveTemperature: Float {
        return max(0.70, 0.25 - ((Float(level) - 8.0) * 0.05))
    }

    /// Decay temperature for the early game by 0.5 every this many moves, scaled with board size.
    var chosenMoveTemperatureHalflife: Int {
        return 30 - ((level - 8) * 3)
    }

    /// Temperature only starts to dampen moves below this
    var chosenMoveTemperatureOnlyBelowProb: Float {
        return max(0.01, pow(10.0, (Float(level) - 8.0) * 0.2))
    }

    /// When a move starts to lose more than 0.08 utility (several percent winrate), downweight it.
    /// Increase this number to reduce the strength and use the human SL policy more and KataGo's evaluations less.
    /// Decrease this number a little more to improve strength even further and play less human-like.
    /// (although below 0.02 you probably are better off going back to a normal KataGo config and scaling visits).
    var humanSLChosenMovePiklLambda: Float {
        return min(1e8, pow(10.0, 8.0 - Float(level)))
    }

    var commands: [String] {
        ["kata-set-param humanSLProfile \(humanSLProfile)",
         "kata-set-param humanSLChosenMoveProp \(humanSLChosenMoveProp)",
         "kata-set-param humanSLRootExploreProbWeightful \(humanSLRootExploreProbWeightful)",
         "kata-set-param chosenMoveTemperatureEarly \(chosenMoveTemperatureEarly)",
         "kata-set-param chosenMoveTemperature \(chosenMoveTemperature)",
         "kata-set-param chosenMoveTemperatureHalflife \(chosenMoveTemperatureHalflife)",
         "kata-set-param chosenMoveTemperatureOnlyBelowProb \(chosenMoveTemperatureOnlyBelowProb)",
         "kata-set-param humanSLChosenMovePiklLambda \(humanSLChosenMovePiklLambda)"]
    }
}
