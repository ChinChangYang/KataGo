//
//  NewGameRuleset.swift
//  KataGoUICore
//
//  Named-ruleset presets + rule serialization for the "New Game" setup dialog
//  (macOS today; reusable by iOS/visionOS later). Kept in the shared package —
//  not the Mac app target — so it is unit-testable on the iOS Simulator (the
//  only test gate) alongside the C++ bridge it relies on.
//
//  The dialog lets the user pick a named ruleset (which fills the granular
//  controls) OR edit the granular controls directly (which switches the picker
//  to "Custom"). Both paths end up as an SGF `RU[]` string fed through the SAME
//  `SgfOperations` / `createGameRecord` path the app already uses, so there is
//  no new C++ and no second rule interpreter.
//

import Foundation

/// The six granular rule components the engine's SGF `RU[]` field encodes (komi
/// is separate, in `KM[]`). A plain value type so the dialog can hold, compare,
/// and serialize a rule set without a live engine. Mirrors the fields of the
/// bridge `Rules` struct minus komi/friendlyPassOk (the app exposes neither as a
/// per-game control).
public struct NewGameRuleComponents: Equatable {
    public var koRule: KoRule
    public var scoringRule: ScoringRule
    public var taxRule: TaxRule
    public var multiStoneSuicideLegal: Bool
    public var hasButton: Bool
    public var whiteHandicapBonusRule: WhiteHandicapBonusRule

    public init(koRule: KoRule,
                scoringRule: ScoringRule,
                taxRule: TaxRule,
                multiStoneSuicideLegal: Bool,
                hasButton: Bool,
                whiteHandicapBonusRule: WhiteHandicapBonusRule) {
        self.koRule = koRule
        self.scoringRule = scoringRule
        self.taxRule = taxRule
        self.multiStoneSuicideLegal = multiStoneSuicideLegal
        self.hasButton = hasButton
        self.whiteHandicapBonusRule = whiteHandicapBonusRule
    }
}

/// A named ruleset preset offered in the New Game dialog's Ruleset picker, plus
/// the terminal `.custom` sentinel for a hand-edited rule combination.
public enum NewGameRuleset: CaseIterable, Equatable, Sendable {
    case chinese, japanese, korean, aga, bga, newZealand, trompTaylor, custom

    /// Picker order: named presets first, Custom last.
    public static let pickerCases: [NewGameRuleset] =
        [.chinese, .japanese, .korean, .aga, .bga, .newZealand, .trompTaylor, .custom]

    public var displayName: String {
        switch self {
        case .chinese: return "Chinese"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .aga: return "AGA"
        case .bga: return "BGA"
        case .newZealand: return "New Zealand"
        case .trompTaylor: return "Tromp-Taylor"
        case .custom: return "Custom"
        }
    }

    /// The SGF `RU[]` token for a named preset — a spelling `Rules::parseRules`
    /// accepts (see `cpp/game/rules.cpp`). `nil` for `.custom`, which has no
    /// canonical name and is serialized from its granular components instead.
    public var sgfToken: String? {
        switch self {
        case .chinese: return "chinese"
        case .japanese: return "japanese"
        case .korean: return "korean"
        case .aga: return "aga"
        case .bga: return "bga"
        case .newZealand: return "new-zealand"
        case .trompTaylor: return "tromp-taylor"
        case .custom: return nil
        }
    }
}

/// Stateless helpers that expand/serialize/match new-game rules. Every mapping
/// goes through the engine's own SGF parser, so the presets never drift from
/// what the engine actually plays.
public enum NewGameRules {
    /// White-handicap-bonus labels ordered by `WhiteHandicapBonusRule.rawValue`
    /// (zero→"0", n→"N", n_minus_one→"N-1"), matching the C++ `Rules::WHB_*`
    /// constants. `Config.whiteHandicapBonusRules` now uses the same order, so
    /// this is a straight alias kept for source compatibility.
    public static let whiteHandicapBonusLabels = Config.whiteHandicapBonusRules

    /// Expands a named preset to its concrete rule components by parsing an
    /// `RU[<token>]` SGF through the same engine path the app loads games with —
    /// the single source of truth. Returns `nil` for `.custom` or on a parse
    /// failure.
    ///
    /// The probe MUST carry a `KM[]` tag: `Sgf::getRulesOrFail` throws without
    /// one (`getKomiOrFail`), and the bridge then swallows the throw and returns
    /// an all-default rule set — which would silently make every preset look like
    /// AREA/SIMPLE/NONE. `KM[7]` is arbitrary and ignored (komi comes from the
    /// dialog / `suggestedKomi`).
    public static func expand(_ preset: NewGameRuleset) -> NewGameRuleComponents? {
        guard let token = preset.sgfToken else { return nil }
        let rules = SgfOperations(sgf: "(;FF[4]GM[1]SZ[19]KM[7]RU[\(token)])").rules
        return NewGameRuleComponents(
            koRule: rules.koRule,
            scoringRule: rules.scoringRule,
            taxRule: rules.taxRule,
            multiStoneSuicideLegal: rules.multiStoneSuicideLegal,
            hasButton: rules.hasButton,
            whiteHandicapBonusRule: rules.whiteHandicapBonusRule)
    }

    /// The named preset whose expansion equals `components`, or `.custom` if none
    /// matches. `preferring` (the currently-selected preset) is checked first so
    /// engine-identical rulesets (Japanese/Korean, AGA/BGA) keep the user's
    /// chosen label instead of snapping to the first match.
    public static func match(_ components: NewGameRuleComponents,
                             preferring current: NewGameRuleset? = nil) -> NewGameRuleset {
        if let current, current != .custom, expand(current) == components {
            return current
        }
        for preset in NewGameRuleset.pickerCases where preset != .custom {
            if expand(preset) == components { return preset }
        }
        return .custom
    }

    /// KataGo's own default-komi rule (mirrors `parseRulesHelper`): territory →
    /// 6.5, button → 7.0, otherwise 7.5. Derived from the rule components so it is
    /// correct for both named presets and custom combinations without a
    /// per-preset table.
    public static func suggestedKomi(_ components: NewGameRuleComponents) -> Float {
        if components.scoringRule == .territory { return 6.5 }
        if components.hasButton { return 7.0 }
        return 7.5
    }

    /// The compact `RU[]` string for a set of components, in KataGo's
    /// `Rules::toStringNoKomi()` form — `whb` omitted when zero and `button`
    /// omitted when false, exactly as the engine serializes — so it round-trips
    /// back through `SgfOperations(...).rules` to the same components.
    public static func compactRuleString(_ components: NewGameRuleComponents) -> String {
        var s = "ko\(Config.koRules[components.koRule.rawValue])"
        s += "score\(Config.scoringRules[components.scoringRule.rawValue])"
        s += "tax\(Config.taxRules[components.taxRule.rawValue])"
        s += "sui\(components.multiStoneSuicideLegal ? 1 : 0)"
        if components.hasButton { s += "button1" }
        if components.whiteHandicapBonusRule != .zero {
            s += "whb\(whiteHandicapBonusToken(components.whiteHandicapBonusRule))"
        }
        return s
    }

    /// The SGF `RU[]` string to write for a chosen preset + components: the named
    /// token for a real preset (which also preserves engine-only fields such as
    /// `friendlyPassOk` that the compact form can't express), else the compact
    /// custom form.
    public static func ruleString(preset: NewGameRuleset,
                                  components: NewGameRuleComponents) -> String {
        preset.sgfToken ?? compactRuleString(components)
    }

    /// The correct compact-string token for a white-handicap-bonus rule (matching
    /// the C++ `Rules::writeWhiteHandicapBonusRule`).
    private static func whiteHandicapBonusToken(_ whb: WhiteHandicapBonusRule) -> String {
        switch whb {
        case .zero: return "0"
        case .n: return "N"
        case .n_minus_one: return "N-1"
        }
    }
}
