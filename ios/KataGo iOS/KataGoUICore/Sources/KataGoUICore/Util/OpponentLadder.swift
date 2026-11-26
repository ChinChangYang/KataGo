//
//  OpponentLadder.swift
//  KataGoUICore
//
//  The opponent strengths the iOS New Game sheet offers, as ONE line a slider
//  can travel: the weakest rank on the left, Full Strength on the right.
//
//  `RankCatalog` groups the same kinds by type for menus (Full Strength, Dan,
//  Kyu, Pro), strongest first. A slider wants the opposite: a single ordered
//  scale where dragging right always means "stronger". Pro is not on it — a
//  pro profile imitates an era, not a strength, and stays in the player
//  label's long-press menu.
//
//  Pure values, no SwiftUI: the sheet is a thin shell over this and
//  `TVNewGameForm`, and the unit target pins both.
//

public enum OpponentLadder {
    /// Every rung, weakest first: 25k ... 1k, 1d ... 9d, then Full Strength.
    public static let kinds: [String] =
        RankCatalog.kyu.reversed() + RankCatalog.dan.reversed() + [RankCatalog.aiProfile]

    /// The rung a first-time New Game starts on: a double-digit kyu, weak
    /// enough that a newcomer is not flattened by the first game and far
    /// enough from either end that the slider visibly has room both ways.
    public static let defaultKind = "15k"

    /// The rung of a stored kind, or of a full profile key ("5k 2019"). A
    /// kind that is not on the ladder — Pro, a legacy or garbage string —
    /// lands on `defaultKind`, never on an end.
    public static func index(of kindOrProfile: String) -> Int {
        let kind = HumanSLModel(profile: kindOrProfile)?.kind ?? kindOrProfile
        return kinds.firstIndex(of: kind)
            ?? kinds.firstIndex(of: defaultKind)
            ?? 0
    }

    /// The kind at a slider position, clamped onto the ladder.
    public static func kind(at index: Int) -> String {
        kinds[min(max(index, 0), kinds.count - 1)]
    }

    /// The rung as the sheet headlines it: "15 kyu", "3 dan", "Full Strength".
    /// Built as a plain `String` so a caller can show it with
    /// `Text(verbatim:)` and no number formatting.
    public static func title(forKind kind: String) -> String {
        if kind == RankCatalog.aiProfile { return "Full Strength" }
        if kind.hasSuffix("k") { return String(kind.dropLast()) + " kyu" }
        if kind.hasSuffix("d") { return String(kind.dropLast()) + " dan" }
        return kind
    }

    /// One line under the headline saying who this opponent is.
    public static func summary(forKind kind: String) -> String {
        guard kind != RankCatalog.aiProfile, let rank = Int(kind.dropLast()) else {
            return "Superhuman. KataGo with nothing held back."
        }
        if kind.hasSuffix("d") {
            return rank >= 5
                ? "Expert. Plays like a strong human dan player."
                : "Advanced. Plays like a human dan player."
        }
        switch rank {
        case 20...: return "Just starting out. Plays like a human novice."
        case 10...: return "Beginner. Plays like a human of this rank."
        default: return "Intermediate. Plays like a human of this rank."
        }
    }
}
