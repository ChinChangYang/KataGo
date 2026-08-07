# Ruleset Presets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a named-Ruleset preset picker (Chinese, Japanese, Tromp-Taylor, OGS/KGS, AGA, Stone Scoring, … — 11 presets + Custom) to the iOS per-game rules sheet and the macOS per-game Config editor, so users never need KataGo's knob-mapping table.

**Architecture:** Reuse the existing `NewGameRuleset`/`NewGameRules` machinery in `KataGoUICore` (mapping source of truth: the engine's own SGF parser via `NewGameRules.expand`). A new `ConfigEngineSync.applyRuleset` applies a preset through the six existing per-knob setters + komi (never `kata-set-rules`, preserving the app's forced `friendlyPassOk false`). The chosen label persists in the existing `Config.rule` Int via an append-only extension of `Config.rules` with a `-1` Custom sentinel.

**Tech Stack:** Swift / SwiftUI (iOS), AppKit (macOS), Swift Testing (`KataGo AnytimeTests` target), SwiftData `Config` model (no schema change).

**Spec:** `docs/superpowers/specs/2026-08-07-ruleset-presets-design.md`

**Discovered prerequisite (Task 1):** planning uncovered a live bug the feature sits on. `Config.whiteHandicapBonusRules` is `["0", "N-1", "N"]` while `WhiteHandicapBonusRule` raw values (and the C++ `Rules::WHB_*` constants, and the bridge parser) mean 0 / N / N-1. `GobanState.switchGame` (GobanState.swift:1122) assigns the bridge enum directly into the config and then replays `config.whiteHandicapBonusRuleText` — so a game loaded from `RU[chinese]` (whb=N) sends `kata-set-rule whiteHandicapBonus N-1`, and the value oscillates N↔N-1 across save/load cycles. The same wrong text would be sent by `applyRuleset`. Task 1 reorders the array to `["0", "N", "N-1"]` so array index == enum rawValue == C++ constant everywhere. Old records persisted through the old iOS picker flip label meaning; that is accepted under the standing "tester data disposable / no migrations" agreement.

**Declared spec deltas** (recorded in the spec's Implementation notes by Task 8 Step 5):
1. The Task 1 WHB order fix (above).
2. The Task 7 TV label derivation change (display only; TV rule *editing* stays out of scope).
3. A refinement of spec Decision 4 ("picking a preset auto-sets komi"): when the picked preset's expansion **already equals** the current components, only the label (`config.rule`) is persisted — no GTP, no komi reset. This is load-bearing on iOS (the picker's programmatic snap after a hand-edit is indistinguishable from a user pick) and it resolves the spec's own tension with "the user can hand-edit komi afterwards". On macOS, AppKit reports an explicit re-pick of the already-selected item (SwiftUI cannot), so a same-label re-pick *does* re-apply fully and restores the preset's default komi; relabeling to an engine-identical preset (Japanese → Korean) stays label-only on both platforms.

## Global Constraints

- **English-only** in every committed file — no CJK anywhere in the diff.
- **Never modify SwiftData `@Model` schemas** (CloudKit-frozen). This plan only touches static arrays, computed accessors, and the already-existing `rule: Int` stored property.
- Tester data is disposable (TestFlight only): no migration code for the Task 1 meaning-flip or the `Config.rules` extension.
- `Config.rules` may only be **appended to** — the first six entries `["chinese", "japanese", "korean", "aga", "bga", "new-zealand"]` keep their indices (synced records store the index).
- **Never run two xcodebuild invocations concurrently** (DerivedData lock ⇒ spurious TEST FAILED). Do not delegate builds to parallel subagents.
- Piped xcodebuild exit codes lie — always grep for `BUILD SUCCEEDED` / `TEST SUCCEEDED` (or `FAILED`) in the output.
- Working directory for all build/test commands: `ios/KataGo iOS` (note the space).
- The unit-test **target** is named `KataGo AnytimeTests` (folder: `KataGo iOSTests`). Tests run on iOS Simulator only.
- Add **no new files** to the Xcode project (avoids pbxproj surgery): new tests go into existing test files; new shared code goes into existing `KataGoUICore` files (SwiftPM globs the package sources).
- Commit after each task; end every commit message with:

  ```
  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
  ```
- Commit only — do **not** push (ios-dev pushes are spaced ≥ ~1 day; every push distributes via Xcode Cloud).

---

### Task 1: Fix the white-handicap-bonus text order

The prerequisite correctness fix. After this task, `Config.whiteHandicapBonusRules[rawValue]` yields the token the engine and the bridge mean, the Mac Config editor's WHB popup stops mislabeling, and SGF-loaded games replay the correct `whiteHandicapBonus`.

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/ConfigModel.swift:702`
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/NewGameRuleset.swift:90-97`
- Test: `ios/KataGo iOS/KataGo iOSTests/NewGameRulesetTests.swift`

**Interfaces:**
- Consumes: `Config.whiteHandicapBonusRules`, `Config().whiteHandicapBonusRuleText`, `NewGameRules.whiteHandicapBonusLabels` (all existing).
- Produces: `Config.whiteHandicapBonusRules == ["0", "N", "N-1"]` and `NewGameRules.whiteHandicapBonusLabels` aliasing it. Later tasks rely on `config.whiteHandicapBonusRuleText` being rawValue-correct.

- [ ] **Step 1: Write the failing test**

Append inside `struct NewGameRulesetTests` in `ios/KataGo iOS/KataGo iOSTests/NewGameRulesetTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd "ios/KataGo iOS" && xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/NewGameRulesetTests" 2>&1 | grep -E "Test Suite|Test Case|TEST|error:|failed" | tail -20
```

Expected: `whbConfigTextMatchesEnumRawValues` FAILS (array is `["0", "N-1", "N"]`); `TEST FAILED`.

- [ ] **Step 3: Reorder the array**

In `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/ConfigModel.swift` line 702, replace:

```swift
    public static let whiteHandicapBonusRules = ["0", "N-1", "N"]
```

with:

```swift
    /// Ordered by `WhiteHandicapBonusRule.rawValue` (matching the C++
    /// `Rules::WHB_*` constants), so `whiteHandicapBonusRuleText` names the
    /// rule the bridge parsed. Historically this was `["0", "N-1", "N"]`,
    /// which made SGF-loaded games replay the wrong whb token.
    public static let whiteHandicapBonusRules = ["0", "N", "N-1"]
```

- [ ] **Step 4: Alias the New Game labels to the fixed array**

In `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/NewGameRuleset.swift`, replace lines 90-97 (the `whiteHandicapBonusLabels` doc comment + declaration):

```swift
    /// White-handicap-bonus labels ordered by `WhiteHandicapBonusRule.rawValue`
    /// (zero→"0", n→"N", n_minus_one→"N-1"). NOTE: this is DELIBERATELY not the
    /// existing `Config.whiteHandicapBonusRules` (`["0","N-1","N"]`), which is
    /// historically mis-ordered relative to the enum raw values; using it for a
    /// popup would mislabel the rule. The raw values here match the C++
    /// `Rules::WHB_*` constants, so display, selection, and serialization stay
    /// self-consistent and round-trip correctly.
    public static let whiteHandicapBonusLabels = ["0", "N", "N-1"]
```

with:

```swift
    /// White-handicap-bonus labels ordered by `WhiteHandicapBonusRule.rawValue`
    /// (zero→"0", n→"N", n_minus_one→"N-1"), matching the C++ `Rules::WHB_*`
    /// constants. `Config.whiteHandicapBonusRules` now uses the same order, so
    /// this is a straight alias kept for source compatibility.
    public static let whiteHandicapBonusLabels = Config.whiteHandicapBonusRules
```

Also update the stale guard-comment in `ios/KataGo iOS/KataGo iOSTests/NewGameRulesetTests.swift` lines 55-57. Replace:

```swift
    /// `whb=N` must serialize to `whbN` and parse back to `.n` (NOT `.n_minus_one`).
    /// This is the guard against the historically mis-ordered
    /// `Config.whiteHandicapBonusRules` array.
```

with:

```swift
    /// `whb=N` must serialize to `whbN` and parse back to `.n` (NOT
    /// `.n_minus_one`) — the guard that serialization is keyed by rawValue,
    /// not by any display-array position.
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd "ios/KataGo iOS" && xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/NewGameRulesetTests" -only-testing:"KataGo AnytimeTests/GtpCommandBuilderTests" 2>&1 | grep -E "Test Suite|TEST|error:|failed" | tail -20
```

Expected: `TEST SUCCEEDED` (GtpCommandBuilderTests asserts whb text `"0"` for defaults — index 0 is unchanged by the reorder).

- [ ] **Step 6: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/ConfigModel.swift" "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/NewGameRuleset.swift" "ios/KataGo iOS/KataGo iOSTests/NewGameRulesetTests.swift"
git commit -m "fix(rules): order whiteHandicapBonusRules by enum rawValue

The array was [0, N-1, N] while the enum raw values (and the C++ WHB_*
constants the bridge parser returns) mean 0/N/N-1. GobanState.switchGame
assigns the bridge enum into the config and replays the array text, so an
SGF-loaded RU[chinese] game (whb=N) sent whiteHandicapBonus N-1 and the
value oscillated N<->N-1 across save/load cycles. The Mac Config editor
popup mislabeled the same way. Tester data is disposable, so the label
meaning-flip for old picker-persisted records ships without migration.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF"
```

---

### Task 2: Extend NewGameRuleset with the four missing engine rulesets

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/NewGameRuleset.swift:49-84`
- Test: `ios/KataGo iOS/KataGo iOSTests/NewGameRulesetTests.swift`

**Interfaces:**
- Consumes: `NewGameRules.expand` (unchanged — parses `RU[<token>]` through the engine).
- Produces: cases `.chineseOGS`, `.agaButton`, `.stoneScoring`, `.ancientTerritory` on `NewGameRuleset`; `pickerCases` order `[.chinese, .chineseOGS, .japanese, .korean, .aga, .bga, .agaButton, .newZealand, .trompTaylor, .stoneScoring, .ancientTerritory, .custom]`; display names `"Chinese (OGS/KGS)"`, `"AGA Button"`, `"Stone Scoring"`, `"Ancient Territory"`; SGF tokens `"chinese-ogs"`, `"aga-button"`, `"stone-scoring"`, `"ancient-territory"`. The macOS New Game dialog picks these up automatically via `pickerCases`.

- [ ] **Step 1: Write the failing tests**

In `ios/KataGo iOS/KataGo iOSTests/NewGameRulesetTests.swift`, extend the `expected` table (after the `.trompTaylor` line, values transcribed from `cpp/game/rules.cpp` `parseRulesHelper`):

```swift
        (.chineseOGS,       NewGameRuleComponents(koRule: .positional,  scoringRule: .area,      taxRule: .none, multiStoneSuicideLegal: false, hasButton: false, whiteHandicapBonusRule: .n)),
        (.agaButton,        NewGameRuleComponents(koRule: .situational, scoringRule: .area,      taxRule: .none, multiStoneSuicideLegal: false, hasButton: true,  whiteHandicapBonusRule: .n_minus_one)),
        (.stoneScoring,     NewGameRuleComponents(koRule: .simple,      scoringRule: .area,      taxRule: .all,  multiStoneSuicideLegal: false, hasButton: false, whiteHandicapBonusRule: .zero)),
        (.ancientTerritory, NewGameRuleComponents(koRule: .simple,      scoringRule: .territory, taxRule: .all,  multiStoneSuicideLegal: false, hasButton: false, whiteHandicapBonusRule: .zero)),
```

And append these tests inside the struct:

```swift
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
```

- [ ] **Step 2: Run to verify they fail to compile**

```bash
cd "ios/KataGo iOS" && xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/NewGameRulesetTests" 2>&1 | grep -E "error:|TEST" | tail -10
```

Expected: compile errors — `type 'NewGameRuleset' has no member 'chineseOGS'` (etc.).

- [ ] **Step 3: Add the enum cases**

In `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/NewGameRuleset.swift`, replace the enum body pieces:

Line 50:

```swift
    case chinese, japanese, korean, aga, bga, newZealand, trompTaylor, custom
```

becomes:

```swift
    case chinese, chineseOGS, japanese, korean, aga, bga, agaButton, newZealand,
         trompTaylor, stoneScoring, ancientTerritory, custom
```

Lines 52-54 (`pickerCases`):

```swift
    /// Picker order: named presets first, Custom last.
    public static let pickerCases: [NewGameRuleset] =
        [.chinese, .japanese, .korean, .aga, .bga, .newZealand, .trompTaylor, .custom]
```

becomes:

```swift
    /// Picker order: named presets first (regional variants adjacent), Custom last.
    public static let pickerCases: [NewGameRuleset] =
        [.chinese, .chineseOGS, .japanese, .korean, .aga, .bga, .agaButton,
         .newZealand, .trompTaylor, .stoneScoring, .ancientTerritory, .custom]
```

`displayName` switch — insert the new cases (keep the existing ones):

```swift
        case .chineseOGS: return "Chinese (OGS/KGS)"
        case .agaButton: return "AGA Button"
        case .stoneScoring: return "Stone Scoring"
        case .ancientTerritory: return "Ancient Territory"
```

`sgfToken` switch — insert (tokens accepted by `Rules::parseRules`, `cpp/game/rules.cpp:296-341`; `chinese-ogs` ≡ `chinese-kgs` engine-side, one entry suffices):

```swift
        case .chineseOGS: return "chinese-ogs"
        case .agaButton: return "aga-button"
        case .stoneScoring: return "stone-scoring"
        case .ancientTerritory: return "ancient-territory"
```

- [ ] **Step 4: Run the tests to verify they pass**

Same command as Step 2. Expected: `TEST SUCCEEDED` — the extended `expected` table proves each token expands (through the real engine parser) to the rules.cpp components, and `namedRulesetSgfRoundTrips` covers the new four automatically because it iterates `expected`.

- [ ] **Step 5: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/NewGameRuleset.swift" "ios/KataGo iOS/KataGo iOSTests/NewGameRulesetTests.swift"
git commit -m "feat(rules): add Chinese (OGS/KGS), AGA Button, Stone Scoring, Ancient Territory presets

All four tokens are parsed by the engine (rules.cpp), so expand() needs no
change. The macOS New Game dialog picks them up automatically through
pickerCases.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF"
```

---

### Task 3: Persist the preset label — Config.rules extension + index mapping

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/ConfigModel.swift:269-272`
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/NewGameRuleset.swift` (append an extension)
- Test: `ios/KataGo iOS/KataGo iOSTests/NewGameRulesetTests.swift`

**Interfaces:**
- Consumes: `NewGameRuleset.sgfToken`, `NewGameRuleset.pickerCases` (Task 2).
- Produces: `Config.customRule: Int` (= -1), extended `Config.rules` (11 tokens), `NewGameRuleset.configRuleIndex: Int` (instance property), `NewGameRuleset.preset(fromConfigRule: Int) -> NewGameRuleset?` (static). Tasks 4-7 call all three.

- [ ] **Step 1: Write the failing tests**

Append inside `struct NewGameRulesetTests`:

```swift
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
```

- [ ] **Step 2: Run to verify they fail to compile**

```bash
cd "ios/KataGo iOS" && xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/NewGameRulesetTests" 2>&1 | grep -E "error:|TEST" | tail -10
```

Expected: compile errors — no `configRuleIndex`, no `Config.customRule`.

- [ ] **Step 3: Implement**

In `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/ConfigModel.swift`, replace lines 269-272:

```swift
extension Config {
    public static let defaultRule = 0
    public static let rules = ["chinese", "japanese", "korean", "aga", "bga", "new-zealand"]
}
```

with:

```swift
extension Config {
    public static let defaultRule = 0
    /// Sentinel stored in `rule` when the granular knobs match no named
    /// ruleset (a hand-edited "Custom" combination). Readers treat any
    /// out-of-range index the same way.
    public static let customRule = -1
    /// Named-ruleset tokens, indexed by the persisted `rule` field. Synced
    /// records store the index, so this array is APPEND-ONLY: the first six
    /// entries keep their historical positions.
    public static let rules = ["chinese", "japanese", "korean", "aga", "bga", "new-zealand",
                               "tromp-taylor", "chinese-ogs", "stone-scoring", "aga-button",
                               "ancient-territory"]
}
```

In `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/NewGameRuleset.swift`, append after the `NewGameRuleset` enum (before `NewGameRules`):

```swift
extension NewGameRuleset {
    /// Index of this preset in `Config.rules` — the value the per-game rule
    /// editors persist in `Config.rule` so the chosen label (e.g. Japanese
    /// vs the engine-identical Korean) survives relaunch. `Config.customRule`
    /// (-1) for `.custom`.
    public var configRuleIndex: Int {
        guard let token = sgfToken else { return Config.customRule }
        return Config.rules.firstIndex(of: token) ?? Config.customRule
    }

    /// The preset a persisted `Config.rule` index names, or `nil` when the
    /// index is the Custom sentinel / out of range (legacy or synced-ahead
    /// records) — callers fall back to component matching or "Custom".
    public static func preset(fromConfigRule index: Int) -> NewGameRuleset? {
        guard Config.rules.indices.contains(index) else { return nil }
        let token = Config.rules[index]
        return NewGameRuleset.pickerCases.first { $0.sgfToken == token }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Same command as Step 2. Expected: `TEST SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/ConfigModel.swift" "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/NewGameRuleset.swift" "ios/KataGo iOS/KataGo iOSTests/NewGameRulesetTests.swift"
git commit -m "feat(rules): append the five missing ruleset tokens to Config.rules with preset index mapping

Append-only so the six historical indices synced records store stay valid;
-1 is the Custom sentinel (TV's indices.contains guard already renders any
out-of-range value as Custom).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF"
```

---

### Task 4: ConfigEngineSync.applyRuleset

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Session/ConfigEngineSync.swift` (insert after `setWhiteHandicapBonusRule`, before the Playout-doubling section)
- Test: `ios/KataGo iOS/KataGo iOSTests/NewGameRulesetTests.swift`

**Interfaces:**
- Consumes: `NewGameRules.expand`, `NewGameRules.suggestedKomi` (existing), `configRuleIndex` (Task 3), the six existing `ConfigEngineSync` setters + `setKomi`.
- Produces: `ConfigEngineSync.applyRuleset(_ preset: NewGameRuleset, config: Config, messageList: MessageList)` — `@MainActor` (inherited from the enum). Tasks 5 and 6 call it.

- [ ] **Step 1: Write the failing tests**

Append inside `struct NewGameRulesetTests` (`MessageList` without a `session` just records `"> <command>"` lines — no engine involved; `ConfigEngineSync` is `@MainActor`, so the tests are too):

```swift
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
```

- [ ] **Step 2: Run to verify they fail to compile**

```bash
cd "ios/KataGo iOS" && xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/NewGameRulesetTests" 2>&1 | grep -E "error:|TEST" | tail -10
```

Expected: compile error — `ConfigEngineSync` has no member `applyRuleset`.

- [ ] **Step 3: Implement**

In `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Session/ConfigEngineSync.swift`, insert after the `setWhiteHandicapBonusRule` function (after line 113), before the `// MARK: Playout doubling advantage` block:

```swift
    // MARK: Named ruleset preset

    /// Applies a named ruleset preset from the per-game rule editors: expands
    /// it through the engine's own SGF parser (`NewGameRules.expand`), writes
    /// all six granular rule fields plus the ruleset's default komi
    /// (`NewGameRules.suggestedKomi`), persists the preset's label in
    /// `config.rule`, and replays the SAME six `kata-set-rule` commands +
    /// `komi` a game reload sends. Deliberately NOT `kata-set-rules <name>`:
    /// the named GTP command would also flip `friendlyPassOk` to the preset's
    /// value, diverging from the `false` the app forces at session start.
    /// No-op for `.custom`, which has no expansion.
    public static func applyRuleset(_ preset: NewGameRuleset,
                                    config: Config,
                                    messageList: MessageList) {
        guard let components = NewGameRules.expand(preset) else { return }
        setKoRule(components.koRule, config: config, messageList: messageList)
        setScoringRule(components.scoringRule, config: config, messageList: messageList)
        setTaxRule(components.taxRule, config: config, messageList: messageList)
        setMultiStoneSuicideLegal(components.multiStoneSuicideLegal, config: config, messageList: messageList)
        setHasButton(components.hasButton, config: config, messageList: messageList)
        setWhiteHandicapBonusRule(components.whiteHandicapBonusRule, config: config, messageList: messageList)
        setKomi(NewGameRules.suggestedKomi(components), config: config, messageList: messageList)
        config.rule = preset.configRuleIndex
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Same command as Step 2. Expected: `TEST SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Session/ConfigEngineSync.swift" "ios/KataGo iOS/KataGo iOSTests/NewGameRulesetTests.swift"
git commit -m "feat(rules): ConfigEngineSync.applyRuleset applies a named preset via the per-knob setters

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF"
```

---

### Task 5: iOS rules sheet — Ruleset picker + echo-guarded knob handlers

No unit test target covers SwiftUI views; the gate is the iOS build plus the Task 8 manual QA script. The behavioral logic (`match`, `expand`, `applyRuleset`, index mapping) is already unit-tested.

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/Config/ConfigView.swift` (`RuleConfigView`, lines 158-349)

**Interfaces:**
- Consumes: `NewGameRuleset.pickerCases/.displayName`, `NewGameRules.match/.expand`, `NewGameRuleset.preset(fromConfigRule:)`, `configRuleIndex`, `ConfigEngineSync.applyRuleset` (Tasks 2-4).
- Produces: UI only.

Behavioral contract (mirrors the Mac New Game dialog, adapted to SwiftUI's cascading `.onChange`):
- The picker shows `match(componentsFromConfig, preferring: preset(fromConfigRule: config.rule))` — the stored label is a tie-breaker for engine-identical pairs (Japanese/Korean, AGA/BGA), never trusted against the actual knobs.
- Picking a named preset applies it (six `kata-set-rule` + `komi`) and refreshes every knob `@State`.
- **Echo suppression, no timing flags:** each knob's `.onChange` first compares the incoming value against the config; equal means it is the echo of a programmatic `@State` refresh (or the `onAppear` seeding) and the handler returns without sending. A genuine hand-edit then recomputes the matched preset, snaps the picker, and persists the label (Custom sentinel `-1` when nothing matches).
- If the picked preset's expansion already equals the current components (a programmatic snap, or the user relabeling identical rules, e.g. Japanese → Korean), only `config.rule` is written — no GTP, no komi reset — and only when the index actually differs, so merely opening the sheet never dirties the CloudKit-synced record. Consequence (accepted, declared spec delta 3): re-picking the already-matching preset does not reset a hand-edited komi on iOS — SwiftUI cannot distinguish that from the programmatic snap. macOS can, and does re-apply (Task 6).
- Selecting "Custom" is a no-op (it is a display state, same as the Mac New Game dialog).

- [ ] **Step 1: Add the ruleset state + helpers**

In `RuleConfigView` (line 158), add to the `@State` block (after line 174, `komiText`):

```swift
    @State var rulesetText: String = NewGameRuleset.custom.displayName
```

Add these members at the bottom of `RuleConfigView` (after the `body` property, before the closing brace at line 350):

```swift
    /// The six granular rule components currently persisted in the config.
    private var currentComponents: NewGameRuleComponents {
        NewGameRuleComponents(koRule: config.koRule,
                              scoringRule: config.scoringRule,
                              taxRule: config.taxRule,
                              multiStoneSuicideLegal: config.multiStoneSuicideLegal,
                              hasButton: config.hasButton,
                              whiteHandicapBonusRule: config.whiteHandicapBonusRule)
    }

    /// The named preset the current knobs correspond to (Custom when none).
    /// The persisted `config.rule` label only breaks ties between
    /// engine-identical presets (Japanese/Korean, AGA/BGA).
    private var matchedRuleset: NewGameRuleset {
        NewGameRules.match(currentComponents,
                           preferring: NewGameRuleset.preset(fromConfigRule: config.rule))
    }

    /// After a hand-edit of one granular knob: snap the Ruleset picker to the
    /// matching named preset (or Custom) and persist that label.
    private func refreshRulesetSelection() {
        let matched = matchedRuleset
        config.rule = matched.configRuleIndex
        rulesetText = matched.displayName
    }
```

- [ ] **Step 2: Insert the Ruleset picker row**

In the `List` body, directly after the branch-active footnote block (after line 218's closing `}` of `if gobanState.isBranchActive { ... }`) and before the "Ko rule" `ConfigTextPicker`, insert:

```swift
            ConfigTextPicker(
                title: "Ruleset",
                texts: NewGameRuleset.pickerCases.map(\.displayName),
                selectedText: $rulesetText
            )
            .onAppear {
                rulesetText = matchedRuleset.displayName
            }
            .onChange(of: rulesetText) { _, newValue in
                guard let preset = NewGameRuleset.pickerCases.first(where: { $0.displayName == newValue }),
                      preset != .custom else { return }
                if NewGameRules.expand(preset) == currentComponents {
                    // The picker snapped here programmatically, or the user
                    // relabeled engine-identical rules (Japanese -> Korean):
                    // persist the label, leave knobs/komi/engine untouched.
                    // The equal-value guard keeps a plain sheet-open (the
                    // onAppear snap) from re-dirtying the synced record; a
                    // DIFFERING stale label is deliberately healed to match
                    // the actual knobs.
                    if config.rule != preset.configRuleIndex {
                        config.rule = preset.configRuleIndex
                    }
                    return
                }
                ConfigEngineSync.applyRuleset(preset, config: config, messageList: messageList)
                koRuleText = config.koRuleText
                scoringRuleText = config.scoringRuleText
                taxRuleText = config.taxRuleText
                multiStoneSuicideLegal = config.multiStoneSuicideLegal
                hasButton = config.hasButton
                whiteHandicapBonusRuleText = config.whiteHandicapBonusRuleText
                komi = config.komi
                komiText = String(config.komi)
                isRuleChanged = true
            }
```

- [ ] **Step 3: Echo-guard the six knob handlers + komi**

Replace each existing `.onChange` handler body as follows (the row/`onAppear` parts stay untouched).

Ko rule (lines 228-233) — replace:

```swift
            .onChange(of: koRuleText) { _, newValue in
                let rawValue = Config.koRules.firstIndex(of: newValue) ?? Config.defaultKoRule
                let koRule = KoRule(rawValue: rawValue) ?? .simple
                ConfigEngineSync.setKoRule(koRule, config: config, messageList: messageList)
                isRuleChanged = true
            }
```

with:

```swift
            .onChange(of: koRuleText) { _, newValue in
                let rawValue = Config.koRules.firstIndex(of: newValue) ?? Config.defaultKoRule
                let koRule = KoRule(rawValue: rawValue) ?? .simple
                // Equal to the config means this is the echo of a programmatic
                // @State refresh (preset apply / onAppear seeding), not an edit.
                guard koRule != config.koRule else { return }
                ConfigEngineSync.setKoRule(koRule, config: config, messageList: messageList)
                isRuleChanged = true
                refreshRulesetSelection()
            }
```

Scoring rule (lines 243-248) — replace:

```swift
            .onChange(of: scoringRuleText) { _, _ in
                let rawValue = Config.scoringRules.firstIndex(of: scoringRuleText) ?? Config.defaultScoringRule
                let scoringRule = ScoringRule(rawValue: rawValue) ?? .area
                ConfigEngineSync.setScoringRule(scoringRule, config: config, messageList: messageList)
                isRuleChanged = true
            }
```

with:

```swift
            .onChange(of: scoringRuleText) { _, _ in
                let rawValue = Config.scoringRules.firstIndex(of: scoringRuleText) ?? Config.defaultScoringRule
                let scoringRule = ScoringRule(rawValue: rawValue) ?? .area
                guard scoringRule != config.scoringRule else { return }
                ConfigEngineSync.setScoringRule(scoringRule, config: config, messageList: messageList)
                isRuleChanged = true
                refreshRulesetSelection()
            }
```

Tax rule (lines 258-263) — replace:

```swift
            .onChange(of: taxRuleText) { _, _ in
                let rawValue = Config.taxRules.firstIndex(of: taxRuleText) ?? Config.defaultTaxRule
                let taxRule = TaxRule(rawValue: rawValue) ?? .none
                ConfigEngineSync.setTaxRule(taxRule, config: config, messageList: messageList)
                isRuleChanged = true
            }
```

with:

```swift
            .onChange(of: taxRuleText) { _, _ in
                let rawValue = Config.taxRules.firstIndex(of: taxRuleText) ?? Config.defaultTaxRule
                let taxRule = TaxRule(rawValue: rawValue) ?? .none
                guard taxRule != config.taxRule else { return }
                ConfigEngineSync.setTaxRule(taxRule, config: config, messageList: messageList)
                isRuleChanged = true
                refreshRulesetSelection()
            }
```

Multi-stone suicide (lines 269-272) — replace:

```swift
                .onChange(of: multiStoneSuicideLegal) { _, newValue in
                    ConfigEngineSync.setMultiStoneSuicideLegal(newValue, config: config, messageList: messageList)
                    isRuleChanged = true
                }
```

with:

```swift
                .onChange(of: multiStoneSuicideLegal) { _, newValue in
                    guard newValue != config.multiStoneSuicideLegal else { return }
                    ConfigEngineSync.setMultiStoneSuicideLegal(newValue, config: config, messageList: messageList)
                    isRuleChanged = true
                    refreshRulesetSelection()
                }
```

Has button (lines 278-281) — replace:

```swift
                .onChange(of: hasButton) { _, newValue in
                    ConfigEngineSync.setHasButton(newValue, config: config, messageList: messageList)
                    isRuleChanged = true
                }
```

with:

```swift
                .onChange(of: hasButton) { _, newValue in
                    guard newValue != config.hasButton else { return }
                    ConfigEngineSync.setHasButton(newValue, config: config, messageList: messageList)
                    isRuleChanged = true
                    refreshRulesetSelection()
                }
```

White handicap bonus (lines 291-296) — replace:

```swift
            .onChange(of: whiteHandicapBonusRuleText) { _, _ in
                let rawValue = Config.whiteHandicapBonusRules.firstIndex(of: whiteHandicapBonusRuleText) ?? Config.defaultWhiteHandicapBonusRule
                let rule = WhiteHandicapBonusRule(rawValue: rawValue) ?? .zero
                ConfigEngineSync.setWhiteHandicapBonusRule(rule, config: config, messageList: messageList)
                isRuleChanged = true
            }
```

with:

```swift
            .onChange(of: whiteHandicapBonusRuleText) { _, _ in
                let rawValue = Config.whiteHandicapBonusRules.firstIndex(of: whiteHandicapBonusRuleText) ?? Config.defaultWhiteHandicapBonusRule
                let rule = WhiteHandicapBonusRule(rawValue: rawValue) ?? .zero
                guard rule != config.whiteHandicapBonusRule else { return }
                ConfigEngineSync.setWhiteHandicapBonusRule(rule, config: config, messageList: messageList)
                isRuleChanged = true
                refreshRulesetSelection()
            }
```

Komi (lines 306-309) — replace:

```swift
            .onChange(of: komiText) { _, newValue in
                ConfigEngineSync.setKomi(Float(newValue) ?? Config.defaultKomi, config: config, messageList: messageList)
                isRuleChanged = true
            }
```

with:

```swift
            .onChange(of: komiText) { _, newValue in
                // Clamp + half-point-round exactly as setKomi will, so the
                // echo of a programmatic refresh compares equal and is skipped.
                let newKomi = min(1_000, max(-1_000, ((Float(newValue) ?? Config.defaultKomi) * 2).rounded() / 2))
                guard newKomi != config.komi else { return }
                ConfigEngineSync.setKomi(newKomi, config: config, messageList: messageList)
                isRuleChanged = true
            }
```

(Komi is not part of preset matching — no `refreshRulesetSelection()` here.)

- [ ] **Step 4: Build the iOS scheme**

```bash
cd "ios/KataGo iOS" && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)|error:"
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add "ios/KataGo iOS/KataGo iOS/Config/ConfigView.swift"
git commit -m "feat(ios): Ruleset preset picker in the per-game rules sheet

Picking a named ruleset fills all six knobs + komi through
ConfigEngineSync.applyRuleset; hand-editing a knob snaps the picker to the
matching preset or Custom. Knob handlers gained echo guards (skip when the
incoming value equals the config) so programmatic @State refreshes neither
resend GTP nor flip the picker.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF"
```

---

### Task 6: macOS Config editor — Ruleset row with preset ⇄ granular sync

**Files:**
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/ConfigEditorViewController.swift` (properties block at lines 60-62; `addRuleSection` at lines 182-260; new private methods)

**Interfaces:**
- Consumes: same Task 2-4 APIs as iOS, plus `PopupRow.reload(selectedIndex:)`, `NumericRow.reload(value:)`, `CheckboxRow.reload(isOn:)` (all existing, none re-fire `onChange` — `ConfigEditingSupport.swift`).
- Produces: UI only.

AppKit rows fire `onChange` only on user action, so no echo guards are needed — this mirrors `NewGameViewController.rulesetChanged`/`granularChanged` exactly, but applies live through `ConfigEngineSync`.

- [ ] **Step 1: Add row references**

After line 62 (`private let formStack = NSStackView()`), add:

```swift
    // Rules rows kept for programmatic repopulation when a Ruleset preset is
    // picked (mirrors NewGameViewController's preset <-> granular sync).
    // `reload(...)` never re-fires `onChange`, so there is no feedback loop.
    private var rulesetRow: PopupRow!
    private var komiRow: NumericRow!
    private var koRow: PopupRow!
    private var scoringRow: PopupRow!
    private var taxRow: PopupRow!
    private var suicideRow: CheckboxRow!
    private var buttonRow: CheckboxRow!
    private var whbRow: PopupRow!
```

- [ ] **Step 2: Rebuild addRuleSection around the references + Ruleset row**

Replace the whole `addRuleSection()` (lines 182-260) with:

```swift
    private func addRuleSection() {
        let config = self.config
        formStack.addArrangedSubview(ConfigFormBuilder.sectionHeader("Rules"))

        rulesetRow = ConfigFormBuilder.popupRow(
            title: "Ruleset",
            options: NewGameRuleset.pickerCases.map(\.displayName),
            selectedIndex: NewGameRuleset.pickerCases.firstIndex(of: matchedRuleset()) ?? 0,
            onChange: { [weak self] index in self?.rulesetChanged(index) })
        formStack.addArrangedSubview(rulesetRow)

        komiRow = ConfigFormBuilder.numericRow(
            title: "Komi",
            value: Double(config.komi),
            minValue: -1_000,
            maxValue: 1_000,
            step: 0.5,
            format: { Config.komiText(Float($0)) },
            onChange: { [weak self] newValue in
                guard let self else { return }
                ConfigEngineSync.setKomi(Float(newValue), config: config, messageList: self.messageList)
            })
        formStack.addArrangedSubview(komiRow)

        koRow = ConfigFormBuilder.popupRow(
            title: "Ko rule",
            options: Config.koRules,
            selectedIndex: config.koRule.rawValue,
            onChange: { [weak self] index in
                guard let self else { return }
                let koRule = KoRule(rawValue: index) ?? .simple
                ConfigEngineSync.setKoRule(koRule, config: config, messageList: self.messageList)
                self.granularRuleChanged()
            })
        formStack.addArrangedSubview(koRow)

        scoringRow = ConfigFormBuilder.popupRow(
            title: "Scoring rule",
            options: Config.scoringRules,
            selectedIndex: config.scoringRule.rawValue,
            onChange: { [weak self] index in
                guard let self else { return }
                let scoringRule = ScoringRule(rawValue: index) ?? .area
                ConfigEngineSync.setScoringRule(scoringRule, config: config, messageList: self.messageList)
                self.granularRuleChanged()
            })
        formStack.addArrangedSubview(scoringRow)

        taxRow = ConfigFormBuilder.popupRow(
            title: "Tax rule",
            options: Config.taxRules,
            selectedIndex: config.taxRule.rawValue,
            onChange: { [weak self] index in
                guard let self else { return }
                let taxRule = TaxRule(rawValue: index) ?? .none
                ConfigEngineSync.setTaxRule(taxRule, config: config, messageList: self.messageList)
                self.granularRuleChanged()
            })
        formStack.addArrangedSubview(taxRow)

        suicideRow = ConfigFormBuilder.checkboxRow(
            title: "Multi-stone suicide",
            isOn: config.multiStoneSuicideLegal,
            onChange: { [weak self] isOn in
                guard let self else { return }
                ConfigEngineSync.setMultiStoneSuicideLegal(isOn, config: config, messageList: self.messageList)
                self.granularRuleChanged()
            })
        formStack.addArrangedSubview(suicideRow)

        buttonRow = ConfigFormBuilder.checkboxRow(
            title: "Has button",
            isOn: config.hasButton,
            onChange: { [weak self] isOn in
                guard let self else { return }
                ConfigEngineSync.setHasButton(isOn, config: config, messageList: self.messageList)
                self.granularRuleChanged()
            })
        formStack.addArrangedSubview(buttonRow)

        whbRow = ConfigFormBuilder.popupRow(
            title: "White handicap bonus",
            options: Config.whiteHandicapBonusRules,
            selectedIndex: config.whiteHandicapBonusRule.rawValue,
            onChange: { [weak self] index in
                guard let self else { return }
                let rule = WhiteHandicapBonusRule(rawValue: index) ?? .zero
                ConfigEngineSync.setWhiteHandicapBonusRule(rule, config: config, messageList: self.messageList)
                self.granularRuleChanged()
            })
        formStack.addArrangedSubview(whbRow)
    }
```

- [ ] **Step 3: Add the sync methods**

After `addRuleSection()`, add:

```swift
    // MARK: Ruleset preset <-> granular sync

    /// The six granular rule components currently persisted in the config.
    private func currentComponents() -> NewGameRuleComponents {
        NewGameRuleComponents(koRule: config.koRule,
                              scoringRule: config.scoringRule,
                              taxRule: config.taxRule,
                              multiStoneSuicideLegal: config.multiStoneSuicideLegal,
                              hasButton: config.hasButton,
                              whiteHandicapBonusRule: config.whiteHandicapBonusRule)
    }

    /// The named preset the current knobs correspond to (Custom when none).
    /// The persisted `config.rule` label only breaks ties between
    /// engine-identical presets (Japanese/Korean, AGA/BGA).
    private func matchedRuleset() -> NewGameRuleset {
        NewGameRules.match(currentComponents(),
                           preferring: NewGameRuleset.preset(fromConfigRule: config.rule))
    }

    /// A named preset was chosen: apply it live (six kata-set-rule + komi via
    /// ConfigEngineSync.applyRuleset) and repopulate the granular rows.
    /// Selecting "Custom" is a display-state no-op, matching the New Game
    /// dialog and the iOS sheet. Relabeling engine-identical rules
    /// (Japanese -> Korean) persists the label without touching the engine or
    /// a hand-edited komi; an explicit re-pick of the already-matching preset
    /// — which AppKit reports, unlike SwiftUI — falls through to a full apply
    /// so it restores the preset's default komi.
    private func rulesetChanged(_ index: Int) {
        guard NewGameRuleset.pickerCases.indices.contains(index) else { return }
        let chosen = NewGameRuleset.pickerCases[index]
        guard chosen != .custom else { return }
        if chosen != matchedRuleset(), NewGameRules.expand(chosen) == currentComponents() {
            if config.rule != chosen.configRuleIndex {
                config.rule = chosen.configRuleIndex
            }
            return
        }
        ConfigEngineSync.applyRuleset(chosen, config: config, messageList: messageList)
        koRow.reload(selectedIndex: config.koRule.rawValue)
        scoringRow.reload(selectedIndex: config.scoringRule.rawValue)
        taxRow.reload(selectedIndex: config.taxRule.rawValue)
        suicideRow.reload(isOn: config.multiStoneSuicideLegal)
        buttonRow.reload(isOn: config.hasButton)
        whbRow.reload(selectedIndex: config.whiteHandicapBonusRule.rawValue)
        komiRow.reload(value: Double(config.komi))
    }

    /// A granular rule was hand-edited: re-derive the matching preset, snap
    /// the Ruleset popup, and persist the label (Custom sentinel when none
    /// match).
    private func granularRuleChanged() {
        let matched = matchedRuleset()
        config.rule = matched.configRuleIndex
        rulesetRow.reload(selectedIndex: NewGameRuleset.pickerCases.firstIndex(of: matched) ?? 0)
    }
```

- [ ] **Step 4: Build the macOS scheme**

```bash
cd "ios/KataGo iOS" && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS' -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)|error:"
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add "ios/KataGo iOS/KataGo Anytime Mac/ConfigEditorViewController.swift"
git commit -m "feat(mac): Ruleset preset row in the per-game Config editor

Mirrors the New Game dialog's preset<->granular sync, applied live through
ConfigEngineSync.applyRuleset. The WHB popup now labels correctly via the
reordered Config.whiteHandicapBonusRules.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF"
```

---

### Task 7: Apple TV ruleset label via the preset display names

`TVReviewScreen.ruleText` prettifies the raw token (`"chinese-ogs"` → `"Chinese Ogs"`, `"aga-button"` → `"Aga Button"`) — wrong for the newly reachable tokens. Route it through the preset display name instead; `-1`/out-of-range still reads "Custom" (that behavior is what the spec's "TV labels get more accurate for free" refers to).

**Files:**
- Modify: `ios/KataGo iOS/KataGo Anytime TV/TVReviewScreen.swift:453-459`

**Interfaces:**
- Consumes: `NewGameRuleset.preset(fromConfigRule:)`, `displayName` (Tasks 2-3; `TVReviewScreen` already imports `KataGoUICore`).
- Produces: UI only.

- [ ] **Step 1: Replace ruleText**

Replace lines 453-459:

```swift
    private var ruleText: String {
        // A synced Config could carry an out-of-range rule; never crash on it.
        guard Config.rules.indices.contains(config.rule) else { return "Custom" }
        let raw = Config.rules[config.rule]
        if raw == "aga" || raw == "bga" { return raw.uppercased() }
        return raw.replacingOccurrences(of: "-", with: " ").capitalized
    }
```

with:

```swift
    private var ruleText: String {
        // The persisted index names a preset; the -1 Custom sentinel and any
        // out-of-range synced value render as "Custom" (never crash).
        NewGameRuleset.preset(fromConfigRule: config.rule)?.displayName ?? "Custom"
    }
```

- [ ] **Step 2: Build the tvOS scheme**

```bash
cd "ios/KataGo iOS" && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime TV" -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)|error:"
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add "ios/KataGo iOS/KataGo Anytime TV/TVReviewScreen.swift"
git commit -m "feat(tvos): derive the ruleset label from NewGameRuleset display names

The old token prettifier renders the newly reachable tokens wrong
(chinese-ogs -> Chinese Ogs); the preset display name is authoritative and
the -1 Custom sentinel reads as Custom.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF"
```

---

### Task 8: Full verification

Sequential — never two xcodebuild invocations at once.

- [ ] **Step 1: Full iOS-simulator unit-test run**

```bash
cd "ios/KataGo iOS" && xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | grep -E "Test Suite|TEST (SUCCEEDED|FAILED)|error:" | tail -25
```

Expected: `TEST SUCCEEDED`. (This is the unit-test bundle; the separate UITests target/FullTestPlan is not required for this change.)

- [ ] **Step 2: KataGoUICore package tests** (never run under xcodebuild — `swift test` is the only gate for them)

```bash
cd "ios/KataGo iOS/KataGoUICore" && swift test 2>&1 | tail -5
```

Expected: all tests pass (guards the package against regressions from the `Config` array changes).

- [ ] **Step 3: Build the remaining schemes** (iOS, Mac, TV already built in Tasks 5-7; verify visionOS + watchOS, then re-verify iOS after all edits)

```bash
cd "ios/KataGo iOS" && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Vision" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
```

```bash
cd "ios/KataGo iOS" && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Watch" -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
```

```bash
cd "ios/KataGo iOS" && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
```

Expected: `BUILD SUCCEEDED` × 3.

- [ ] **Step 4: Manual QA on the iOS Simulator** (use the `verify` skill flow)

1. Open a game → rules sheet: the Ruleset picker shows the game's ruleset (a fresh default game shows "Chinese").
2. Pick "Japanese": Ko SIMPLE, Scoring TERRITORY, Tax SEKI, suicide off, button off, WHB 0, komi 6.5.
3. Hand-edit Tax to ALL: picker flips to "Custom".
4. Set the knobs back to exact Japanese values by hand: picker snaps to "Japanese".
5. Pick "Korean" (identical rules): no engine traffic expected; close and reopen the sheet — the label still reads "Korean".
6. Pick "Chinese (OGS/KGS)" and inspect the command log: `kata-set-rule ko POSITIONAL` … `kata-set-rule whiteHandicapBonus N` … `komi 7.5`.
7. macOS (signed Debug build, per the unsigned-CloudKit-crash rule): Edit… sheet shows the Ruleset row; preset pick repopulates the granular rows + komi; a granular edit snaps the popup; hand-edit komi, then re-pick the same (matching) preset — komi returns to the preset default.
8. macOS New Game dialog (⌘N): the Ruleset popup lists all 12 entries; picking "Stone Scoring" fills the granular rows (Scoring AREA, Tax ALL, komi 7.5).

- [ ] **Step 5: Update the spec status and commit any doc delta**

In `docs/superpowers/specs/2026-08-07-ruleset-presets-design.md`, record the three declared spec deltas from the plan header (the Task 1 WHB order fix; the Task 7 TV label change; the same-components pick persisting only the label — with the macOS explicit-re-pick exception) in a short "## Implementation notes" section at the end, then:

```bash
git add docs/superpowers/specs/2026-08-07-ruleset-presets-design.md
git commit -m "docs(spec): record the WHB order fix and TV label change shipped with ruleset presets

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF"
```

Do **not** push — ios-dev pushes distribute via Xcode Cloud and are spaced by the user.
