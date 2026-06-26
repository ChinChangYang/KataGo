# Human-like AI Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the duplicated `rank_*`/`preaz_*` profile menu with single unified `<rank>` entries driven by PR #1209's tuned KGS-rank ladder, and rename `proyear_<year>` to `Pro <year>` (9d-derived, λ 0.06) — with clean, natural menu labels.

**Architecture:** All the work is concentrated in one value type, `HumanSLModel` (shared `KataGoUICore` package). The stored `Config.humanSLProfile` string becomes a clean **menu key** (`AI` / `9d`…`20k` / `Pro 1800`…`Pro 2023`); `HumanSLModel` is the single place that maps a key → the engine `humanSLProfile` value, the tuned λ, and the emitted `kata-set-param` command list. `Config` remains a pure pass-through (it neither validates nor transforms the string). Consumers (pickers, analysis emitters, player labels) keep routing the stored key through `HumanSLModel`, so they need only label/normalization touch-ups.

**Tech Stack:** Swift 6, SwiftUI (iOS/visionOS) + AppKit (macOS), Swift Testing (`import Testing`, `#expect`), Xcode `xcodebuild`.

## Global Constraints

- **Frozen SwiftData schema.** Do NOT modify `Config`/`GameRecord` `@Model` fields. `Config.humanSLProfile` stays a free-form `String`; only its *values* change. (project memory: never modify SwiftData models)
- **App is unreleased** — no schema migration. The one allowed back-compat touch is input normalization inside `HumanSLModel` (legacy engine strings → new keys), because the developer has a large iCloud-synced library; this is input-validation, not migration.
- **App owns search budget.** Do NOT emit `maxVisits`, `numSearchThreads`, `delayMove*`, `rules`, logging, or resign params from #1209. Only the human-SL behavioral params already in `HumanSLModel.commands` change value.
- **`AI` profile behavior is preserved.** Its emitted params keep the same values as today (AI keeps its level-9 temperatures 0.67/0.16/26 and λ 0.06). Numeric *formatting* is cleaner (e.g. the old formula emitted `0.66999996`-style floats; the new literals emit `0.67`) — values differ by <1e-7, which is imperceptible for a move-selection temperature. AI is also the sentinel for "Human"-labelled-side analysis via `effectiveHumanProfileForBlack/White`, so its parameters must not change in value.
- **Three-platform build required** before done: iOS, visionOS, macOS (scheme `KataGo Anytime` for iOS/visionOS, `KataGo Anytime Mac` for macOS).
- **Test framework is Swift Testing** for unit tests (`@Test`, `#expect`); the UI test target uses XCTest. New unit tests are **appended to the already-registered** `GtpCommandBuilderTests.swift` to avoid editing `project.pbxproj`.
- **Exact #1209 λ ladder** (preaz_<rank>), copy verbatim:
  `9d 0.045, 8d 0.0868, 7d 0.1267, 6d 0.1983, 5d 0.28064, 4d 0.373, 3d 0.45556, 2d 0.5133, 1d 0.5093, 1k 0.48988, 2k 0.46755, 3k 0.49173, 4k 0.4713, 5k 0.5072, 6k 0.48925, 7k 0.5337, 8k 0.5064, 9k 0.5388, 10k 0.59036, 11k 0.56458, 12k 0.54297, 13k 0.58977, 14k 0.61625, 15k 0.61839, 16k 0.6705, 17k 0.7413, 18k 0.7821, 19k 0.8982, 20k 1.2227`.

**Paths** (commands below assume cwd = repo root `/Users/chinchangyang/Code/KataGo-ios-dev`):
- Model: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/HumanSLModel.swift`
- Tests: `ios/KataGo iOS/KataGo iOSTests/GtpCommandBuilderTests.swift`, `ConfigModelTests.swift`, `PlayerLabelTests.swift`
- iOS picker: `ios/KataGo iOS/KataGo iOS/Config/ConfigView.swift`
- Mac pickers: `ios/KataGo iOS/KataGo Anytime Mac/ConfigEditorViewController.swift`, `InspectorInfoViewController.swift`
- Stale strings: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Rendering/StoneView.swift`, `ios/KataGo iOS/KataGo iOSUITests/PlayerNameLabelUITests.swift`, `KataGoUICore/Sources/KataGoGameStore/ConfigModel.swift`

---

## Task 1: Rewrite `HumanSLModel` (keys, key→engine mapping, #1209 λ ladder, legacy normalization)

**Files:**
- Modify (full rewrite): `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/HumanSLModel.swift`
- Test (append a new struct): `ios/KataGo iOS/KataGo iOSTests/GtpCommandBuilderTests.swift`
- Test (update literals): `ios/KataGo iOS/KataGo iOSTests/ConfigModelTests.swift`, `ios/KataGo iOS/KataGo iOSTests/PlayerLabelTests.swift`

**Interfaces:**
- Produces (public surface other tasks rely on):
  - `HumanSLModel.allProfiles: [String]` — `["AI"] + 9d…20k + "Pro 1800"…"Pro 2023"` (count 254).
  - `HumanSLModel.canonicalProfile(_ raw: String) -> String` — legacy/garbage → current key, else `"AI"`.
  - `HumanSLModel.init?(profile: String)` — accepts a current key OR a legacy engine string (`rank_9d`/`preaz_9d`→`9d`, `proyear_2023`→`Pro 2023`); `nil` for unrecognized.
  - `HumanSLModel().profile == "AI"`; `var profile: String { get set }` (setter normalizes, ignores unrecognized).
  - `HumanSLModel.humanSLProfile: String` (engine value) and `HumanSLModel.commands: [String]` (11 `kata-set-param` lines) — unchanged signatures.

- [ ] **Step 1: Append the new test struct to `GtpCommandBuilderTests.swift`**

Add this struct at the end of `ios/KataGo iOS/KataGo iOSTests/GtpCommandBuilderTests.swift` (after the existing `ConfigEngineSyncTests`):

```swift
// MARK: - HumanSLModel: keys, key→engine mapping, #1209 λ ladder, legacy normalization

struct HumanSLModelTests {

    private func lambdaValue(in commands: [String]) -> Float? {
        let prefix = "kata-set-param humanSLChosenMovePiklLambda "
        guard let line = commands.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return Float(line.dropFirst(prefix.count))
    }

    @Test func allProfilesAreCleanUnifiedKeys() {
        let all = HumanSLModel.allProfiles
        #expect(all.first == "AI")
        #expect(all.contains("9d"))
        #expect(all.contains("20k"))
        #expect(all.contains("Pro 1800"))
        #expect(all.contains("Pro 2023"))
        // The old duplicated/raw engine strings are gone from the menu.
        #expect(!all.contains("rank_9d"))
        #expect(!all.contains("preaz_9d"))
        #expect(!all.contains("proyear_2023"))
        // 1 (AI) + 29 ranks (9d…1d, 1k…20k) + 224 pros (1800…2023) = 254.
        #expect(all.count == 254)
    }

    @Test func defaultProfileIsAI() {
        #expect(HumanSLModel().profile == "AI")
    }

    @Test func rankKeyMapsToPreazEngineProfile() {
        #expect(HumanSLModel(profile: "9d")?.commands.contains("kata-set-param humanSLProfile preaz_9d") == true)
        #expect(HumanSLModel(profile: "5k")?.commands.contains("kata-set-param humanSLProfile preaz_5k") == true)
        #expect(HumanSLModel(profile: "20k")?.commands.contains("kata-set-param humanSLProfile preaz_20k") == true)
    }

    @Test func proKeyMapsToProyearEngineProfile() {
        #expect(HumanSLModel(profile: "Pro 2023")?.commands.contains("kata-set-param humanSLProfile proyear_2023") == true)
        #expect(HumanSLModel(profile: "Pro 1800")?.commands.contains("kata-set-param humanSLProfile proyear_1800") == true)
    }

    @Test func aiMapsToRank9dEngineProfile() {
        #expect(HumanSLModel(profile: "AI")?.commands.contains("kata-set-param humanSLProfile rank_9d") == true)
    }

    @Test func humanProfilesUse1209Constants() {
        let cmds = HumanSLModel(profile: "5k")!.commands
        #expect(cmds.contains("kata-set-param humanSLChosenMoveProp 1.0"))
        #expect(cmds.contains("kata-set-param humanSLRootExploreProbWeightless 0.8"))
        #expect(cmds.contains("kata-set-param chosenMoveTemperatureEarly 0.7"))
        #expect(cmds.contains("kata-set-param chosenMoveTemperature 0.25"))
        #expect(cmds.contains("kata-set-param chosenMoveTemperatureHalflife 30"))
        #expect(cmds.contains("kata-set-param chosenMoveTemperatureOnlyBelowProb 1.0"))
        #expect(cmds.contains("kata-set-param winLossUtilityFactor 1.0"))
        #expect(cmds.contains("kata-set-param staticScoreUtilityFactor 0.5"))
        #expect(cmds.contains("kata-set-param dynamicScoreUtilityFactor 0.5"))
    }

    @Test func aiProfileEmittedCommandsArePreserved() {
        // AI keeps the same param VALUES as today's level-9 emission (the new
        // literals just format cleaner than the old float arithmetic, e.g.
        // 0.66999996 → 0.67). This pins the canonical AI command list.
        #expect(HumanSLModel(profile: "AI")!.commands == [
            "kata-set-param humanSLProfile rank_9d",
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
        ])
    }

    @Test func proProfileDerivesFrom9dWithLambda006() {
        let pro = HumanSLModel(profile: "Pro 1950")!.commands
        let nineDan = HumanSLModel(profile: "9d")!.commands
        // Same constant set as 9d except the profile line and λ.
        #expect(pro.contains("kata-set-param humanSLProfile proyear_1950"))
        #expect(lambdaValue(in: pro)! == 0.06)
        #expect(pro.contains("kata-set-param humanSLRootExploreProbWeightless 0.8"))
        #expect(pro.contains("kata-set-param winLossUtilityFactor 1.0"))
        #expect(pro.contains("kata-set-param chosenMoveTemperature 0.25"))
        // 9d differs only by profile (preaz_9d) and λ (0.045).
        #expect(nineDan.contains("kata-set-param humanSLProfile preaz_9d"))
        #expect(lambdaValue(in: nineDan)! != 0.06)
    }

    @Test func rankLambdaLadderMatches1209() {
        let expected: [String: Float] = [
            "9d": 0.045, "8d": 0.0868, "7d": 0.1267, "6d": 0.1983, "5d": 0.28064,
            "4d": 0.373, "3d": 0.45556, "2d": 0.5133, "1d": 0.5093,
            "1k": 0.48988, "2k": 0.46755, "3k": 0.49173, "4k": 0.4713, "5k": 0.5072,
            "6k": 0.48925, "7k": 0.5337, "8k": 0.5064, "9k": 0.5388, "10k": 0.59036,
            "11k": 0.56458, "12k": 0.54297, "13k": 0.58977, "14k": 0.61625, "15k": 0.61839,
            "16k": 0.6705, "17k": 0.7413, "18k": 0.7821, "19k": 0.8982, "20k": 1.2227,
        ]
        for (key, lam) in expected {
            let cmds = HumanSLModel(profile: key)!.commands
            let value = lambdaValue(in: cmds)
            #expect(value != nil)
            #expect(abs((value ?? 0) - lam) < 1e-4)
        }
    }

    @Test func legacyEngineStringsNormalizeToUnifiedKeys() {
        #expect(HumanSLModel(profile: "rank_9d")?.profile == "9d")
        #expect(HumanSLModel(profile: "preaz_9d")?.profile == "9d")   // both collapse
        #expect(HumanSLModel(profile: "preaz_5k")?.profile == "5k")
        #expect(HumanSLModel(profile: "proyear_2000")?.profile == "Pro 2000")
        #expect(HumanSLModel(profile: "AI")?.profile == "AI")
        // A normalized legacy rank still drives the preaz engine profile.
        #expect(HumanSLModel(profile: "rank_5k")?.commands.contains("kata-set-param humanSLProfile preaz_5k") == true)
    }

    @Test func unrecognizedProfileIsRejectedAndCanonicalizesToAI() {
        #expect(HumanSLModel(profile: "garbage_profile") == nil)
        #expect(HumanSLModel.canonicalProfile("garbage_profile") == "AI")
        #expect(HumanSLModel.canonicalProfile("rank_3d") == "3d")
        #expect(HumanSLModel.canonicalProfile("Pro 1999") == "Pro 1999")
        #expect(HumanSLModel.canonicalProfile("7k") == "7k")
    }
}
```

- [ ] **Step 2: Update existing test literals to the new keys**

In `ios/KataGo iOS/KataGo iOSTests/GtpCommandBuilderTests.swift`, inside `ConfigEngineSyncTests`:

Change `togglingSideToHumanReconfiguresAnalysisToBestAI`:
```swift
        config.humanProfileForWhite = "5k"
```
(was `"rank_5k"`; assertions on the AI bundle are unchanged.)

Change `togglingSideToAIRestoresHumanStyleProfile` — the stored key is now `5k`, and the emitted engine profile becomes `preaz_5k`:
```swift
        config.humanProfileForWhite = "5k"
```
and
```swift
        #expect(texts.contains("> kata-set-param humanSLProfile preaz_5k"))
```
(was `"rank_5k"` and `humanSLProfile rank_5k`.)

In `ios/KataGo iOS/KataGo iOSTests/ConfigModelTests.swift`, `testEffectiveHumanProfileFollowsHumanAIState` and `testIsEqualBlackWhiteEffectiveHumanSettings`: replace every `"rank_5k"` with `"5k"` and every `"proyear_2000"` with `"Pro 2000"` (5 assignments + 2 expectations across both tests — lines ~140-141, 153-154, 159-160, 173). Leave the `"custom_profile"` / `"different_profile"` / `"custom_white_profile"` strings untouched (they intentionally test arbitrary pass-through values).

In `ios/KataGo iOS/KataGo iOSTests/PlayerLabelTests.swift`:
```swift
    @Test func blackWithPositiveThinkingTimeShowsItsHumanProfileName() {
        // humanSLProfile is the black profile accessor.
        let config = Config(humanSLProfile: "9d", optionalBlackMaxTime: 0.5)
        #expect(config.playerLabel(for: .black) == "9d")
    }

    @Test func whiteWithPositiveThinkingTimeShowsItsHumanProfileName() {
        let config = Config(optionalHumanProfileForWhite: "5k",
                            optionalWhiteMaxTime: 0.5)
        #expect(config.playerLabel(for: .white) == "5k")
    }
```
and in `exactlyZeroThinkingTimeIsHumanNotAI` change `humanSLProfile: "rank_9d"` → `humanSLProfile: "9d"`, and in `eachColorIsIndependent` change `"rank_3d"`→`"3d"`, `"rank_7d"`→`"7d"`, and the expectation `== "rank_3d"` → `== "3d"`. (The doc comment on line 13 mentioning `"rank_9d"` may be left or updated to `"9d"`; update it for coherence.)

- [ ] **Step 3: Run the tests to verify they FAIL against the current model**

Run:
```bash
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/HumanSLModelTests" -only-testing:"KataGo AnytimeTests/GtpCommandBuilderTests" -only-testing:"KataGo AnytimeTests/ConfigEngineSyncTests" -only-testing:"KataGo AnytimeTests/PlayerLabelTests" 2>&1 | tail -40
```
Expected: FAIL — e.g. `allProfilesAreCleanUnifiedKeys` ("9d" not found), `rankKeyMapsToPreazEngineProfile`, and the updated `togglingSideToAIRestoresHumanStyleProfile` (`preaz_5k` not emitted by the old model).

- [ ] **Step 4: Rewrite `HumanSLModel.swift`**

Replace the entire contents of `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/HumanSLModel.swift` with:

```swift
//
//  HumanSLModel.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/5/8.
//

import Foundation

/// Maps a clean human-SL **menu key** (`"AI"`, a KGS rank like `"9d"`/`"5k"`, or a
/// pro era like `"Pro 2023"`) to the engine `humanSLProfile` value, the tuned
/// `humanSLChosenMovePiklLambda`, and the `kata-set-param` command list.
///
/// Ranks adopt lightvector/KataGo PR #1209's calibrated KGS-rank ladder
/// (`humanSLProfile = preaz_<rank>` + a per-rank tuned λ). Pros derive from the 9d
/// config with λ 0.06. `AI` is the strongest-net, no-human-bias profile and is
/// preserved byte-for-byte from the previous implementation.
public struct HumanSLModel {

    // MARK: - Profile keys (the key is also the stored value and the display label)

    /// 9d…1d, then 1k…20k.
    private static let rankKeys: [String] =
        (1...9).reversed().map { "\($0)d" } + (1...20).map { "\($0)k" }

    /// "Pro 1800" … "Pro 2023".
    private static let proKeys: [String] = (1800...2023).map { "Pro \($0)" }

    /// All selectable keys, in menu order: AI, ranks (9d→20k), pros (oldest→newest).
    public static let allProfiles: [String] = ["AI"] + rankKeys + proKeys

    // MARK: - PR #1209 tuned λ ladder (keyed by the unified rank key)

    private static let rankLambda: [String: Float] = [
        "9d": 0.045,   "8d": 0.0868,  "7d": 0.1267,  "6d": 0.1983,  "5d": 0.28064,
        "4d": 0.373,   "3d": 0.45556, "2d": 0.5133,  "1d": 0.5093,
        "1k": 0.48988, "2k": 0.46755, "3k": 0.49173, "4k": 0.4713,  "5k": 0.5072,
        "6k": 0.48925, "7k": 0.5337,  "8k": 0.5064,  "9k": 0.5388,  "10k": 0.59036,
        "11k": 0.56458, "12k": 0.54297, "13k": 0.58977, "14k": 0.61625, "15k": 0.61839,
        "16k": 0.6705, "17k": 0.7413, "18k": 0.7821, "19k": 0.8982, "20k": 1.2227,
    ]

    /// Pro profiles derive from the 9d config but use this λ (empirically used by
    /// the old formula's proyear branch).
    private static let proLambda: Float = 0.06

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

    var internal_profile: String

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
    private var isPro: Bool { profile.hasPrefix("Pro ") }

    // MARK: - Engine parameters

    /// Value sent via `kata-set-param humanSLProfile`.
    public var humanSLProfile: String {
        if isAI { return "rank_9d" }
        if isPro { return "proyear_" + String(profile.dropFirst(4)) }   // "Pro 2023" → proyear_2023
        return "preaz_" + profile                                       // "9d" → preaz_9d
    }

    /// Probability of playing a human-like move rather than KataGo's move.
    var humanSLChosenMoveProp: Float { isAI ? 0.0 : 1.0 }

    /// Use the human SL policy for root exploration during search.
    var humanSLRootExploreProbWeightless: Float { isAI ? 0.0 : 0.8 }

    /// AI keeps today's level-9 temperatures (these still affect AI's own move
    /// selection); human profiles use #1209's constants.
    var chosenMoveTemperatureEarly: Float { isAI ? 0.67 : 0.70 }
    var chosenMoveTemperature: Float { isAI ? 0.16 : 0.25 }
    var chosenMoveTemperatureHalflife: Int { isAI ? 26 : 30 }
    var chosenMoveTemperatureOnlyBelowProb: Float { 1.0 }

    /// Suppress human-like moves KataGo disapproves of. AI: 0.06 (no effect since
    /// prop 0); ranks: #1209 tuned ladder; pros: 0.06.
    var humanSLChosenMovePiklLambda: Float {
        if isAI { return 0.06 }
        if isPro { return HumanSLModel.proLambda }
        return HumanSLModel.rankLambda[profile] ?? HumanSLModel.proLambda
    }

    var winLossUtilityFactor: Float { 1.0 }
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
```

- [ ] **Step 5: Run the tests to verify they PASS**

Run:
```bash
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/HumanSLModelTests" -only-testing:"KataGo AnytimeTests/GtpCommandBuilderTests" -only-testing:"KataGo AnytimeTests/ConfigEngineSyncTests" -only-testing:"KataGo AnytimeTests/PlayerLabelTests" -only-testing:"KataGo AnytimeTests/ConfigModelTests" 2>&1 | tail -40
```
Expected: PASS — `** TEST SUCCEEDED **`. In particular `aiProfileEmittedCommandsArePreserved` pins the AI command list (same values as before, cleaner formatting), and `rankLambdaLadderMatches1209` confirms all 29 λ values.

- [ ] **Step 6: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/HumanSLModel.swift" "ios/KataGo iOS/KataGo iOSTests/GtpCommandBuilderTests.swift" "ios/KataGo iOS/KataGo iOSTests/ConfigModelTests.swift" "ios/KataGo iOS/KataGo iOSTests/PlayerLabelTests.swift"
git commit -m "feat(ios): unify human-SL ranks on #1209 ladder + Pro <year>

Consolidate rank_*/preaz_* into single <rank> keys driven by PR #1209's
tuned KGS-rank ladder (preaz_<rank> + per-rank humanSLChosenMovePiklLambda),
rename proyear_<year> to 'Pro <year>' (9d-derived, lambda 0.06), and add
legacy input normalization. AI profile behavior preserved.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WoQvc49FJf5btyZsHLawb3"
```

---

## Task 2: Resolve legacy stored values in the pickers + refresh stale strings

**Why:** `Config` stores raw strings. A game saved before this change may hold
`rank_9d`/`proyear_2000`; the pickers must show the right unified selection (and
re-persist the new key) rather than silently defaulting to AI. Uses
`HumanSLModel.canonicalProfile(_:)` from Task 1.

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/Config/ConfigView.swift` (iOS profile `onAppear`, 2 sites)
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/ConfigEditorViewController.swift` (2 `selectedIndex`)
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/InspectorInfoViewController.swift` (2 `selectedIndex`)
- Modify (comments/preview only): `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Rendering/StoneView.swift`, `ios/KataGo iOS/KataGo iOSUITests/PlayerNameLabelUITests.swift`, `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/ConfigModel.swift`

**Interfaces:**
- Consumes: `HumanSLModel.canonicalProfile(_:)` (Task 1).
- Produces: nothing new; pure call-site wiring + comment refresh.

- [ ] **Step 1: Normalize the iOS `ConfigView` profile `onAppear` (both colors)**

In `ios/KataGo iOS/KataGo iOS/Config/ConfigView.swift`, the Black profile picker `onAppear`:
```swift
                .onAppear {
                    let canonical = HumanSLModel.canonicalProfile(config.humanProfileForBlack)
                    humanProfileForBlack = canonical
                    blackHumanSLModel.profile = canonical
                }
```
and the White profile picker `onAppear`:
```swift
                .onAppear {
                    let canonical = HumanSLModel.canonicalProfile(config.humanProfileForWhite)
                    humanProfileForWhite = canonical
                    whiteHumanSLModel.profile = canonical
                }
```
(The existing `.onChange` handlers are unchanged: when normalization changes the
value, `onChange` fires and persists the new key via `ConfigEngineSync`.)

- [ ] **Step 2: Normalize the macOS `ConfigEditorViewController` popups (both colors)**

In `ios/KataGo iOS/KataGo Anytime Mac/ConfigEditorViewController.swift`, the Black popup `selectedIndex`:
```swift
                selectedIndex: HumanSLModel.allProfiles.firstIndex(of: HumanSLModel.canonicalProfile(config.humanProfileForBlack)) ?? 0,
```
and the White popup `selectedIndex`:
```swift
                selectedIndex: HumanSLModel.allProfiles.firstIndex(of: HumanSLModel.canonicalProfile(config.humanProfileForWhite)) ?? 0,
```

- [ ] **Step 3: Normalize the macOS `InspectorInfoViewController` popups (both colors)**

In `ios/KataGo iOS/KataGo Anytime Mac/InspectorInfoViewController.swift`, apply the identical change to its two `selectedIndex:` lines:
```swift
                selectedIndex: HumanSLModel.allProfiles.firstIndex(of: HumanSLModel.canonicalProfile(config.humanProfileForBlack)) ?? 0,
```
```swift
                selectedIndex: HumanSLModel.allProfiles.firstIndex(of: HumanSLModel.canonicalProfile(config.humanProfileForWhite)) ?? 0,
```

- [ ] **Step 4: Refresh stale profile-string examples in comments/previews**

These are non-functional (comments + a SwiftUI `#Preview`), updated for coherence:

`StoneView.swift`:
- The doc comment example `(e.g. "AI" / "rank_9d")` → `(e.g. "AI" / "9d")`.
- The `#Preview("Captured labels — long profile")` comment `("proyear_1810")` → `("Pro 1810")`.
- That preview's `whitePlayerName: "proyear_1810"` → `whitePlayerName: "Pro 1810"`.

`ConfigModel.swift`:
- The doc comment `as "rank_9d")` → `as "9d")`.

`PlayerNameLabelUITests.swift`:
- The header comment `like "proyear_1817"` → `like "Pro 1817"`. (The test body is profile-name-agnostic — it only checks ≠ "Human" — so no logic change.)

- [ ] **Step 5: Build iOS + macOS to verify the call-site edits compile**

Run:
```bash
xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | tail -5
xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS' -configuration Debug 2>&1 | tail -5
```
Expected: both `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add "ios/KataGo iOS/KataGo iOS/Config/ConfigView.swift" "ios/KataGo iOS/KataGo Anytime Mac/ConfigEditorViewController.swift" "ios/KataGo iOS/KataGo Anytime Mac/InspectorInfoViewController.swift" "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Rendering/StoneView.swift" "ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/ConfigModel.swift" "ios/KataGo iOS/KataGo iOSUITests/PlayerNameLabelUITests.swift"
git commit -m "feat(ios): resolve legacy human-SL profiles in pickers; refresh examples

Pickers canonicalize a possibly-legacy stored profile (rank_*/preaz_*/proyear_*)
to its unified key so saved games show the right selection and re-persist it.
Refresh stale profile-string examples in comments/previews.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WoQvc49FJf5btyZsHLawb3"
```

---

## Task 3: Full verification (3-platform build + full unit suite)

**Files:** none (verification only).

- [ ] **Step 1: Run the full iOS unit test plan**

Run:
```bash
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`, 0 failures. (The pre-existing flaky `PlayerNameLabelUITests` thinking-time test is NOT in the default FastTestPlan and is unrelated — do not chase it.)

- [ ] **Step 2: Build visionOS**

Run:
```bash
xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Confirm iOS + macOS builds (re-run if not already green from Task 2)**

Run:
```bash
xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | tail -5
xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS' -configuration Debug 2>&1 | tail -5
```
Expected: both `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Manual GTP spot-check guidance (record for the reviewer; not automated)**

In the running app, set an AI side's profile to a rank (e.g. `5k`) and a pro
(e.g. `Pro 2023`) and confirm in the GTP log:
- rank → `kata-set-param humanSLProfile preaz_5k`, `humanSLChosenMovePiklLambda 0.5072`, `winLossUtilityFactor 1.0`;
- pro → `kata-set-param humanSLProfile proyear_2023`, `humanSLChosenMovePiklLambda 0.06`;
- the on-board player label reads the clean key (`5k` / `Pro 2023` / `AI`).

(No commit — this task is verification only. If everything is green, proceed to the finishing-a-development-branch step.)

---

## Self-Review (completed by plan author)

- **Spec coverage:** Goal 1 (consolidate rank_/preaz_ → unified `<rank>`, #1209 ladder) → Task 1 (`rankKeys`, `rankLambda`, `humanSLProfile` → `preaz_<rank>`). Goal 2 (`Pro <year>`, 9d-derived, λ 0.06) → Task 1 (`proKeys`, `isPro`, `proLambda`) + `proProfileDerivesFrom9dWithLambda006`. Full-#1209-constant adoption (winLoss 1.0, rootExplore 0.8, constant temps) → Task 1 commands + `humanProfilesUse1209Constants`. AI byte-preservation → `aiProfileEmittedCommandsArePreserved`. Legacy normalization → Task 1 + Task 2 picker wiring. Clean menu labels / blast radius (pickers, player labels, tests) → Tasks 1–2. Three-platform build + verification → Task 3.
- **Placeholder scan:** none — every step has concrete code/commands and expected output.
- **Type consistency:** `canonicalProfile(_:) -> String`, `init?(profile:)`, `allProfiles: [String]`, `commands: [String]` used identically in tests (Task 1) and call sites (Task 2). λ table values match the Global Constraints ladder and the test's `expected` dict.
