//
//  NewGameRulesetTests.swift
//  KataGo iOSTests
//
//  Verifies the New Game dialog's rule model against the engine's own SGF
//  parser: every named preset expands to the components in `cpp/game/rules.cpp`,
//  and both the named and the compact (Custom) `RU[]` strings round-trip back to
//  the same components through the same `SgfOperations` path `createGameRecord`
//  and `GobanState.loadGame` use.
//

import Testing
@testable import KataGoUICore

struct NewGameRulesetTests {

    // Expected granular rules per named preset, transcribed from
    // cpp/game/rules.cpp `parseRulesHelper`.
    private let expected: [(NewGameRuleset, NewGameRuleComponents)] = [
        (.chinese,     NewGameRuleComponents(koRule: .simple,      scoringRule: .area,      taxRule: .none, multiStoneSuicideLegal: false, hasButton: false, whiteHandicapBonusRule: .n)),
        (.japanese,    NewGameRuleComponents(koRule: .simple,      scoringRule: .territory, taxRule: .seki, multiStoneSuicideLegal: false, hasButton: false, whiteHandicapBonusRule: .zero)),
        (.korean,      NewGameRuleComponents(koRule: .simple,      scoringRule: .territory, taxRule: .seki, multiStoneSuicideLegal: false, hasButton: false, whiteHandicapBonusRule: .zero)),
        (.aga,         NewGameRuleComponents(koRule: .situational, scoringRule: .area,      taxRule: .none, multiStoneSuicideLegal: false, hasButton: false, whiteHandicapBonusRule: .n_minus_one)),
        (.bga,         NewGameRuleComponents(koRule: .situational, scoringRule: .area,      taxRule: .none, multiStoneSuicideLegal: false, hasButton: false, whiteHandicapBonusRule: .n_minus_one)),
        (.newZealand,  NewGameRuleComponents(koRule: .situational, scoringRule: .area,      taxRule: .none, multiStoneSuicideLegal: true,  hasButton: false, whiteHandicapBonusRule: .zero)),
        (.trompTaylor, NewGameRuleComponents(koRule: .positional,  scoringRule: .area,      taxRule: .none, multiStoneSuicideLegal: true,  hasButton: false, whiteHandicapBonusRule: .zero)),
        (.chineseOGS,       NewGameRuleComponents(koRule: .positional,  scoringRule: .area,      taxRule: .none, multiStoneSuicideLegal: false, hasButton: false, whiteHandicapBonusRule: .n)),
        (.agaButton,        NewGameRuleComponents(koRule: .situational, scoringRule: .area,      taxRule: .none, multiStoneSuicideLegal: false, hasButton: true,  whiteHandicapBonusRule: .n_minus_one)),
        (.stoneScoring,     NewGameRuleComponents(koRule: .simple,      scoringRule: .area,      taxRule: .all,  multiStoneSuicideLegal: false, hasButton: false, whiteHandicapBonusRule: .zero)),
        (.ancientTerritory, NewGameRuleComponents(koRule: .simple,      scoringRule: .territory, taxRule: .all,  multiStoneSuicideLegal: false, hasButton: false, whiteHandicapBonusRule: .zero)),
    ]

    // MARK: - Preset expansion matches the engine table

    @Test func expandMatchesEngineTable() {
        for (preset, want) in expected {
            #expect(NewGameRules.expand(preset) == want, "\(preset.displayName) expanded wrong")
        }
    }

    @Test func customHasNoExpansion() {
        #expect(NewGameRules.expand(.custom) == nil)
    }

    // MARK: - Named RU[] round-trips through the real SGF path

    @Test func namedRulesetSgfRoundTrips() {
        for (preset, want) in expected {
            let ruleString = NewGameRules.ruleString(preset: preset, components: want)
            let sgf = GameRecord.makeSgf(width: 19, height: 19, komi: 7.5, ruleString: ruleString)
            let parsed = SgfOperations(sgf: sgf).rules
            #expect(components(parsed) == want, "\(preset.displayName) did not round-trip")
            #expect(parsed.komi == 7.5, "\(preset.displayName) komi lost")
        }
    }

    // MARK: - Compact (Custom) RU[] round-trips — the tricky serializer paths

    /// `whb=N` must serialize to `whbN` and parse back to `.n` (NOT
    /// `.n_minus_one`) — the guard that serialization is keyed by rawValue,
    /// not by any display-array position.
    @Test func customWhbN_roundTrips() {
        let c = NewGameRuleComponents(koRule: .positional, scoringRule: .area, taxRule: .none,
                                      multiStoneSuicideLegal: false, hasButton: false,
                                      whiteHandicapBonusRule: .n)
        #expect(roundTripCompact(c) == c)
    }

    /// `whb=N-1` serializes to `whbN-1` and parses back to `.n_minus_one`.
    @Test func customWhbNMinusOne_roundTrips() {
        let c = NewGameRuleComponents(koRule: .situational, scoringRule: .area, taxRule: .none,
                                      multiStoneSuicideLegal: false, hasButton: false,
                                      whiteHandicapBonusRule: .n_minus_one)
        #expect(roundTripCompact(c) == c)
    }

    /// Button + suicide are carried; a zero whb is omitted and still reads `.zero`.
    @Test func customButtonAndSuicide_roundTrips() {
        let c = NewGameRuleComponents(koRule: .positional, scoringRule: .area, taxRule: .none,
                                      multiStoneSuicideLegal: true, hasButton: true,
                                      whiteHandicapBonusRule: .zero)
        #expect(roundTripCompact(c) == c)
    }

    @Test func customTaxSeki_roundTrips() {
        let c = NewGameRuleComponents(koRule: .simple, scoringRule: .territory, taxRule: .seki,
                                      multiStoneSuicideLegal: false, hasButton: false,
                                      whiteHandicapBonusRule: .zero)
        #expect(roundTripCompact(c) == c)
    }

    // MARK: - Reverse matching

    @Test func matchReturnsPresetForKnownRules() {
        #expect(NewGameRules.match(NewGameRules.expand(.chinese)!) == .chinese)
        #expect(NewGameRules.match(NewGameRules.expand(.trompTaylor)!) == .trompTaylor)
    }

    /// Japanese/Korean (and AGA/BGA) are engine-identical; `preferring` keeps the
    /// user's chosen label rather than snapping to the first match.
    @Test func matchPrefersCurrentForIdenticalRulesets() {
        let korean = NewGameRules.expand(.korean)!
        #expect(NewGameRules.match(korean) == .japanese)                      // first match wins by default
        #expect(NewGameRules.match(korean, preferring: .korean) == .korean)   // sticky preference
        let bga = NewGameRules.expand(.bga)!
        #expect(NewGameRules.match(bga, preferring: .bga) == .bga)
    }

    @Test func matchReturnsCustomForUnknownRules() {
        // Positional ko + territory scoring is no named preset.
        let odd = NewGameRuleComponents(koRule: .positional, scoringRule: .territory, taxRule: .none,
                                        multiStoneSuicideLegal: false, hasButton: false,
                                        whiteHandicapBonusRule: .zero)
        #expect(NewGameRules.match(odd) == .custom)
    }

    // MARK: - Suggested komi (KataGo's own default rule)

    @Test func suggestedKomiFollowsScoring() {
        #expect(NewGameRules.suggestedKomi(NewGameRules.expand(.japanese)!) == 6.5)   // territory
        #expect(NewGameRules.suggestedKomi(NewGameRules.expand(.chinese)!) == 7.5)    // area
        let button = NewGameRuleComponents(koRule: .situational, scoringRule: .area, taxRule: .none,
                                           multiStoneSuicideLegal: false, hasButton: true,
                                           whiteHandicapBonusRule: .n_minus_one)
        #expect(NewGameRules.suggestedKomi(button) == 7.0)                            // button
    }

    // MARK: - New presets (all engine-named rulesets)

    /// Every named preset matches itself (with `preferring:` breaking the
    /// engine-identical Japanese/Korean and AGA/BGA ties), so the editors can
    /// identify each of the eleven unambiguously.
    @Test func everyNamedPresetMatchesItself() {
        for preset in NewGameRuleset.pickerCases where preset != .custom {
            #expect(NewGameRules.match(NewGameRules.expand(preset)!, preferring: preset) == preset,
                    "\(preset.displayName) did not match itself")
        }
        // chinese-ogs differs from chinese only in ko — keep them distinct.
        #expect(NewGameRules.expand(.chineseOGS) != NewGameRules.expand(.chinese))
    }

    /// `suggestedKomi` agrees with rules.cpp for the new presets: aga-button
    /// 7.0 (button), ancient-territory 6.5 (territory), the rest 7.5 (area).
    @Test func suggestedKomiForNewPresets() {
        #expect(NewGameRules.suggestedKomi(NewGameRules.expand(.agaButton)!) == 7.0)
        #expect(NewGameRules.suggestedKomi(NewGameRules.expand(.ancientTerritory)!) == 6.5)
        #expect(NewGameRules.suggestedKomi(NewGameRules.expand(.chineseOGS)!) == 7.5)
        #expect(NewGameRules.suggestedKomi(NewGameRules.expand(.stoneScoring)!) == 7.5)
    }

    // MARK: - makeSgf board size + komi formatting

    @Test func makeSgfSquareBoard() {
        let sgf = GameRecord.makeSgf(width: 13, height: 13, komi: 7, ruleString: "chinese")
        let ops = SgfOperations(sgf: sgf)
        #expect(ops.xSize == 13)
        #expect(ops.ySize == 13)
        #expect(sgf.contains("SZ[13]"))
    }

    @Test func makeSgfRectangularBoard() {
        let sgf = GameRecord.makeSgf(width: 19, height: 13, komi: 7, ruleString: "chinese")
        let ops = SgfOperations(sgf: sgf)
        #expect(ops.xSize == 19)
        #expect(ops.ySize == 13)
        #expect(sgf.contains("SZ[19:13]"))
    }

    @Test func makeSgfKomiFormatting() {
        #expect(GameRecord.makeSgf(width: 19, height: 19, komi: 7, ruleString: "chinese").contains("KM[7]"))
        #expect(GameRecord.makeSgf(width: 19, height: 19, komi: 6.5, ruleString: "japanese").contains("KM[6.5]"))
        #expect(GameRecord.makeSgf(width: 19, height: 19, komi: 0, ruleString: "chinese").contains("KM[0]"))
    }

    // MARK: - Config WHB text alignment

    /// `Config.whiteHandicapBonusRules` must be ordered by
    /// `WhiteHandicapBonusRule.rawValue` (0 -> "0", n -> "N",
    /// n_minus_one -> "N-1", matching the C++ `Rules::WHB_*` constants), so
    /// the GTP text sent for a bridge-parsed rule is the rule itself.
    @Test func whbConfigTextMatchesEnumRawValues() {
        #expect(Config.whiteHandicapBonusRules == ["0", "N", "N-1"])
        #expect(NewGameRules.whiteHandicapBonusLabels == Config.whiteHandicapBonusRules)
        let config = Config()
        config.whiteHandicapBonusRule = .n
        #expect(config.whiteHandicapBonusRuleText == "N")
        config.whiteHandicapBonusRule = .n_minus_one
        #expect(config.whiteHandicapBonusRuleText == "N-1")
        config.whiteHandicapBonusRule = .zero
        #expect(config.whiteHandicapBonusRuleText == "0")
    }

    // MARK: - applyRuleset (preset -> config + GTP)

    /// Applying Japanese writes all six knobs + komi 6.5 into the config,
    /// stores the preset label, and sends exactly the reload-replay command
    /// sequence (six kata-set-rule + komi — never kata-set-rules).
    @Test @MainActor func applyRulesetJapanese() {
        let config = Config()
        let messageList = MessageList()
        ConfigEngineSync.applyRuleset(.japanese, config: config, messageList: messageList)
        #expect(config.koRule == .simple)
        #expect(config.scoringRule == .territory)
        #expect(config.taxRule == .seki)
        #expect(config.multiStoneSuicideLegal == false)
        #expect(config.hasButton == false)
        #expect(config.whiteHandicapBonusRule == .zero)
        #expect(config.komi == 6.5)
        #expect(config.rule == NewGameRuleset.japanese.configRuleIndex)
        #expect(messageList.messages.map(\.text) == [
            "> kata-set-rule ko SIMPLE",
            "> kata-set-rule scoring TERRITORY",
            "> kata-set-rule tax SEKI",
            "> kata-set-rule suicide false",
            "> kata-set-rule hasButton false",
            "> kata-set-rule whiteHandicapBonus 0",
            "> komi 6.5"])
    }

    /// Chinese carries whb=N — the command must say "N" (this is what the
    /// Task-1 array fix guarantees) — and area komi 7.5.
    @Test @MainActor func applyRulesetChineseSendsWhbN() {
        let config = Config()
        let messageList = MessageList()
        ConfigEngineSync.applyRuleset(.chinese, config: config, messageList: messageList)
        #expect(config.whiteHandicapBonusRule == .n)
        #expect(config.komi == 7.5)
        #expect(config.rule == 0)
        #expect(messageList.messages.map(\.text).contains("> kata-set-rule whiteHandicapBonus N"))
    }

    /// Custom has no expansion: nothing is written, nothing is sent.
    @Test @MainActor func applyRulesetCustomIsNoOp() {
        let config = Config()
        let before = config.rule
        let messageList = MessageList()
        ConfigEngineSync.applyRuleset(.custom, config: config, messageList: messageList)
        #expect(messageList.messages.isEmpty)
        #expect(config.rule == before)
    }

    // MARK: - Config.rule label persistence

    /// The first six Config.rules entries are index-stable: synced records
    /// persist the index, so this array is append-only.
    @Test func configRulesKeepsHistoricalPrefix() {
        #expect(Array(Config.rules.prefix(6)) ==
                ["chinese", "japanese", "korean", "aga", "bga", "new-zealand"])
    }

    /// Every named preset round-trips preset -> Config.rule index -> preset;
    /// Custom maps to the -1 sentinel, which reads back as nil.
    @Test func presetConfigRuleIndexRoundTrips() {
        for preset in NewGameRuleset.pickerCases where preset != .custom {
            let index = preset.configRuleIndex
            #expect(Config.rules.indices.contains(index), "\(preset.displayName) has no Config.rules entry")
            #expect(NewGameRuleset.preset(fromConfigRule: index) == preset,
                    "\(preset.displayName) did not round-trip")
        }
        #expect(NewGameRuleset.custom.configRuleIndex == Config.customRule)
        #expect(NewGameRuleset.preset(fromConfigRule: Config.customRule) == nil)
        #expect(NewGameRuleset.preset(fromConfigRule: Config.rules.count) == nil)
    }

    // MARK: - Helpers

    private func components(_ r: Rules) -> NewGameRuleComponents {
        NewGameRuleComponents(koRule: r.koRule, scoringRule: r.scoringRule, taxRule: r.taxRule,
                              multiStoneSuicideLegal: r.multiStoneSuicideLegal, hasButton: r.hasButton,
                              whiteHandicapBonusRule: r.whiteHandicapBonusRule)
    }

    /// Serializes components to a compact `RU[]`, feeds it through `makeSgf` +
    /// the real SGF parser, and returns the parsed components.
    private func roundTripCompact(_ c: NewGameRuleComponents) -> NewGameRuleComponents {
        let ruleString = NewGameRules.compactRuleString(c)
        let sgf = GameRecord.makeSgf(width: 19, height: 19, komi: 7, ruleString: ruleString)
        return components(SgfOperations(sgf: sgf).rules)
    }
}
