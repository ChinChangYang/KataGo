//
//  HumanSLModel.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/5/8.
//

import Foundation

/// Maps a clean human-SL **menu key** (`"AI"`, a KGS rank like `"9d"`/`"5k"`, or a
/// pro era like `"Pro 2023"`) to the engine `humanSLProfile` value, the tuned
/// `humanSLChosenMovePiklLambda`, and the `kata-set-param` command list.
///
/// Ranks adopt lightvector/KataGo PR #1209's calibrated KGS-rank ladder
/// (`humanSLProfile = preaz_<rank>` + a per-rank tuned λ). Pros derive from the 9d
/// config with λ 0.06. `AI` is the strongest-net, no-human-bias profile and is
/// preserved byte-for-byte from the previous implementation.
public struct HumanSLModel {

    // MARK: - Profile keys (the key is also the stored value and the display label)

    /// 9d…1d, then 1k…20k.
    private static let rankKeys: [String] =
        (1...9).reversed().map { "\($0)d" } + (1...20).map { "\($0)k" }

    /// "Pro 1800" … "Pro 2023".
    private static let proKeys: [String] = (1800...2023).map { "Pro \($0)" }

    /// All selectable keys, in menu order: AI, ranks (9d→20k), pros (oldest→newest).
    public static let allProfiles: [String] = ["AI"] + rankKeys + proKeys

    // MARK: - PR #1209 tuned λ ladder (keyed by the unified rank key)

    private static let rankLambda: [String: Float] = [
        "9d": 0.045,   "8d": 0.0868,  "7d": 0.1267,  "6d": 0.1983,  "5d": 0.28064,
        "4d": 0.373,   "3d": 0.45556, "2d": 0.5133,  "1d": 0.5093,
        "1k": 0.48988, "2k": 0.46755, "3k": 0.49173, "4k": 0.4713,  "5k": 0.5072,
        "6k": 0.48925, "7k": 0.5337,  "8k": 0.5064,  "9k": 0.5388,  "10k": 0.59036,
        "11k": 0.56458, "12k": 0.54297, "13k": 0.58977, "14k": 0.61625, "15k": 0.61839,
        "16k": 0.6705, "17k": 0.7413, "18k": 0.7821, "19k": 0.8982, "20k": 1.2227,
    ]

    /// Pro profiles derive from the 9d config but use this λ (empirically used by
    /// the old formula's proyear branch).
    private static let proLambda: Float = 0.06

    /// The pro-key display prefix. The trailing space is load-bearing — it
    /// distinguishes "Pro 1800" from rank/other keys.
    private static let proKeyPrefix = "Pro "

    // MARK: - Legacy normalization (input-validation, not schema migration)

    /// Map a possibly-legacy stored engine string to a current menu key:
    /// `rank_<r>` and `preaz_<r>` both collapse to `<r>`, `proyear_<y>` → `Pro <y>`.
    /// Anything already in key form (or unknown) is returned unchanged.
    private static func normalizeLegacy(_ raw: String) -> String {
        if raw.hasPrefix("rank_")    { return String(raw.dropFirst(5)) }
        if raw.hasPrefix("preaz_")   { return String(raw.dropFirst(6)) }
        if raw.hasPrefix("proyear_") { return "Pro " + String(raw.dropFirst(8)) }
        return raw
    }

    /// The canonical menu key for a possibly-legacy stored value, falling back to
    /// `"AI"` if unrecognized. Used by the profile pickers so legacy/garbage values
    /// still resolve to a valid selection.
    public static func canonicalProfile(_ raw: String) -> String {
        HumanSLModel(profile: raw)?.profile ?? "AI"
    }

    // MARK: - Instance

    private var internal_profile: String

    public var profile: String {
        get { internal_profile }
        set {
            let key = HumanSLModel.normalizeLegacy(newValue)
            if HumanSLModel.allProfiles.contains(key) {
                internal_profile = key
            }
        }
    }

    public init() {
        internal_profile = "AI"
    }

    public init?(profile: String) {
        let key = HumanSLModel.normalizeLegacy(profile)
        guard HumanSLModel.allProfiles.contains(key) else { return nil }
        internal_profile = key
    }

    private var isAI: Bool { profile == "AI" }
    private var isPro: Bool { profile.hasPrefix(HumanSLModel.proKeyPrefix) }

    // MARK: - Engine parameters

    /// Value sent via `kata-set-param humanSLProfile`.
    public var humanSLProfile: String {
        if isAI { return "rank_9d" }
        if isPro { return "proyear_" + String(profile.dropFirst(HumanSLModel.proKeyPrefix.count)) }   // "Pro 2023" → proyear_2023
        return "preaz_" + profile                                       // "9d" → preaz_9d
    }

    /// Probability of playing a human-like move rather than KataGo's move.
    var humanSLChosenMoveProp: Float { isAI ? 0.0 : 1.0 }

    /// Use the human SL policy for root exploration during search.
    var humanSLRootExploreProbWeightless: Float { isAI ? 0.0 : 0.8 }

    /// AI keeps today's level-9 temperatures (these still affect AI's own move
    /// selection); human profiles use #1209's constants.
    var chosenMoveTemperatureEarly: Float { isAI ? 0.67 : 0.70 }
    var chosenMoveTemperature: Float { isAI ? 0.16 : 0.25 }
    var chosenMoveTemperatureHalflife: Int { isAI ? 26 : 30 }
    /// Always 1.0 (both AI and human): #1209's human configs use 1.0, and the old
    /// level-9 AI formula also clamped to 1.0 — so no AI/human branch is needed.
    var chosenMoveTemperatureOnlyBelowProb: Float { 1.0 }

    /// Suppress human-like moves KataGo disapproves of. AI: 0.06 (no effect since
    /// prop 0); ranks: #1209 tuned ladder; pros: 0.06.
    var humanSLChosenMovePiklLambda: Float {
        if isAI { return 0.06 }
        if isPro { return HumanSLModel.proLambda }
        return HumanSLModel.rankLambda[profile] ?? HumanSLModel.proLambda
    }

    var winLossUtilityFactor: Float { 1.0 }
    var staticScoreUtilityFactor: Float { isAI ? 0.1 : 0.5 }
    var dynamicScoreUtilityFactor: Float { isAI ? 0.3 : 0.5 }

    public var commands: [String] {
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
