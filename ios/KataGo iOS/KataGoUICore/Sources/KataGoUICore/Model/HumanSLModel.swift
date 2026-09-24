//
//  HumanSLModel.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/5/8.
//

import Foundation

/// Maps a human-SL **profile key** to the engine `humanSLProfile` value and the
/// `kata-set-param` command list.
///
/// A key is a *profile kind* plus, unless the kind is `AI`, a *style year*, and it
/// always spells the year out: `"AI"`, `"5k 2019"`, `"Pro 1997"` (ADR 0019). The key
/// is what `Config` stores per side (the SwiftData schema is frozen, so the year
/// lives in the existing profile string), and what the player label shows.
///
/// Ranks map to `humanSLProfile = rankyear_<year>_<rank>` — the fork-local KGS rank
/// profile dated `<year>-09-01`, so 2016 is exactly the old `preaz_<rank>`. Rank
/// years run 2016…2023, the KGS years the human-SL net has training data for. Pros
/// map to `proyear_<year>` (1800…2023). `AI` is the strongest-net, no-human-bias
/// profile; a year there would be inert, so it has none.
///
/// Rank params come from the KataGo PR #1209 even-game ELO ladder
/// (`docs/HumanSL_Rank_Ladder.md` on the `gtp-human-rank-configs` branch): the
/// 8d→25k rungs share constant human params and differ only in the certified
/// per-rank `humanSLChosenMovePiklLambda` (7d…14k a ~100-ELO staircase; 15k…25k the
/// pure-human tail at 1e8); `9d` is the ladder docs' separate legacy-strong
/// reference (λ 0.045, try-to-win, 400 visits via `GtpCommandBuilder`); pros reuse
/// the 8d-anchor λ 0.06 in imitation mode. The ladder was certified on
/// kata1-b28c512nbt @ 8 search threads, 40 visits, Japanese komi 6.5, at `preaz`
/// (2016) — under the app's nets/threads the rungs are a calibrated relative
/// ladder, not exact absolute strengths, and at any other style year a rank keeps
/// its 2016 λ: the same rung imitating a different era, not a re-measured strength.
public struct HumanSLModel {

    // MARK: - Kinds and years

    /// The full-strength kind: no human bias, and no style year.
    public static let aiKind = "AI"

    /// The professional kind; its key is "Pro <year>".
    public static let proKind = "Pro"

    /// 9d…1d, then 1k…25k.
    public static let rankKinds: [String] =
        (1...9).reversed().map { "\($0)d" } + (1...25).map { "\($0)k" }

    /// Every kind, in chooser order: AI, ranks (9d→25k), Pro.
    public static let profileKinds: [String] = [aiKind] + rankKinds + [proKind]

    /// The KGS years the human-SL net learned amateur play from.
    public static let rankYears: ClosedRange<Int> = 2016...2023

    /// The pro years `proyear_` accepts.
    public static let proYears: ClosedRange<Int> = 1800...2023

    /// The style year a side starts at when it leaves `AI`, and the year every
    /// key written before the style year existed played at (`preaz`, 2016-09-01),
    /// which is also where the #1209 ladder was calibrated.
    public static let defaultStyleYear = 2016

    /// The years a kind may take, or nil for `AI` and unknown kinds.
    public static func yearRange(forKind kind: String) -> ClosedRange<Int>? {
        if kind == proKind { return proYears }
        if rankKinds.contains(kind) { return rankYears }
        return nil
    }

    /// The key for a kind at a year: "5k 2019", "Pro 1997", or "AI" (which has
    /// no year). The year is taken as given; callers clamp.
    public static func key(kind: String, year: Int) -> String {
        kind == aiKind ? aiKind : "\(kind) \(year)"
    }

    /// Every valid key, in menu order: AI, each rank at every rank year, then
    /// Pro at every pro year (oldest first).
    public static let allProfiles: [String] =
        [aiKind]
        + rankKinds.flatMap { kind in rankYears.map { key(kind: kind, year: $0) } }
        + proYears.map { key(kind: proKind, year: $0) }

    // MARK: - Parsing (input-validation, not schema migration)

    /// Read a possibly-legacy stored string as (kind, year): a current key
    /// passes through; a bare rank (a menu key from before the style year),
    /// `preaz_<r>` and `rank_<r>` all read as `<r>` at 2016, the year they
    /// played at; `proyear_<y>` reads as Pro at `<y>`. Anything else — an
    /// unknown kind, a year outside the kind's range, a stray space — is nil.
    private static func parse(_ raw: String) -> (kind: String, year: Int?)? {
        if raw == aiKind { return (aiKind, nil) }
        if raw.hasPrefix("rank_")    { return parse(String(raw.dropFirst(5))) }
        if raw.hasPrefix("preaz_")   { return parse(String(raw.dropFirst(6))) }
        if raw.hasPrefix("proyear_") { return parse("\(proKind) " + String(raw.dropFirst(8))) }
        if rankKinds.contains(raw) { return (raw, defaultStyleYear) }

        let parts = raw.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let year = Int(parts[1]), String(year) == parts[1] else { return nil }
        let kind = String(parts[0])
        guard let range = yearRange(forKind: kind), range.contains(year) else { return nil }
        return (kind, year)
    }

    /// The canonical key for a possibly-legacy stored value, falling back to
    /// `"AI"` if unrecognized. Used by the choosers and the player label so
    /// legacy/garbage values still resolve to a valid selection.
    public static func canonicalProfile(_ raw: String) -> String {
        HumanSLModel(profile: raw)?.profile ?? aiKind
    }

    // MARK: - Instance

    public private(set) var kind: String
    /// The style year; nil exactly when `kind` is `AI`.
    public private(set) var year: Int?

    /// The canonical key.
    public var profile: String {
        year.map { HumanSLModel.key(kind: kind, year: $0) } ?? kind
    }

    public init() {
        kind = HumanSLModel.aiKind
        year = nil
    }

    public init?(profile: String) {
        guard let parsed = HumanSLModel.parse(profile) else { return nil }
        kind = parsed.kind
        year = parsed.year
    }

    /// The key after the side picks `newKind`: the style year carries over,
    /// moved into the new kind's range; a side leaving `AI` starts at 2016.
    /// An unknown kind leaves the key unchanged.
    public func choosing(kind newKind: String) -> String {
        if newKind == HumanSLModel.aiKind { return newKind }
        guard let range = HumanSLModel.yearRange(forKind: newKind) else { return profile }
        let carried = year ?? HumanSLModel.defaultStyleYear
        return HumanSLModel.key(kind: newKind, year: min(max(carried, range.lowerBound), range.upperBound))
    }

    /// The key after the side picks `newYear`, clamped into its kind's range.
    /// `AI` has no year, so it is returned unchanged.
    public func choosing(year newYear: Int) -> String {
        guard let range = HumanSLModel.yearRange(forKind: kind) else { return profile }
        return HumanSLModel.key(kind: kind, year: min(max(newYear, range.lowerBound), range.upperBound))
    }

    private var isAI: Bool { kind == HumanSLModel.aiKind }
    private var isPro: Bool { kind == HumanSLModel.proKind }

    // MARK: - Engine parameters

    /// Value sent via `kata-set-param humanSLProfile`.
    public var humanSLProfile: String {
        guard let year else { return "rank_9d" }                    // AI
        if isPro { return "proyear_\(year)" }                        // "Pro 2023" → proyear_2023
        return "rankyear_\(year)_\(kind)"                             // "9d 2016" → rankyear_2016_9d
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
        HumanSLModel.rankPiklLambda[kind] ?? "0.06"
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
                "kata-set-param winLossUtilityFactor \(kind == "9d" ? "1.0" : "0.0")",
                "kata-set-param staticScoreUtilityFactor 0.5",
                "kata-set-param dynamicScoreUtilityFactor 0.5",
                "kata-set-param useLcbForSelection false",
                "kata-set-param useUncertainty false",
                "kata-set-param useNoisePruning false",
                "kata-set-param subtreeValueBiasFactor 0.0"]
    }
}
