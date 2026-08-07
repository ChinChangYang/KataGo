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
/// Ranks map to `humanSLProfile = preaz_<rank>`; pros to `proyear_<year>`. `AI` is
/// the strongest-net, no-human-bias profile.
///
/// Rank params come from the KataGo PR #1209 even-game ELO ladder
/// (`docs/HumanSL_Rank_Ladder.md` on the `gtp-human-rank-configs` branch): the
/// 8d→25k rungs share constant human params and differ only in the certified
/// per-rank `humanSLChosenMovePiklLambda` (7d…14k a ~100-ELO staircase; 15k…25k the
/// pure-human tail at 1e8); `9d` is the ladder docs' separate legacy-strong
/// reference (λ 0.045, try-to-win, 400 visits via `GtpCommandBuilder`); pros reuse
/// the 8d-anchor λ 0.06 in imitation mode. The ladder was certified on
/// kata1-b28c512nbt @ 8 search threads, 40 visits, Japanese komi 6.5 — under the
/// app's nets/threads the rungs are a calibrated relative ladder, not exact
/// absolute strengths.
public struct HumanSLModel {

    // MARK: - Profile keys (the key is also the stored value and the display label)

    /// 9d…1d, then 1k…25k.
    private static let rankKeys: [String] =
        (1...9).reversed().map { "\($0)d" } + (1...25).map { "\($0)k" }

    /// "Pro 1800" … "Pro 2023".
    private static let proKeys: [String] = (1800...2023).map { "Pro \($0)" }

    /// All selectable keys, in menu order: AI, ranks (9d→25k), pros (oldest→newest).
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

    // MARK: - Engine parameters

    /// Value sent via `kata-set-param humanSLProfile`.
    public var humanSLProfile: String {
        if isAI { return "rank_9d" }
        if isPro { return "proyear_" + String(profile.dropFirst(HumanSLModel.proKeyPrefix.count)) }   // "Pro 2023" → proyear_2023
        return "preaz_" + profile                                       // "9d" → preaz_9d
    }

    /// The certified per-rank `humanSLChosenMovePiklLambda`, byte-copied from the
    /// PR #1209 ladder table (values as strings so the GTP text is exactly the
    /// config's — `Float` would print the tail's 1e8 as "1e+08").
    private static let rankPiklLambda: [String: String] = [
        "9d": "0.045",                                    // legacy-strong reference
        "8d": "0.06",                                     // hand-set anchor
        "7d": "0.07760", "6d": "0.09940", "5d": "0.13240", "4d": "0.15750",
        "3d": "0.18960", "2d": "0.21300", "1d": "0.19170",
        "1k": "0.20150", "2k": "0.19950", "3k": "0.20760", "4k": "0.21180",
        "5k": "0.21600", "6k": "0.22480", "7k": "0.24590", "8k": "0.25840",
        "9k": "0.30620", "10k": "0.37250", "11k": "0.40810", "12k": "0.46300",
        "13k": "0.83000", "14k": "3.40040",
        // 15k…25k: pure-human tail — even λ→∞ cannot reach a 100-ELO step here.
        "15k": "100000000", "16k": "100000000", "17k": "100000000",
        "18k": "100000000", "19k": "100000000", "20k": "100000000",
        "21k": "100000000", "22k": "100000000", "23k": "100000000",
        "24k": "100000000", "25k": "100000000",
    ]

    /// Suppression of human-like moves KataGo disapproves of; pros reuse the
    /// 8d-anchor λ. (AI's own 0.06 is emitted by the AI branch directly.)
    private var piklLambda: String {
        HumanSLModel.rankPiklLambda[profile] ?? "0.06"
    }

    public var commands: [String] {
        if isAI {
            // Full-strength profile. The last four lines RESTORE the engine's GTP
            // defaults for the search heuristics the human profiles override below —
            // kata-set-param is sticky, so without them a human-profile move would
            // leave the heuristics off for subsequent full-strength play/analysis.
            return ["kata-set-param humanSLProfile rank_9d",
                    "kata-set-param humanSLChosenMoveProp 0.0",
                    "kata-set-param humanSLRootExploreProbWeightless 0.0",
                    "kata-set-param chosenMoveTemperatureEarly 0.67",
                    "kata-set-param chosenMoveTemperature 0.16",
                    "kata-set-param chosenMoveTemperatureHalflife 26",
                    "kata-set-param chosenMoveTemperatureOnlyBelowProb 1.0",
                    "kata-set-param humanSLChosenMovePiklLambda 0.06",
                    "kata-set-param winLossUtilityFactor 1.0",
                    "kata-set-param staticScoreUtilityFactor 0.1",
                    "kata-set-param dynamicScoreUtilityFactor 0.3",
                    "kata-set-param useLcbForSelection true",
                    "kata-set-param useUncertainty true",
                    "kata-set-param useNoisePruning true",
                    "kata-set-param subtreeValueBiasFactor 0.45"]
        }
        // The ladder's constant human params; only λ (and 9d's try-to-win) vary.
        // winLoss 0 = imitation for every rung and pro; the legacy-strong 9d alone
        // optimizes winrate. The four heuristics are OFF to match the calibration.
        return ["kata-set-param humanSLProfile \(humanSLProfile)",
                "kata-set-param humanSLChosenMoveProp 1.0",
                "kata-set-param humanSLRootExploreProbWeightless 0.8",
                "kata-set-param chosenMoveTemperatureEarly 0.7",
                "kata-set-param chosenMoveTemperature 0.25",
                "kata-set-param chosenMoveTemperatureHalflife 30",
                "kata-set-param chosenMoveTemperatureOnlyBelowProb 1.0",
                "kata-set-param humanSLChosenMovePiklLambda \(piklLambda)",
                "kata-set-param winLossUtilityFactor \(profile == "9d" ? "1.0" : "0.0")",
                "kata-set-param staticScoreUtilityFactor 0.5",
                "kata-set-param dynamicScoreUtilityFactor 0.5",
                "kata-set-param useLcbForSelection false",
                "kata-set-param useUncertainty false",
                "kata-set-param useNoisePruning false",
                "kata-set-param subtreeValueBiasFactor 0.0"]
    }
}
