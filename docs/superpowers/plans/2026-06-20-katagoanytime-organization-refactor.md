# KataGo Anytime Organization-Core Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** De-duplicate and reorganize the KataGo Anytime app (ranks 1–7 of the architecture assessment) without changing any behavior: hoist the byte-identical CoreML loader, single-source the GlobalSettings keys and config→GTP command logic, move SGF parsing and engine ownership to their proper layers, clean the repo, and fold the iOS target into per-feature folders.

**Architecture:** The app is a fork of KataGo with an iOS/visionOS SwiftUI target (`KataGo Anytime`), a macOS AppKit target (`KataGo Anytime Mac`), and a shared SwiftPM package `KataGoUICore` (one module, folders Bridge/Model/Session/Services/Rendering). Refactors push platform-neutral logic into `KataGoUICore`; only framework-specific UI stays in app targets. Behavior parity is enforced by Swift Testing unit tests (especially equivalence tests that assert new code matches the existing code's exact output before the old code is deleted).

**Tech Stack:** Swift 6.2, SwiftUI (iOS/visionOS), AppKit (macOS), SwiftData (+CloudKit), SwiftPM (`KataGoUICore`), Swift Testing (`import Testing`), Swift/C++ interop, `xcodeproj` Ruby gem for project edits, `xcodebuild`.

## Global Constraints

Every task implicitly includes these. Verbatim from the spec (`docs/superpowers/specs/2026-06-19-katagoanytime-organization-refactor-design.md`):

- **App is UNRELEASED** — no migration or back-compat code.
- **SwiftData `@Model` schemas (`Config`, `GameRecord`) are FROZEN** — never add, remove, or rename a stored `@Attribute`/`@Relationship`. Only relocate methods and computed (non-stored) properties; those do not affect the persisted schema.
- **Behavior-preserving** — identical GTP command strings, identical emit order/timing, no feature change, no UI change.
- **No `git push`** during this effort (Xcode Cloud free-tier rate limit). One commit per task. Work stays on branch `refactor/organization-core` (already created off `ios-dev`).
- **Deletions:** `trash` CLI for untracked files/dirs; `git rm`/`git mv` for git-tracked files (recoverable via history).
- **`project.pbxproj` edits** use the `xcodeproj` Ruby gem. Target names: app target `KataGo Anytime`, macOS target `KataGo Anytime Mac`, unit-test target `KataGo AnytimeTests`. The `.xcodeproj` is at `ios/KataGo iOS/KataGo Anytime.xcodeproj`.
- **Tests:** Swift Testing only (`import Testing`, `@Test`, `#expect`). Test files live in `ios/KataGo iOS/KataGo iOSTests/` (target `KataGo AnytimeTests`) and use `@testable import KataGo_Anytime` + `@testable import KataGoUICore`. New test files must be registered in the test target via the `xcodeproj` gem. Unit tests run in the default `FastTestPlan`.
- **`KataGoUICore` is a single Swift module.** "Bridge / Model / Session" are folders, not modules; there is no cross-module `import`. "Layer" fixes are about *where a type is constructed/defined*, not about import statements.

### Build & test commands (run from `ios/KataGo iOS`)

```bash
# Build all three platforms (Debug)
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime"     -destination 'platform=iOS Simulator,name=iPhone 17'              -configuration Debug
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime"     -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS'                                   -configuration Debug

# Unit tests (FastTestPlan = default)
xcodebuild test  -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime"     -destination 'platform=iOS Simulator,name=iPhone 17'

# Full test plan (includes UI tests) — milestone boundaries only
xcodebuild test  -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime"     -destination 'platform=iOS Simulator,name=iPhone 17' -testPlan FullTestPlan
```

**Per-task verification:** build all three platforms + run `FastTestPlan`.
**Per-milestone verification (A, B, C):** run `FullTestPlan`. Milestone B additionally requires manual iOS + macOS app runs confirming config edits behave identically.

---

# Milestone A — De-duplication & hygiene (low risk)

## Task A1: Share the byte-identical `CoreMLComputeHandleLoader` across both app targets

The file is byte-identical in both targets (verified `diff` = 0) and **live on both** — iOS calls `registerCoreMLBridge()` in `KataGo_iOSApp.swift:42`, macOS in `AppDelegate.swift:29`. It cannot move into `KataGoUICore` (it `import`s the `KataGoSwift` framework and uses `@_silgen_name("katagocoreml_*")` + interop types `MetalComputeContext`/`CoreMLComputeHandle`). Fix: one physical file with dual target membership.

**Files:**
- Keep (canonical): `ios/KataGo iOS/KataGo iOS/CoreMLComputeHandleLoader.swift`
- Delete: `ios/KataGo iOS/KataGo Anytime Mac/CoreMLComputeHandleLoader.swift`
- Modify: `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj` (add canonical fileRef to the macOS target's Sources phase; remove the Mac copy's build file + fileRef)

- [ ] **Step 1: Confirm the two files are still identical**

Run:
```bash
cd "ios/KataGo iOS"
diff "KataGo iOS/CoreMLComputeHandleLoader.swift" "KataGo Anytime Mac/CoreMLComputeHandleLoader.swift" && echo "IDENTICAL"
```
Expected: prints `IDENTICAL` (no diff output). If they differ, STOP — reconcile manually first (the share assumes identical content).

- [ ] **Step 2: Rewire pbxproj — share the iOS file with the macOS target**

Create `ios/KataGo iOS/share_coreml_loader.rb`:
```ruby
require 'xcodeproj'
project = Xcodeproj::Project.open('KataGo Anytime.xcodeproj')
mac = project.targets.find { |t| t.name == 'KataGo Anytime Mac' }

# Canonical iOS file reference (NOT the one physically under "KataGo Anytime Mac/")
ios_ref = project.files.find do |f|
  f.path&.end_with?('CoreMLComputeHandleLoader.swift') &&
    !f.real_path.to_s.include?('KataGo Anytime Mac')
end
raise 'iOS loader fileRef not found' unless ios_ref

# Remove the macOS copy's build file + its fileRef from the project.
mac.source_build_phase.files.dup.each do |bf|
  ref = bf.file_ref
  next unless ref&.path&.end_with?('CoreMLComputeHandleLoader.swift')
  next unless ref.real_path.to_s.include?('KataGo Anytime Mac')
  mac.source_build_phase.remove_build_file(bf)
  ref.remove_from_project
end

# Add the canonical iOS file to the macOS target's compile sources.
mac.add_file_references([ios_ref]) unless mac.source_build_phase.files_references.include?(ios_ref)
project.save
puts 'OK: macOS target now compiles the shared iOS CoreMLComputeHandleLoader.swift'
```
Run:
```bash
cd "ios/KataGo iOS" && ruby share_coreml_loader.rb
```
Expected: `OK: macOS target now compiles the shared iOS CoreMLComputeHandleLoader.swift`

- [ ] **Step 3: Delete the duplicate physical file and the helper script**

Run:
```bash
cd "ios/KataGo iOS"
trash "KataGo Anytime Mac/CoreMLComputeHandleLoader.swift"
trash share_coreml_loader.rb
```

- [ ] **Step 4: Build all three platforms**

Run the three `xcodebuild build` commands from Global Constraints.
Expected: all succeed. (Critical check: the macOS build must still resolve `registerCoreMLBridge`/`loadCoreMLHandle` — it now compiles the shared iOS file.)

- [ ] **Step 5: Run unit tests**

Run the `FastTestPlan` test command. Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: share one CoreMLComputeHandleLoader across iOS+macOS targets"
```

## Task A2: Single-source the 14 `GlobalSettings` keys in `KataGoUICore`

14 identical UserDefaults keys are hardcoded twice: iOS `GameSplitView.swift` (`@AppStorage`, lines 576–589) and macOS `MacGlobalPreferenceSync.swift` (`private enum Key`, lines 24–39). No drift today. Extract the key strings; do **not** change defaults, seeding, or write-back logic.

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Services/GlobalSettingsKeys.swift`
- Modify: `ios/KataGo iOS/KataGo iOS/GameSplitView.swift:576-589`
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/MacGlobalPreferenceSync.swift:24-39`
- Test: `ios/KataGo iOS/KataGo iOSTests/GlobalSettingsKeysTests.swift`

**Interfaces — Produces:**
```swift
public enum GlobalSettingsKeys {
    public static let soundEffect = "GlobalSettings.soundEffect"
    public static let hapticFeedback = "GlobalSettings.hapticFeedback"
    public static let showVisitsPerSecond = "GlobalSettings.showVisitsPerSecond"
    public static let showCoordinate = "GlobalSettings.showCoordinate"
    public static let showPass = "GlobalSettings.showPass"
    public static let verticalFlip = "GlobalSettings.verticalFlip"
    public static let showOwnership = "GlobalSettings.showOwnership"
    public static let showWinrateBar = "GlobalSettings.showWinrateBar"
    public static let showCharts = "GlobalSettings.showCharts"
    public static let showComments = "GlobalSettings.showComments"
    public static let stoneStyle = "GlobalSettings.stoneStyle"
    public static let moveNumberStyle = "GlobalSettings.moveNumberStyle"
    public static let analysisStyle = "GlobalSettings.analysisStyle"
    public static let analysisInformation = "GlobalSettings.analysisInformation"
}
```

- [ ] **Step 1: Write the failing test**

Create `ios/KataGo iOS/KataGo iOSTests/GlobalSettingsKeysTests.swift`:
```swift
//
//  GlobalSettingsKeysTests.swift
//  KataGo iOSTests
//

import Testing
@testable import KataGoUICore

struct GlobalSettingsKeysTests {
    @Test func keysMatchTheHistoricalStringLiterals() {
        #expect(GlobalSettingsKeys.soundEffect == "GlobalSettings.soundEffect")
        #expect(GlobalSettingsKeys.hapticFeedback == "GlobalSettings.hapticFeedback")
        #expect(GlobalSettingsKeys.showVisitsPerSecond == "GlobalSettings.showVisitsPerSecond")
        #expect(GlobalSettingsKeys.showCoordinate == "GlobalSettings.showCoordinate")
        #expect(GlobalSettingsKeys.showPass == "GlobalSettings.showPass")
        #expect(GlobalSettingsKeys.verticalFlip == "GlobalSettings.verticalFlip")
        #expect(GlobalSettingsKeys.showOwnership == "GlobalSettings.showOwnership")
        #expect(GlobalSettingsKeys.showWinrateBar == "GlobalSettings.showWinrateBar")
        #expect(GlobalSettingsKeys.showCharts == "GlobalSettings.showCharts")
        #expect(GlobalSettingsKeys.showComments == "GlobalSettings.showComments")
        #expect(GlobalSettingsKeys.stoneStyle == "GlobalSettings.stoneStyle")
        #expect(GlobalSettingsKeys.moveNumberStyle == "GlobalSettings.moveNumberStyle")
        #expect(GlobalSettingsKeys.analysisStyle == "GlobalSettings.analysisStyle")
        #expect(GlobalSettingsKeys.analysisInformation == "GlobalSettings.analysisInformation")
    }
}
```
Register it in the test target:
```ruby
# ios/KataGo iOS/register_test.rb  (delete after use)
require 'xcodeproj'
project = Xcodeproj::Project.open('KataGo Anytime.xcodeproj')
target = project.targets.find { |t| t.name == 'KataGo AnytimeTests' }
group = project.main_group.find_subpath('KataGo iOSTests', true)
# Pass the FILENAME ONLY: the group already has path "KataGo iOSTests", so a
# path-qualified arg here produces a doubled "KataGo iOSTests/KataGo iOSTests/…"
# fileRef. (Reuse this snippet for later test files — swap the filename.)
ref = group.new_file('GlobalSettingsKeysTests.swift')
target.add_file_references([ref])
project.save
```
Run: `cd "ios/KataGo iOS" && ruby register_test.rb && trash register_test.rb`

- [ ] **Step 2: Run the test to verify it fails**

Run `FastTestPlan`. Expected: FAIL to compile — `GlobalSettingsKeys` is undefined.

- [ ] **Step 3: Create `GlobalSettingsKeys.swift`**

Create the file with the exact `public enum GlobalSettingsKeys` from the Interfaces block above (14 constants). Add a header comment:
```swift
//
//  GlobalSettingsKeys.swift
//  KataGoUICore
//
//  Single source of truth for the GlobalSettings.* UserDefaults keys shared by
//  the iOS @AppStorage sync (GameSplitView) and the macOS observation sync
//  (MacGlobalPreferenceSync).
//
import Foundation
```
(Package source files are picked up automatically — no pbxproj edit needed for the package.)

- [ ] **Step 4: Run the test to verify it passes**

Run `FastTestPlan`. Expected: PASS.

- [ ] **Step 5: Reference the constants from iOS `GameSplitView.swift`**

Replace each `@AppStorage("GlobalSettings.X")` literal (lines 576–589) with the constant, keeping the property name and default unchanged. Example transformation (apply to all 14):
```swift
// before
@AppStorage("GlobalSettings.soundEffect") private var soundEffect = false
// after
@AppStorage(GlobalSettingsKeys.soundEffect) private var soundEffect = false
```
Full mapping (literal → constant): `soundEffect`, `hapticFeedback`, `showVisitsPerSecond`, `showCoordinate`, `showPass`, `verticalFlip`, `showOwnership`, `showWinrateBar`, `showCharts`, `showComments`, `stoneStyle`, `moveNumberStyle`, `analysisStyle`, `analysisInformation`. Leave the `.onAppear` seeding (593–608) and the 14 `.onChange` write-backs (609–622) unchanged.

- [ ] **Step 6: Reference the constants from macOS `MacGlobalPreferenceSync.swift`**

Delete the `private enum Key { ... }` block (lines 24–39). Replace every `Key.X` usage in `seedFromDefaults()` (62–75) and `persistToDefaults()` (122–139) with `GlobalSettingsKeys.X` (same suffix). Leave the seeding/observation/write-back logic otherwise unchanged.

- [ ] **Step 7: Build all three platforms + run unit tests**

Run the three builds + `FastTestPlan`. Expected: all PASS.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor: single-source GlobalSettings keys in KataGoUICore"
```

## Task A3: Repo hygiene — relocate screenshots, drop dead assets/dirs, extend `.gitignore`

Only the 6 root PNGs are git-tracked bloat. Five are referenced by `README.md`; `GobanViewNote.png` (2.8 MB) is unreferenced. Five dirs are empty/untracked junk with zero pbxproj references. `__MACOSX/` and `.build/` are not yet ignored.

**Files:**
- Move (tracked): `GobanView.png`, `Xcode_Signing.png`, `CloneDialog.png`, `CommandView.png`, `ConfigView.png` → `ios/KataGo iOS/docs/screenshots/`
- Remove (tracked): `ios/KataGo iOS/GobanViewNote.png`
- Modify: `ios/KataGo iOS/README.md` (lines 8, 104, 211, 216, 233)
- Remove (untracked junk): `ios/KataGo iOS/KataGo Helper/`, `KataGo Intents/`, `SgfHelper/`, `KataGo IntentsUI/`, `KataGoApp/`
- Modify: `/Users/chinchangyang/Code/KataGo-ios-dev/.gitignore`

- [ ] **Step 1: Move the five referenced screenshots (preserving history)**

```bash
cd "ios/KataGo iOS"
mkdir -p docs/screenshots
git mv GobanView.png docs/screenshots/GobanView.png
git mv Xcode_Signing.png docs/screenshots/Xcode_Signing.png
git mv CloneDialog.png docs/screenshots/CloneDialog.png
git mv CommandView.png docs/screenshots/CommandView.png
git mv ConfigView.png docs/screenshots/ConfigView.png
```

- [ ] **Step 2: Update the README image links**

In `ios/KataGo iOS/README.md` make these exact edits:
- Line 8: `![Screenshot of the board view](GobanView.png)` → `![Screenshot of the board view](docs/screenshots/GobanView.png)`
- Line 104: `![Screenshot of Xcode signing](Xcode_Signing.png)` → `![Screenshot of Xcode signing](docs/screenshots/Xcode_Signing.png)`
- Line 211: `![Clone dialog](CloneDialog.png)` → `![Clone dialog](docs/screenshots/CloneDialog.png)`
- Line 216: `![GTP Console Screenshot](CommandView.png)` → `![GTP Console Screenshot](docs/screenshots/CommandView.png)`
- Line 233: `![Configurations Screenshot](ConfigView.png)` → `![Configurations Screenshot](docs/screenshots/ConfigView.png)`

- [ ] **Step 3: Remove the unreferenced screenshot (tracked) and the empty/junk dirs (untracked)**

```bash
cd "ios/KataGo iOS"
git rm GobanViewNote.png
trash "KataGo Helper" "KataGo Intents" "SgfHelper" "KataGo IntentsUI" "KataGoApp"
```

- [ ] **Step 4: Extend `.gitignore`**

Append to `/Users/chinchangyang/Code/KataGo-ios-dev/.gitignore`:
```gitignore

# SwiftPM build products and macOS zip cruft
.build/
__MACOSX/
```

- [ ] **Step 5: Verify no broken README links and a clean status**

```bash
cd "ios/KataGo iOS"
grep -nE '\]\((GobanView|Xcode_Signing|CloneDialog|CommandView|ConfigView)\.png\)' README.md && echo "STALE LINK FOUND" || echo "no stale links"
ls docs/screenshots
```
Expected: `no stale links`; five PNGs listed under `docs/screenshots`.

- [ ] **Step 6: Build all three platforms**

Run the three builds. Expected: PASS (no source touched; this guards against an accidental pbxproj dependency on a removed path).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "chore: relocate screenshots to docs/, drop dead assets/dirs, ignore .build & __MACOSX"
```

## Task A4: Fold the flat iOS target into per-feature folders

All 27 iOS files sit flat. Move them into logical subfolders and update the pbxproj groups. **iOS-only task** — does not touch the macOS target or the shared loader from A1 (leave `CoreMLComputeHandleLoader.swift` at the iOS root, since the macOS target references that path). Do this **last in Milestone A**; build after each folder so a bad move is caught immediately.

**Folder mapping** (all under `ios/KataGo iOS/KataGo iOS/`):
| Folder | Files |
|--------|-------|
| `App/` | `KataGo_iOSApp.swift`, `ContentView.swift`, `ModelRunnerView.swift`, `LoadingView.swift` |
| `Game/` | `GameSplitView.swift`, `GobanView.swift`, `PlayView.swift` |
| `GameList/` | `GameListView.swift`, `GameLinkView.swift`, `GameListToolbar.swift`, `PlusMenuView.swift`, `NameEditorView.swift` |
| `Config/` | `ConfigView.swift`, `BackendConfigSheet.swift` |
| `Models/` | `ModelPickerView.swift`, `CoreMLCacheFooterView.swift` |
| `Toolbars/` | `StatusToolbarItems.swift`, `TopToolbarView.swift` |
| `Misc/` | `InfoView.swift`, `CommandView.swift`, `AcknowledgmentsView.swift`, `QuitButton.swift`, `MLXTuneExperimentView.swift` |
| (root, unmoved) | `CoreMLComputeHandleLoader.swift` (shared with macOS — leave in place) |
| `AppIntents/` | already grouped — leave as-is |

**Files:**
- Move: the files per the table (via `git mv`)
- Modify: `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj` (reparent fileRefs into new groups + fix paths)

- [ ] **Step 1: Author the move-and-reparent script**

Create `ios/KataGo iOS/fold_ios_target.rb`:
```ruby
require 'xcodeproj'
require 'fileutils'

MAPPING = {
  'App'      => %w[KataGo_iOSApp.swift ContentView.swift ModelRunnerView.swift LoadingView.swift],
  'Game'     => %w[GameSplitView.swift GobanView.swift PlayView.swift],
  'GameList' => %w[GameListView.swift GameLinkView.swift GameListToolbar.swift PlusMenuView.swift NameEditorView.swift],
  'Config'   => %w[ConfigView.swift BackendConfigSheet.swift],
  'Models'   => %w[ModelPickerView.swift CoreMLCacheFooterView.swift],
  'Toolbars' => %w[StatusToolbarItems.swift TopToolbarView.swift],
  'Misc'     => %w[InfoView.swift CommandView.swift AcknowledgmentsView.swift QuitButton.swift MLXTuneExperimentView.swift],
}

project = Xcodeproj::Project.open('KataGo Anytime.xcodeproj')
ios_group = project.main_group.find_subpath('KataGo iOS', true)

MAPPING.each do |folder, files|
  FileUtils.mkdir_p("KataGo iOS/#{folder}")
  subgroup = ios_group.find_subpath(folder, true)
  subgroup.set_source_tree('<group>')
  # RELATIVE to the parent group (which already carries path "KataGo iOS").
  # Setting "KataGo iOS/#{folder}" here would double to "KataGo iOS/KataGo iOS/#{folder}".
  subgroup.set_path(folder)
  files.each do |fname|
    # physical move (preserve git history)
    system('git', 'mv', "KataGo iOS/#{fname}", "KataGo iOS/#{folder}/#{fname}") or raise "git mv failed: #{fname}"
    # find the existing fileRef by its CURRENT (pre-move) resolved location and reparent + repath
    ref = project.files.find { |f| f.path&.end_with?(fname) && f.real_path.to_s.include?('/KataGo iOS/KataGo iOS/') }
    raise "fileRef not found: #{fname}" unless ref
    ref.move(subgroup)
    ref.path = fname            # bare filename — resolves via the folder group to "KataGo iOS/#{folder}/#{fname}"
  end
end

project.save
puts 'OK: iOS target folded into per-feature folders'
```

- [ ] **Step 2: Run the script**

```bash
cd "ios/KataGo iOS" && ruby fold_ios_target.rb && trash fold_ios_target.rb
```
Expected: `OK: iOS target folded into per-feature folders`.

- [ ] **Step 3: Build iOS + visionOS (the two targets that compile these files)**

```bash
cd "ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug
```
Expected: both succeed. If a file fails to resolve, the fileRef path/group is wrong — inspect that fileRef in the pbxproj and fix its `path`/parent before continuing.

- [ ] **Step 4: Build macOS (regression guard)**

```bash
cd "ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS' -configuration Debug
```
Expected: succeeds (macOS target only references the unmoved shared loader).

- [ ] **Step 5: Run unit tests**

Run `FastTestPlan`. Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: organize iOS target into per-feature folders"
```

## Milestone A checkpoint

- [ ] **Run the full test plan**

```bash
cd "ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -testPlan FullTestPlan
```
Expected: PASS (unit + UI). If green, Milestone A is complete.

---

# Milestone B — Config linchpin (medium risk, isolated)

Extract the 19 GTP command generators off the frozen `ConfigModel` into a pure shared `GtpCommandBuilder`, unify the iOS/macOS config-editing sync into one shared `ConfigEngineSync`, migrate **all** ~50 call sites, then delete the generators. Safety net: equivalence tests prove `GtpCommandBuilder` output equals the live `ConfigModel` output before anything is deleted.

The 19 generators and their exact output (from grounding): `getKataAnalyzeCommand()`/`getKataAnalyzeCommand(analysisInterval:)`, `getKataFastAnalyzeCommand()`, `getKataGenMoveAnalyzeCommands(maxTime:)`, `getKataBoardSizeCommand()`, `getKataKomiCommand()`, `getKataPlayoutDoublingAdvantageCommand()`, `getKataAnalysisWideRootNoiseCommand()`, `getKataRuleCommand()`, computed vars `koRuleCommand`/`scoringRuleCommand`/`taxRuleCommand`/`multiStoneSuicideLegalCommand`/`hasButtonCommand`/`whiteHandicapBonusRuleCommand`/`ruleCommands`, and `getSymmetricHumanAnalysisCommands()`.

## Task B1: Create the pure `GtpCommandBuilder` with equivalence tests

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Session/GtpCommandBuilder.swift`
- Test: `ios/KataGo iOS/KataGo iOSTests/GtpCommandBuilderTests.swift`
- Read for parity: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/ConfigModel.swift:200-688`

**Interfaces — Produces** (all pure, no side effects; parameters replace the `config` reads in the original bodies):
```swift
public enum GtpCommandBuilder {
    public static func analyzeCommand(interval: Int, maxMoves: Int) -> String
    public static func fastAnalyzeCommand(maxMoves: Int) -> String
    public static func genMoveAnalyzeCommands(maxTime: Float, interval: Int, maxMoves: Int) -> [String]
    public static func boardSizeCommand(width: Int, height: Int) -> String
    public static func komiCommand(_ komi: Float) -> String
    public static func playoutDoublingAdvantageCommand(_ value: Float) -> String
    public static func analysisWideRootNoiseCommand(_ value: Float) -> String
    public static func rulesetCommand(_ ruleName: String) -> String
    public static func koRuleCommand(_ text: String) -> String
    public static func scoringRuleCommand(_ text: String) -> String
    public static func taxRuleCommand(_ text: String) -> String
    public static func multiStoneSuicideCommand(_ legal: Bool) -> String
    public static func hasButtonCommand(_ enabled: Bool) -> String
    public static func whiteHandicapBonusCommand(_ text: String) -> String
    public static func ruleCommandsBundle(ko: String, scoring: String, tax: String,
                                          multiStoneSuicide: Bool, hasButton: Bool,
                                          whiteHandicapBonus: String) -> [String]
    public static func symmetricHumanAnalysisCommands(humanSLProfile: String, humanProfileForWhite: String, humanRatioForBlack: Float, humanRatioForWhite: Float) -> [String]
}
```

- [ ] **Step 1: Write the equivalence test (the safety net)**

Create `ios/KataGo iOS/KataGo iOSTests/GtpCommandBuilderTests.swift`. For a matrix of `Config` values, assert each builder function returns the SAME string(s) as the corresponding live `ConfigModel` generator. The expected values come from the live code at run time — no transcription. Representative content (extend the matrix to cover at least 2 distinct configs incl. non-default komi/rules/times):
```swift
//
//  GtpCommandBuilderTests.swift
//  KataGo iOSTests
//

import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

struct GtpCommandBuilderTests {
    private func makeConfigs() -> [Config] {
        let a = Config()                          // defaults
        let b = Config()
        b.komi = 0.5
        b.boardWidth = 13; b.boardHeight = 13
        b.playoutDoublingAdvantage = 1.5
        b.analysisWideRootNoise = 0.1
        b.maxAnalysisMoves = 30
        b.analysisInterval = 25
        b.blackMaxTime = 3; b.whiteMaxTime = 0
        let c = Config()                          // profiles equal (defaults) but ratios differ -> asymmetric
        c.humanRatioForBlack = 0.5
        c.humanRatioForWhite = 0.0
        return [a, b, c]
    }

    @Test func builderMatchesConfigForAllScalarCommands() {
        for c in makeConfigs() {
            #expect(GtpCommandBuilder.analyzeCommand(interval: c.analysisInterval, maxMoves: c.maxAnalysisMoves) == c.getKataAnalyzeCommand())
            #expect(GtpCommandBuilder.fastAnalyzeCommand(maxMoves: c.maxAnalysisMoves) == c.getKataFastAnalyzeCommand())
            #expect(GtpCommandBuilder.boardSizeCommand(width: c.boardWidth, height: c.boardHeight) == c.getKataBoardSizeCommand())
            #expect(GtpCommandBuilder.komiCommand(c.komi) == c.getKataKomiCommand())
            #expect(GtpCommandBuilder.playoutDoublingAdvantageCommand(c.playoutDoublingAdvantage) == c.getKataPlayoutDoublingAdvantageCommand())
            #expect(GtpCommandBuilder.analysisWideRootNoiseCommand(c.analysisWideRootNoise) == c.getKataAnalysisWideRootNoiseCommand())
            #expect(GtpCommandBuilder.rulesetCommand(c.rules[c.rule]) == c.getKataRuleCommand())
            #expect(GtpCommandBuilder.koRuleCommand(c.koRuleText) == c.koRuleCommand)
            #expect(GtpCommandBuilder.scoringRuleCommand(c.scoringRuleText) == c.scoringRuleCommand)
            #expect(GtpCommandBuilder.taxRuleCommand(c.taxRuleText) == c.taxRuleCommand)
            #expect(GtpCommandBuilder.multiStoneSuicideCommand(c.multiStoneSuicideLegal) == c.multiStoneSuicideLegalCommand)
            #expect(GtpCommandBuilder.hasButtonCommand(c.hasButton) == c.hasButtonCommand)
            #expect(GtpCommandBuilder.whiteHandicapBonusCommand(c.whiteHandicapBonusRuleText) == c.whiteHandicapBonusRuleCommand)
        }
    }

    @Test func builderMatchesConfigForArrayCommands() {
        for c in makeConfigs() {
            #expect(GtpCommandBuilder.ruleCommandsBundle(
                ko: c.koRuleText, scoring: c.scoringRuleText, tax: c.taxRuleText,
                multiStoneSuicide: c.multiStoneSuicideLegal, hasButton: c.hasButton,
                whiteHandicapBonus: c.whiteHandicapBonusRuleText) == c.ruleCommands)
            #expect(GtpCommandBuilder.genMoveAnalyzeCommands(maxTime: c.blackMaxTime, interval: c.analysisInterval, maxMoves: c.maxAnalysisMoves)
                    == c.getKataGenMoveAnalyzeCommands(maxTime: c.blackMaxTime))
            #expect(GtpCommandBuilder.symmetricHumanAnalysisCommands(humanSLProfile: c.humanSLProfile, humanProfileForWhite: c.humanProfileForWhite, humanRatioForBlack: c.humanRatioForBlack, humanRatioForWhite: c.humanRatioForWhite)
                    == c.getSymmetricHumanAnalysisCommands())
        }
    }
}
```
> NOTE on exact parameter names: while writing the test, open `ConfigModel.swift` and confirm the exact stored-property names each generator reads (e.g. `rule`, `rules`, `koRuleText`, `humanProfileForBlack/White`); adjust the call arguments above to match. The asserted *right-hand side* is the live generator, so the test cannot silently pass with wrong formatting.

Register the test file via the `register_test.rb` snippet from Task A2 (substituting the filename), then `trash` it.

- [ ] **Step 2: Run the test to verify it fails**

Run `FastTestPlan`. Expected: FAIL to compile — `GtpCommandBuilder` undefined.

- [ ] **Step 3: Implement `GtpCommandBuilder` by relocating the generator bodies**

Create `GtpCommandBuilder.swift`. For each function, **move the body of the corresponding `ConfigModel` generator** (`ConfigModel.swift:200-688`), replacing every `self.`/`config.` stored-property read with the function's parameter. Do not change formatting, rounding, string interpolation, or array order. Header:
```swift
//
//  GtpCommandBuilder.swift
//  KataGoUICore
//
//  Pure Config -> GTP command-string mapping. Relocated from ConfigModel so the
//  frozen SwiftData @Model no longer generates GTP. No side effects.
//
import Foundation
```
Composite functions:
- `analyzeCommand` / `fastAnalyzeCommand` / `genMoveAnalyzeCommands`: relocate from `getKataAnalyzeCommand(analysisInterval:)`, `getKataFastAnalyzeCommand()`, `getKataGenMoveAnalyzeCommands(maxTime:)`.
- `ruleCommandsBundle`: returns the six rule strings in the SAME order `ConfigModel.ruleCommands` uses — build it by calling the six individual rule builders so order is guaranteed.
- `symmetricHumanAnalysisCommands`: relocate the body of `getSymmetricHumanAnalysisCommands()`. It takes `humanSLProfile`, `humanProfileForWhite`, `humanRatioForBlack`, `humanRatioForWhite` and replicates `isEqualBlackWhiteHumanSettings` EXACTLY — `(humanSLProfile == humanProfileForWhite) && (humanRatioForBlack == humanRatioForWhite)` — returning `HumanSLModel(profile: humanSLProfile)?.commands ?? []` when equal, else `[]`. Profile equality ALONE is insufficient; the ratio check is required to preserve behavior.
- `rulesetCommand` (from `getKataRuleCommand()`, `kata-set-rules …`): this generator appears in **no** migration table in Task B4 — it has no live app caller today. Still add `rulesetCommand` + its equivalence assertion for completeness so B5 can delete `getKataRuleCommand` with proven parity; the builder function will simply be unused (harmless). If, while implementing, a grep confirms zero callers AND you prefer not to carry dead code, you may omit both `rulesetCommand` and its test line — but then still delete `getKataRuleCommand` from `ConfigModel` in B5.

- [ ] **Step 4: Run the test to verify it passes**

Run `FastTestPlan`. Expected: PASS — proves byte-for-byte parity with the live generators.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add pure GtpCommandBuilder with equivalence tests vs ConfigModel"
```

## Task B2: Move `ConfigEngineSync` into the shared package, layered over `GtpCommandBuilder`

`ConfigEngineSync` is today a macOS-only `@MainActor enum` in `ConfigEditingSupport.swift` (lines 31–301) with 12 static methods + private `rearmAnalysis` (291–300). Move it into `KataGoUICore` (so iOS can use it too), make it `public`, and rewire its internals to call `GtpCommandBuilder` instead of `config.get*Command()`. Leave `ConfigFormBuilder` (AppKit `NSView` row builders, 317–404) in the macOS file — it owns no command logic.

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Session/ConfigEngineSync.swift`
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/ConfigEditingSupport.swift` (remove the `ConfigEngineSync` enum; keep `ConfigFormBuilder`)
- Test: extend `ios/KataGo iOS/KataGo iOSTests/GtpCommandBuilderTests.swift` (or a new `ConfigEngineSyncTests.swift`)

**Interfaces — Produces (public):** the existing 12 methods plus the iOS-needed additions, all `public static`:
```swift
public enum ConfigEngineSync {
    public static func setKomi(_ newValue: Float, config: Config, messageList: MessageList)
    public static func setKoRule(_ koRule: KoRule, config: Config, messageList: MessageList)
    public static func setScoringRule(_ scoringRule: ScoringRule, config: Config, messageList: MessageList)
    public static func setTaxRule(_ taxRule: TaxRule, config: Config, messageList: MessageList)
    public static func setMultiStoneSuicideLegal(_ isOn: Bool, config: Config, messageList: MessageList)
    public static func setHasButton(_ isOn: Bool, config: Config, messageList: MessageList)
    public static func setWhiteHandicapBonusRule(_ rule: WhiteHandicapBonusRule, config: Config, messageList: MessageList)
    public static func setPlayoutDoublingAdvantage(_ newValue: Float, config: Config, messageList: MessageList)
    public static func setAnalysisWideRootNoise(_ newValue: Float, config: Config, messageList: MessageList)
    public static func setBlackHumanProfile(_ profile: String, config: Config, player: Turn, messageList: MessageList)
    public static func setWhiteHumanProfile(_ profile: String, config: Config, player: Turn, messageList: MessageList)
    public static func setBlackMaxTime(_ seconds: Float, config: Config, gobanState: GobanState, player: Turn, messageList: MessageList)
    public static func setWhiteMaxTime(_ seconds: Float, config: Config, gobanState: GobanState, player: Turn, messageList: MessageList)
    public static func setMaxAnalysisMoves(_ value: Int, config: Config, gobanState: GobanState, player: Turn, messageList: MessageList)
    public static func setAnalysisInterval(_ value: Int, config: Config, gobanState: GobanState, player: Turn, messageList: MessageList)
    public static func setAnalysisForWhom(_ index: Int, config: Config)
}
```

- [ ] **Step 1: Move and re-scope the type**

Cut the entire `ConfigEngineSync` enum (incl. `private static func rearmAnalysis`) from `ConfigEditingSupport.swift` into the new `Session/ConfigEngineSync.swift`. Mark the enum and every method `public` (keep `rearmAnalysis` private). Header:
```swift
//
//  ConfigEngineSync.swift
//  KataGoUICore
//
//  Shared orchestrator: applies a Config edit and emits the matching GTP via
//  GtpCommandBuilder, re-arming analysis where required. Used by iOS ConfigView
//  and the macOS Inspector/Config-Editor controllers so both emit identical GTP.
//
import Foundation
```

- [ ] **Step 2: Rewire internals to `GtpCommandBuilder`**

Inside each method, replace any `config.get*Command()` / `config.<x>Command` call with the matching `GtpCommandBuilder.*` call (passing the config fields). Keep all validation (`clampKomi`, noise `0...1` clamp, komi ±1000 round-to-0.5), all `messageList.appendAndSend` ordering, the per-color human-profile gating, and `rearmAnalysis` semantics byte-identical.

- [ ] **Step 3: Add the iOS-needed methods that don't exist yet**

The macOS enum already covers most. Add any missing methods iOS needs (see Task B3 mapping): ensure `setPlayoutDoublingAdvantage`, `setBlackHumanProfile`, `setWhiteHumanProfile`, and prop-only/`re-arm` setters (`setMaxAnalysisMoves`, `setAnalysisInterval`, `setBlackMaxTime`, `setWhiteMaxTime`, `setAnalysisForWhom`) all exist with the signatures above. For human profiles, preserve the exact turn-gating used inline on iOS today (`player.nextColorForPlayCommand != .white/.black`) and the `HumanSLModel(...).commands` send.

- [ ] **Step 4: Add a focused unit test for an orchestrator method**

Add to the test file a test that a representative `ConfigEngineSync` call mutates the config and enqueues the expected command into a `MessageList` (use a `Config()` + a real `MessageList`; assert `messageList.messages.last` contains the expected `GtpCommandBuilder` string). Example:
```swift
@Test func setKomiUpdatesConfigAndEnqueuesKomiCommand() {
    let config = Config(); let messageList = MessageList()
    ConfigEngineSync.setKomi(6.5, config: config, messageList: messageList)
    #expect(config.komi == 6.5)
    #expect(messageList.messages.last?.text == "> \(GtpCommandBuilder.komiCommand(6.5))")
}
```

- [ ] **Step 5: Build all three platforms + run tests**

The macOS `ConfigEditingSupport.swift` still compiles (it kept `ConfigFormBuilder`); the macOS controllers still call `ConfigEngineSync.*` (now resolved from `KataGoUICore`). Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: move ConfigEngineSync into KataGoUICore over GtpCommandBuilder"
```

## Task B3: Route iOS `ConfigView` edits through the shared `ConfigEngineSync`

Replace the iOS inline `messageList.appendAndSend(command: config.get*Command())` `onChange` handlers with `ConfigEngineSync.*` calls so iOS and macOS emit identical GTP from one code path.

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/Config/ConfigView.swift` (post-A4 path)

**Exact per-site migration** (`ConfigView.swift`):
| Line | Before | After |
|------|--------|-------|
| 218 | `messageList.appendAndSend(command: config.koRuleCommand)` | `ConfigEngineSync.setKoRule(koRule, config: config, messageList: messageList)` |
| 233 | `…config.scoringRuleCommand)` | `ConfigEngineSync.setScoringRule(scoringRule, config: config, messageList: messageList)` |
| 248 | `…config.taxRuleCommand)` | `ConfigEngineSync.setTaxRule(taxRule, config: config, messageList: messageList)` |
| 258 | `…config.multiStoneSuicideLegalCommand)` | `ConfigEngineSync.setMultiStoneSuicideLegal(multiStoneSuicideLegal, config: config, messageList: messageList)` |
| 268 | `…config.hasButtonCommand)` | `ConfigEngineSync.setHasButton(hasButton, config: config, messageList: messageList)` |
| 283 | `…config.whiteHandicapBonusRuleCommand)` | `ConfigEngineSync.setWhiteHandicapBonusRule(rule, config: config, messageList: messageList)` |
| 297 | `…config.getKataKomiCommand())` | `ConfigEngineSync.setKomi(config.komi, config: config, messageList: messageList)` |
| 386 | `…config.getKataAnalysisWideRootNoiseCommand())` | `ConfigEngineSync.setAnalysisWideRootNoise(config.analysisWideRootNoise, config: config, messageList: messageList)` |
| 433 | `…config.getKataPlayoutDoublingAdvantageCommand())` | `ConfigEngineSync.setPlayoutDoublingAdvantage(newValue, config: config, messageList: messageList)` |
| 446–451 | inline Black human-profile gate | `ConfigEngineSync.setBlackHumanProfile(newValue, config: config, player: player, messageList: messageList)` |
| 481–483 | inline White human-profile gate | `ConfigEngineSync.setWhiteHumanProfile(newValue, config: config, player: player, messageList: messageList)` |

> The `onChange` closures currently also set the local config property and (for komi/noise/advantage) parse/clamp text before sending. Because `ConfigEngineSync.set*` performs the same property write + clamp internally, remove the now-duplicated inline property writes for those fields so the value is set exactly once. For the human-profile sites, the closure also sets `blackHumanSLModel.profile`/`whiteHumanSLModel.profile`; keep those local view-model writes and let `ConfigEngineSync.setBlack/WhiteHumanProfile` own the config write + gated send.

> The prop-only sites (analysisForWhom 360–362, maxAnalysisMoves 393–395, analysisInterval 401–403, blackMaxTime 465–467, whiteMaxTime 498–500) currently set a config property with no immediate GTP (they are re-armed downstream). Route them through the matching `ConfigEngineSync.set*` so the re-arm path is shared with macOS. Confirm via the milestone manual run that analysis re-arms exactly as before.

- [ ] **Step 1: Apply the table edits to `ConfigView.swift`**

Make each replacement above; ensure the local picker/text binding variable names (`koRule`, `scoringRule`, `taxRule`, `rule`, `newValue`, …) match what each `onChange` provides.

- [ ] **Step 2: Build iOS + visionOS**

Run the iOS and visionOS builds. Expected: PASS.

- [ ] **Step 3: Run unit tests**

Run `FastTestPlan`. Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor: route iOS ConfigView edits through shared ConfigEngineSync"
```

## Task B4: Migrate the analysis-arming and session-setup callers to `GtpCommandBuilder`

These call the generators outside config-editing. Replace each with the equivalent `GtpCommandBuilder` call so the generators can be deleted in B5.

**Files & exact migrations:**

`KataGoUICore/Sources/KataGoUICore/Model/GobanState.swift`:
| Line | Before | After |
|------|--------|-------|
| 80 | `config.getKataGenMoveAnalyzeCommands(maxTime: config.blackMaxTime)` | `GtpCommandBuilder.genMoveAnalyzeCommands(maxTime: config.blackMaxTime, interval: config.analysisInterval, maxMoves: config.maxAnalysisMoves)` |
| 82 | `config.getKataGenMoveAnalyzeCommands(maxTime: config.whiteMaxTime)` | `GtpCommandBuilder.genMoveAnalyzeCommands(maxTime: config.whiteMaxTime, interval: config.analysisInterval, maxMoves: config.maxAnalysisMoves)` |
| 86 | `[config.getKataFastAnalyzeCommand()]` | `[GtpCommandBuilder.fastAnalyzeCommand(maxMoves: config.maxAnalysisMoves)]` |
| 764 | `messageList.appendAndSend(commands: config.ruleCommands)` | `messageList.appendAndSend(commands: GtpCommandBuilder.ruleCommandsBundle(ko: config.koRuleText, scoring: config.scoringRuleText, tax: config.taxRuleText, multiStoneSuicide: config.multiStoneSuicideLegal, hasButton: config.hasButton, whiteHandicapBonus: config.whiteHandicapBonusRuleText))` |
| 765 | `…config.getKataKomiCommand())` | `…GtpCommandBuilder.komiCommand(config.komi))` |
| 766 | `…config.getKataPlayoutDoublingAdvantageCommand())` | `…GtpCommandBuilder.playoutDoublingAdvantageCommand(config.playoutDoublingAdvantage))` |
| 767 | `…config.getKataAnalysisWideRootNoiseCommand())` | `…GtpCommandBuilder.analysisWideRootNoiseCommand(config.analysisWideRootNoise))` |
| 768 | `…config.getSymmetricHumanAnalysisCommands())` | `…GtpCommandBuilder.symmetricHumanAnalysisCommands(humanSLProfile: config.humanSLProfile, humanProfileForWhite: config.humanProfileForWhite, humanRatioForBlack: config.humanRatioForBlack, humanRatioForWhite: config.humanRatioForWhite))` |

`KataGoUICore/Sources/KataGoUICore/Session/GameSession.swift` (`sendInitialCommands`, 101–108): apply the same substitutions — `getKataBoardSizeCommand()` → `GtpCommandBuilder.boardSizeCommand(width: config.boardWidth, height: config.boardHeight)`; `ruleCommands` → `ruleCommandsBundle(...)`; `getKataKomiCommand()` → `komiCommand(config.komi)`; `getKataPlayoutDoublingAdvantageCommand()` → `playoutDoublingAdvantageCommand(config.playoutDoublingAdvantage)`; `getKataAnalysisWideRootNoiseCommand()` → `analysisWideRootNoiseCommand(config.analysisWideRootNoise)`; `getSymmetricHumanAnalysisCommands()` → `symmetricHumanAnalysisCommands(humanSLProfile: config.humanSLProfile, humanProfileForWhite: config.humanProfileForWhite, humanRatioForBlack: config.humanRatioForBlack, humanRatioForWhite: config.humanRatioForWhite)`. Leave line 105 (`kata-set-rule friendlyPassOk false` literal) unchanged.

`KataGo iOS/Game/GameSplitView.swift` (post-A4 path):
| Line | Before | After |
|------|--------|-------|
| 335 | `…config.getKataPlayoutDoublingAdvantageCommand())` | `…GtpCommandBuilder.playoutDoublingAdvantageCommand(config.playoutDoublingAdvantage))` |
| 336 | `…config.getKataAnalysisWideRootNoiseCommand())` | `…GtpCommandBuilder.analysisWideRootNoiseCommand(config.analysisWideRootNoise))` |
| 492 | `…config.getKataAnalyzeCommand())` | `…GtpCommandBuilder.analyzeCommand(interval: config.analysisInterval, maxMoves: config.maxAnalysisMoves))` |

`KataGo Anytime Mac/MainWindowController.swift`:
| Line | Before | After |
|------|--------|-------|
| 1133 | `command: gameRecord.concreteConfig.getKataAnalyzeCommand()` | `command: GtpCommandBuilder.analyzeCommand(interval: gameRecord.concreteConfig.analysisInterval, maxMoves: gameRecord.concreteConfig.maxAnalysisMoves)` |
| 1342 | `…config.getKataPlayoutDoublingAdvantageCommand())` | `…GtpCommandBuilder.playoutDoublingAdvantageCommand(config.playoutDoublingAdvantage))` |
| 1343 | `…config.getKataAnalysisWideRootNoiseCommand())` | `…GtpCommandBuilder.analysisWideRootNoiseCommand(config.analysisWideRootNoise))` |
(Line 1056 is a comment — leave it, or update the prose reference if desired.)

- [ ] **Step 1: Apply all migrations in the table**

Edit the four files exactly as above. The equivalence tests from B1 already guarantee these substitutions produce identical output.

- [ ] **Step 2: Confirm no non-config-editing generator calls remain**

```bash
cd "ios/KataGo iOS"
grep -rnE 'config\.(getKata|koRuleCommand|scoringRuleCommand|taxRuleCommand|multiStoneSuicideLegalCommand|hasButtonCommand|whiteHandicapBonusRuleCommand|ruleCommands|getSymmetricHumanAnalysisCommands)' \
  "KataGoUICore/Sources/KataGoUICore/Model/GobanState.swift" \
  "KataGoUICore/Sources/KataGoUICore/Session/GameSession.swift" \
  "KataGo iOS/Game/GameSplitView.swift" \
  "KataGo Anytime Mac/MainWindowController.swift" | grep -v '//'
```
Expected: no output.

- [ ] **Step 3: Build all three platforms + run unit tests**

Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor: migrate analysis/setup callers to GtpCommandBuilder"
```

## Task B5: Delete the 19 generators from `ConfigModel`; milestone verification

Now that every caller uses `GtpCommandBuilder` (direct or via `ConfigEngineSync`), delete the command-generation methods from the frozen `@Model`. Only methods/computed vars are removed — no stored property changes.

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/ConfigModel.swift` (remove the 19 generators)
- Modify: `ios/KataGo iOS/KataGo iOSTests/GtpCommandBuilderTests.swift` (convert the equivalence tests to standalone literal assertions)

- [ ] **Step 1: Snapshot the proven outputs, then convert the equivalence tests**

The B1 equivalence tests reference the soon-to-be-deleted generators, so they must become self-contained. Before deleting, capture the exact strings: temporarily add `print()` of each builder output in a test run (or read them from the green test output), then rewrite each `#expect(builder == config.getX())` as `#expect(builder == "<captured literal>")`. Keep the same `Config` matrix. This preserves the characterization coverage without referencing `ConfigModel`.

- [ ] **Step 2: Delete the 19 generators from `ConfigModel.swift`**

Remove `getKataAnalyzeCommand()` / `getKataAnalyzeCommand(analysisInterval:)`, `getKataFastAnalyzeCommand()`, `getKataGenMoveAnalyzeCommands(maxTime:)`, `getKataBoardSizeCommand()`, `getKataKomiCommand()`, `getKataPlayoutDoublingAdvantageCommand()`, `getKataAnalysisWideRootNoiseCommand()`, `getKataRuleCommand()`, the computed vars `koRuleCommand`/`scoringRuleCommand`/`taxRuleCommand`/`multiStoneSuicideLegalCommand`/`hasButtonCommand`/`whiteHandicapBonusRuleCommand`/`ruleCommands`, and `getSymmetricHumanAnalysisCommands()`. Leave all stored properties, rule enums, labels, and the `*Text` computed accessors that `GtpCommandBuilder` callers still read.

- [ ] **Step 3: Confirm the generators are gone and unreferenced**

```bash
cd "ios/KataGo iOS"
grep -rnE 'getKata(Analyze|FastAnalyze|GenMoveAnalyze|BoardSize|Komi|PlayoutDoublingAdvantage|AnalysisWideRootNoise|Rule)Command|getSymmetricHumanAnalysisCommands|\bruleCommands\b' \
  KataGoUICore "KataGo iOS" "KataGo Anytime Mac" | grep -vE 'DerivedData|/\.build/|GtpCommandBuilder|//'
```
Expected: no output (all command generation now lives in `GtpCommandBuilder`).

- [ ] **Step 4: Build all three platforms + run unit tests**

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: remove GTP command generation from frozen ConfigModel"
```

## Milestone B checkpoint

- [ ] **Run the full test plan**

```bash
cd "ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -testPlan FullTestPlan
```
Expected: PASS.

- [ ] **Manual iOS run — config parity**

Launch the iOS app (simulator). Open a game, open Config, and change: komi, ko/scoring/tax rules, multi-stone suicide, has-button, white handicap bonus, playout doubling advantage, analysis wide root noise, max analysis moves, analysis interval, time/move, and a human profile. Confirm analysis behaves exactly as before (re-arms, no stalls) and (via the GTP console / `CommandView`) the emitted commands are unchanged.

- [ ] **Manual macOS run — config parity**

Launch `KataGo Anytime Mac`. Repeat the same edits via the Inspector Info tab and the Config Editor sheet. Confirm identical behavior. If both manual runs pass, Milestone B is complete.

---

# Milestone C — Layer & ownership cleanup (medium risk, package-internal)

## Task C1: Centralize SGF parsing in a Session-layer `SgfOperations`

Model code (`GobanState`, `GameRecord`) constructs the Bridge `SgfHelper` directly (7 + 3 sites). Introduce a Session-layer `SgfOperations` with an API mirroring `SgfHelper` so call sites are a drop-in type swap, keeping the build-once/loop-many pattern (no per-call re-parsing). After this, `SgfHelper` is constructed in exactly one place outside the Bridge folder.

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Session/SgfOperations.swift`
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/GobanState.swift` (sites 484, 542, 583, 657, 665, 737)
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/GameRecord.swift` (sites 372, 440, 529)
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Session/GameSession.swift:339` (passes `sgfHelper:` into `maybeUpdateMoves`)
- Test: `ios/KataGo iOS/KataGo iOSTests/SgfOperationsTests.swift`

**Interfaces — Produces** (mirror of `SgfHelper`, instance wrapper):
```swift
public final class SgfOperations {
    public init(sgf: String)
    public func getMove(at index: Int) -> Move?
    public func getComment(at index: Int) -> String?
    public var moveSize: Int?
    public var xSize: Int
    public var ySize: Int
    public var rules: Rules
}
```

- [ ] **Step 1: Write the failing test**

Create `ios/KataGo iOS/KataGo iOSTests/SgfOperationsTests.swift` asserting `SgfOperations` returns the same results as `SgfHelper` for a known SGF:
```swift
import Testing
@testable import KataGoUICore

struct SgfOperationsTests {
    private let sgf = "(;FF[4]GM[1]SZ[19]KM[6.5];B[pd];W[dp])"

    @Test func mirrorsSgfHelperForBasics() {
        let ops = SgfOperations(sgf: sgf)
        let ref = SgfHelper(sgf: sgf)
        #expect(ops.moveSize == ref.moveSize)
        #expect(ops.xSize == ref.xSize)
        #expect(ops.ySize == ref.ySize)
        #expect(ops.getMove(at: 0)?.location.x == ref.getMove(at: 0)?.location.x)
        #expect(ops.rules.komi == ref.rules.komi)
    }
}
```
Register it via the `register_test.rb` snippet (Task A2), then `trash` it.

- [ ] **Step 2: Run the test to verify it fails**

Run `FastTestPlan`. Expected: FAIL to compile — `SgfOperations` undefined.

- [ ] **Step 3: Implement `SgfOperations` as a thin `SgfHelper` wrapper**

```swift
//
//  SgfOperations.swift
//  KataGoUICore
//
//  Session-layer access point for SGF parsing. Wraps the Bridge SgfHelper so the
//  Model layer no longer constructs the C++ bridge parser directly; SGF parsing
//  is created in exactly one place. Instance-based to preserve the
//  build-once/loop-many pattern of the navigation call sites.
//
import Foundation

public final class SgfOperations {
    private let helper: SgfHelper
    public init(sgf: String) { self.helper = SgfHelper(sgf: sgf) }
    public func getMove(at index: Int) -> Move? { helper.getMove(at: index) }
    public func getComment(at index: Int) -> String? { helper.getComment(at: index) }
    public var moveSize: Int? { helper.moveSize }
    public var xSize: Int { helper.xSize }
    public var ySize: Int { helper.ySize }
    public var rules: Rules { helper.rules }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run `FastTestPlan`. Expected: PASS.

- [ ] **Step 5: Swap Model call sites to `SgfOperations`**

In `GobanState.swift` and `GameRecord.swift`, replace each `SgfHelper(sgf:)` construction with `SgfOperations(sgf:)`. The method/property names are identical, so no other changes at those sites. Sites: GobanState 484, 542, 583, 657, 665 (the `?? SgfOperations(sgf:)` default), 737; GameRecord 372, 440, 529.

- [ ] **Step 6: Change `maybeUpdateMoves`'s reuse parameter type**

`GobanState.maybeUpdateMoves(gameRecord:board:sgfHelper: SgfHelper? = nil)` (line 665): change the parameter to `sgfHelper: SgfOperations? = nil` (keep the external label `sgfHelper:` to avoid churn, or rename to `sgfOperations:` and update both callers). Update the two callers: `CommentView.swift:95` (uses the default — no change needed if the label stays) and `GameSession.swift:339` (builds the reuse instance — change its local `SgfHelper(sgf:)` to `SgfOperations(sgf:)` and pass it in).

- [ ] **Step 7: Confirm Model no longer constructs `SgfHelper` directly**

```bash
cd "ios/KataGo iOS"
grep -rn 'SgfHelper(' KataGoUICore/Sources/KataGoUICore/Model
```
Expected: no output. (`SgfHelper(` should now appear only in `Session/SgfOperations.swift` and `Session/MoveNumbers.swift` — `MoveNumbers` is already Session-layer; optionally switch it to `SgfOperations` too for consistency, but it is not a layer violation.)

- [ ] **Step 8: Build all three platforms + run unit tests**

Expected: all PASS.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "refactor: route Model SGF parsing through Session-layer SgfOperations"
```

## Task C2: Make `GameSession` the sole engine owner

`MessageList` holds its own `engine` (default `InProcessKataGoEngine()`, `KataGoModel.swift:519-520`), reconciled with `GameSession.engine` only by `useEngine(_:)`. Remove the duplicate; have `MessageList` send through a weak reference to its owning `GameSession`.

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/KataGoModel.swift` (`MessageList`, 508–540)
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Session/GameSession.swift` (`init`, `useEngine`)
- Test: `ios/KataGo iOS/KataGo iOSTests/MessageListEngineOwnershipTests.swift`

**Interfaces — Produces:**
```swift
// MessageList gains:
public weak var session: GameSession?   // @ObservationIgnored
// MessageList loses: public var engine: KataGoEngineIO
// GameSession.useEngine(_:) now sets only self.engine
```

- [ ] **Step 1: Write the failing test**

Create `ios/KataGo iOS/KataGo iOSTests/MessageListEngineOwnershipTests.swift` with a stub engine to prove `appendAndSend` routes through `GameSession.engine`:
```swift
import Testing
@testable import KataGoUICore

@MainActor
final class RecordingEngine: KataGoEngineIO {
    var sent: [String] = []
    func sendCommand(_ command: String) { sent.append(command) }
    func getMessageLine() -> String { "" }
    var hasReachedEOF: Bool { false }
}

@MainActor
struct MessageListEngineOwnershipTests {
    @Test func appendAndSendRoutesThroughSessionEngine() {
        let session = GameSession()
        let engine = RecordingEngine()
        session.useEngine(engine)
        session.messageList.appendAndSend(command: "version")
        #expect(engine.sent == ["version"])
    }
}
```
> While writing this, open `Bridge/KataGoEngineIO.swift` and match the exact protocol requirements (method names, `async`/actor annotations) for `RecordingEngine`. Register the test file via `register_test.rb`, then `trash` it.

- [ ] **Step 2: Run the test to verify it fails or is wrong-pathed**

Run `FastTestPlan`. Expected: with the current dual-ownership code it would pass via `messageList.engine`; this test instead pins the *target* wiring. If it passes now, that's because `useEngine` still sets `messageList.engine` — proceed to make the source change so the test passes via the new path.

- [ ] **Step 3: Update `MessageList`**

In `KataGoModel.swift`: remove the `engine` property + its `InProcessKataGoEngine()` default (519–520). Add:
```swift
@ObservationIgnored
public weak var session: GameSession?
```
Change `appendAndSend(command:)` (532–535) to:
```swift
public func appendAndSend(command: String) {
    append(command: command)
    session?.engine.sendCommand(command)
}
```
Leave `appendAndSend(commands:)` (delegates) unchanged.

- [ ] **Step 4: Update `GameSession`**

In `GameSession.swift`: set the back-reference in `init` (line 47):
```swift
public init() {
    messageList.session = self
}
```
Change `useEngine(_:)` (53–56) to set only the session engine:
```swift
public func useEngine(_ engine: KataGoEngineIO) {
    self.engine = engine
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run `FastTestPlan`. Expected: PASS — `appendAndSend` now routes through `session?.engine`.

- [ ] **Step 6: Build all three platforms + run unit tests**

iOS/visionOS use the default in-process engine (unchanged behavior since `GameSession.engine` defaults to `InProcessKataGoEngine()`); macOS injects via `useEngine` (still works). Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor: make GameSession the sole engine owner"
```

## Milestone C checkpoint

- [ ] **Run the full test plan**

```bash
cd "ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -testPlan FullTestPlan
```
Expected: PASS. If green, Milestone C — and the organization-core refactor — is complete.

---

## Final verification (whole effort)

- [ ] All three platforms build (iOS, visionOS, macOS).
- [ ] `FullTestPlan` passes.
- [ ] `git log --oneline ios-dev..HEAD` shows ~11 focused commits, one per task.
- [ ] Success criteria (from the spec) all met:
  - `CoreMLComputeHandleLoader` duplication eliminated (one physical file).
  - `GlobalSettings` keys and config→GTP logic each defined once, shared across platforms.
  - `ConfigModel` no longer generates GTP commands; Model no longer constructs the Bridge `SgfHelper`.
  - `GameSession` is the single engine owner.
  - iOS target organized into per-feature folders; repo free of stale dirs and the unreferenced PNG.
- [ ] No `git push` performed (left to the user).
