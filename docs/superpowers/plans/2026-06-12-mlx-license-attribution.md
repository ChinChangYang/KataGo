# In-App Open-Source License Attribution — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **PROJECT RULE — commits:** The user's standing rule is **commit only when explicitly asked**. The `git commit` steps below are shown for completeness and structure. When executing, **stage the work and pause** for the user to say "commit" rather than committing automatically. Never push.

**Goal:** Add an in-app "Open-Source Licenses" screen that reproduces the verbatim license text of every third-party component shipped in the iOS binary, and update `/LICENSE`, so the app meets its MIT/Apache-2.0/BSD-3 attribution obligations before App Store / TestFlight release.

**Architecture:** A static Swift data array (`ThirdPartyLicense.all`, license texts embedded as raw-string constants — no app-resource bundling) drives a SwiftUI list→detail screen (`AcknowledgmentsView` → `LicenseDetailView`) reached from a new third row in the existing *Configurations* screen (`ConfigView`). A Swift Testing unit test guards the data; an XCUITest guards reachability. `/LICENSE` gains a paragraph for the MLX stack.

**Tech Stack:** SwiftUI, Swift Testing (`import Testing`), XCUITest. No C++, no SwiftData, no new dependencies. Module name: `KataGo_Anytime`.

---

## Context an implementer needs

- **No synchronized groups.** New `.swift` files do NOT compile until registered in `project.pbxproj`. Use the `xcodeproj` Ruby gem snippet (below). Ruby: `/usr/local/opt/ruby`; install once: `gem install --user-install xcodeproj`.
- Work from `ios/KataGo iOS/` for all `xcodebuild`/registration commands.
- New **app** Swift files live physically in `ios/KataGo iOS/KataGo iOS/` (same dir as `ConfigView.swift`); registered against app target `KataGo Anytime` using anchor `ContentView.swift`.
- New **unit-test** files register against target `KataGo AnytimeTests`, anchor `NavigationContextTests.swift`. Unit tests use **Swift Testing** and `@testable import KataGo_Anytime`.
- The **UI test** is a new method appended to an EXISTING file (`CoreMLCacheFooterUITests.swift`) — no registration needed. UI tests need `-testPlan FullTestPlan` and target `KataGo AnytimeUITests`; the iOS simulator force-pins the backend to CoreML/NE.
- `xcodebuild` runs sometimes delete `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`; if `git status` shows it deleted, restore with `git restore "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"`.

### The pbxproj registration snippet (run from `ios/KataGo iOS/`)

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
' "<TARGET>" "<ANCHOR_FILE>" "<NEW_FILE>"
```

### Verified component list (16) and exact license-text sources

Each `text:` field is the **verbatim** contents of the listed file (copy exactly — this is a mechanical copy, not a placeholder). Paths are relative to repo root `/Users/chinchangyang/Code/KataGo-ios-dev`.

| name | subtitle | text source |
|------|----------|-------------|
| KataGo | `MIT · David J Wu (lightvector)` | `LICENSE` |
| abseil-cpp | `Apache-2.0 · Google` | `cpp/external/abseil-cpp-20260107.1/LICENSE` |
| coremltools | `BSD-3-Clause · Apple Inc.` | `cpp/external/katagocoreml/vendor/mlmodel/LICENSE.txt` |
| FP16 | `MIT · Facebook Inc.` | `cpp/external/katagocoreml/vendor/deps/FP16/LICENSE` |
| fmt | `MIT · Victor Zverovich` | `ios/KataGo iOS/ThirdParty/mlx-swift/Source/Cmlx/fmt/LICENSE` |
| ghc::filesystem | `MIT · Steffen Schümann` | `cpp/external/filesystem-1.5.8/LICENSE` |
| metal-cpp | `Apache-2.0 · Apple Inc.` | `ios/KataGo iOS/ThirdParty/mlx-swift/Source/Cmlx/metal-cpp/LICENSE.txt` |
| MLX | `MIT · Apple Inc.` | `ios/KataGo iOS/ThirdParty/mlx-swift/Source/Cmlx/mlx/LICENSE` |
| mlx-c | `MIT · ml-explore` | `ios/KataGo iOS/ThirdParty/mlx-swift/Source/Cmlx/mlx-c/LICENSE` |
| mlx-swift | `MIT · ml-explore` | `ios/KataGo iOS/ThirdParty/mlx-swift/LICENSE` |
| nlohmann/json | `MIT · Niels Lohmann` | `ios/KataGo iOS/ThirdParty/mlx-swift/Source/Cmlx/json/LICENSE.MIT` |
| pocketfft | `BSD-3-Clause · Max-Planck-Society, Peter Bell` | header comment block at top of `ios/KataGo iOS/ThirdParty/mlx-swift/Source/Cmlx/mlx/mlx/3rdparty/pocketfft.h` |
| Protocol Buffers | `BSD-3-Clause · Google` | `cpp/external/protobuf-34.1/LICENSE` |
| sha2 | `BSD-3-Clause · Aaron D. Gifford` | the license block in the header comment of `cpp/core/sha2.cpp` |
| swift-numerics | `Apache-2.0 (Runtime Library Exception) · Apple Inc.` | not on disk until SwiftPM resolves; see Task 2 Step 3 |
| TCLAP | `MIT · Michael E. Smoot, Daniel Aarno` | `cpp/external/tclap-1.2.5/COPYING` |

---

## Task 1: Unit test for the license data model

**Files:**
- Create: `ios/KataGo iOS/KataGo iOSTests/ThirdPartyLicensesTests.swift`
- Modify (registration): `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj`

- [ ] **Step 1: Confirm the existing test import style**

Run: `grep -nE "import|@testable" "ios/KataGo iOS/KataGo iOSTests/NavigationContextTests.swift" | head`
Expected: shows `import Testing` and `@testable import KataGo_Anytime` (mirror these exact lines in the new file).

- [ ] **Step 2: Write the failing test**

Create `ios/KataGo iOS/KataGo iOSTests/ThirdPartyLicensesTests.swift`:

```swift
import Testing
@testable import KataGo_Anytime

struct ThirdPartyLicensesTests {
    @Test func listsEveryShippedThirdPartyComponent() {
        let all = ThirdPartyLicense.all

        // Exhaustive list of components compiled/linked into the iOS binary.
        #expect(all.count == 16)

        // Every entry is fully populated with a real license body (not a stub).
        for license in all {
            #expect(!license.name.isEmpty)
            #expect(!license.subtitle.isEmpty)
            #expect(license.text.count > 100)
        }

        // Identifiers are unique (drives SwiftUI List + ForEach).
        #expect(Set(all.map(\.id)).count == all.count)

        // The MLX trigger plus a few representative components are present.
        let names = Set(all.map(\.name))
        for expected in ["KataGo", "MLX", "metal-cpp", "swift-numerics", "coremltools"] {
            #expect(names.contains(expected))
        }
    }
}
```

- [ ] **Step 3: Register the test file**

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
' "KataGo AnytimeTests" "NavigationContextTests.swift" "ThirdPartyLicensesTests.swift"
```

- [ ] **Step 4: Run the test to verify it fails (red)**

Run: `xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/ThirdPartyLicensesTests"`
Expected: **build failure** — `cannot find 'ThirdPartyLicense' in scope` (the type does not exist yet). This is the expected red state.

- [ ] **Step 5: Stage (commit held — see PROJECT RULE)**

```bash
git add "ios/KataGo iOS/KataGo iOSTests/ThirdPartyLicensesTests.swift" "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
# git commit -m "test(license): failing test for ThirdPartyLicense.all data model"
```

---

## Task 2: License data model + embedded license texts

**Files:**
- Create: `ios/KataGo iOS/KataGo iOS/ThirdPartyLicenses.swift`
- Modify (registration): `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj`

- [ ] **Step 1: Create the model + data scaffold**

Create `ios/KataGo iOS/KataGo iOS/ThirdPartyLicenses.swift` with this exact structure. Use Swift **extended (raw) string delimiters** `#"""` … `"""#` for every `text:` so embedded quotes/backslashes need no escaping.

```swift
import Foundation

/// One third-party component shipped in the app binary, with its verbatim license.
struct ThirdPartyLicense: Identifiable {
    var id: String { name }
    let name: String
    let subtitle: String   // "<license type> · <copyright holder>"
    let text: String       // verbatim license text

    init(name: String, subtitle: String, text: String) {
        self.name = name
        self.subtitle = subtitle
        self.text = text
    }
}

extension ThirdPartyLicense {
    /// Every third-party component compiled into or linked by the iOS app target,
    /// sorted case-insensitively by name for stable display.
    static let all: [ThirdPartyLicense] = unsorted
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

    private static let unsorted: [ThirdPartyLicense] = [
        ThirdPartyLicense(
            name: "MLX",
            subtitle: "MIT · Apple Inc.",
            text: #"""
            MIT License

            Copyright © 2023 Apple Inc.

            Permission is hereby granted, free of charge, to any person obtaining a copy
            of this software and associated documentation files (the "Software"), to deal
            in the Software without restriction, including without limitation the rights
            to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
            copies of the Software, and to permit persons to whom the Software is
            furnished to do so, subject to the following conditions:

            The above copyright notice and this permission notice shall be included in all
            copies or substantial portions of the Software.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
            IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
            FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
            AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
            LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
            OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
            SOFTWARE.
            """#),

        // === Remaining 15 entries — same shape ===
        // For each row in the "Verified component list" table in this plan, add a
        // ThirdPartyLicense(name:, subtitle:, text:) where `text` is the VERBATIM
        // contents of that row's license source file, wrapped in #""" … """#.
        // Required names (exact spelling), all must be present:
        //   KataGo, abseil-cpp, coremltools, FP16, fmt, ghc::filesystem, metal-cpp,
        //   mlx-c, mlx-swift, nlohmann/json, pocketfft, Protocol Buffers, sha2,
        //   swift-numerics, TCLAP
        // (MLX is already provided above as the worked example.)
    ]
}
```

- [ ] **Step 2: Fill in the 15 remaining entries verbatim**

For each remaining component, read its license source file (paths in the "Verified component list" table) and paste the exact contents into a `text: #""" … """#` literal, with the `name`/`subtitle` from that table. Concretely, read each file, e.g.:

Run (examples — repeat per component):
```bash
cat "/Users/chinchangyang/Code/KataGo-ios-dev/cpp/external/abseil-cpp-20260107.1/LICENSE"
cat "/Users/chinchangyang/Code/KataGo-ios-dev/cpp/external/protobuf-34.1/LICENSE"
cat "/Users/chinchangyang/Code/KataGo-ios-dev/cpp/external/tclap-1.2.5/COPYING"
cat "/Users/chinchangyang/Code/KataGo-ios-dev/cpp/external/filesystem-1.5.8/LICENSE"
cat "/Users/chinchangyang/Code/KataGo-ios-dev/cpp/external/katagocoreml/vendor/mlmodel/LICENSE.txt"
cat "/Users/chinchangyang/Code/KataGo-ios-dev/cpp/external/katagocoreml/vendor/deps/FP16/LICENSE"
cat "/Users/chinchangyang/Code/KataGo-ios-dev/LICENSE"
cat "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS/ThirdParty/mlx-swift/LICENSE"
cat "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS/ThirdParty/mlx-swift/Source/Cmlx/mlx-c/LICENSE"
cat "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS/ThirdParty/mlx-swift/Source/Cmlx/metal-cpp/LICENSE.txt"
cat "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS/ThirdParty/mlx-swift/Source/Cmlx/fmt/LICENSE"
cat "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS/ThirdParty/mlx-swift/Source/Cmlx/json/LICENSE.MIT"
```

For **sha2** and **pocketfft**, copy only the license/copyright comment block from the top of the source header (strip the leading `*`/`//` comment markers so the text reads cleanly), from:
```bash
sed -n '1,40p' "/Users/chinchangyang/Code/KataGo-ios-dev/cpp/core/sha2.cpp"
sed -n '1,40p' "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS/ThirdParty/mlx-swift/Source/Cmlx/mlx/mlx/3rdparty/pocketfft.h"
```

- [ ] **Step 3: Obtain the swift-numerics license text**

swift-numerics is a SwiftPM dependency (not vendored in-tree). After at least one build has resolved packages, copy its `LICENSE.txt` verbatim:

```bash
find ~/Library/Developer/Xcode/DerivedData -ipath "*SourcePackages/checkouts/swift-numerics/LICENSE.txt" 2>/dev/null | head -1 | xargs cat
```

If the find returns nothing (packages not yet resolved), run the iOS build once (Task 3 Step 4 command) to populate `SourcePackages/`, then re-run the `find` above. Paste the verbatim Apache-2.0-with-Runtime-Library-Exception text into the `swift-numerics` entry.

- [ ] **Step 4: Register the data file in the app target**

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
' "KataGo Anytime" "ContentView.swift" "ThirdPartyLicenses.swift"
```

- [ ] **Step 5: Run the unit test to verify it passes (green)**

Run: `xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/ThirdPartyLicensesTests"`
Expected: **Test Succeeded** — `listsEveryShippedThirdPartyComponent` passes (count == 16, all texts populated, key names present).

- [ ] **Step 6: Stage (commit held — see PROJECT RULE)**

```bash
git add "ios/KataGo iOS/KataGo iOS/ThirdPartyLicenses.swift" "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
# git commit -m "feat(license): add ThirdPartyLicense data with verbatim third-party licenses"
```

---

## Task 3: Acknowledgments screen + Configurations entry point

**Files:**
- Create: `ios/KataGo iOS/KataGo iOS/AcknowledgmentsView.swift`
- Modify: `ios/KataGo iOS/KataGo iOS/ConfigView.swift` (the `ConfigView` struct, ~lines 799–810)
- Modify (registration): `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj`

- [ ] **Step 1: Create the screen**

Create `ios/KataGo iOS/KataGo iOS/AcknowledgmentsView.swift`. Note: **do not** use `.navigationBarTitleDisplayMode` — it is unavailable on macOS and this view compiles for the macOS target too.

```swift
import SwiftUI

/// Lists every third-party component shipped in the app, with its license.
struct AcknowledgmentsView: View {
    var body: some View {
        List(ThirdPartyLicense.all) { license in
            NavigationLink {
                LicenseDetailView(license: license)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(license.name)
                    Text(license.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier(license.name)
        }
        .navigationTitle("Open-Source Licenses")
    }
}

/// Shows one component's full, verbatim license text.
struct LicenseDetailView: View {
    let license: ThirdPartyLicense

    var body: some View {
        ScrollView {
            Text(license.text)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(license.name)
    }
}
```

- [ ] **Step 2: Add the Configurations row**

In `ios/KataGo iOS/KataGo iOS/ConfigView.swift`, the `ConfigView` body currently is:

```swift
        List {
            NavigationLink("Global Settings") {
                GlobalSettingsView()
            }

            NavigationLink("Game Settings") {
                GameSettingsView(gameRecord: gameRecord, maxBoardLength: maxBoardLength)
            }
        }
        .navigationTitle("Configurations")
```

Add a third row after the Game Settings link:

```swift
        List {
            NavigationLink("Global Settings") {
                GlobalSettingsView()
            }

            NavigationLink("Game Settings") {
                GameSettingsView(gameRecord: gameRecord, maxBoardLength: maxBoardLength)
            }

            NavigationLink("Open-Source Licenses") {
                AcknowledgmentsView()
            }
        }
        .navigationTitle("Configurations")
```

- [ ] **Step 3: Register the view file in the app target**

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
' "KataGo Anytime" "ContentView.swift" "AcknowledgmentsView.swift"
```

- [ ] **Step 4: Build the app for iOS to verify it compiles**

Run: `xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug`
Expected: **BUILD SUCCEEDED**. (This also resolves SwiftPM packages, populating `SourcePackages/` for Task 2 Step 3 if not done yet.)

- [ ] **Step 5: Stage (commit held — see PROJECT RULE)**

```bash
git add "ios/KataGo iOS/KataGo iOS/AcknowledgmentsView.swift" "ios/KataGo iOS/KataGo iOS/ConfigView.swift" "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
# git commit -m "feat(license): add Open-Source Licenses screen to Configurations"
```

---

## Task 4: UI test — screen is reachable and renders license text

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOSUITests/CoreMLCacheFooterUITests.swift` (append a method after the existing `testDisplayPreferencesMovedToGlobalSettings()`, before `// MARK: - Helpers`)

- [ ] **Step 1: Add the UI test method**

Insert this method into the `CoreMLCacheFooterUITests` class (reuses the existing `builtInTitle`, `tapModelRow`, `tapDownloadOrPlay` helpers):

```swift
    func testOpenSourceLicensesScreen() throws {
        let app = XCUIApplication()
        app.launch()

        // A game must be selected for the "Configurations" menu item to appear.
        tapModelRow(in: app, title: builtInTitle)
        tapDownloadOrPlay(in: app)        // built-in is bundled → play.fill

        let lockButton = app.buttons["Lock"]
        XCTAssertTrue(lockButton.waitForExistence(timeout: 240),
                      "Goban (Lock button) did not appear after launching the built-in engine")

        // Open "More" → "Configurations".
        let moreButton = app.buttons["More"].firstMatch
        XCTAssertTrue(moreButton.waitForExistence(timeout: 10), "More menu button not found")
        moreButton.tap()

        let configurations = app.buttons["Configurations"].firstMatch
        XCTAssertTrue(configurations.waitForExistence(timeout: 10),
                      "Configurations menu item not found")
        configurations.tap()

        // The new third row opens the Open-Source Licenses list.
        let licensesRow = app.buttons["Open-Source Licenses"].firstMatch
        XCTAssertTrue(licensesRow.waitForExistence(timeout: 10),
                      "'Open-Source Licenses' row missing from Configurations")
        licensesRow.tap()

        // The list includes the MLX trigger and KataGo itself.
        let mlxRow = app.buttons["MLX"].firstMatch
        XCTAssertTrue(mlxRow.waitForExistence(timeout: 10),
                      "'MLX' row missing from Open-Source Licenses")
        XCTAssertTrue(app.buttons["KataGo"].firstMatch.exists,
                      "'KataGo' row missing from Open-Source Licenses")

        // Opening a component shows its verbatim license text.
        mlxRow.tap()
        XCTAssertTrue(app.navigationBars["MLX"].waitForExistence(timeout: 10),
                      "MLX license detail did not open")
        let licenseBody = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "Permission is hereby granted")).firstMatch
        XCTAssertTrue(licenseBody.waitForExistence(timeout: 10),
                      "MLX license text not shown")
    }
```

- [ ] **Step 2: Run the UI test (FullTestPlan required)**

Run: `xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -testPlan FullTestPlan -only-testing:"KataGo AnytimeUITests/CoreMLCacheFooterUITests/testOpenSourceLicensesScreen"`
Expected: **Test Succeeded**. If a row tap lands on the wrong element, mirror the trailing-edge tap / `XCTNSPredicateExpectation` patterns already used in `testDisplayPreferencesMovedToGlobalSettings`.

- [ ] **Step 3: Stage (commit held — see PROJECT RULE)**

```bash
git add "ios/KataGo iOS/KataGo iOSUITests/CoreMLCacheFooterUITests.swift"
# git commit -m "test(license): UI test for the Open-Source Licenses screen"
```

---

## Task 5: Update repository `/LICENSE` (source-side attribution)

**Files:**
- Modify: `/Users/chinchangyang/Code/KataGo-ios-dev/LICENSE`

- [ ] **Step 1: Add the MLX-stack attribution paragraph**

In `LICENSE`, find this existing sentence near the top:

```
Additionally, cpp/core/sha2.cpp derives from another piece of external code and embeds its own license within that file.
```

Immediately after it (new paragraph), insert:

```
Additionally, the iOS/macOS/visionOS app under ios/KataGo iOS bundles the mlx-swift
library and its vendored components: mlx, mlx-c, metal-cpp, fmt, nlohmann_json, and
pocketfft, as well as the swift-numerics package. For the licenses of those libraries,
see the individual license files within ios/KataGo iOS/ThirdParty/mlx-swift and its
Source/Cmlx subdirectories. These components are all under permissive licenses (MIT,
Apache-2.0, or BSD-3-Clause).
```

- [ ] **Step 2: Verify the edit**

Run: `grep -n "mlx-swift" "/Users/chinchangyang/Code/KataGo-ios-dev/LICENSE"`
Expected: the new paragraph is present.

- [ ] **Step 3: Stage (commit held — see PROJECT RULE)**

```bash
git add LICENSE
# git commit -m "docs(license): attribute the bundled mlx-swift stack in /LICENSE"
```

---

## Task 6: Three-platform build verification

**Files:** none (verification only).

- [ ] **Step 1: Build for iOS Simulator**

Run: `xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug`
Expected: **BUILD SUCCEEDED**.

- [ ] **Step 2: Build for macOS**

Run: `xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=macOS' -configuration Debug`
Expected: **BUILD SUCCEEDED** (confirms `AcknowledgmentsView`/`LicenseDetailView` compile without `navigationBarTitleDisplayMode`).

- [ ] **Step 3: Build for visionOS Simulator**

Run: `xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug`
Expected: **BUILD SUCCEEDED**.

- [ ] **Step 4: Restore Package.resolved if xcodebuild deleted it**

Run: `git status --short "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"`
If it shows as deleted (` D`), run:
`git restore "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"`

- [ ] **Step 5: Final confirmation**

All three platforms green, unit test green, UI test green. The work is staged across Tasks 1–5; **pause for the user to authorize commit(s)** per the PROJECT RULE.

---

## Done-when

- `ThirdPartyLicense.all` has 16 fully-populated entries; unit test passes.
- *Configurations → Open-Source Licenses* lists all components; tapping one shows its verbatim license; UI test passes.
- `/LICENSE` attributes the mlx-swift stack.
- iOS, macOS, visionOS all build green.
