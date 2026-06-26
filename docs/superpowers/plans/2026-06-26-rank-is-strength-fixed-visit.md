# Rank Is Strength — Fixed-Visit Human Play Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a human-profile engine move search a fixed 400 visits (PR #1209's calibration point) so a rank plays at its calibrated strength regardless of device/thinking-time, while "Time per move" applies only to the full-strength `AI` profile.

**Architecture:** One engine-layer change in the shared `KataGoUICore` (a search-budget helper feeding `GtpCommandBuilder.genMoveAnalyzeCommands`, wired through the single `GobanState.getRequestAnalysisCommands` chokepoint, with a `maxVisits` reset on the continuous-analysis branch so analysis stays unbounded) plus a per-side UI change (show a "Time per move" stepper for the `AI` profile, an "Engine plays this side" toggle for human profiles) on iOS `ConfigView` and the two macOS config panes.

**Tech Stack:** Swift 6, SwiftUI (iOS/visionOS) + AppKit (macOS), Swift Testing (`import Testing`, `#expect`), `xcodebuild`.

## Global Constraints

- **Frozen SwiftData schema** — do NOT change `Config`/`GameRecord` `@Model` fields. `blackMaxTime`/`whiteMaxTime` are reused as the engine-on/off flag (`> 0` = engine plays the side, `= 0` = a human plays it). (project memory: never modify SwiftData models)
- **Fixed visit budget = 400** for human profiles (the #1209 calibration point). Constants: `humanSLPlayMaxVisits = 400`, `unboundedMaxVisits = 1_000_000_000`, `humanSLPlaySafetyMaxTime: Float = 60`.
- **Continuous analysis stays unbounded** — every exit of `getRequestAnalysisCommands` sets `maxVisits` explicitly so a prior human move's `maxVisits = 400` never leaks into analysis.
- **`AI` profile behavior unchanged** — AI moves stay time-budgeted (`maxTime`, floored at 0.5s) with unbounded visits.
- **All three platforms** — the engine seam is shared (`GobanState`/`GtpCommandBuilder`), so iOS, visionOS, and the macOS subprocess engine all get the budget change.
- **Engine on/off via the existing time field** — the human-profile toggle maps on/off to `maxTime` `Config.toggleAIThinkingTime (0.5) ↔ 0`, identical to the board player-label tap.
- **Test framework is Swift Testing**; new unit tests are appended to the already-registered `GtpCommandBuilderTests.swift` (no `project.pbxproj` edit).

**Paths** (commands assume cwd = repo root `/Users/chinchangyang/Code/KataGo-ios-dev`):
- Engine: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Session/GtpCommandBuilder.swift`, `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/GobanState.swift`
- Tests: `ios/KataGo iOS/KataGo iOSTests/GtpCommandBuilderTests.swift`
- iOS UI: `ios/KataGo iOS/KataGo iOS/Config/ConfigView.swift`
- macOS UI: `ios/KataGo iOS/KataGo Anytime Mac/ConfigEditorViewController.swift`, `ios/KataGo iOS/KataGo Anytime Mac/InspectorInfoViewController.swift`

---

## Task 1: Search-budget helper + budget-aware `genMoveAnalyzeCommands`

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Session/GtpCommandBuilder.swift`
- Test: `ios/KataGo iOS/KataGo iOSTests/GtpCommandBuilderTests.swift`

**Interfaces:**
- Produces:
  - `GtpCommandBuilder.unboundedMaxVisits: Int` (`1_000_000_000`), `GtpCommandBuilder.humanSLPlayMaxVisits: Int` (`400`), `GtpCommandBuilder.humanSLPlaySafetyMaxTime: Float` (`60`).
  - `GtpCommandBuilder.searchBudgetCommands(effectiveProfile: String, maxTime: Float) -> [String]`.
  - `GtpCommandBuilder.genMoveAnalyzeCommands(effectiveProfile: String, maxTime: Float, interval: Int, maxMoves: Int) -> [String]` (signature gains `effectiveProfile`).

- [ ] **Step 1: Write the failing tests** — append to the `GtpCommandBuilderTests` struct in `ios/KataGo iOS/KataGo iOSTests/GtpCommandBuilderTests.swift`:

```swift
    @Test func searchBudgetForAIProfileIsTimeBoundedUnboundedVisits() {
        #expect(GtpCommandBuilder.searchBudgetCommands(effectiveProfile: "AI", maxTime: 2.0)
                == ["kata-set-param maxVisits 1000000000",
                    "kata-set-param maxTime 2.0"])
        // maxTime is floored at 0.5 for the AI profile.
        #expect(GtpCommandBuilder.searchBudgetCommands(effectiveProfile: "AI", maxTime: 0.0)
                == ["kata-set-param maxVisits 1000000000",
                    "kata-set-param maxTime 0.5"])
    }

    @Test func searchBudgetForHumanProfileIsFixed400VisitsIgnoringTime() {
        let expected = ["kata-set-param maxVisits 400",
                        "kata-set-param maxTime 60.0"]
        // The time magnitude is irrelevant for a human profile.
        #expect(GtpCommandBuilder.searchBudgetCommands(effectiveProfile: "9d", maxTime: 0.5) == expected)
        #expect(GtpCommandBuilder.searchBudgetCommands(effectiveProfile: "9d", maxTime: 30.0) == expected)
        #expect(GtpCommandBuilder.searchBudgetCommands(effectiveProfile: "Pro 1800", maxTime: 0.5) == expected)
    }

    @Test func genMoveAnalyzeCommandsPrependsBudget() {
        #expect(GtpCommandBuilder.genMoveAnalyzeCommands(effectiveProfile: "AI", maxTime: 0.5, interval: 50, maxMoves: 50)
                == ["kata-set-param maxVisits 1000000000",
                    "kata-set-param maxTime 0.5",
                    "kata-search_analyze_cancellable interval 50 maxmoves 50 ownership true ownershipStdev true rootInfo true"])
        #expect(GtpCommandBuilder.genMoveAnalyzeCommands(effectiveProfile: "5k", maxTime: 3.0, interval: 25, maxMoves: 30)
                == ["kata-set-param maxVisits 400",
                    "kata-set-param maxTime 60.0",
                    "kata-search_analyze_cancellable interval 25 maxmoves 30 ownership true ownershipStdev true rootInfo true"])
    }
```

- [ ] **Step 2: Update the two existing `genMoveAnalyzeCommands` call sites in the same file** (they call the old signature and will no longer compile). In `builderMatchesConfigForArrayCommands`, replace the config-a assertion:

```swift
        // config a: blackMaxTime=0, profile "AI" → unbounded visits, maxTime floored to 0.5
        #expect(GtpCommandBuilder.genMoveAnalyzeCommands(effectiveProfile: a.effectiveHumanProfileForBlack, maxTime: a.blackMaxTime, interval: a.analysisInterval, maxMoves: a.maxAnalysisMoves)
                == ["kata-set-param maxVisits 1000000000",
                    "kata-set-param maxTime 0.5",
                    "kata-search_analyze_cancellable interval 50 maxmoves 50 ownership true ownershipStdev true rootInfo true"])
```

and the config-b assertion:

```swift
        // config b: blackMaxTime=3, profile "AI" → unbounded visits, maxTime 3.0
        #expect(GtpCommandBuilder.genMoveAnalyzeCommands(effectiveProfile: b.effectiveHumanProfileForBlack, maxTime: b.blackMaxTime, interval: b.analysisInterval, maxMoves: b.maxAnalysisMoves)
                == ["kata-set-param maxVisits 1000000000",
                    "kata-set-param maxTime 3.0",
                    "kata-search_analyze_cancellable interval 25 maxmoves 30 ownership true ownershipStdev true rootInfo true"])
```

- [ ] **Step 3: Run tests — expect FAIL** (compile error: `searchBudgetCommands` undefined / `genMoveAnalyzeCommands` signature mismatch):

```bash
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/GtpCommandBuilderTests" 2>&1 | tail -25
```

- [ ] **Step 4: Implement in `GtpCommandBuilder.swift`.** Add the constants + helper near the top of the enum, and rewrite `genMoveAnalyzeCommands`:

```swift
    // MARK: - Search budget

    /// Effectively-unbounded visit cap (the engine never reaches it within a move).
    public static let unboundedMaxVisits = 1_000_000_000
    /// Fixed visit budget for human-SL profile play — PR #1209's calibration point,
    /// at which the rank λ ladder is ~1 KGS stone apart.
    public static let humanSLPlayMaxVisits = 400
    /// Backstop wall-clock for a human-SL move so a slow device/large net cannot
    /// hang; on normal devices the 400 visits bind first.
    public static let humanSLPlaySafetyMaxTime: Float = 60

    /// The `(maxVisits, maxTime)` search-budget commands for a side's move.
    /// The `AI` profile is time-bounded with unbounded visits (today's behavior);
    /// a human rank/pro profile is fixed at `humanSLPlayMaxVisits` visits (the
    /// "Time per move" magnitude is ignored), with a safety time cap.
    public static func searchBudgetCommands(effectiveProfile: String, maxTime: Float) -> [String] {
        if effectiveProfile == "AI" {
            return ["kata-set-param maxVisits \(unboundedMaxVisits)",
                    "kata-set-param maxTime \(max(maxTime, 0.5))"]
        } else {
            return ["kata-set-param maxVisits \(humanSLPlayMaxVisits)",
                    "kata-set-param maxTime \(humanSLPlaySafetyMaxTime)"]
        }
    }

    public static func genMoveAnalyzeCommands(effectiveProfile: String, maxTime: Float, interval: Int, maxMoves: Int) -> [String] {
        return searchBudgetCommands(effectiveProfile: effectiveProfile, maxTime: maxTime)
            + ["kata-search_analyze_cancellable interval \(interval) maxmoves \(maxMoves) ownership true ownershipStdev true rootInfo true"]
    }
```

(Delete the old `genMoveAnalyzeCommands` body that emitted the lone `kata-set-param maxTime …`.)

- [ ] **Step 5: Run tests — expect PASS:**

```bash
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/GtpCommandBuilderTests" 2>&1 | tail -25
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit:**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Session/GtpCommandBuilder.swift" "ios/KataGo iOS/KataGo iOSTests/GtpCommandBuilderTests.swift"
git commit -m "feat(ios): fixed 400-visit search budget for human-SL profile moves

Add GtpCommandBuilder.searchBudgetCommands: AI profile stays time-bounded
with unbounded visits; human rank/pro profiles use a fixed 400 visits
(#1209 calibration point) + a safety time cap, ignoring Time per move.
genMoveAnalyzeCommands now takes the effective profile.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WoQvc49FJf5btyZsHLawb3"
```

---

## Task 2: Wire the budget through `getRequestAnalysisCommands` + reset analysis visits

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/GobanState.swift` (`getRequestAnalysisCommands`, ~lines 80–91)
- Test: `ios/KataGo iOS/KataGo iOSTests/GtpCommandBuilderTests.swift`

**Interfaces:**
- Consumes: `GtpCommandBuilder.genMoveAnalyzeCommands(effectiveProfile:…)`, `GtpCommandBuilder.unboundedMaxVisits`, `Config.effectiveHumanProfileForBlack/White` (existing).
- Produces: `GobanState.getRequestAnalysisCommands(config:nextColorForPlayCommand:)` becomes **internal** (was `private`) and budget-aware.

- [ ] **Step 1: Write the failing tests** — append a new struct to `ios/KataGo iOS/KataGo iOSTests/GtpCommandBuilderTests.swift`:

```swift
// MARK: - GobanState search-budget routing (gen-move vs continuous analysis)

@MainActor
struct AnalysisBudgetRoutingTests {

    private func runningState() -> GobanState {
        let s = GobanState()
        s.analysisStatus = .run
        return s
    }

    @Test func aiSideGenMoveIsTimeBoundedUnboundedVisits() {
        let config = Config()                 // default profile "AI"
        config.blackMaxTime = 2.0             // engine plays Black
        let cmds = runningState().getRequestAnalysisCommands(config: config, nextColorForPlayCommand: .black)
        #expect(cmds == ["kata-set-param maxVisits 1000000000",
                         "kata-set-param maxTime 2.0",
                         "kata-search_analyze_cancellable interval 50 maxmoves 50 ownership true ownershipStdev true rootInfo true"])
    }

    @Test func humanSideGenMoveIsFixed400VisitsIgnoringTime() {
        let config = Config()
        config.humanProfileForBlack = "9d"
        config.blackMaxTime = 0.5            // engine plays Black as 9d; magnitude ignored
        let cmds = runningState().getRequestAnalysisCommands(config: config, nextColorForPlayCommand: .black)
        #expect(cmds == ["kata-set-param maxVisits 400",
                         "kata-set-param maxTime 60.0",
                         "kata-search_analyze_cancellable interval 50 maxmoves 50 ownership true ownershipStdev true rootInfo true"])
    }

    @Test func continuousAnalysisResetsVisitsToUnbounded() {
        let config = Config()                 // blackMaxTime 0 → human plays → analysis branch
        let cmds = runningState().getRequestAnalysisCommands(config: config, nextColorForPlayCommand: .black)
        #expect(cmds == ["kata-set-param maxVisits 1000000000",
                         "kata-analyze interval 10 maxmoves 50 ownership true ownershipStdev true rootInfo true"])
    }
}
```

- [ ] **Step 2: Run tests — expect FAIL** (`getRequestAnalysisCommands` is `private`, inaccessible; and the analysis branch doesn't yet reset visits):

```bash
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/AnalysisBudgetRoutingTests" 2>&1 | tail -25
```

- [ ] **Step 3: Implement** — in `GobanState.swift`, change `getRequestAnalysisCommands` from `private func` to `func` (internal) and rewrite its body:

```swift
    func getRequestAnalysisCommands(config: Config, nextColorForPlayCommand: PlayerColor?) -> [String] {

        if (analysisStatus == .run) && (!isAutoPlaying) && (passCount < 2) {
            if (nextColorForPlayCommand == .black) && (config.blackMaxTime > 0) {
                return GtpCommandBuilder.genMoveAnalyzeCommands(effectiveProfile: config.effectiveHumanProfileForBlack, maxTime: config.blackMaxTime, interval: config.analysisInterval, maxMoves: config.maxAnalysisMoves)
            } else if (nextColorForPlayCommand == .white) && (config.whiteMaxTime > 0) {
                return GtpCommandBuilder.genMoveAnalyzeCommands(effectiveProfile: config.effectiveHumanProfileForWhite, maxTime: config.whiteMaxTime, interval: config.analysisInterval, maxMoves: config.maxAnalysisMoves)
            }
        }

        // Continuous analysis: reset the visit cap to unbounded so a prior human
        // gen-move's maxVisits=400 never leaks into (and caps) analysis.
        return ["kata-set-param maxVisits \(GtpCommandBuilder.unboundedMaxVisits)",
                GtpCommandBuilder.fastAnalyzeCommand(maxMoves: config.maxAnalysisMoves)]
    }
```

- [ ] **Step 4: Audit for other bare-`kata-analyze` sites.** Run:

```bash
grep -rn "fastAnalyzeCommand\|analyzeCommand\|kata-analyze\|kata-search_analyze" "ios/KataGo iOS/KataGoUICore" "ios/KataGo iOS/KataGo Anytime Mac" --include=*.swift | grep -v DerivedData
```
The only move/analysis arming path that follows a played move is `getRequestAnalysisCommands` (now reset). If the grep shows another site that issues a bare `kata-analyze`/`fastAnalyzeCommand` directly after a move (not through `getRequestAnalysisCommands`), prepend `"kata-set-param maxVisits \(GtpCommandBuilder.unboundedMaxVisits)"` there too. (Initial-analysis/showboard paths that run before any human gen-move need no reset — `default_gtp.cfg` leaves visits unbounded.) Note any site you changed in the commit body.

- [ ] **Step 5: Run tests — expect PASS:**

```bash
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/AnalysisBudgetRoutingTests" -only-testing:"KataGo AnytimeTests/GtpCommandBuilderTests" 2>&1 | tail -25
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit:**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/GobanState.swift" "ios/KataGo iOS/KataGo iOSTests/GtpCommandBuilderTests.swift"
git commit -m "feat(ios): route per-side search budget; keep analysis unbounded

getRequestAnalysisCommands passes the side's effective profile to the
gen-move builder (human profiles -> 400 visits, AI -> time) and resets
maxVisits to unbounded on the continuous-analysis branch so analysis is
never capped by a prior human move.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WoQvc49FJf5btyZsHLawb3"
```

---

## Task 3: iOS `ConfigView` — stepper for `AI`, "Engine plays" toggle for human profiles

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/Config/ConfigView.swift` (Black block ~437–465, White block ~472–499)

**Interfaces:**
- Consumes: `Config.toggleAIThinkingTime` (0.5), `ConfigEngineSync.setBlackMaxTime/setWhiteMaxTime`, `HumanSLModel.canonicalProfile` (existing).
- Produces: conditional per-side control (no new public API).

- [ ] **Step 1: Replace the Black profile + time block** (the `HumanStylePicker` for Black and the `ConfigFloatItem` "Time per move" that follows it) with:

```swift
            HumanStylePicker(title: "Human profile", humanSLProfile: $humanProfileForBlack)
                .onAppear {
                    let canonical = HumanSLModel.canonicalProfile(config.humanProfileForBlack)
                    humanProfileForBlack = canonical
                    blackHumanSLModel.profile = canonical
                    blackMaxTime = config.blackMaxTime   // seed for both stepper and toggle
                }
                .onChange(of: humanProfileForBlack) { _, newValue in
                    blackHumanSLModel.profile = newValue
                    ConfigEngineSync.setBlackHumanProfile(newValue, config: config, player: player, messageList: messageList)
                }

            if humanProfileForBlack == "AI" {
                ConfigFloatItem(title: "Time per move",
                                value: $blackMaxTime,
                                step: 0.5,
                                minValue: 0,
                                maxValue: 60,
                                format: .number,
                                postFix: "s",
                                stepperAccessibilityID: "blackTimePerMove")
                .onChange(of: blackMaxTime) { _, newValue in
                    ConfigEngineSync.setBlackMaxTime(newValue, config: config, gobanState: gobanState,
                                                     player: player, messageList: messageList)
                }
            } else {
                Toggle("Engine plays this side", isOn: Binding(
                    get: { blackMaxTime > 0 },
                    set: { isOn in
                        let newTime: Float = isOn ? Config.toggleAIThinkingTime : 0
                        blackMaxTime = newTime
                        ConfigEngineSync.setBlackMaxTime(newTime, config: config, gobanState: gobanState,
                                                         player: player, messageList: messageList)
                    }))
                .accessibilityIdentifier("blackEnginePlays")
            }
```

(Note: the `blackMaxTime` seed moved into the picker's `onAppear` so it is set regardless of which control renders; the old `ConfigFloatItem.onAppear { blackMaxTime = config.blackMaxTime }` is removed.)

- [ ] **Step 2: Replace the White profile + time block** identically, with the White bindings/helpers:

```swift
            HumanStylePicker(title: "Human profile", humanSLProfile: $humanProfileForWhite)
                .onAppear {
                    let canonical = HumanSLModel.canonicalProfile(config.humanProfileForWhite)
                    humanProfileForWhite = canonical
                    whiteHumanSLModel.profile = canonical
                    whiteMaxTime = config.whiteMaxTime
                }
                .onChange(of: humanProfileForWhite) { _, newValue in
                    whiteHumanSLModel.profile = newValue
                    ConfigEngineSync.setWhiteHumanProfile(newValue, config: config, player: player, messageList: messageList)
                }

            if humanProfileForWhite == "AI" {
                ConfigFloatItem(title: "Time per move",
                                value: $whiteMaxTime,
                                step: 0.5,
                                minValue: 0,
                                maxValue: 60,
                                format: .number,
                                postFix: "s",
                                stepperAccessibilityID: "whiteTimePerMove")
                .onChange(of: whiteMaxTime) { _, newValue in
                    ConfigEngineSync.setWhiteMaxTime(newValue, config: config, gobanState: gobanState,
                                                     player: player, messageList: messageList)
                }
            } else {
                Toggle("Engine plays this side", isOn: Binding(
                    get: { whiteMaxTime > 0 },
                    set: { isOn in
                        let newTime: Float = isOn ? Config.toggleAIThinkingTime : 0
                        whiteMaxTime = newTime
                        ConfigEngineSync.setWhiteMaxTime(newTime, config: config, gobanState: gobanState,
                                                         player: player, messageList: messageList)
                    }))
                .accessibilityIdentifier("whiteEnginePlays")
            }
```

- [ ] **Step 3: Build iOS to verify it compiles:**

```bash
xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`. (The default profile is `AI`, so the `blackTimePerMove`/`whiteTimePerMove` steppers the existing `PlayerNameLabelUITests` drives still render — no UI-test break.)

- [ ] **Step 4: Commit:**

```bash
git add "ios/KataGo iOS/KataGo iOS/Config/ConfigView.swift"
git commit -m "feat(ios): config shows time stepper for AI, engine toggle for ranks

Per side, the AI profile keeps the Time per move stepper; a human rank/pro
profile shows an 'Engine plays this side' toggle (on/off = 0.5/0), since the
time magnitude no longer affects human-profile strength (fixed 400 visits).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WoQvc49FJf5btyZsHLawb3"
```

---

## Task 4: macOS config panes — same conditional + rebuild on profile change

**Files:**
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/ConfigEditorViewController.swift` (`addAISection`, ~331–428; add a `rebuildForm()`)
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/InspectorInfoViewController.swift` (`addAISection`, ~278–340; reuse existing `rebuildForm()`)

**Interfaces:**
- Consumes: `ConfigFormBuilder.numericRow/checkboxRow/popupRow`, `Config.toggleAIThinkingTime`, `HumanSLModel.canonicalProfile`, `ConfigEngineSync.setBlack/WhiteHumanProfile` + `setBlack/WhiteMaxTime` (existing). `config` is `gameRecord.concreteConfig` (the persisted source of truth), so a rebuild after a profile change reflects the new value.

- [ ] **Step 1: ConfigEditorViewController — add a form rebuild.** Add this method (next to `buildForm`):

```swift
    private func rebuildForm() {
        for subview in formStack.arrangedSubviews {
            formStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        buildForm()
    }
```

- [ ] **Step 2: ConfigEditorViewController — make each side's AI control conditional + rebuild on profile change.** In `addAISection`, replace the Black `popupRow` + `numericRow` pair with (and the White pair analogously, using `humanProfileForWhite`/`setWhiteHumanProfile`/`whiteMaxTime`/`setWhiteMaxTime`):

```swift
        formStack.addArrangedSubview(
            ConfigFormBuilder.popupRow(
                title: "Human profile",
                options: HumanSLModel.allProfiles,
                selectedIndex: HumanSLModel.allProfiles.firstIndex(of: HumanSLModel.canonicalProfile(config.humanProfileForBlack)) ?? 0,
                onChange: { [weak self] index in
                    guard let self else { return }
                    let profile = HumanSLModel.allProfiles[index]
                    ConfigEngineSync.setBlackHumanProfile(profile, config: config,
                                                          player: self.player, messageList: self.messageList)
                    // Defer the rebuild so the popup's own action completes before
                    // its row is torn down.
                    DispatchQueue.main.async { [weak self] in self?.rebuildForm() }
                }))

        if HumanSLModel.canonicalProfile(config.humanProfileForBlack) == "AI" {
            formStack.addArrangedSubview(
                ConfigFormBuilder.numericRow(
                    title: "Time per move",
                    value: Double(config.blackMaxTime),
                    minValue: 0,
                    maxValue: 60,
                    step: 0.5,
                    format: { Self.secondsText(Float($0)) },
                    onChange: { [weak self] newValue in
                        guard let self else { return }
                        ConfigEngineSync.setBlackMaxTime(Float(newValue), config: config,
                                                         gobanState: self.gobanState,
                                                         player: self.player,
                                                         messageList: self.messageList)
                    }))
        } else {
            formStack.addArrangedSubview(
                ConfigFormBuilder.checkboxRow(
                    title: "Engine plays this side",
                    isOn: config.blackMaxTime > 0,
                    onChange: { [weak self] isOn in
                        guard let self else { return }
                        let newTime: Float = isOn ? Config.toggleAIThinkingTime : 0
                        ConfigEngineSync.setBlackMaxTime(newTime, config: config,
                                                         gobanState: self.gobanState,
                                                         player: self.player,
                                                         messageList: self.messageList)
                    }))
        }
```

- [ ] **Step 3: InspectorInfoViewController — same conditional, reusing the existing `rebuildForm()`.** In `addAISection`, for the Black popup add `DispatchQueue.main.async { [weak self] in self?.rebuildForm() }` after `setBlackHumanProfile`, and replace its `numericRow("Black time/move")` with the conditional (White analogously):

```swift
        if HumanSLModel.canonicalProfile(config.humanProfileForBlack) == "AI" {
            formStack.addArrangedSubview(
                ConfigFormBuilder.numericRow(
                    title: "Black time/move",
                    value: Double(config.blackMaxTime),
                    minValue: 0,
                    maxValue: 60,
                    step: 0.5,
                    format: { Self.secondsText(Float($0)) },
                    onChange: { [weak self] newValue in
                        guard let self else { return }
                        ConfigEngineSync.setBlackMaxTime(Float(newValue), config: config,
                                                         gobanState: self.gobanState,
                                                         player: self.player,
                                                         messageList: self.messageList)
                    }))
        } else {
            formStack.addArrangedSubview(
                ConfigFormBuilder.checkboxRow(
                    title: "Black engine plays",
                    isOn: config.blackMaxTime > 0,
                    onChange: { [weak self] isOn in
                        guard let self else { return }
                        let newTime: Float = isOn ? Config.toggleAIThinkingTime : 0
                        ConfigEngineSync.setBlackMaxTime(newTime, config: config,
                                                         gobanState: self.gobanState,
                                                         player: self.player,
                                                         messageList: self.messageList)
                    }))
        }
```

(`Self.secondsText` already exists in both controllers — it's used by the current `numericRow` time rows.)

- [ ] **Step 4: Build macOS to verify it compiles:**

```bash
xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS' -configuration Debug 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit:**

```bash
git add "ios/KataGo iOS/KataGo Anytime Mac/ConfigEditorViewController.swift" "ios/KataGo iOS/KataGo Anytime Mac/InspectorInfoViewController.swift"
git commit -m "feat(macOS): config panes show time stepper for AI, engine toggle for ranks

Both Mac config panes render a Time-per-move stepper for the AI profile and
an Engine-plays checkbox for human rank/pro profiles, rebuilding the form on
profile change (ConfigEditorViewController gains rebuildForm; Inspector reuses
its existing one).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WoQvc49FJf5btyZsHLawb3"
```

---

## Task 5: Full verification (3-platform build + full unit suite)

**Files:** none (verification only).

- [ ] **Step 1: Full iOS unit suite:**

```bash
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`, 0 failures.

- [ ] **Step 2: visionOS + macOS builds:**

```bash
xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug 2>&1 | tail -5
xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS' -configuration Debug 2>&1 | tail -5
```
Expected: both `** BUILD SUCCEEDED **`. (iOS Debug build already covered by Task 3 Step 3; re-run if anything changed since.)

- [ ] **Step 3: Manual spot-check guidance (record for reviewer; not automated).** In the running app: set a side to `9d` + Engine-on; confirm via the visits/s overlay or move latency that a move searches ~400 visits regardless of the toggle; switch the side to `AI` and confirm the Time-per-move stepper returns and bounds the move; confirm the continuous-analysis overlay keeps refining past 400 visits after a human move (not capped).

---

## Self-Review (completed by plan author)

- **Spec coverage:** Goal 1 (fixed 400-visit human move) → Task 1 `searchBudgetCommands` + Task 2 routing. Goal 2 (`AI` keeps time) → Task 1 AI branch. Goal 3 (analysis unbounded) → Task 2 reset + Task 2 Step 4 audit + `continuousAnalysisResetsVisitsToUnbounded`. Goal 4 (UI stops showing irrelevant time for human profiles) → Tasks 3 (iOS) + 4 (macOS, both panes). Constants/values, frozen-schema reuse of `maxTime`, all-platform shared seam, test-append-no-pbxproj → Global Constraints honored across tasks. Verification → Task 5.
- **Placeholder scan:** none — every code step shows complete code; every command has expected output.
- **Type consistency:** `searchBudgetCommands(effectiveProfile:maxTime:)`, `genMoveAnalyzeCommands(effectiveProfile:maxTime:interval:maxMoves:)`, `unboundedMaxVisits`/`humanSLPlayMaxVisits`/`humanSLPlaySafetyMaxTime`, and `getRequestAnalysisCommands(config:nextColorForPlayCommand:)` are used identically in their defining task and all consumers/tests. Emitted strings (`maxVisits 1000000000`, `maxVisits 400`, `maxTime 60.0`, `maxTime 0.5`) match between the helper, the routing, and the test expectations.
