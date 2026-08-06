# Default Stone Style → Classic Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Classic the stone style a fresh install renders with, instead of Fast.

**Architecture:** `Config.defaultStoneStyle` is the single constant every consumer of the stone-style setting reads — the iOS `@AppStorage` seed, the macOS UserDefaults seed and picker fallback, `ConfigView`'s picker state, the GIF-export seed, `GobanState`'s compiled default (which is what tvOS and the Deep Analysis Report actually use), and new SwiftData `Config` rows. Flipping that one integer from `0` to `1` moves all of them. Nothing else in production changes.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing (`@Test`/`#expect`), XCTest (for the pre-existing perf tests), xcodebuild.

**Spec:** `docs/superpowers/specs/2026-08-06-default-stone-style-classic-design.md`

## Global Constraints

- **Never reorder `Config.stoneStyles`.** The array is `[fastStoneStyle, classicStoneStyle]` and the *index* is what persists — in the `GlobalSettings.stoneStyle` UserDefaults key and in the SwiftData `Config.stoneStyle` column. Reordering silently reinterprets every value already stored on every device and in CloudKit. Only the default index may move.
- **Do not modify the `@Model` schema.** The `Config` `@Model` declaration, its property names, and their types stay exactly as they are. Only a default-value literal moves, which is not part of a Core Data entity version hash — so there is no CloudKit migration and none may be added.
- **No migration code.** Users who explicitly chose Fast must keep Fast. The `GlobalSettings.stoneStyle` key is only written on an actual change, so this falls out for free — do not add anything that rewrites stored preferences.
- **The picker keeps listing Fast first.** Which entry is listed first and which is selected by default are independent. Do not touch picker ordering.
- **English only.** No CJK in any committed content.
- **Piped `xcodebuild` exit codes are unreliable.** Judge every build and test run by grepping the log for `BUILD SUCCEEDED` / `BUILD FAILED` / `TEST SUCCEEDED` / `TEST FAILED`, never by `$?` after a pipe.
- **Never run two xcodebuild invocations at once.** They contend on the shared DerivedData lock and produce spurious `TEST FAILED` results. Build and test strictly one at a time.

## File Structure

Two files change. No files are created.

| File | Responsibility | Change |
| --- | --- | --- |
| `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/ConfigModel.swift` | Owns `Config` (`@Model`) and every `Config.default*` constant. Line 321 is the sole definition of the stone-style default. | Flip `defaultStoneStyle` `0` → `1`, with a comment recording why the original perf-driven default no longer applies. |
| `ios/KataGo iOS/KataGo iOSTests/ConfigModelTests.swift` | Swift Testing suite for `Config`'s defaults and computed properties. Three assertions currently pin the default to Fast. | Add a regression guard that pins the default to Classic; flip the two tests that assert a fresh `Config()` is Fast. |

Not touched, and deliberately so: `StoneView.swift` (renders whatever style it is handed), `StoneRenderPerfTests.swift` (its 20 ms classic bound needs no change but now guards the default path), the various `#Preview` blocks (hardcoded `isClassicStoneStyle: false` call sites, out of scope per the spec), and `README.md` (line 141 names no default).

**Amended after the fact (2026-08-07, commit `946af2db`):** `PhotoImportSheet.swift` was on that list and is no longer. See the Out of Scope section for why it moved in.

---

### Task 1: Flip the default and pin it with a test

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/ConfigModel.swift:317-322`
- Test: `ios/KataGo iOS/KataGo iOSTests/ConfigModelTests.swift` (add one test after `testStoneStyleComputedProperties`; modify `testStoneStyleComputedProperties` and `stoneStyle`)

**Interfaces:**
- Consumes: nothing from earlier tasks — this is the first task.
- Produces: `Config.defaultStoneStyle == 1`, and therefore `Config.defaultStoneStyleText == Config.classicStoneStyle == "Classic"`. No signatures change. `Config.stoneStyles` stays `["Fast", "Classic"]`; `Config.fastStoneStyle` stays `"Fast"`; `Config.classicStoneStyle` stays `"Classic"`; `Config().isClassicStoneStyle` becomes `true` and `Config().isFastStoneStyle` becomes `false`.

- [ ] **Step 1: Write the failing test**

In `ios/KataGo iOS/KataGo iOSTests/ConfigModelTests.swift`, find `testStoneStyleComputedProperties` (around line 219) and insert this new test immediately **after** that test's closing brace:

```swift
    /// Pins the SHIPPING default. Fast held this slot from 829a9dbd
    /// (2024-07-11) purely for render cost; the `Canvas`-of-symbols rewrite in
    /// `StoneView` removed that reason, and Classic is the better-looking
    /// board. A future change back to Fast should fail here rather than ship.
    @Test func defaultStoneStyleIsClassic() async throws {
        #expect(Config.defaultStoneStyleText == Config.classicStoneStyle)
        #expect(Config().isClassicStoneStyle == true)
        #expect(Config().isFastStoneStyle == false)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
LOG="${TMPDIR:-/tmp}/katago-stone-style-1.log"
xcodebuild test \
  -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/ConfigModelTests" \
  > "$LOG" 2>&1
grep -E "TEST (SUCCEEDED|FAILED)|defaultStoneStyleIsClassic" "$LOG" | tail -20
```

Expected: `TEST FAILED`, with a recorded failure on `defaultStoneStyleIsClassic` —
`Expectation failed: (Config.defaultStoneStyleText → "Fast") == (Config.classicStoneStyle → "Classic")`.

If instead the build fails to compile, fix that before continuing — a compile error is not the failure this step is looking for.

- [ ] **Step 3: Flip the default**

In `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/ConfigModel.swift`, replace:

```swift
    public static let fastStoneStyle = "Fast"
    public static let classicStoneStyle = "Classic"
    public static let stoneStyles = [fastStoneStyle, classicStoneStyle]
    public static let defaultStoneStyle = 0
    public static let defaultStoneStyleText = stoneStyles[defaultStoneStyle]
```

with:

```swift
    public static let fastStoneStyle = "Fast"
    public static let classicStoneStyle = "Classic"
    public static let stoneStyles = [fastStoneStyle, classicStoneStyle]
    /// Classic (index 1). Fast held this slot from 829a9dbd (2024-07-11) for
    /// render cost alone: the old per-stone view tree ran ~76 ms per frame on
    /// a dense 19x19. The `Canvas`-of-symbols renderer in `StoneView` brought
    /// that to ~0.9 ms — `StoneRenderPerfTests` guards it at 20 ms — so the
    /// default is no longer a performance choice.
    ///
    /// ⚠️ Do NOT change this by reordering `stoneStyles`. The INDEX is what
    /// persists, in both the `GlobalSettings.stoneStyle` UserDefaults key and
    /// the SwiftData `Config.stoneStyle` column, so a reorder silently
    /// reinterprets every value already stored on device and in CloudKit.
    public static let defaultStoneStyle = 1
    public static let defaultStoneStyleText = stoneStyles[defaultStoneStyle]
```

- [ ] **Step 4: Run the tests — the new one passes, two old ones now fail**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
LOG="${TMPDIR:-/tmp}/katago-stone-style-2.log"
xcodebuild test \
  -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/ConfigModelTests" \
  > "$LOG" 2>&1
grep -E "TEST (SUCCEEDED|FAILED)|Expectation failed|defaultStoneStyleIsClassic|testStoneStyleComputedProperties" "$LOG" | tail -30
```

Expected: `TEST FAILED` overall, but for the *right* reasons —
`defaultStoneStyleIsClassic` now **passes**, while `testStoneStyleComputedProperties`
and `stoneStyle` **fail** on `#expect(config.isFastStoneStyle == true)`. Those two
are the assertions that pin the old default; Step 5 flips them.

- [ ] **Step 5: Flip the two tests that pinned the old default**

In `ios/KataGo iOS/KataGo iOSTests/ConfigModelTests.swift`, replace `testStoneStyleComputedProperties`:

```swift
    @Test func testStoneStyleComputedProperties() async throws {
        let config = Config()

        // Default is "Fast" (index 0)
        #expect(config.isFastStoneStyle == true)
        #expect(config.isClassicStoneStyle == false)

        // Set to "Classic" (index 1)
        config.stoneStyle = 1
        #expect(config.isFastStoneStyle == false)
        #expect(config.isClassicStoneStyle == true)

        // Set to an invalid index (e.g., 2) to ensure no false positives
        config.stoneStyle = 2
        #expect(config.isFastStoneStyle == false)
        #expect(config.isClassicStoneStyle == false)
    }
```

with:

```swift
    @Test func testStoneStyleComputedProperties() async throws {
        let config = Config()

        // Default is "Classic" (index 1)
        #expect(config.isFastStoneStyle == false)
        #expect(config.isClassicStoneStyle == true)

        // Set to "Fast" (index 0)
        config.stoneStyle = 0
        #expect(config.isFastStoneStyle == true)
        #expect(config.isClassicStoneStyle == false)

        // Set to an invalid index (e.g., 2) to ensure no false positives
        config.stoneStyle = 2
        #expect(config.isFastStoneStyle == false)
        #expect(config.isClassicStoneStyle == false)
    }
```

Then, further down the same file (around line 521), replace `stoneStyle`:

```swift
    @Test func stoneStyle() async throws {
        let config = Config()
        #expect(config.isFastStoneStyle == true)
        #expect(config.isClassicStoneStyle == false)
        config.stoneStyle = 1
        #expect(config.isFastStoneStyle == false)
        #expect(config.isClassicStoneStyle == true)
    }
```

with:

```swift
    @Test func stoneStyle() async throws {
        let config = Config()
        #expect(config.isFastStoneStyle == false)
        #expect(config.isClassicStoneStyle == true)
        config.stoneStyle = 0
        #expect(config.isFastStoneStyle == true)
        #expect(config.isClassicStoneStyle == false)
    }
```

Leave `testDefaultInitialization`, `testAllStoneStyles`, and `testInvalidStoneStyleIndex` alone — they are index-relative, not default-relative, and stay green.

- [ ] **Step 6: Run the tests to verify they all pass**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
LOG="${TMPDIR:-/tmp}/katago-stone-style-3.log"
xcodebuild test \
  -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/ConfigModelTests" \
  > "$LOG" 2>&1
grep -E "TEST (SUCCEEDED|FAILED)" "$LOG" | tail -5
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/ConfigModel.swift" \
        "ios/KataGo iOS/KataGo iOSTests/ConfigModelTests.swift"
git commit -F - <<'MSG'
feat(board): default the stone style to Classic

Fast has been the default since 829a9dbd, chosen for render cost when
the classic stones cost ~76 ms per frame on a dense 19x19. The Canvas
of pre-rasterized symbols in StoneView brought that to ~0.9 ms, so the
default is no longer a performance choice.

Flipping Config.defaultStoneStyle moves every consumer at once: the
iOS @AppStorage seed, the macOS seed and picker fallback, ConfigView's
picker state, the GIF-export seed, GobanState's compiled default (what
tvOS and the Deep Report use), and new SwiftData Config rows.

No migration. GlobalSettings.stoneStyle is only written on an actual
change, so users who never opened the picker pick up Classic and users
who chose Fast keep it. A default-value literal is not part of a Core
Data entity version hash, so the SwiftData/CloudKit schema is untouched.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
MSG
```

---

### Task 2: Verify across all five platforms

The default now reaches targets that have no stone-style picker (tvOS takes the compiled `GobanState` default directly), so a green iOS unit run is not sufficient evidence. This task is verification only — it produces no source changes unless it finds a break.

**Files:**
- Modify: none expected.

**Interfaces:**
- Consumes: `Config.defaultStoneStyle == 1` from Task 1.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Run the full iOS unit suite**

Wider than Task 1's single class — this is where `StoneRenderPerfTests`' 20 ms classic bound runs, and it now guards the default path.

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
LOG="${TMPDIR:-/tmp}/katago-stone-style-full.log"
xcodebuild test \
  -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  > "$LOG" 2>&1
grep -E "TEST (SUCCEEDED|FAILED)" "$LOG" | tail -5
```

Expected: `** TEST SUCCEEDED **`. The scheme's default plan is `FastTestPlan`, which runs the `KataGo AnytimeTests` unit target only — no UI tests, so no UI-test flake to triage here.

If `testClassicDenseBoardRenderTime` fails its 20 ms bound, stop and report it: that would mean the classic renderer is no longer cheap enough to be the default, which invalidates the premise of the whole change.

- [ ] **Step 2: Run the package test suites**

`KataGoUICore`'s SwiftPM tests never run under `xcodebuild`, so they need their own invocation.

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS/KataGoUICore"
swift test 2>&1 | tail -20
```

Expected: all suites pass. None of them cover `Config`, so this is a no-regression check rather than a test of the change.

- [ ] **Step 3: Build all five schemes, one at a time**

Run these **sequentially**. Two concurrent `xcodebuild` invocations contend on the shared DerivedData lock and produce spurious failures.

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
for spec in \
  "KataGo Anytime|platform=iOS Simulator,name=iPhone 17" \
  "KataGo Anytime Mac|platform=macOS" \
  "KataGo Anytime Vision|platform=visionOS Simulator,name=Apple Vision Pro" \
  "KataGo Anytime TV|platform=tvOS Simulator,name=Apple TV" \
  "KataGo Anytime Watch|platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)"
do
  scheme="${spec%%|*}"; dest="${spec##*|}"
  log="${TMPDIR:-/tmp}/katago-build-${scheme// /-}.log"
  xcodebuild build -project "KataGo Anytime.xcodeproj" \
    -scheme "$scheme" -destination "$dest" -configuration Debug > "$log" 2>&1
  result="$(grep -Eo 'BUILD (SUCCEEDED|FAILED)' "$log" | tail -1)"
  printf '%-24s %s\n' "$scheme" "${result:-NO RESULT LINE - see $log}"
done
```

Expected: `BUILD SUCCEEDED` on all five lines. A `NO RESULT LINE` means the
invocation died before it got as far as reporting (bad destination name, missing
simulator runtime, DerivedData lock) — open the log rather than assuming a
compile error.

The one that actually exercises new ground is `KataGo Anytime TV`: tvOS never syncs `GlobalSettingsKeys`, so its board and its Deep Report slides now take the Classic path. `Shaders.metal` is compiled into that target (verified in `project.pbxproj`), so the shader resolves — but a build failure there would be the signal that it does not.

- [ ] **Step 4: Confirm the board visually on the iOS Simulator**

Follow the project's `verify` skill for the build/launch/drive recipe. Delete the app from the simulator first so the run starts with no `GlobalSettings.stoneStyle` key — that absent key is the whole point of the change.

Confirm three things:
1. A new game's stones render as glossy, lit Classic stones — not flat discs.
2. Global Settings → Stone style reads **Classic**.
3. Switching the picker to Fast renders flat discs, and switching back to Classic restores the glossy ones. This proves the picker still writes the key and that only the *default* moved.

- [ ] **Step 5: Report**

State plainly which of the five builds succeeded, whether both test runs passed, and what the simulator showed. If anything failed, report the failure output rather than a summary. There is nothing to commit in this task unless Step 3 or 4 surfaced a break that needed fixing.

---

## Out of Scope

Recorded so a reviewer does not read these as omissions:

- ~~**`PhotoImportSheet.swift:210`** hardcodes `isClassicStoneStyle: false` for the photo/camera import preview board. It ignores the user's setting today and will continue to. The user explicitly chose to leave it.~~

  **REVERSED 2026-08-07 (commit `946af2db`) — this bullet was wrong to include it.** The user's scoping call ruled out the hardcoded `#Preview` call sites; this plan folded the import preview in with them, but it is not a `#Preview` — it is a shipping surface a user sees whenever they import a board from a photo. Its `false` had merely *coincided* with the old shipping default, so the flip to Classic turned a silent match into a guaranteed mismatch: the import preview would have been the one board in the app still drawing Fast. The final review surfaced it, the user asked for it to be decided in the follow-up round, and the decision was to make it follow `GlobalSettings.stoneStyle` like every other board. The `#Preview` exclusion below still stands.
- **`GameGifRenderer`'s `isClassicStoneStyle: Bool = false` default parameter** is dead — `GameGifExportView` is the only caller and always passes an explicit value seeded from the setting.
- **`DeepReportModel.isClassicStoneStyle = false`** is a property initializer that `DeepReportGenerator` overwrites from `gobanState` before the report renders.
- **`#Preview` blocks** in `StoneView.swift` and `ReportBoardView.swift` pass fixed styles on purpose, to exercise both paths.
- **Widget, watch, and Messages boards** resolve stones through `WidgetBoardStyle` variants chosen per surface, not through `Config.defaultStoneStyle`.
- **`README.md:141`** lists "Stone style (Fast / Classic)" without naming a default, so it stays accurate.
