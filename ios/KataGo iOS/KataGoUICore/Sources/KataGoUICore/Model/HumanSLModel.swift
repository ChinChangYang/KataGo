//
//  HumanSLModel.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/5/8.
//

import Foundation

/// Maps a clean human-SL **menu key** (`"AI"`, a KGS rank like `"9d"`/`"5k"`, or a
/// pro era like `"Pro 2023"`) to the engine `humanSLProfile` value and the
/// `kata-set-param` command list.
///
/// Ranks map to `humanSLProfile = preaz_<rank>`; pros to `proyear_<year>`. The
/// move-selection params (temperatures, λ, exploration) scale with a strength
/// `level` derived from the rank key (AI/pros → 9; `Nd` → N-1; `Nk` → -N). `AI` is
/// the strongest-net, no-human-bias profile.
public struct HumanSLModel {

    // MARK: - Profile keys (the key is also the stored value and the display label)

    /// 9d…1d, then 1k…20k.
    private static let rankKeys: [String] =
        (1...9).reversed().map { "\($0)d" } + (1...20).map { "\($0)k" }

    /// "Pro 1800" … "Pro 2023".
    private static let proKeys: [String] = (1800...2023).map { "Pro \($0)" }

    /// All selectable keys, in menu order: AI, ranks (9d→20k), pros (oldest→newest).
    public static let allProfiles: [String] = ["AI"] + rankKeys + proKeys

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

    /// Strength level driving the move-selection formulas: AI and pros are strongest
    /// (9); ranks step down — `9d`→8 … `1d`→0, `1k`→-1 … `20k`→-20. Checked after the
    /// AI/pro guards so a pro key never reaches the rank regex.
    private var level: Int {
        if isAI || isPro { return 9 }
        if let m = profile.wholeMatch(of: /(\d+)d/), let n = Int(m.1) { return n - 1 }
        if let m = profile.wholeMatch(of: /(\d+)k/), let n = Int(m.1) { return -n }
        return -30
    }

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
    var humanSLRootExploreProbWeightless: Float { isAI ? 0.0 : 0.5 }

    /// Temperatures scale with `level`; the level-9 AI/pro values collapse to
    /// 0.67 / 0.16 / 26 / 1.0 via these formulas.
    var chosenMoveTemperatureEarly: Float { min(0.85, 0.70 - ((Float(level) - 8.0) * 0.03)) }
    var chosenMoveTemperature: Float { min(0.70, 0.25 - ((Float(level) - 8.0) * 0.09)) }
    var chosenMoveTemperatureHalflife: Int { 30 - ((level - 8) * 4) }
    var chosenMoveTemperatureOnlyBelowProb: Float { min(1.0, max(0.01, pow(10.0, (Float(level) - 8.0) * 0.2))) }

    /// Suppress human-like moves KataGo disapproves of, growing quadratically as the
    /// level drops below 9 (AI/pros → 0.06; weaker ranks → larger, less suppression).
    var humanSLChosenMovePiklLambda: Float { 0.06 + (Float(level) - 9.0) * (Float(level) - 9.0) * 0.03 }

    /// Human profiles imitate (ignore win/loss); only AI tries to win.
    var winLossUtilityFactor: Float { isAI ? 1.0 : 0.0 }
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
