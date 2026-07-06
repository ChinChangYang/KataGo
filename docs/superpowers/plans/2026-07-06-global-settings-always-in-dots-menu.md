# Global Settings Always in the Dots Menu — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an always-visible "Global Settings" item to the dots (ellipsis) menu of the iOS/visionOS app that opens `GlobalSettingsView` directly, so global settings are reachable even when no game is selected.

**Architecture:** Single change site — every dots-menu surface (game-list toolbar, goban toolbar, fallback screens) renders the same `PlusMenuView`, so one edit covers all. The new item sits in an unconditional settings section anchored by a divider, above the existing game-gated Configurations/Developer Mode/Deep Report block, and presents `NavigationStack { GlobalSettingsView() }` as a sheet. One new UI test proves the item exists and opens with no game selected.

**Tech Stack:** SwiftUI (iOS 26+/visionOS 26+), XCTest UI tests, xcodeproj Ruby gem (file registration).

**Spec:** `docs/superpowers/specs/2026-07-06-global-settings-always-in-dots-menu-design.md`

## Global Constraints

- Only the iOS/visionOS app target (`KataGo iOS/` folder, scheme `KataGo Anytime`) changes. Do NOT touch macOS (`KataGo Anytime Mac/`), tvOS, or watchOS targets.
- Working directory for all build/test commands: `ios/KataGo iOS` (note the space; always quote).
- English-only source, comments, and UI strings.
- The Xcode project has NO synchronized groups: every new Swift file must be registered in `KataGo Anytime.xcodeproj/project.pbxproj` via the `xcodeproj` Ruby gem (installed, v1.27.0).
- Piped `xcodebuild` exit codes lie (`xcodebuild | tail` exits with tail's status). Always prefix with `set -o pipefail &&` and check for `BUILD SUCCEEDED` / `** TEST SUCCEEDED **` in output.
- UI test TARGET is named `KataGo AnytimeUITests`; its DIRECTORY is `KataGo iOSUITests`. `-only-testing:` takes the target name, and `-testPlan FullTestPlan` is required.
- On the iOS Simulator the backend is pinned to CoreML/NE and Debug builds always show the model picker at launch; engine init + CoreML conversion takes minutes (tests use a 360 s wait for the board).
- Commit messages end with:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Existing flaky test note: the PlayerName thinking-time UI test is a known pre-existing flake — do not chase it if it fails in a full-suite run.

---

### Task 1: Failing UI test — Global Settings reachable with no game selected

**Files:**
- Create: `ios/KataGo iOS/KataGo iOSUITests/GlobalSettingsMenuUITests.swift`
- Modify: `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj` (via Ruby script, not by hand)

**Interfaces:**
- Consumes: existing accessibility labels — `"More"` (the `PlusMenuView` menu label), `"Built-in KataGo Network"` + `"ModelDetailView.downloadPlayButton"` (model picker), `"Forward to End"` (board toolbar), `"Games"` (game-list navigation title).
- Produces: a test that requires a menu button labeled **`"Global Settings"`** and a presented navigation bar titled **`"Global Settings"`**. Task 2's implementation must use exactly these strings.

- [ ] **Step 1: Write the failing UI test**

Create `ios/KataGo iOS/KataGo iOSUITests/GlobalSettingsMenuUITests.swift` with exactly:

```swift
//
//  GlobalSettingsMenuUITests.swift
//  KataGo AnytimeUITests
//
//  The dots ("More") menu must offer "Global Settings" even when no game is
//  selected. Regression test for the gap where Global Settings was only
//  reachable via the game-gated Configurations sheet.
//

import XCTest

final class GlobalSettingsMenuUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launches the engine, pops back from the board to the game list
    /// (clearing the selection on compact width), opens the dots menu, and
    /// drills into the Global Settings sheet.
    @MainActor func testGlobalSettingsAvailableWithoutSelectedGame() throws {
        let app = XCUIApplication()
        app.launch()

        // Get past the model picker if it is up (Debug always shows it).
        let row = app.staticTexts["Built-in KataGo Network"]
        if row.waitForExistence(timeout: 20) {
            row.tap()
            let play = app.buttons["ModelDetailView.downloadPlayButton"]
            if play.waitForExistence(timeout: 15) {
                play.tap()
            }
        }

        // Engine init + on-the-fly CoreML conversion is slow on the simulator.
        let forwardEnd = app.buttons["Forward to End"]
        XCTAssertTrue(forwardEnd.waitForExistence(timeout: 360),
                      "Board did not appear (engine never finished launching)")

        // Pop back to the game list so no game is selected (compact width).
        // The back button carries the previous screen's title when it fits.
        let boardBar = app.navigationBars.firstMatch
        let namedBack = boardBar.buttons["Games"]
        if namedBack.waitForExistence(timeout: 5) {
            namedBack.tap()
        } else {
            boardBar.buttons.element(boundBy: 0).tap()  // leading = Back
        }
        XCTAssertTrue(app.navigationBars["Games"].waitForExistence(timeout: 10),
                      "Game list did not appear")

        // The dots menu must contain Global Settings with no game selected.
        let more = app.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 15), "More menu not found")
        more.tap()
        let globalSettings = app.buttons["Global Settings"].firstMatch
        XCTAssertTrue(globalSettings.waitForExistence(timeout: 10),
                      "Global Settings menu item not found")
        globalSettings.tap()

        // The Global Settings sheet opens directly.
        XCTAssertTrue(app.navigationBars["Global Settings"].waitForExistence(timeout: 15),
                      "Global Settings sheet not shown")
    }
}
```

- [ ] **Step 2: Register the file in the Xcode project (Ruby, not by hand)**

Run from `ios/KataGo iOS`:

```bash
cd "ios/KataGo iOS" && ruby -e '
require "xcodeproj"
project = Xcodeproj::Project.open("KataGo Anytime.xcodeproj")
target = project.targets.find { |t| t.name == "KataGo AnytimeUITests" }
raise "UI test target not found" unless target
existing = project.files.find { |f| f.path&.end_with?("BackendConfigSheetUITests.swift") }
raise "anchor file not found" unless existing
group = existing.parent
file_ref = group.new_reference("GlobalSettingsMenuUITests.swift")
target.add_file_references([file_ref])
project.save
puts "registered"
'
```

Expected output: `registered`

Verify registration:

```bash
grep -c "GlobalSettingsMenuUITests.swift" "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
```

Expected: `2` or more (file reference + build-phase entry; comment decorations may add more).

- [ ] **Step 3: Run the new test and verify it FAILS for the right reason**

```bash
cd "ios/KataGo iOS" && set -o pipefail && xcodebuild test \
  -project "KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -testPlan FullTestPlan \
  -only-testing:"KataGo AnytimeUITests/GlobalSettingsMenuUITests" \
  2>&1 | tail -40
```

Expected: `** TEST FAILED **` with the assertion message **"Global Settings menu item not found"** (the run takes ~7–10 minutes; the engine launch inside the test dominates). If it instead fails earlier (board never appeared, back button not found), fix the test navigation before proceeding — that is a test bug, not the expected red.

Do NOT commit yet — the tree would be red. Task 2 commits test + implementation together.

---

### Task 2: Implement the always-visible Global Settings menu item

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/GameList/PlusMenuView.swift` (state ~line 24, menu body ~lines 91–114, sheets ~line 119)

**Interfaces:**
- Consumes: `GlobalSettingsView` (internal, defined in `ios/KataGo iOS/KataGo iOS/Config/ConfigView.swift:676`; requires `GobanState` and `ThumbnailModel` in the environment — both already declared by `PlusMenuView`). Test contract from Task 1: menu button label `"Global Settings"`, navigation title `"Global Settings"` (already set inside `GlobalSettingsView`).
- Produces: n/a (terminal task).

- [ ] **Step 1: Add presentation state**

In `PlusMenuView.swift`, below the existing `@State private var showingReport = false` line, add:

```swift
    @State private var showingGlobalSettings = false
```

- [ ] **Step 2: Restructure the settings section of the menu**

Replace this existing block (the game-gated settings section):

```swift
            if gameRecord != nil {
#if !os(visionOS)
                Divider()
#endif

                Button {
                    showingConfig = true
                } label: {
                    Label("Configurations", systemImage: "gearshape")
                }
```

with (divider now unconditional, new always-visible item first, then the
game-gated block continues):

```swift
#if !os(visionOS)
            Divider()
#endif

            Button {
                showingGlobalSettings = true
            } label: {
                Label("Global Settings", systemImage: "gearshape.2")
            }

            if gameRecord != nil {
                Button {
                    showingConfig = true
                } label: {
                    Label("Configurations", systemImage: "gearshape")
                }
```

The rest of the `if gameRecord != nil` block (Developer Mode, Deep Report buttons and the closing brace) stays exactly as it is.

- [ ] **Step 3: Add the sheet**

After the existing `.sheet(isPresented: $showingConfig) { ... }` modifier, add:

```swift
        .sheet(isPresented: $showingGlobalSettings) {
            NavigationStack {
                GlobalSettingsView()
            }
        }
```

(No `#if os(macOS)` frame modifiers — this target builds only iOS/visionOS.)

- [ ] **Step 4: Run the Task 1 UI test and verify it PASSES**

```bash
cd "ios/KataGo iOS" && set -o pipefail && xcodebuild test \
  -project "KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -testPlan FullTestPlan \
  -only-testing:"KataGo AnytimeUITests/GlobalSettingsMenuUITests" \
  2>&1 | tail -40
```

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Build for visionOS Simulator (same target compiles there)**

```bash
cd "ios/KataGo iOS" && set -o pipefail && xcodebuild build \
  -project "KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' \
  -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: English-only sweep of changed files**

```bash
cd "ios/KataGo iOS" && grep -nP '[\x{4E00}-\x{9FFF}\x{3040}-\x{30FF}\x{AC00}-\x{D7AF}]' \
  "KataGo iOS/GameList/PlusMenuView.swift" \
  "KataGo iOSUITests/GlobalSettingsMenuUITests.swift" || echo "clean"
```

Expected: `clean`

- [ ] **Step 7: Commit test + implementation together (tree goes red→green in one commit)**

```bash
cd "ios/KataGo iOS" && git add \
  "KataGo iOS/GameList/PlusMenuView.swift" \
  "KataGo iOSUITests/GlobalSettingsMenuUITests.swift" \
  "KataGo Anytime.xcodeproj/project.pbxproj" && \
git commit -m "feat(ios): always-available Global Settings in dots menu

Global Settings was only reachable through the game-gated Configurations
sheet, so with no game selected there was no path to it at all. Add an
unconditional Global Settings item (gearshape.2) to PlusMenuView that
presents GlobalSettingsView directly; the Configurations link stays.
Covered by GlobalSettingsMenuUITests.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Post-plan verification (optional but recommended)

- Full local test gate (CI runs no tests): run the whole `FullTestPlan` on the iPhone 17 simulator. Budget 30+ minutes; the PlayerName thinking-time test is a known pre-existing flake — rerun or ignore it, do not chase.
- Manual smoke on the iPhone simulator: with a game open, the menu shows Global Settings AND Configurations (two gear icons, `gearshape.2` vs `gearshape`); on iPad/visionOS "Select a game" screen, the menu shows Global Settings.
