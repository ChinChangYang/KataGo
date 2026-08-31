//
//  RankCatalog.swift
//  KataGoUICore
//
//  The 259-entry profile ladder split by TYPE, so no chooser ever shows it as
//  one flat list: Full Strength ("AI"), the dan ladder, the kyu ladder, and
//  the pro years bucketed by decade. Derived from `HumanSLModel.allProfiles`
//  at runtime, never hardcoded, so a change to the ladder (or a new pro year)
//  flows through with no edit here.
//
//  Extracted from the tvOS New Game chooser, which keeps its own three-way
//  presentation on top of this, so the iOS long-press menu and the Mac rank
//  menu group the same way and one unit test covers all three.
//

public enum RankCatalog {
    /// One pro-era profile with the year it stands for.
    public struct ProEntry: Identifiable, Sendable, Equatable {
        public let year: Int
        public let profile: String

        public var id: Int { year }
        /// `String(year)` on purpose: `Text("\(year)")` would take the
        /// LocalizedStringKey path and render "1,997".
        public var label: String { String(year) }
    }

    public static let all: [String] = HumanSLModel.allProfiles

    /// The full-strength engine, the ladder's first entry.
    public static let aiProfile: String = all.first { $0 == "AI" } ?? all.first ?? "AI"

    /// The title every chooser shows for `aiProfile`.
    public static let aiTitle = "Full Strength (AI)"

    /// 9d ... 1d, in ladder order.
    public static let dan: [String] = all.filter { isRank($0, suffix: "d") }

    /// 1k ... 25k, in ladder order.
    public static let kyu: [String] = all.filter { isRank($0, suffix: "k") }

    /// Every pro-era profile, oldest first.
    public static let pro: [ProEntry] = all.compactMap { profile in
        guard profile.hasPrefix("Pro "),
              let year = Int(profile.dropFirst(4)) else { return nil }
        return ProEntry(year: year, profile: profile)
    }
    .sorted { $0.year < $1.year }

    /// The decades the pro years span (1800, 1810, ...), ascending.
    public static let decades: [Int] = {
        var seen = Set<Int>()
        var ordered: [Int] = []
        for entry in pro where seen.insert(decade(of: entry.year)).inserted {
            ordered.append(decade(of: entry.year))
        }
        return ordered.sorted()
    }()

    public static func entries(inDecade start: Int) -> [ProEntry] {
        pro.filter { decade(of: $0.year) == start }
    }

    /// The decade a pro profile belongs to, or nil for a non-pro profile.
    public static func decade(containing profile: String) -> Int? {
        pro.first { $0.profile == profile }.map { decade(of: $0.year) }
    }

    /// "1990s", as a plain String: never interpolate a year into a
    /// LocalizedStringKey, which number-formats it.
    public static func decadeLabel(_ start: Int) -> String { String(start) + "s" }

    /// The title a chooser shows for any profile: the ladder key itself,
    /// except the full-strength entry, which reads as what it is.
    public static func title(for profile: String) -> String {
        profile == aiProfile ? aiTitle : profile
    }

    public static func decade(of year: Int) -> Int { (year / 10) * 10 }

    private static func isRank(_ profile: String, suffix: Character) -> Bool {
        guard profile.last == suffix else { return false }
        return Int(profile.dropLast()) != nil
    }
}
