# Phase 0 — Extract `KataGoUICore` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the platform-agnostic core (logic, models, services, state, and reusable SwiftUI rendering) out of the iOS app target into a new local Swift package `KataGoUICore`, with **zero behavior change** to the existing iOS/macOS/visionOS app.

**Architecture:** A new local Swift package `KataGoUICore` is added to `KataGo Anytime.xcodeproj`. It depends on the existing `KataGoInterface` framework (C++ bridge). Files move from `KataGo iOS/` into `KataGoUICore/Sources/KataGoUICore/<group>/`; cross-module symbols are made `public`; the app target and the unit-test target add `import KataGoUICore`. Resources used by moved services (stone sounds, the 9×9 opening book) move into the package and load via `Bundle.module`. This is a **pure refactor** — verified by the existing 16 unit-test files plus 3-platform builds.

**Tech Stack:** Swift, SwiftUI, SwiftData, Swift Package Manager (local package), Xcode (`xcodebuild`), the `xcodeproj` Ruby gem (1.27.0, already used in this repo) for `project.pbxproj` edits.

**This plan does NOT:** extract the GTP message loop into a `GameSession` (Phase 1), create any AppKit code (Phase 1+), or change the SwiftData schema / CloudKit container.

---

## Conventions used in every task

- All commands run from the project dir: `cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"`.
- **Build (per platform):**
  - iOS: `xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug`
  - macOS: same with `-destination 'platform=macOS'`
  - visionOS: same with `-destination 'platform=visionOS Simulator,name=Apple Vision Pro'`
- **Unit tests (regression gate):** `xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17'` (default FastTestPlan = the 16 unit-test files; UI tests excluded).
- **Public-ification loop** (used in every move task): after moving files, build the iOS target; for each `'X' is inaccessible due to 'internal' protection level` (or `initializer 'init' is inaccessible`) error, add `public` to that type/member (and a `public init` for types the app constructs). Rebuild until green. The build *is* the completeness check — there are no hidden cross-module references it won't surface.
- **Moving a file** = `git mv` it into the package source tree, then remove its `PBXFileReference`/build-file entry from the app target in `project.pbxproj` (the package auto-compiles everything under its `Sources/` directory, so it must NOT also be a member of the app target). Use the Ruby helper in Task 1, Step 6.
- **Commit** after each green task.

---

## File Structure (target end state)

```
ios/KataGo iOS/
├── KataGo Anytime.xcodeproj
├── KataGoInterface/                  (unchanged framework — C++ bridge)
├── KataGoUICore/                     (NEW local Swift package)
│   ├── Package.swift
│   └── Sources/KataGoUICore/
│       ├── Session/      AnalysisLineParser, BoardTextParser, MoveNumbers, SgfTruncation
│       ├── Model/        KataGoModel, GobanState, NavigationContext, GameRecord, ConfigModel,
│       │                 NeuralNetworkModel, HumanSLModel, BackendChoice, TransferableSgf
│       ├── Services/     AudioModel, BookLookup, Downloader, Commentator, EngineLifecycle,
│       │                 CoreMLCacheReadiness, CoreMLCacheReadinessProjection, BinFileHasher,
│       │                 ThumbnailModel, TerminationModel, ThirdPartyLicenses, DebugUtils
│       ├── Rendering/    GobanView, BoardView, BoardLineView, StoneView, AnalysisView,
│       │                 WinrateBarView, MoveNumberView, BookAnalysisView, LinePlotView, CommentView
│       └── Resources/    PlayGoStone{1,2,3}.mp3, CaptureGoStone{1,2,3}.mp3, book9x9jp-20260226.kbook.gz
├── KataGo iOS/                       (app target — chrome only after this phase)
│   ├── KataGo_iOSApp.swift, ContentView.swift, GameSplitView.swift, GameListView.swift,
│   │   ModelRunnerView.swift, ModelPickerView.swift, ConfigView.swift, BackendConfigSheet.swift,
│   │   StatusToolbarItems.swift, TopToolbarView.swift, GameListToolbar.swift, InfoView.swift,
│   │   PlayView.swift, PlusMenuView.swift, QuitButton.swift, LoadingView.swift, CommandView.swift,
│   │   AcknowledgmentsView.swift, MLXTuneExperimentView.swift, CoreMLCacheFooterView.swift,
│   │   GameLinkView.swift, NameEditorView.swift
│   └── AppIntents/  (GameEntity, GetGameInfo, KataGoShortcuts)
├── KataGo iOSTests/                  (imports KataGoUICore after this phase)
└── Resources/                        (engine nets + gtp.cfg stay here — loaded app-side)
```

---

## Task 1: Add the empty `KataGoUICore` package and wire it up

**Files:**
- Create: `KataGoUICore/Package.swift`
- Create: `KataGoUICore/Sources/KataGoUICore/Placeholder.swift`
- Modify: `KataGo Anytime.xcodeproj/project.pbxproj` (add local package ref + product dependency on app and unit-test targets)

- [ ] **Step 1: Record the green baseline (build all 3 platforms + unit tests)**

Run, from `ios/KataGo iOS`, each build command in "Conventions", then the test command.
Expected: `** BUILD SUCCEEDED **` for iOS, macOS, visionOS; `** TEST SUCCEEDED **` for tests. If any fail, STOP — fix or report before refactoring (the baseline must be green to prove "no behavior change").

- [ ] **Step 2: Create `KataGoUICore/Package.swift`**

```swift
// swift-tools-version: 6.2          // 6.2 required: the .v26 platform symbols are unavailable in 6.0
import PackageDescription

let package = Package(
    name: "KataGoUICore",
    platforms: [.iOS(.v26), .macOS(.v26), .visionOS(.v26)],
    products: [
        .library(name: "KataGoUICore", targets: ["KataGoUICore"])
    ],
    targets: [
        .target(
            name: "KataGoUICore",
            swiftSettings: [
                // REQUIRED so the package can `import KataGoInterface`, whose public
                // headers (KataGoCpp.hpp) include C++ stdlib (<string>). Verified during
                // Task 1 execution. Matches the app target's C++ interop.
                .interoperabilityMode(.Cxx)
            ]
            // NOTE: the `resources: [.process("Resources")]` argument is added in Task 4
            // (an empty Resources dir produces a degenerate bundle that fails codesign).
        )
    ]
)
```

Note: `KataGoInterface` is an Xcode framework target, not a SwiftPM package, so it cannot be a `Package.swift` dependency. The Xcode project links it; moved files keep `import KataGoInterface` and resolve against the framework at app-build time. Verify this assumption in Step 7; if the package cannot see `KataGoInterface`, fall back to also adding `KataGoInterface` as a target dependency via the Xcode project's package settings (documented in Risks).

- [ ] **Step 3: Create a placeholder source so the package compiles**

```swift
// KataGoUICore/Sources/KataGoUICore/Placeholder.swift
// Temporary: removed in Task 3 once real sources land.
public enum KataGoUICore {}
```

- [ ] **Step 4: Add the local package reference to the Xcode project**

Write `/tmp/add_package.rb`:

```ruby
require "xcodeproj"
project = Xcodeproj::Project.open("KataGo Anytime.xcodeproj")
# Local package reference (relative path)
ref = project.root_object.package_references.find { |r| r.respond_to?(:relative_path) && r.relative_path == "KataGoUICore" }
unless ref
  ref = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
  ref.relative_path = "KataGoUICore"
  project.root_object.package_references << ref
end
# Add product dependency "KataGoUICore" to the app target and the unit-test target
["KataGo Anytime", "KataGo AnytimeTests"].each do |tname|
  t = project.targets.find { |x| x.name == tname }
  next unless t
  next if t.package_product_dependencies.any? { |d| d.product_name == "KataGoUICore" }
  dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.product_name = "KataGoUICore"
  dep.package = ref
  t.package_product_dependencies << dep
  # also add to the target's Frameworks build phase
  bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  bf.product_ref = dep
  t.frameworks_build_phase.files << bf
end
project.save
puts "OK"
```

- [ ] **Step 5: Run it**

Run: `ruby /tmp/add_package.rb`
Expected: prints `OK`. (If the exact `XCLocalSwiftPackageReference` API differs in gem 1.27.0, add the package via Xcode UI: File ▸ Add Package Dependencies ▸ Add Local… ▸ select `KataGoUICore`, then add the `KataGoUICore` library to both targets.)

- [ ] **Step 6: Add the reusable pbxproj file-reference remover (used by later tasks)**

Write `/tmp/remove_from_app_target.rb` (takes filenames as ARGV; removes their references so only the package compiles them):

```ruby
require "xcodeproj"
project = Xcodeproj::Project.open("KataGo Anytime.xcodeproj")
names = ARGV
removed = []
project.targets.each do |t|
  next unless ["KataGo Anytime", "KataGo AnytimeTests", "KataGo AnytimeUITests"].include?(t.name)
  t.source_build_phase.files.dup.each do |bf|
    fr = bf.file_ref
    if fr && names.include?(File.basename(fr.path.to_s))
      bf.remove_from_project
      removed << "#{t.name}:#{File.basename(fr.path.to_s)}"
    end
  end
end
# also delete now-orphaned PBXFileReferences for those names
project.files.dup.each do |fr|
  fr.remove_from_project if names.include?(File.basename(fr.path.to_s))
end
project.save
puts "removed: #{removed.join(', ')}"
```

- [ ] **Step 7: Build iOS to verify the empty package links**

Run the iOS build command.
Expected: `** BUILD SUCCEEDED **` (the placeholder package compiles and links; no behavior change).

- [ ] **Step 8: Commit**

```bash
git add "KataGoUICore" "KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "build(mac): add empty KataGoUICore local Swift package"
```

---

## Task 2: Move the pure parsers/utilities (lowest risk)

**Files (move into `KataGoUICore/Sources/KataGoUICore/Session/` and `/Services/`):**
- `Session/`: `AnalysisLineParser.swift`, `BoardTextParser.swift`, `MoveNumbers.swift`, `SgfTruncation.swift`
- `Services/`: `BinFileHasher.swift`, `EngineLifecycle.swift`, `DebugUtils.swift`, `ThirdPartyLicenses.swift`, `TerminationModel.swift`, `ThumbnailModel.swift`, `CoreMLCacheReadiness.swift`, `CoreMLCacheReadinessProjection.swift`
- `Model/`: `NeuralNetworkModel.swift`, `HumanSLModel.swift`, `BackendChoice.swift`
- Delete: `KataGoUICore/Sources/KataGoUICore/Placeholder.swift`
- Modify: each moved file (add `public`), app files that reference them (add `import KataGoUICore`), test files for these types (add `import KataGoUICore`)

- [ ] **Step 1: Move the files and drop the placeholder**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
P="KataGoUICore/Sources/KataGoUICore"
mkdir -p "$P/Session" "$P/Services" "$P/Model"
git mv "KataGo iOS/AnalysisLineParser.swift" "$P/Session/"
git mv "KataGo iOS/BoardTextParser.swift"    "$P/Session/"
git mv "KataGo iOS/MoveNumbers.swift"         "$P/Session/"
git mv "KataGo iOS/SgfTruncation.swift"       "$P/Session/"
git mv "KataGo iOS/BinFileHasher.swift"       "$P/Services/"
git mv "KataGo iOS/EngineLifecycle.swift"     "$P/Services/"
git mv "KataGo iOS/DebugUtils.swift"          "$P/Services/"
git mv "KataGo iOS/ThirdPartyLicenses.swift"  "$P/Services/"
git mv "KataGo iOS/TerminationModel.swift"    "$P/Services/"
git mv "KataGo iOS/ThumbnailModel.swift"      "$P/Services/"
git mv "KataGo iOS/CoreMLCacheReadiness.swift" "$P/Services/"
git mv "KataGo iOS/CoreMLCacheReadinessProjection.swift" "$P/Services/"
git mv "KataGo iOS/NeuralNetworkModel.swift"  "$P/Model/"
git mv "KataGo iOS/HumanSLModel.swift"        "$P/Model/"
git mv "KataGo iOS/BackendChoice.swift"       "$P/Model/"
git rm "$P/Placeholder.swift"
```

- [ ] **Step 2: Remove these files from the app/test targets in pbxproj**

```bash
ruby /tmp/remove_from_app_target.rb AnalysisLineParser.swift BoardTextParser.swift MoveNumbers.swift SgfTruncation.swift BinFileHasher.swift EngineLifecycle.swift DebugUtils.swift ThirdPartyLicenses.swift TerminationModel.swift ThumbnailModel.swift CoreMLCacheReadiness.swift CoreMLCacheReadinessProjection.swift NeuralNetworkModel.swift HumanSLModel.swift BackendChoice.swift
```
Expected: prints a `removed: …` line listing the app-target (and any test-target) memberships removed.

- [ ] **Step 3: Make the cross-module API `public` (build-driven loop)**

Run the iOS build. For each `is inaccessible due to 'internal' protection level` error, add `public` to the named type and the referenced member; for types the app instantiates, add a `public init(...)`. Representative example — `AnalysisLineParser.swift`:

```swift
// before
struct ParsedAnalysis { let info: [AnalysisInfo]; let ownership: [OwnershipUnit] }
enum AnalysisLineParser { static func parse(_ line: String) -> ParsedAnalysis? { ... } }

// after
public struct ParsedAnalysis { public let info: [AnalysisInfo]; public let ownership: [OwnershipUnit]
    public init(info: [AnalysisInfo], ownership: [OwnershipUnit]) { self.info = info; self.ownership = ownership } }
public enum AnalysisLineParser { public static func parse(_ line: String) -> ParsedAnalysis? { ... } }
```

Repeat the build→add-`public`→build loop until the iOS target compiles. Add `import KataGoUICore` to the top of every app file the compiler reports as now missing these symbols (e.g. `ContentView.swift`, `ModelRunnerView.swift`, `GobanState.swift`, `KataGoModel.swift`, …).

- [ ] **Step 4: Fix unit-test imports**

For each test whose subject moved (`AnalysisLineParserTests`, `BoardTextParserTests`, `MoveNumbersTests`, `SgfTruncationTests`, `BinFileHasherTests`, `EngineLifecycleTests`), change/add the import at the top:

```swift
@testable import KataGoUICore   // was: @testable import KataGo_Anytime (or the app module name)
```
Keep `@testable` so tests can still reach `internal` members; only the app target needs `public`.

- [ ] **Step 5: Build all 3 platforms**

Run iOS, macOS, visionOS build commands.
Expected: `** BUILD SUCCEEDED **` for all three.

- [ ] **Step 6: Run the unit tests (regression gate)**

Run the test command.
Expected: `** TEST SUCCEEDED **`, with `AnalysisLineParserTests`, `BoardTextParserTests`, `MoveNumbersTests`, `SgfTruncationTests`, `BinFileHasherTests`, `EngineLifecycleTests` all passing.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor(core): move parsers, utilities, and metadata types into KataGoUICore"
```

---

## Task 3: Move state + SwiftData models (handle the model container)

**Files:**
- `Model/`: `KataGoModel.swift`, `GobanState.swift`, `NavigationContext.swift`, `GameRecord.swift`, `ConfigModel.swift`, `TransferableSgf.swift`
- Modify: `KataGo_iOSApp.swift` (add `import KataGoUICore`; the `.modelContainer(for: GameRecord.self)` now resolves `GameRecord` from the package — no code change beyond the import), and any app files referencing these types.
- Test imports: `KataGoModelTests`, `GobanStateBranchTests`, `NavigationContextTests`, `GameRecordTests`, `ConfigModelTests`.

- [ ] **Step 1: Move the files**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"; P="KataGoUICore/Sources/KataGoUICore"
git mv "KataGo iOS/KataGoModel.swift"      "$P/Model/"
git mv "KataGo iOS/GobanState.swift"       "$P/Model/"
git mv "KataGo iOS/NavigationContext.swift" "$P/Model/"
git mv "KataGo iOS/GameRecord.swift"       "$P/Model/"
git mv "KataGo iOS/ConfigModel.swift"      "$P/Model/"
git mv "KataGo iOS/TransferableSgf.swift"  "$P/Model/"
ruby /tmp/remove_from_app_target.rb KataGoModel.swift GobanState.swift NavigationContext.swift GameRecord.swift ConfigModel.swift TransferableSgf.swift
```

- [ ] **Step 2: Make types `public` (build-driven loop)**

Run the iOS build and add `public` as in Task 2 Step 3. Special attention for SwiftData `@Model` classes:
- `@Model public final class GameRecord` and `@Model public final class Config` need a **`public init`** (SwiftData synthesizes an internal one; the app constructs these — e.g. `GameRecord.createGameRecord` and `modelContext.insert(...)`). Add an explicit `public init(...)` mirroring current stored properties, and make any factory methods (`createGameRecord`) and accessed properties `public`.
- `@Observable` classes (`GobanState`, `KataGoModel` state types like `Stones`, `Turn`, `Analysis`, `Winrate`, `Score`, `MessageList`, `Coordinate`, `BoardPoint`, `NavigationContext`): make the class, its `public init`, and every property/method the app reads/writes `public`.
- Do **not** add/rename/remove any stored property on `@Model` types (frozen schema). Only change access level and add a `public init`.

- [ ] **Step 3: Add imports where the compiler reports missing symbols**

Add `import KataGoUICore` to `KataGo_iOSApp.swift` and every other app file flagged (most chrome views reference `GameRecord`, `Config`, `GobanState`, `NavigationContext`).

- [ ] **Step 4: Fix test imports** (`@testable import KataGoUICore` in the five test files listed above).

- [ ] **Step 5: Build all 3 platforms** → expect `** BUILD SUCCEEDED **` ×3.

- [ ] **Step 6: Run unit tests** → expect `** TEST SUCCEEDED **` (esp. `GameRecordTests`, `ConfigModelTests`, `GobanStateBranchTests`, `KataGoModelTests`, `NavigationContextTests`).

- [ ] **Step 7: Smoke-test persistence (manual, one-time)**

Run the iOS app in the simulator; create a New Game, make a move, quit and relaunch. Expected: the game persists (SwiftData container still resolves the package-defined `@Model`). If the container fails to register, see Risks (model container must reference the package type; the `import KataGoUICore` in `KataGo_iOSApp.swift` is sufficient — no `Schema` change needed).

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor(core): move game/board state and SwiftData models into KataGoUICore"
```

---

## Task 4: Move services + their resources (sounds, opening book)

**Files:**
- `Services/`: `AudioModel.swift`, `BookLookup.swift`, `Downloader.swift`, `Commentator.swift`
- Resources → `KataGoUICore/Sources/KataGoUICore/Resources/`: `PlayGoStone1/2/3.mp3`, `CaptureGoStone1/2/3.mp3`, `book9x9jp-20260226.kbook.gz`
- Modify: `AudioModel.swift` and `BookLookup.swift` to load via `Bundle.module`; remove those resources from the app target.

- [ ] **Step 1: Move service files**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"; P="KataGoUICore/Sources/KataGoUICore"
git mv "KataGo iOS/AudioModel.swift"   "$P/Services/"
git mv "KataGo iOS/BookLookup.swift"   "$P/Services/"
git mv "KataGo iOS/Downloader.swift"   "$P/Services/"
git mv "KataGo iOS/Commentator.swift"  "$P/Services/"
ruby /tmp/remove_from_app_target.rb AudioModel.swift BookLookup.swift Downloader.swift Commentator.swift
```

- [ ] **Step 2: Move the resources into the package**

```bash
mkdir -p "$P/Resources"
git mv "Resources/PlayGoStone1.mp3" "Resources/PlayGoStone2.mp3" "Resources/PlayGoStone3.mp3" "$P/Resources/"
git mv "Resources/CaptureGoStone1.mp3" "Resources/CaptureGoStone2.mp3" "Resources/CaptureGoStone3.mp3" "$P/Resources/"
git mv "Resources/book9x9jp-20260226.kbook.gz" "$P/Resources/"
ruby /tmp/remove_from_app_target.rb PlayGoStone1.mp3 PlayGoStone2.mp3 PlayGoStone3.mp3 CaptureGoStone1.mp3 CaptureGoStone2.mp3 CaptureGoStone3.mp3 book9x9jp-20260226.kbook.gz
```
(The engine nets `default_model.bin.gz`, `b18c384nbt-humanv0.bin.gz`, and `default_gtp.cfg` stay in `Resources/` and in the app target — they're loaded app-side, not by moved code.)

- [ ] **Step 3: Switch resource loading to `Bundle.module`**

In `AudioModel.swift`, change the bundle used to locate the mp3s. Representative change:

```swift
// before
guard let url = Bundle.main.url(forResource: name, withExtension: "mp3") else { return }
// after
guard let url = Bundle.module.url(forResource: name, withExtension: "mp3") else { return }
```

In `BookLookup.swift`, change the `.kbook.gz` lookup the same way:

```swift
// before
let url = Bundle.main.url(forResource: "book9x9jp-20260226", withExtension: "kbook.gz")
// after
let url = Bundle.module.url(forResource: "book9x9jp-20260226", withExtension: "kbook.gz")
```
(`Bundle.module` is auto-generated for the package target because `Package.swift` declares `.process("Resources")`.)

- [ ] **Step 4: Make services `public`** (build-driven loop, as Task 2 Step 3) and add `import KataGoUICore` where the compiler flags app files (e.g. `ContentView`, `GameSplitView`, `StatusToolbarItems`, `BoardView`, `CommentView`).

- [ ] **Step 5: Build all 3 platforms** → `** BUILD SUCCEEDED **` ×3.

- [ ] **Step 6: Run unit tests** → `** TEST SUCCEEDED **` (esp. `BookLookupTests` — confirms `Bundle.module` finds the book).

- [ ] **Step 7: Smoke-test audio + book (manual)**

Run iOS app: play a stone (hear a sound) and open a 9×9 game (book loads). Expected: sounds play and the opening book activates — proving `Bundle.module` resources resolve.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor(core): move services + sound/book resources into KataGoUICore (Bundle.module)"
```

---

## Task 5: Move the reusable rendering views

**Files (→ `KataGoUICore/Sources/KataGoUICore/Rendering/`):**
`GobanView.swift`, `BoardView.swift`, `BoardLineView.swift`, `StoneView.swift`, `AnalysisView.swift`, `WinrateBarView.swift`, `MoveNumberView.swift`, `BookAnalysisView.swift`, `LinePlotView.swift`, `CommentView.swift`

- [ ] **Step 1: Move the files**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"; P="KataGoUICore/Sources/KataGoUICore"; mkdir -p "$P/Rendering"
for f in GobanView BoardView BoardLineView StoneView AnalysisView WinrateBarView MoveNumberView BookAnalysisView LinePlotView CommentView; do git mv "KataGo iOS/$f.swift" "$P/Rendering/"; done
ruby /tmp/remove_from_app_target.rb GobanView.swift BoardView.swift BoardLineView.swift StoneView.swift AnalysisView.swift WinrateBarView.swift MoveNumberView.swift BookAnalysisView.swift LinePlotView.swift CommentView.swift
```

- [ ] **Step 2: Make the entry-point views and their initializers `public`** (build-driven loop)

Each view the app instantiates directly (at minimum `GobanView`, `BoardView`, `CommentView`, `LinePlotView`) needs `public struct …: View` and a `public init(...)`; the `public var body` is required for a public `View`. Views only used *internally* by other rendering views (e.g. `StoneView`, `BoardLineView`, `MoveNumberView`) can stay `internal`. Representative:

```swift
public struct GobanView: View {
    public init(/* same parameters as today */) { ... }
    public var body: some View { ... }
}
```
Add `import KataGoUICore` to the chrome views that embed these (`ContentView`, `GameSplitView`, `InfoView`, `PlayView`, etc.).

- [ ] **Step 3: Build all 3 platforms** → `** BUILD SUCCEEDED **` ×3.

- [ ] **Step 4: Run the FULL test plan (unit + UI) to catch view regressions**

Run: `xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -testPlan FullTestPlan`
Expected: `** TEST SUCCEEDED **` (UI tests `BackendConfigSheetUITests`, `CoreMLCacheFooterUITests` exercise the rendered board/sheets).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor(core): move reusable SwiftUI rendering views into KataGoUICore"
```

---

## Task 6: Final verification & cleanup

- [ ] **Step 1: Confirm the app target now contains only chrome**

Run: `ls "KataGo iOS"/*.swift | sed 's:.*/::' | sort`
Expected: only the chrome files (`KataGo_iOSApp`, `ContentView`, `GameSplitView`, `GameListView`, `GameLinkView`, `ModelRunnerView`, `ModelPickerView`, `ConfigView`, `BackendConfigSheet`, `StatusToolbarItems`, `TopToolbarView`, `GameListToolbar`, `InfoView`, `PlayView`, `PlusMenuView`, `QuitButton`, `LoadingView`, `CommandView`, `AcknowledgmentsView`, `MLXTuneExperimentView`, `CoreMLCacheFooterView`, `NameEditorView`) plus `AppIntents/`. No parser/model/service/rendering files remain.

- [ ] **Step 2: Clean build all 3 platforms** (delete DerivedData first to prove a cold build works)

```bash
rm -rf ~/Library/Developer/Xcode/DerivedData/KataGo* "DerivedData"
```
Then run all 3 build commands. Expected: `** BUILD SUCCEEDED **` ×3.

- [ ] **Step 3: Confirm zero warnings**

Inspect each build's output: `grep -c "warning:"` on the captured logs must be `0` (house standard; matches the current clean state).

- [ ] **Step 4: Run the full test plan** → `** TEST SUCCEEDED **`.

- [ ] **Step 5: Manual parity smoke test**

Launch iOS app: library loads, open a game, analysis runs, move navigation works, comments/chart show, sounds play, settings toggles work. Confirm **no observable behavior change** vs. the Task 1 baseline.

- [ ] **Step 6: Final commit + tag the milestone**

```bash
git add -A
git commit -m "refactor(core): complete KataGoUICore extraction (Phase 0)"
git tag mac-phase0-complete
```

---

## Risks & Mitigations

- **`KataGoInterface` visibility from the package — RESOLVED (Task 1):** the package *can* resolve and import the `KataGoInterface` Xcode framework, but because its public headers expose C++ (`KataGoCpp.hpp` includes `<string>`), the import only compiles when the package target has **Swift/C++ interop enabled**. Fix verified empirically in Task 1: add `swiftSettings: [.interoperabilityMode(.Cxx)]` to the `KataGoUICore` target (shown in Task 1 Step 2). No protocol-inversion or framework-repackaging needed. All later tasks that move `KataGoInterface`-importing files rely on this.
- **`public init` for `@Model`/`@Observable`:** the build surfaces every missing one; never change stored properties of `@Model` types (frozen schema) — only access levels + add `public init`.
- **Resource loading:** only `AudioModel` and `BookLookup` change to `Bundle.module`; engine nets/gtp.cfg stay app-side. The `BookLookupTests` + audio smoke test verify this.
- **pbxproj edits:** if the Ruby `XCLocalSwiftPackageReference` API differs in gem 1.27.0, use the Xcode UI fallbacks noted in Task 1 Steps 5–6; commit the resulting `project.pbxproj` either way.
- **Test module name:** the current `@testable import` module name may be `KataGo_Anytime` (target "KataGo Anytime"). Confirm by reading one existing test file's import line before bulk-editing; replace only the moved-type tests with `@testable import KataGoUICore`.

## Out of Scope (later phases)
`GameSession` GTP-loop extraction (Phase 1), any AppKit code (Phase 1+), AppIntents relocation, retiring the SwiftUI macOS build (Phase 6).
