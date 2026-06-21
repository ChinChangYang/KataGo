# Power-Saving Analysis Pause Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pause continuous `kata-analyze` when a person plays the AI and the analysis overlay is hidden on the human's turn, to save battery/thermal cost.

**Architecture:** One pure predicate on `GobanState` (`isAnalysisHiddenForPowerSaving`) is the single source of truth. It gates the shared request path (`shouldRequestAnalysis`) and the iOS/visionOS continuous re-issue loop and resume-on-reveal wiring in `GameSplitView`. The predicate is a compile-time no-op on macOS, so the Mac app is unchanged.

**Tech Stack:** Swift, SwiftUI, SwiftData; KataGo GTP engine; Swift Testing for unit tests; Xcode project `KataGo Anytime.xcodeproj`.

**Spec:** `docs/superpowers/specs/2026-06-21-power-saving-analysis-pause-design.md`

## Global Constraints

- Platforms: **iOS + visionOS only** (the `KataGo Anytime` app target / `GameSplitView`). macOS (`KataGo Anytime Mac`) must remain behaviorally unchanged — the predicate returns `false` under `#if os(macOS)`.
- Pause **only** when all hold: `eyeStatus != .opened`, exactly one of `config.blackMaxTime`/`config.whiteMaxTime` is `> 0` (mixed human-vs-AI), and it is the human's turn (side to move has time `0`, opponent `> 0`).
- Never change: both-human games, both-AI games, the AI's own turn, or the eye-`.opened` case.
- **Do not modify any SwiftData `@Model` schema** (`Config`/`GameRecord`). This plan does not touch them.
- New `.swift` files must be registered in `project.pbxproj` (no synchronized groups). Test target: `KataGo AnytimeTests`; tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`); test module name is `KataGo_Anytime`.
- All build/test commands run from `ios/KataGo iOS/`.

---

### Task 1: Predicate `isAnalysisHiddenForPowerSaving` + unit tests

**Files:**
- Create: `ios/KataGo iOS/KataGo iOSTests/AnalysisPowerSavingTests.swift`
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/GobanState.swift` (add method after `shouldRequestAnalysis`, ~line 123)
- Modify: `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj` (register the test file)

**Interfaces:**
- Produces: `GobanState.isAnalysisHiddenForPowerSaving(config: Config, nextColorForPlayCommand: PlayerColor?) -> Bool` — `true` only in the power-saving case described in Global Constraints; `false` everywhere else and on macOS.

- [ ] **Step 1: Create the failing test file**

Create `ios/KataGo iOS/KataGo iOSTests/AnalysisPowerSavingTests.swift`:

```swift
//
//  AnalysisPowerSavingTests.swift
//  KataGo AnytimeTests
//

import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

/// Power-saving pauses continuous analysis only when a human is playing the AI
/// (exactly one side has a positive per-move thinking time), the analysis
/// overlay is hidden (eye `.book`/`.closed`), and it is the human's turn. Every
/// other combination keeps analysis running.
struct AnalysisPowerSavingTests {

    /// Black human (0s) vs White AI (2s).
    private func mixedHumanBlackVsAIWhite() -> Config {
        Config(optionalBlackMaxTime: 0.0, optionalWhiteMaxTime: 2.0)
    }

    // MARK: - Pauses (the only cases that return true)

    @Test func pausesWhenHumanToMoveAndEyeClosed() {
        let state = GobanState()
        state.eyeStatus = .closed
        #expect(state.isAnalysisHiddenForPowerSaving(
            config: mixedHumanBlackVsAIWhite(),
            nextColorForPlayCommand: .black) == true)
    }

    @Test func pausesWhenHumanToMoveAndEyeBook() {
        let state = GobanState()
        state.eyeStatus = .book
        #expect(state.isAnalysisHiddenForPowerSaving(
            config: mixedHumanBlackVsAIWhite(),
            nextColorForPlayCommand: .black) == true)
    }

    @Test func pausesWhenHumanIsWhiteToMove() {
        // White human (0s) vs Black AI (1s), white to move, eye closed.
        let config = Config(optionalBlackMaxTime: 1.0, optionalWhiteMaxTime: 0.0)
        let state = GobanState()
        state.eyeStatus = .closed
        #expect(state.isAnalysisHiddenForPowerSaving(
            config: config, nextColorForPlayCommand: .white) == true)
    }

    // MARK: - Keeps running

    @Test func runsWhenEyeOpened() {
        let state = GobanState()
        state.eyeStatus = .opened
        #expect(state.isAnalysisHiddenForPowerSaving(
            config: mixedHumanBlackVsAIWhite(),
            nextColorForPlayCommand: .black) == false)
    }

    @Test func runsOnAITurnEvenWhenHidden() {
        // Mixed game, but it's the AI's (white's) turn — keep running so the
        // engine can generate the AI move.
        let state = GobanState()
        state.eyeStatus = .closed
        #expect(state.isAnalysisHiddenForPowerSaving(
            config: mixedHumanBlackVsAIWhite(),
            nextColorForPlayCommand: .white) == false)
    }

    @Test func runsForBothHumanGame() {
        let config = Config(optionalBlackMaxTime: 0.0, optionalWhiteMaxTime: 0.0)
        let state = GobanState()
        state.eyeStatus = .closed
        #expect(state.isAnalysisHiddenForPowerSaving(
            config: config, nextColorForPlayCommand: .black) == false)
        #expect(state.isAnalysisHiddenForPowerSaving(
            config: config, nextColorForPlayCommand: .white) == false)
    }

    @Test func runsForBothAIGame() {
        let config = Config(optionalBlackMaxTime: 1.0, optionalWhiteMaxTime: 2.0)
        let state = GobanState()
        state.eyeStatus = .closed
        #expect(state.isAnalysisHiddenForPowerSaving(
            config: config, nextColorForPlayCommand: .black) == false)
        #expect(state.isAnalysisHiddenForPowerSaving(
            config: config, nextColorForPlayCommand: .white) == false)
    }

    @Test func runsWhenNextColorIsNilOrUnknown() {
        let state = GobanState()
        state.eyeStatus = .closed
        #expect(state.isAnalysisHiddenForPowerSaving(
            config: mixedHumanBlackVsAIWhite(),
            nextColorForPlayCommand: nil) == false)
        #expect(state.isAnalysisHiddenForPowerSaving(
            config: mixedHumanBlackVsAIWhite(),
            nextColorForPlayCommand: .unknown) == false)
    }
}
```

- [ ] **Step 2: Register the test file in the Xcode project**

Run from `ios/KataGo iOS/`:

```bash
ruby -e '
require "xcodeproj"
proj   = Xcodeproj::Project.open("KataGo Anytime.xcodeproj")
target = proj.targets.find { |t| t.name == ARGV[0] }
anchor = proj.files.find { |f| f.path == ARGV[1] }
group  = anchor.parent
fname  = ARGV[2]
unless proj.files.any? { |f| f.path == fname }
  ref = group.new_file(fname)
  target.source_build_phase.add_file_reference(ref, true)
end
proj.save
' "KataGo AnytimeTests" "NavigationContextTests.swift" "AnalysisPowerSavingTests.swift"
```

Expected: command exits 0; `git diff --stat` shows `project.pbxproj` modified. (If `xcodeproj` gem is missing: `gem install --user-install xcodeproj`; Ruby is at `/usr/local/opt/ruby`.)

- [ ] **Step 3: Run the tests to verify they FAIL**

Run:

```bash
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/AnalysisPowerSavingTests" 2>&1 | tail -30
```

Expected: **compile failure** — `value of type 'GobanState' has no member 'isAnalysisHiddenForPowerSaving'`.

- [ ] **Step 4: Implement the predicate**

In `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/GobanState.swift`, insert this method immediately after the closing brace of `shouldRequestAnalysis(config:nextColorForPlayCommand:)` (currently ends at ~line 123):

```swift
    /// Continuous analysis is hidden AND pointless to run, so it can be paused
    /// to save power: a human-vs-AI game (exactly one side has a positive
    /// per-move thinking time), the analysis overlay is not visible
    /// (eye `.book`/`.closed`), and it is the human's turn. The AI's own turn is
    /// never suppressed — the engine must still `genmove` — and both-human /
    /// both-AI games are unaffected. No-op on macOS, whose always-on analysis is
    /// intentionally left unchanged.
    public func isAnalysisHiddenForPowerSaving(config: Config,
                                               nextColorForPlayCommand: PlayerColor?) -> Bool {
        #if os(macOS)
        return false
        #else
        guard eyeStatus != .opened, let nextColorForPlayCommand else { return false }
        switch nextColorForPlayCommand {
        case .black: return config.blackMaxTime == 0 && config.whiteMaxTime > 0
        case .white: return config.whiteMaxTime == 0 && config.blackMaxTime > 0
        case .unknown: return false
        }
        #endif
    }
```

- [ ] **Step 5: Run the tests to verify they PASS**

Run:

```bash
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/AnalysisPowerSavingTests" 2>&1 | tail -30
```

Expected: **TEST SUCCEEDED**; all 8 `@Test` cases pass.

- [ ] **Step 6: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/GobanState.swift" \
        "ios/KataGo iOS/KataGo iOSTests/AnalysisPowerSavingTests.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat: add isAnalysisHiddenForPowerSaving predicate"
```

---

### Task 2: Gate `shouldRequestAnalysis` with the predicate

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/GobanState.swift` (`shouldRequestAnalysis`, ~line 117-123)
- Modify: `ios/KataGo iOS/KataGo iOSTests/AnalysisPowerSavingTests.swift` (append integration tests)

**Interfaces:**
- Consumes: `GobanState.isAnalysisHiddenForPowerSaving(config:nextColorForPlayCommand:)` (Task 1).
- Produces: `shouldRequestAnalysis` returns `false` in the power-saving case (suppressing initial/post-move/manual analysis requests), unchanged otherwise.

- [ ] **Step 1: Append failing integration tests**

Add these `@Test` methods inside `struct AnalysisPowerSavingTests` in `AnalysisPowerSavingTests.swift` (before the final closing `}`):

```swift
    // MARK: - shouldRequestAnalysis integration

    @Test func shouldRequestAnalysisFalseWhenPowerSaving() {
        let state = GobanState()            // analysisStatus defaults to .run
        state.eyeStatus = .closed
        #expect(state.shouldRequestAnalysis(
            config: mixedHumanBlackVsAIWhite(),
            nextColorForPlayCommand: .black) == false)
    }

    @Test func shouldRequestAnalysisTrueOnAITurnWhenHidden() {
        let state = GobanState()
        state.eyeStatus = .closed
        #expect(state.shouldRequestAnalysis(
            config: mixedHumanBlackVsAIWhite(),
            nextColorForPlayCommand: .white) == true)
    }

    @Test func shouldRequestAnalysisTrueWhenEyeOpened() {
        let state = GobanState()
        state.eyeStatus = .opened
        #expect(state.shouldRequestAnalysis(
            config: mixedHumanBlackVsAIWhite(),
            nextColorForPlayCommand: .black) == true)
    }
```

- [ ] **Step 2: Run the new tests to verify `shouldRequestAnalysisFalseWhenPowerSaving` FAILS**

Run:

```bash
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/AnalysisPowerSavingTests" 2>&1 | tail -30
```

Expected: `shouldRequestAnalysisFalseWhenPowerSaving` FAILS (`shouldRequestAnalysis` still returns `true` because it doesn't yet consult the predicate). The other two new tests pass.

- [ ] **Step 3: Wire the predicate into `shouldRequestAnalysis`**

In `GobanState.swift`, replace the existing `shouldRequestAnalysis` body's `if let` branch. Change:

```swift
    public func shouldRequestAnalysis(config: Config, nextColorForPlayCommand: PlayerColor?) -> Bool {
        if let nextColorForPlayCommand {
            return (analysisStatus != .clear) && config.isAnalysisForCurrentPlayer(nextColorForPlayCommand: nextColorForPlayCommand)
        } else {
            return (analysisStatus != .clear)
        }
    }
```

to:

```swift
    public func shouldRequestAnalysis(config: Config, nextColorForPlayCommand: PlayerColor?) -> Bool {
        if let nextColorForPlayCommand {
            return (analysisStatus != .clear)
                && config.isAnalysisForCurrentPlayer(nextColorForPlayCommand: nextColorForPlayCommand)
                && !isAnalysisHiddenForPowerSaving(config: config, nextColorForPlayCommand: nextColorForPlayCommand)
        } else {
            return (analysisStatus != .clear)
        }
    }
```

- [ ] **Step 4: Run the tests to verify they PASS**

Run:

```bash
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/AnalysisPowerSavingTests" 2>&1 | tail -30
```

Expected: **TEST SUCCEEDED**; all 11 `@Test` cases pass.

- [ ] **Step 5: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/GobanState.swift" \
        "ios/KataGo iOS/KataGo iOSTests/AnalysisPowerSavingTests.swift"
git commit -m "feat: suppress analysis requests when hidden for power saving"
```

---

### Task 3: iOS/visionOS continuous-stop + resume-on-reveal wiring

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/Game/GameSplitView.swift`
  - `processChange(oldWaitingForAnalysis:newWaitingForAnalysis:)` (~line 483-528)
  - `processEyeStatusChange(newEyeStatus:)` (~line 426-430) → rename to `(oldEyeStatus:newEyeStatus:)`
  - `onChange(of: gobanState.eyeStatus)` call site (~line 133-135)

**Interfaces:**
- Consumes: `GobanState.isAnalysisHiddenForPowerSaving(config:nextColorForPlayCommand:)` (Task 1); existing `gobanState.shouldGenMove(config:player:)`, `gobanState.maybeRequestAnalysis(config:nextColorForPlayCommand:messageList:)`, `navigationContext.selectedGameRecord`, `player`, `messageList`.
- Produces: continuous analysis stops within one cycle once the eye is hidden on the human's turn (mixed game), and resumes when the eye is reopened.

> **Note:** This task is view-layer glue that depends on SwiftUI environment/bindings and is not unit-tested (consistent with the codebase, which unit-tests model logic only). It is verified by a successful iOS + visionOS build here and the full build/test matrix in Task 4. Behavior is already covered by the predicate/`shouldRequestAnalysis` tests.

- [ ] **Step 1: Stop the continuous loop when power-saving applies**

In `processChange(oldWaitingForAnalysis:newWaitingForAnalysis:)`, change the stop condition. Find:

```swift
                if gobanState.analysisStatus == .pause {
                    messageList.appendAndSend(command: "stop")
                } else {
                    messageList.appendAndSend(command: GtpCommandBuilder.analyzeCommand(interval: config.analysisInterval, maxMoves: config.maxAnalysisMoves))
                }
```

Replace with:

```swift
                if gobanState.analysisStatus == .pause
                    || gobanState.isAnalysisHiddenForPowerSaving(config: config, nextColorForPlayCommand: player.nextColorForPlayCommand) {
                    messageList.appendAndSend(command: "stop")
                } else {
                    messageList.appendAndSend(command: GtpCommandBuilder.analyzeCommand(interval: config.analysisInterval, maxMoves: config.maxAnalysisMoves))
                }
```

- [ ] **Step 2: Add resume-on-reveal to `processEyeStatusChange`**

Replace the entire method:

```swift
    private func processEyeStatusChange(newEyeStatus: EyeStatus) {
        if newEyeStatus == .book {
            syncBookState()
        }
    }
```

with:

```swift
    private func processEyeStatusChange(oldEyeStatus: EyeStatus, newEyeStatus: EyeStatus) {
        if newEyeStatus == .book {
            syncBookState()
        }

        // Revealing the overlay again resumes the continuous analysis that
        // power-saving stopped while it was hidden. Only the human's turn in a
        // human-vs-AI game was ever stopped, so skip while the engine is
        // generating an AI move (avoids double-issuing kata-analyze) and for
        // both-human / both-AI games (nothing was stopped).
        if newEyeStatus == .opened,
           oldEyeStatus != .opened,
           gobanState.analysisStatus == .run,
           let config = navigationContext.selectedGameRecord?.config,
           !gobanState.shouldGenMove(config: config, player: player) {
            gobanState.maybeRequestAnalysis(
                config: config,
                nextColorForPlayCommand: player.nextColorForPlayCommand,
                messageList: messageList
            )
        }
    }
```

- [ ] **Step 3: Update the `onChange` call site**

Find:

```swift
        .onChange(of: gobanState.eyeStatus) { _, newEyeStatus in
            processEyeStatusChange(newEyeStatus: newEyeStatus)
        }
```

Replace with:

```swift
        .onChange(of: gobanState.eyeStatus) { oldEyeStatus, newEyeStatus in
            processEyeStatusChange(oldEyeStatus: oldEyeStatus, newEyeStatus: newEyeStatus)
        }
```

- [ ] **Step 4: Build iOS to verify it compiles**

Run:

```bash
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | tail -15
```

Expected: **BUILD SUCCEEDED**.

- [ ] **Step 5: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git add "ios/KataGo iOS/KataGo iOS/Game/GameSplitView.swift"
git commit -m "feat: stop/resume analysis on eye toggle for power saving (iOS/visionOS)"
```

---

### Task 4: Cross-platform build matrix + test plan

**Files:** none (verification only).

**Interfaces:** none.

> Confirms iOS/visionOS get the behavior, macOS still compiles with the no-op predicate (Mac path unchanged), and the unit suite is green.

- [ ] **Step 1: Build visionOS**

```bash
cd "ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug 2>&1 | tail -15
```

Expected: **BUILD SUCCEEDED**.

- [ ] **Step 2: Build macOS (verifies the no-op leaves the Mac target compiling)**

```bash
cd "ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" \
  -destination 'platform=macOS' -configuration Debug 2>&1 | tail -15
```

Expected: **BUILD SUCCEEDED**.

- [ ] **Step 3: Run the full iOS unit test plan**

```bash
cd "ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -25
```

Expected: **TEST SUCCEEDED** (FastTestPlan, unit-only). `AnalysisPowerSavingTests` included and green.

- [ ] **Step 4: Final review against the spec**

Confirm the behavior table in `docs/superpowers/specs/2026-06-21-power-saving-analysis-pause-design.md` matches the implementation:
- both-human / both-AI / eye-opened / AI's-turn: unchanged.
- mixed + hidden (`.book`/`.closed`) + human's turn: paused; reopening the eye resumes.
- macOS: predicate returns `false`; no behavior change.

No commit required if all steps pass and nothing changed.
