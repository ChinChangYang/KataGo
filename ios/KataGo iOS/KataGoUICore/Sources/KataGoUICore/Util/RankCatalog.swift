//
//  RankCatalog.swift
//  KataGoUICore
//
//  The profile kinds split by TYPE, so no chooser ever shows them as one flat
//  list: Full Strength ("AI"), the dan ladder, the kyu ladder, Pro — plus the
//  pro years bucketed by decade for the menus that pick a pro year directly,
//  and the rank years. Derived from `HumanSLModel` at runtime, never
//  hardcoded, so a change to the ladder (or a new year) flows through with no
//  edit here.
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

    /// The full-strength engine, the ladder's first entry.
    public static let aiProfile: String = HumanSLModel.aiKind

    /// The professional kind, chosen as one entry; its year is picked apart.
    public static let proKind: String = HumanSLModel.proKind

    /// The title every chooser shows for `aiProfile`.
    public static let aiTitle = "Full Strength (AI)"

    /// 9d ... 1d, in ladder order.
    public static let dan: [String] = HumanSLModel.rankKinds.filter { $0.hasSuffix("d") }

    /// 1k ... 25k, in ladder order.
    public static let kyu: [String] = HumanSLModel.rankKinds.filter { $0.hasSuffix("k") }

    /// Every pro-era profile, oldest first.
    public static let pro: [ProEntry] = HumanSLModel.proYears.map {
        ProEntry(year: $0, profile: HumanSLModel.key(kind: HumanSLModel.proKind, year: $0))
    }

    /// The style years a rank may take, oldest first.
    public static let rankYears: [Int] = Array(HumanSLModel.rankYears)

    /// A year as a chooser shows it. `String(year)` on purpose: a year
    /// interpolated into a LocalizedStringKey renders "2,016".
    public static func yearLabel(_ year: Int) -> String { String(year) }

    /// The key a side gets when it picks `kind` from a chooser: it keeps its
    /// style year (clamped into the kind's range), or starts at 2016 when it
    /// was Full Strength. `current` may be legacy or garbage; it is read as
    /// its canonical key.
    public static func profile(choosing kind: String, from current: String) -> String {
        (HumanSLModel(profile: current) ?? HumanSLModel()).choosing(kind: kind)
    }

    /// The key a side gets when it picks `year` from a Year chooser: it keeps
    /// its kind, the year clamped into the kind's range. Full Strength has no
    /// year and stays as it is; `current` is read as its canonical key.
    public static func profile(choosingYear year: Int, from current: String) -> String {
        (HumanSLModel(profile: current) ?? HumanSLModel()).choosing(year: year)
    }

    /// Whether `kind` is the side's current kind — the checkmark a rank item
    /// wears whatever the side's year.
    public static func isCurrent(kind: String, current: String) -> Bool {
        HumanSLModel(profile: current)?.kind == kind
    }

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
}
