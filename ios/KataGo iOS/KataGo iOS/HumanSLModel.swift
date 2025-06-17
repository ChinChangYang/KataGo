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
    /// For example, humanSLRootExploreProbWeightless = 0.5 would tell KataGo at the root of the search to spend
    /// 50% of its visits to judge different possible human moves, but NOT to use those visits for determining the
    /// value of the position (avoiding biasing the utility if some human SL moves are very bad).
    var humanSLRootExploreProbWeightless: Float {
        if profile == "AI" {
            return 0.0
        } else {
            return 0.5
        }
    }

    /// Temperature for the early game, randomize between chosen moves with this temperature
    var chosenMoveTemperatureEarly: Float {
        return min(0.85, 0.70 - ((Float(level) - 8.0) * 0.03))
    }

    /// At the end of search after the early game, randomize between chosen moves with this temperature
    var chosenMoveTemperature: Float {
        return min(0.70, 0.25 - ((Float(level) - 8.0) * 0.09))
    }

    /// Decay temperature for the early game by 0.5 every this many moves, scaled with board size.
    var chosenMoveTemperatureHalflife: Int {
        return 30 - ((level - 8) * 4)
    }

    /// Temperature only starts to dampen moves below this
    var chosenMoveTemperatureOnlyBelowProb: Float {
        return min(1.0, max(0.01, pow(10.0, (Float(level) - 8.0) * 0.2)))
    }

    /// By default humanSLChosenMovePiklLambda is a large number which effectively disables it.
    /// Setting it to a smaller number will "suppress" human-like moves that KataGo disapproves of.
    /// In particular, if set to, for example, 0.4 when KataGo judges a human SL move to lose 0.4 utility,
    /// it will substantially suppress the chance of playing that move (in particular, by a factor of exp(1)).
    /// Less-bad moves will also be suppressed, but not by as much, e.g. a move losing 0.2 would get lowered
    /// by a factor of exp(0.5).
    /// As configured lower down, utilities by default range from -1.0 (loss) to +1.0 (win), plus up to +/- 0.3 for score.
    /// WARNING: ONLY moves that KataGo actually searches will get suppressed! If a move is so bad that KataGo
    /// rejects it without searching it, it will NOT get suppressed.
    /// Therefore, to use humanSLChosenMovePiklLambda, it is STRONGLY recommended that you also use something
    /// like humanSLRootExploreProbWeightless to ensure most human moves including bad moves get searched,
    /// and ALSO use at least hundreds and ideally thousands of maxVisits, to ensure enough visits.
    var humanSLChosenMovePiklLambda: Float {
        return 0.06 + (Float(level) - 9.0) * (Float(level) - 9.0) * 0.03
    }

    /// Scales the utility of winning/losing
    var winLossUtilityFactor: Float {
        if profile == "AI" {
            return 1.0
        } else {
            return 0.0
        }
    }

    /// Scales the utility for trying to maximize score
    var staticScoreUtilityFactor: Float {
        if profile == "AI" {
            return 0.1
        } else {
            return 0.5
        }
    }

    /// Scales the utility for trying to maximize score based on dynamic score evaluation
    var dynamicScoreUtilityFactor: Float {
        if profile == "AI" {
            return 0.3
        } else {
            return 0.5
        }
    }

    var commands: [String] {
        ["kata-set-param humanSLProfile \(humanSLProfile)",
         "kata-set-param humanSLChosenMoveProp \(humanSLChosenMoveProp)",
         "kata-set-param humanSLRootExploreProbWeightless \(humanSLRootExploreProbWeightless)",
         "kata-set-param chosenMoveTemperatureEarly \(chosenMoveTemperatureEarly)",
         "kata-set-param chosenMoveTemperature \(chosenMoveTemperature)",
         "kata-set-param chosenMoveTemperatureHalflife \(chosenMoveTemperatureHalflife)",
         "kata-set-param chosenMoveTemperatureOnlyBelowProb \(chosenMoveTemperatureOnlyBelowProb)",
         "kata-set-param humanSLChosenMovePiklLambda \(humanSLChosenMovePiklLambda)",
         "kata-set-param winLossUtilityFactor \(winLossUtilityFactor)",
         "kata-set-param staticScoreUtilityFactor \(staticScoreUtilityFactor)",
         "kata-set-param dynamicScoreUtilityFactor \(dynamicScoreUtilityFactor)"]
    }
}
