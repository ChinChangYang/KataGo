//
//  GoRules.swift
//  GoRulesKit
//
//  The full rule space the app exposes (GameRules.swift enums + komi +
//  button), mirroring KataGo's Rules. Normalization matches cpp/game/rules
//  where the app can reach it: the button exists only under area scoring.
//

import Foundation
import KataGoGameStore

public struct GoRules: Sendable, Equatable {
    public var koRule: KoRule
    public var scoringRule: ScoringRule
    public var taxRule: TaxRule
    public var multiStoneSuicideLegal: Bool
    public var hasButton: Bool
    public var whiteHandicapBonusRule: WhiteHandicapBonusRule
    /// White's komi. Stored in half-point precision.
    public var komi: Double

    public init(
        koRule: KoRule = .positional,
        scoringRule: ScoringRule = .area,
        taxRule: TaxRule = .none,
        multiStoneSuicideLegal: Bool = false,
        hasButton: Bool = false,
        whiteHandicapBonusRule: WhiteHandicapBonusRule = .zero,
        komi: Double = 7.0
    ) {
        self.koRule = koRule
        self.scoringRule = scoringRule
        self.taxRule = taxRule
        self.multiStoneSuicideLegal = multiStoneSuicideLegal
        // Button Go exists only under area scoring (Rules normalization).
        self.hasButton = hasButton && scoringRule == .area
        self.whiteHandicapBonusRule = whiteHandicapBonusRule
        self.komi = komi
    }

    /// Named presets matching KataGo's canonical rulesets, for the setup card.
    public static let chinese = GoRules(
        koRule: .simple, scoringRule: .area, taxRule: .none,
        multiStoneSuicideLegal: false, hasButton: false,
        whiteHandicapBonusRule: .n, komi: 7.5)
    public static let japanese = GoRules(
        koRule: .simple, scoringRule: .territory, taxRule: .seki,
        multiStoneSuicideLegal: false, hasButton: false,
        whiteHandicapBonusRule: .zero, komi: 6.5)
    public static let korean = GoRules(
        koRule: .simple, scoringRule: .territory, taxRule: .seki,
        multiStoneSuicideLegal: false, hasButton: false,
        whiteHandicapBonusRule: .zero, komi: 6.5)
    public static let aga = GoRules(
        koRule: .situational, scoringRule: .area, taxRule: .none,
        multiStoneSuicideLegal: false, hasButton: false,
        whiteHandicapBonusRule: .n_minus_one, komi: 7.5)
    public static let trompTaylor = GoRules(
        koRule: .positional, scoringRule: .area, taxRule: .none,
        multiStoneSuicideLegal: true, hasButton: false,
        whiteHandicapBonusRule: .zero, komi: 7.5)
    public static let newZealand = GoRules(
        koRule: .situational, scoringRule: .area, taxRule: .none,
        multiStoneSuicideLegal: true, hasButton: false,
        whiteHandicapBonusRule: .zero, komi: 7.5)
    public static let stoneScoring = GoRules(
        koRule: .simple, scoringRule: .area, taxRule: .all,
        multiStoneSuicideLegal: false, hasButton: false,
        whiteHandicapBonusRule: .zero, komi: 7.5)

    /// The rules a new game receives when the user has not chosen any: the
    /// app default for even games, Chinese for handicap games — its whb-N
    /// compensation offsets the free stones, which Tromp-Taylor's whb 0
    /// does not (ADR 0002). An explicit user choice always wins.
    public static func defaultForNewGame(handicap: Int) -> GoRules {
        handicap >= 2 ? .chinese : .trompTaylor
    }

    /// KataGo's compact rules string (Rules::toStringNoKomi) for the SGF
    /// RU[] property, so the engine's Rules::parseRules reads the hand-off
    /// SGF exactly: "ko<KO>score<SCORING>tax<TAX>sui<0|1>[button1][whb…]".
    public var kataRulesString: String {
        let ko: String
        switch koRule {
        case .simple: ko = "SIMPLE"
        case .positional: ko = "POSITIONAL"
        case .situational: ko = "SITUATIONAL"
        }
        let scoring = scoringRule == .area ? "AREA" : "TERRITORY"
        let tax: String
        switch taxRule {
        case .none: tax = "NONE"
        case .seki: tax = "SEKI"
        case .all: tax = "ALL"
        }
        var result = "ko\(ko)score\(scoring)tax\(tax)sui\(multiStoneSuicideLegal ? 1 : 0)"
        if hasButton {
            result += "button1"
        }
        switch whiteHandicapBonusRule {
        case .zero: break
        case .n: result += "whbN"
        case .n_minus_one: result += "whbN-1"
        }
        return result
    }
}
