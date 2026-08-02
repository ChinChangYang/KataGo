# Mac Draft Editing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On macOS, an unlocked game becomes an unsaved document — nothing reaches SwiftData or iCloud until the user saves.

**Architecture:** While editing, `navigationContext.selectedGameRecord` points at a **detached** `GameRecord` clone that is never inserted into the model context. Every existing write path in the shared package writes into whatever record it was handed, so redirecting the object redirects all of them at once with no shared-package change. Save copies the draft's fields onto the origin (or inserts a new record for an untitled game); Discard drops the clone and reloads the origin. A debounced local mirror file survives crashes, and one field comparator serves both the dirty flag and conflict detection.

**Tech Stack:** Swift 6, AppKit, SwiftData (`@Model`), Swift Testing, `xcodeproj` Ruby gem 1.27.0 for project surgery.

**Spec:** `docs/superpowers/specs/2026-08-02-mac-draft-editing-design.md`

## Global Constraints

- **Working directory for every command:** `ios/KataGo iOS` (contains `KataGo Anytime.xcodeproj`).
- **macOS target only.** Do **not** modify any file under `KataGoUICore/`. iOS, tvOS, visionOS and watchOS must be bit-for-bit unchanged in behavior; the untouched package is the proof.
- **English only** in every committed file — source, comments, docs, commit messages. No CJK anywhere.
- **Piped `xcodebuild` exit codes lie.** Always grep the output for `** BUILD SUCCEEDED **` / `** TEST SUCCEEDED **` rather than trusting `$?`.
- **Never run two `xcodebuild` invocations concurrently** — a DerivedData lock produces spurious `TEST FAILED`.
- **The non-hosted test bundle must never link `KataGoUICore`** (it pulls in the C++ bridge). Only `KataGoGameStore` and `KataGoAnalysisKit`.
- **`isEditing == true` means UNLOCKED.** This is the opposite of what the name suggests; every gate below depends on it.
- **`@Model` schema is frozen** (CloudKit). Never add, rename or delete a stored property on `GameRecord` or `Config`.
- Commit messages end with:
  ```
  Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
  ```
- **Do not push.** Every push to `ios-dev` triggers an Xcode Cloud TestFlight build.

**Standard verification commands**

```bash
cd "ios/KataGo iOS"

# Mac unit tests
xcodebuild test -project "KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime Mac" -destination 'platform=macOS' \
  -only-testing:"KataGo Anytime MacTests" 2>&1 | tail -40

# Mac build
xcodebuild build -project "KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime Mac" -destination 'platform=macOS' \
  -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
```

---

### Task 1: Create the non-hosted macOS unit-test target

A `TEST_HOST` bundle would launch the app for every run, dragging `SharedModelContainer`/CloudKit, the engine subprocess and the app-group preferences path — the three flakiest things on this platform — into the test. Non-hosted avoids all of it.

**Files:**
- Modify: `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj` (via Ruby script)
- Modify: `ios/KataGo iOS/KataGo Anytime.xcodeproj/xcshareddata/xcschemes/KataGo Anytime Mac.xcscheme`
- Create: `ios/KataGo iOS/KataGo Anytime MacTests/SmokeTests.swift`
- Create: `ios/KataGo iOS/scripts/add_mac_test_target.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: a target named `KataGo Anytime MacTests` linking the `KataGoGameStore` and `KataGoAnalysisKit` products, wired into the `KataGo Anytime Mac` scheme's Test action. Later tasks add source files to **both** this target and `KataGo Anytime Mac`.

- [ ] **Step 1: Write the smoke test**

Create `ios/KataGo iOS/KataGo Anytime MacTests/SmokeTests.swift`:

```swift
//
//  SmokeTests.swift
//  KataGo Anytime MacTests
//

import Testing
import SwiftData
@testable import KataGoGameStore
@testable import KataGoAnalysisKit

struct SmokeTests {
    @Test func linksTheBridgeFreeGameStore() {
        let config = Config()
        let record = GameRecord(config: config)
        #expect(record.sgf == GameRecord.defaultSgf)
    }

    @Test func linksTheBridgeFreeSgfScanner() {
        let scan = SgfHeaderScan(sgf: "(;FF[4]GM[1]SZ[19];B[dd];W[pp])")
        #expect(scan?.moveCount == 2)
    }
}
```

- [ ] **Step 2: Write the project-surgery script**

Create `ios/KataGo iOS/scripts/add_mac_test_target.rb`:

```ruby
#!/usr/bin/env ruby
# Adds the non-hosted macOS unit-test bundle "KataGo Anytime MacTests".
#
# Non-hosted on purpose: a TEST_HOST bundle launches the Mac app for every
# run, which boots SharedModelContainer/CloudKit, spawns the katago-engine
# subprocess, and touches the app-group preferences path. Those are the three
# flakiest things on this platform and none of them is under test here.
#
# Idempotent: re-running is a no-op once the target exists.

require 'xcodeproj'

PROJECT = 'KataGo Anytime.xcodeproj'
TEST_TARGET = 'KataGo Anytime MacTests'
APP_TARGET = 'KataGo Anytime Mac'
PRODUCTS = %w[KataGoGameStore KataGoAnalysisKit]

project = Xcodeproj::Project.open(PROJECT)

if project.targets.any? { |t| t.name == TEST_TARGET }
  puts "#{TEST_TARGET} already exists - nothing to do"
  exit 0
end

app = project.targets.find { |t| t.name == APP_TARGET }
raise "missing target #{APP_TARGET}" if app.nil?

app_bundle_id = app.build_configurations.first.build_settings['PRODUCT_BUNDLE_IDENTIFIER']
raise 'app target has no PRODUCT_BUNDLE_IDENTIFIER' if app_bundle_id.nil?

test = project.new_target(:unit_test_bundle, TEST_TARGET, :osx, '26.0',
                          project.products_group, :swift)

test.build_configurations.each do |c|
  s = c.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = "#{app_bundle_id}Tests"
  s['GENERATE_INFOPLIST_FILE'] = 'YES'
  s['SWIFT_VERSION'] = '6.0'
  s['MACOSX_DEPLOYMENT_TARGET'] = '26.0'
  s['CODE_SIGN_STYLE'] = 'Automatic'
  s['SWIFT_EMIT_LOC_STRINGS'] = 'NO'
  # Non-hosted: these two must stay absent.
  s.delete('TEST_HOST')
  s.delete('BUNDLE_LOADER')
end

# The local package reference the app already uses; the test bundle borrows it
# to link the two bridge-free products directly.
pkg = project.root_object.package_references.find do |r|
  r.respond_to?(:relative_path) && r.relative_path == 'KataGoUICore'
end
raise 'local KataGoUICore package reference not found' if pkg.nil?

PRODUCTS.each do |name|
  dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.product_name = name
  dep.package = pkg
  test.package_product_dependencies << dep

  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dep
  test.frameworks_build_phase.files << build_file
end

# KataGoAnalysisKit reaches the app only transitively today. The draft sources
# import it and are compiled into BOTH targets, so make the app's dependency
# explicit rather than relying on transitive module visibility.
unless app.package_product_dependencies.any? { |d| d.product_name == 'KataGoAnalysisKit' }
  dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.product_name = 'KataGoAnalysisKit'
  dep.package = pkg
  app.package_product_dependencies << dep
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dep
  app.frameworks_build_phase.files << build_file
end

group = project.main_group.find_subpath(TEST_TARGET, true)
group.set_source_tree('SOURCE_ROOT')
group.set_path(TEST_TARGET)

Dir.glob("#{TEST_TARGET}/**/*.swift").sort.each do |file|
  ref = group.new_reference(File.basename(file))
  test.add_file_references([ref])
end

project.save

# Join the shared Mac scheme's Test action, so
# `xcodebuild test -scheme "KataGo Anytime Mac"` picks the bundle up.
scheme_path = Xcodeproj::XCScheme.shared_data_dir(PROJECT).join('KataGo Anytime Mac.xcscheme')
scheme = Xcodeproj::XCScheme.new(scheme_path.to_s)
already = scheme.test_action.testables.any? do |t|
  t.buildable_references.any? { |r| r.target_name == TEST_TARGET }
end
unless already
  scheme.test_action.add_testable(
    Xcodeproj::XCScheme::TestAction::TestableReference.new(test))
  scheme.save_as(PROJECT, 'KataGo Anytime Mac', true)
end

puts "added #{TEST_TARGET} linking #{PRODUCTS.join(', ')}"
```

- [ ] **Step 3: Run the script**

```bash
cd "ios/KataGo iOS" && ruby scripts/add_mac_test_target.rb
```

Expected: `added KataGo Anytime MacTests linking KataGoGameStore, KataGoAnalysisKit`

- [ ] **Step 4: Verify the project file is still valid**

```bash
cd "ios/KataGo iOS" && plutil -lint "KataGo Anytime.xcodeproj/project.pbxproj"
```

Expected: `OK`

- [ ] **Step 5: Verify the scheme picked up the test target**

The script above already patched the shared scheme. Confirm:

```bash
cd "ios/KataGo iOS" && grep -c "KataGo Anytime MacTests" \
  "KataGo Anytime.xcodeproj/xcshareddata/xcschemes/KataGo Anytime Mac.xcscheme"
```

Expected: a non-zero count.

- [ ] **Step 6: Run the tests**

```bash
cd "ios/KataGo iOS" && xcodebuild test -project "KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime Mac" -destination 'platform=macOS' \
  -only-testing:"KataGo Anytime MacTests" 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`, with both smoke tests passing.

- [ ] **Step 7: Verify the Mac app still builds**

```bash
cd "ios/KataGo iOS" && xcodebuild build -project "KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime Mac" -destination 'platform=macOS' \
  -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 8: Commit**

```bash
git add "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
        "ios/KataGo iOS/KataGo Anytime MacTests" \
        "ios/KataGo iOS/scripts/add_mac_test_target.rb"
git commit -m "$(cat <<'EOF'
test(mac): add a non-hosted macOS unit-test target

A TEST_HOST bundle would launch the app for every run, booting
CloudKit, the engine subprocess and the app-group preferences path.
None of that is under test, and all three are known flake sources, so
the bundle links KataGoGameStore and KataGoAnalysisKit directly and
never loads the app.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
)"
```

---

### Task 2: GATE — prove long-lived detached `@Model` works

The entire design rests on holding an uninserted `GameRecord` for a whole editing session. The codebase proves only the short-lived case (`GameRecord+SGF.swift:142` mutates a detached record immediately before the caller inserts it). **If any test in this task fails, stop and report — the fallback is the "freeze the store" approach and the spec must be revisited.**

**Files:**
- Create: `ios/KataGo iOS/KataGo Anytime MacTests/DetachedRecordSpikeTests.swift`

**Interfaces:**
- Consumes: the test target from Task 1.
- Produces: confidence only. No production code.

- [ ] **Step 1: Write the spike tests**

Create `ios/KataGo iOS/KataGo Anytime MacTests/DetachedRecordSpikeTests.swift`:

```swift
//
//  DetachedRecordSpikeTests.swift
//  KataGo Anytime MacTests
//
//  GATE for the draft-editing design: a draft is a GameRecord that is never
//  inserted into a ModelContext, held for a whole editing session. These tests
//  pin the four properties that assumption needs.
//

import Testing
import SwiftData
@testable import KataGoGameStore

@MainActor
struct DetachedRecordSpikeTests {

    private func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: GameRecord.self, Config.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test func detachedRecordAcceptsMutationAndReadsItBack() throws {
        let record = GameRecord(config: Config())
        record.sgf = "(;FF[4]GM[1]SZ[19];B[dd])"
        record.currentIndex = 1
        record.comments = [0: "hello"]
        #expect(record.sgf == "(;FF[4]GM[1]SZ[19];B[dd])")
        #expect(record.currentIndex == 1)
        #expect(record.comments?[0] == "hello")
    }

    @Test func detachedRecordSurvivesManyMutations() throws {
        // Stands in for a long editing session: a 200-move game.
        let record = GameRecord(config: Config())
        for i in 1...200 {
            record.currentIndex = i
            record.moves?[i] = "move\(i)"
        }
        #expect(record.currentIndex == 200)
        #expect(record.moves?.count == 200)
        #expect(record.moves?[200] == "move200")
    }

    @Test func mutatingADetachedRecordDoesNotReachTheStore() throws {
        let container = try inMemoryContainer()
        let context = container.mainContext

        let stored = GameRecord(config: Config())
        stored.name = "Saved"
        context.insert(stored)
        try context.save()

        let detached = GameRecord(config: Config())
        detached.name = "Draft"
        detached.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp])"
        try context.save()

        let all = try context.fetch(FetchDescriptor<GameRecord>())
        #expect(all.count == 1)
        #expect(all.first?.name == "Saved")
    }

    @Test func aDetachedRecordCanBeInsertedLater() throws {
        let container = try inMemoryContainer()
        let context = container.mainContext

        let detached = GameRecord(config: Config())
        detached.name = "Late"
        detached.sgf = "(;FF[4]GM[1]SZ[19];B[dd])"

        context.insert(detached)
        try context.save()

        let all = try context.fetch(FetchDescriptor<GameRecord>())
        #expect(all.count == 1)
        #expect(all.first?.name == "Late")
        #expect(all.first?.sgf == "(;FF[4]GM[1]SZ[19];B[dd])")
    }

    @Test func detachedRecordCarriesItsOwnConfig() throws {
        let record = GameRecord(config: Config())
        record.concreteConfig.komi = 5.5
        #expect(record.config?.komi == 5.5)
        #expect(record.concreteConfig.komi == 5.5)
    }

    @Test func detachedRecordEmitsObservationOnMutation() throws {
        // SwiftUI must redraw the board from the draft, which means the
        // generated accessors have to fire observation while detached.
        let record = GameRecord(config: Config())
        var fired = false
        withObservationTracking {
            _ = record.sgf
        } onChange: {
            fired = true
        }
        record.sgf = "(;FF[4]GM[1]SZ[19];B[qq])"
        #expect(fired)
    }
}
```

- [ ] **Step 2: Run the spike**

```bash
cd "ios/KataGo iOS" && xcodebuild test -project "KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime Mac" -destination 'platform=macOS' \
  -only-testing:"KataGo Anytime MacTests/DetachedRecordSpikeTests" 2>&1 | tail -40
```

Expected: `** TEST SUCCEEDED **`, six tests passing.

**If any test fails: STOP.** Report which one and what SwiftData actually did. Do not continue to Task 3.

- [ ] **Step 3: Commit**

```bash
git add "ios/KataGo iOS/KataGo Anytime MacTests/DetachedRecordSpikeTests.swift"
git commit -m "$(cat <<'EOF'
test(mac): pin the detached-@Model behavior the draft design needs

A draft is a GameRecord that is never inserted and is held for a whole
editing session. These tests pin the four properties that rests on:
mutation works detached, nothing leaks into the store, insertion still
works later, and observation still fires so SwiftUI redraws.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
)"
```

---

### Task 3: `GameRecord.detachedDraftCopy()`

`clone()` is close but wrong for a draft: it mints a fresh `uuid`, appends `" (copy)"` to the name, and stamps `lastModificationDate = .now`. A draft must be indistinguishable from its origin until the user changes something.

**Files:**
- Create: `ios/KataGo iOS/KataGo Anytime Mac/Draft/GameRecord+Draft.swift`
- Test: `ios/KataGo iOS/KataGo Anytime MacTests/GameRecordDraftCopyTests.swift`

**Interfaces:**
- Consumes: `GameRecord`, `Config` from `KataGoGameStore`.
- Produces: `GameRecord.detachedDraftCopy() -> GameRecord`.

- [ ] **Step 1: Write the failing test**

Create `ios/KataGo iOS/KataGo Anytime MacTests/GameRecordDraftCopyTests.swift`:

```swift
//
//  GameRecordDraftCopyTests.swift
//  KataGo Anytime MacTests
//

import Testing
import Foundation
@testable import KataGoGameStore

@MainActor
struct GameRecordDraftCopyTests {

    private func makeOrigin() -> GameRecord {
        let record = GameRecord(config: Config())
        record.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp])"
        record.currentIndex = 2
        record.name = "Origin"
        record.comments = [1: "note"]
        record.moves = [0: "D16", 1: "Q4"]
        record.winRates = [1: 0.5]
        record.concreteConfig.komi = 6.5
        return record
    }

    @Test func copyPreservesIdentityFields() {
        let origin = makeOrigin()
        let copy = origin.detachedDraftCopy()
        #expect(copy.uuid == origin.uuid)
        #expect(copy.name == "Origin")
        #expect(copy.lastModificationDate == origin.lastModificationDate)
    }

    @Test func copyCarriesTheGameContent() {
        let origin = makeOrigin()
        let copy = origin.detachedDraftCopy()
        #expect(copy.sgf == origin.sgf)
        #expect(copy.currentIndex == 2)
        #expect(copy.comments?[1] == "note")
        #expect(copy.moves?[1] == "Q4")
        #expect(copy.winRates?[1] == 0.5)
    }

    @Test func copyHasItsOwnConfigObject() {
        let origin = makeOrigin()
        let copy = origin.detachedDraftCopy()
        #expect(copy.concreteConfig !== origin.concreteConfig)
        #expect(copy.concreteConfig.komi == 6.5)
        copy.concreteConfig.komi = 0.5
        #expect(origin.concreteConfig.komi == 6.5)
    }

    @Test func mutatingTheCopyLeavesTheOriginAlone() {
        let origin = makeOrigin()
        let copy = origin.detachedDraftCopy()
        copy.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp];B[cc])"
        copy.name = "Changed"
        #expect(origin.sgf == "(;FF[4]GM[1]SZ[19];B[dd];W[pp])")
        #expect(origin.name == "Origin")
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd "ios/KataGo iOS" && xcodebuild test -project "KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime Mac" -destination 'platform=macOS' \
  -only-testing:"KataGo Anytime MacTests/GameRecordDraftCopyTests" 2>&1 | tail -20
```

Expected: FAIL — `value of type 'GameRecord' has no member 'detachedDraftCopy'`.

- [ ] **Step 3: Write the implementation**

Create `ios/KataGo iOS/KataGo Anytime Mac/Draft/GameRecord+Draft.swift`:

```swift
//
//  GameRecord+Draft.swift
//  KataGo Anytime Mac
//

import Foundation
import KataGoGameStore

extension GameRecord {
    /// A detached copy for editing.
    ///
    /// Differs from `clone()` deliberately: `clone()` mints a fresh `uuid`,
    /// appends `" (copy)"` to the name, and stamps `lastModificationDate` to
    /// now — all correct for a user-visible duplicate, all wrong for a draft,
    /// which must be indistinguishable from its origin until the user changes
    /// something.
    ///
    /// The result is NEVER inserted into a `ModelContext`. That is the property
    /// the whole draft design rests on: an unregistered object cannot be
    /// autosaved, cannot be reached by `context.save()`, and cannot be exported
    /// to CloudKit, no matter what code runs.
    func detachedDraftCopy() -> GameRecord {
        let newConfig = Config(config: config)

        let copy = GameRecord(
            sgf: sgf,
            currentIndex: currentIndex,
            config: newConfig,
            name: name,
            lastModificationDate: lastModificationDate,
            comments: comments,
            thumbnail: thumbnail,
            scoreLeads: scoreLeads,
            bestMoves: bestMoves,
            winRates: winRates,
            deadBlackStones: deadBlackStones,
            deadWhiteStones: deadWhiteStones,
            blackSchrodingerStones: blackSchrodingerStones,
            whiteSchrodingerStones: whiteSchrodingerStones,
            moves: moves,
            blackStones: blackStones,
            whiteStones: whiteStones,
            ownershipWhiteness: ownershipWhiteness,
            ownershipScales: ownershipScales,
            width: width,
            height: height
        )

        // `GameRecord.init` has no `uuid` parameter and defaults it to a fresh
        // UUID; the draft must keep the origin's so deep links, the widget's
        // configured game, and `resolvedRecord` all still line up. There is no
        // collision risk because the draft is never inserted.
        copy.uuid = uuid
        newConfig.gameRecord = copy
        return copy
    }
}
```

- [ ] **Step 4: Add the file to both targets**

```bash
cd "ios/KataGo iOS" && ruby -e '
require "xcodeproj"
p_ = Xcodeproj::Project.open("KataGo Anytime.xcodeproj")
app  = p_.targets.find { |t| t.name == "KataGo Anytime Mac" }
test = p_.targets.find { |t| t.name == "KataGo Anytime MacTests" }
group = p_.main_group.find_subpath("KataGo Anytime Mac/Draft", true)
group.set_source_tree("SOURCE_ROOT")
group.set_path("KataGo Anytime Mac/Draft")
ref = group.new_reference("GameRecord+Draft.swift")
app.add_file_references([ref])
test.add_file_references([ref])
p_.save
puts "added GameRecord+Draft.swift to both targets"'
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd "ios/KataGo iOS" && xcodebuild test -project "KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime Mac" -destination 'platform=macOS' \
  -only-testing:"KataGo Anytime MacTests/GameRecordDraftCopyTests" 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, four tests passing.

- [ ] **Step 6: Commit**

```bash
git add "ios/KataGo iOS/KataGo Anytime Mac/Draft/GameRecord+Draft.swift" \
        "ios/KataGo iOS/KataGo Anytime MacTests/GameRecordDraftCopyTests.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj"
git commit -m "$(cat <<'EOF'
feat(mac): add GameRecord.detachedDraftCopy for draft editing

clone() is close but wrong for a draft: it mints a fresh uuid, appends
" (copy)" and restamps the modification date. A draft must be
indistinguishable from its origin until the user changes something.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
)"
```

---

### Task 4: `DraftSnapshot`

The single place the drafted field list is written down. Used as the dirty/conflict baseline, as the Save-time field copy, and as the crash-mirror payload.

**Files:**
- Create: `ios/KataGo iOS/KataGo Anytime Mac/Draft/DraftSnapshot.swift`
- Test: `ios/KataGo iOS/KataGo Anytime MacTests/DraftSnapshotTests.swift`

**Interfaces:**
- Consumes: `GameRecord`, `Config`.
- Produces:
  - `struct DraftSnapshot: Codable, Equatable`
  - `DraftSnapshot.currentVersion: Int`
  - `init(record: GameRecord, originUUID: UUID?)`
  - `func apply(to record: GameRecord)`
  - `var game: DraftSnapshot.GameFields` — has `sgf`, `name`, `comments`
  - `var config: DraftSnapshot.ConfigFields`
  - `var originUUID: UUID?`

- [ ] **Step 1: Write the failing test**

Create `ios/KataGo iOS/KataGo Anytime MacTests/DraftSnapshotTests.swift`:

```swift
//
//  DraftSnapshotTests.swift
//  KataGo Anytime MacTests
//

import Testing
import Foundation
@testable import KataGoGameStore

@MainActor
struct DraftSnapshotTests {

    private func populated() -> GameRecord {
        let record = GameRecord(config: Config())
        record.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp])"
        record.currentIndex = 2
        record.name = "Populated"
        record.comments = [1: "note"]
        record.moves = [0: "D16", 1: "Q4"]
        record.winRates = [1: 0.42]
        record.scoreLeads = [1: -1.5]
        record.bestMoves = [1: "Q16"]
        record.blackStones = [1: "D16"]
        record.whiteStones = [1: "Q4"]
        record.ownershipWhiteness = [1: [0.1, 0.2]]
        record.ownershipScales = [1: [0.3, 0.4]]
        record.width = 19
        record.height = 19
        record.concreteConfig.komi = 6.5
        record.concreteConfig.boardWidth = 19
        record.concreteConfig.optionalBlackMaxTime = 3.0
        return record
    }

    @Test func snapshotCapturesGameAndConfigFields() {
        let snapshot = DraftSnapshot(record: populated(), originUUID: nil)
        #expect(snapshot.game.sgf == "(;FF[4]GM[1]SZ[19];B[dd];W[pp])")
        #expect(snapshot.game.name == "Populated")
        #expect(snapshot.game.comments?[1] == "note")
        #expect(snapshot.game.winRates?[1] == 0.42)
        #expect(snapshot.config.komi == 6.5)
        #expect(snapshot.config.optionalBlackMaxTime == 3.0)
    }

    @Test func applyCopiesEveryDraftedFieldOntoATarget() {
        let source = populated()
        let snapshot = DraftSnapshot(record: source, originUUID: nil)

        let target = GameRecord(config: Config())
        snapshot.apply(to: target)

        #expect(target.sgf == source.sgf)
        #expect(target.currentIndex == 2)
        #expect(target.name == "Populated")
        #expect(target.comments?[1] == "note")
        #expect(target.moves?[1] == "Q4")
        #expect(target.winRates?[1] == 0.42)
        #expect(target.scoreLeads?[1] == -1.5)
        #expect(target.bestMoves?[1] == "Q16")
        #expect(target.blackStones?[1] == "D16")
        #expect(target.whiteStones?[1] == "Q4")
        #expect(target.ownershipWhiteness?[1] == [0.1, 0.2])
        #expect(target.ownershipScales?[1] == [0.3, 0.4])
        #expect(target.width == 19)
        #expect(target.height == 19)
        #expect(target.concreteConfig.komi == 6.5)
        #expect(target.concreteConfig.optionalBlackMaxTime == 3.0)
    }

    @Test func applyLeavesTheTargetUuidAlone() {
        let source = populated()
        let target = GameRecord(config: Config())
        let targetUUID = target.uuid

        DraftSnapshot(record: source, originUUID: nil).apply(to: target)

        #expect(target.uuid == targetUUID)
        #expect(target.uuid != source.uuid)
    }

    @Test func snapshotRoundTripsThroughJSON() throws {
        let snapshot = DraftSnapshot(record: populated(), originUUID: UUID())
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(DraftSnapshot.self, from: data)
        #expect(decoded == snapshot)
    }

    @Test func snapshotCarriesTheCurrentVersion() {
        let snapshot = DraftSnapshot(record: populated(), originUUID: nil)
        #expect(snapshot.version == DraftSnapshot.currentVersion)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd "ios/KataGo iOS" && xcodebuild test -project "KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime Mac" -destination 'platform=macOS' \
  -only-testing:"KataGo Anytime MacTests/DraftSnapshotTests" 2>&1 | tail -20
```

Expected: FAIL — `cannot find 'DraftSnapshot' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ios/KataGo iOS/KataGo Anytime Mac/Draft/DraftSnapshot.swift`:

```swift
//
//  DraftSnapshot.swift
//  KataGo Anytime Mac
//

import Foundation
import KataGoGameStore

/// A versioned, `Codable` capture of every field a draft owns.
///
/// This is the SINGLE place the drafted field list is written down. It serves
/// three jobs, and a field missing here is silently lost by all three:
///   * the baseline a draft is compared against (dirty / conflict),
///   * the field copy applied to the origin at Save,
///   * the crash-mirror payload on disk.
///
/// It deliberately does NOT carry `uuid`: applying a snapshot must never
/// change the identity of the record it is applied to. The origin's UUID
/// travels separately in `originUUID`, purely so a restored mirror can find
/// its origin again.
struct DraftSnapshot: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    /// The saved record this draft came from, or nil while untitled.
    var originUUID: UUID?
    var game: GameFields
    var config: ConfigFields

    struct GameFields: Codable, Equatable {
        var sgf: String
        var currentIndex: Int
        var name: String
        var lastModificationDate: Date?
        var comments: [Int: String]?
        var thumbnail: Data?
        var scoreLeads: [Int: Float]?
        var bestMoves: [Int: String]?
        var winRates: [Int: Float]?
        var deadBlackStones: [Int: String]?
        var deadWhiteStones: [Int: String]?
        var blackSchrodingerStones: [Int: String]?
        var whiteSchrodingerStones: [Int: String]?
        var moves: [Int: String]?
        var blackStones: [Int: String]?
        var whiteStones: [Int: String]?
        var ownershipWhiteness: [Int: [Float]]?
        var ownershipScales: [Int: [Float]]?
        var width: Int?
        var height: Int?
    }

    struct ConfigFields: Codable, Equatable {
        var boardWidth: Int
        var boardHeight: Int
        var rule: Int
        var komi: Float
        var playoutDoublingAdvantage: Float
        var analysisWideRootNoise: Float
        var maxAnalysisMoves: Int
        var analysisInterval: Int
        var analysisInformation: Int
        var hiddenAnalysisVisitRatio: Float
        var stoneStyle: Int
        var showCoordinate: Bool
        var humanSLRootExploreProbWeightful: Float
        var humanSLProfile: String
        var optionalAnalysisForWhom: Int?
        var optionalShowOwnership: Bool?
        var optionalHumanRatioForWhite: Float?
        var optionalHumanProfileForWhite: String?
        var optionalSoundEffect: Bool?
        var optionalShowComments: Bool?
        var optionalShowPass: Bool?
        var optionalVerticalFlip: Bool?
        var optionalBlackMaxTime: Float?
        var optionalWhiteMaxTime: Float?
        var optionalKoRule: Int?
        var optionalScoringRule: Int?
        var optionalTaxRule: Int?
        var optionalMultiStoneSuicideLegal: Bool?
        var optionalHasButton: Bool?
        var optionalWhiteHandicapBonusRule: Int?
        var optionalShowWinrateBar: Bool?
        var optionalAnalysisStyle: Int?
        var optionalShowCharts: Bool?
        var optionalUseLLM: Bool?
        var optionalTemperature: Float?
        var optionalTone: Int?
    }

    @MainActor
    init(record: GameRecord, originUUID: UUID?) {
        self.version = Self.currentVersion
        self.originUUID = originUUID

        self.game = GameFields(
            sgf: record.sgf,
            currentIndex: record.currentIndex,
            name: record.name,
            lastModificationDate: record.lastModificationDate,
            comments: record.comments,
            thumbnail: record.thumbnail,
            scoreLeads: record.scoreLeads,
            bestMoves: record.bestMoves,
            winRates: record.winRates,
            deadBlackStones: record.deadBlackStones,
            deadWhiteStones: record.deadWhiteStones,
            blackSchrodingerStones: record.blackSchrodingerStones,
            whiteSchrodingerStones: record.whiteSchrodingerStones,
            moves: record.moves,
            blackStones: record.blackStones,
            whiteStones: record.whiteStones,
            ownershipWhiteness: record.ownershipWhiteness,
            ownershipScales: record.ownershipScales,
            width: record.width,
            height: record.height
        )

        let c = record.concreteConfig
        self.config = ConfigFields(
            boardWidth: c.boardWidth,
            boardHeight: c.boardHeight,
            rule: c.rule,
            komi: c.komi,
            playoutDoublingAdvantage: c.playoutDoublingAdvantage,
            analysisWideRootNoise: c.analysisWideRootNoise,
            maxAnalysisMoves: c.maxAnalysisMoves,
            analysisInterval: c.analysisInterval,
            analysisInformation: c.analysisInformation,
            hiddenAnalysisVisitRatio: c.hiddenAnalysisVisitRatio,
            stoneStyle: c.stoneStyle,
            showCoordinate: c.showCoordinate,
            humanSLRootExploreProbWeightful: c.humanSLRootExploreProbWeightful,
            humanSLProfile: c.humanSLProfile,
            optionalAnalysisForWhom: c.optionalAnalysisForWhom,
            optionalShowOwnership: c.optionalShowOwnership,
            optionalHumanRatioForWhite: c.optionalHumanRatioForWhite,
            optionalHumanProfileForWhite: c.optionalHumanProfileForWhite,
            optionalSoundEffect: c.optionalSoundEffect,
            optionalShowComments: c.optionalShowComments,
            optionalShowPass: c.optionalShowPass,
            optionalVerticalFlip: c.optionalVerticalFlip,
            optionalBlackMaxTime: c.optionalBlackMaxTime,
            optionalWhiteMaxTime: c.optionalWhiteMaxTime,
            optionalKoRule: c.optionalKoRule,
            optionalScoringRule: c.optionalScoringRule,
            optionalTaxRule: c.optionalTaxRule,
            optionalMultiStoneSuicideLegal: c.optionalMultiStoneSuicideLegal,
            optionalHasButton: c.optionalHasButton,
            optionalWhiteHandicapBonusRule: c.optionalWhiteHandicapBonusRule,
            optionalShowWinrateBar: c.optionalShowWinrateBar,
            optionalAnalysisStyle: c.optionalAnalysisStyle,
            optionalShowCharts: c.optionalShowCharts,
            optionalUseLLM: c.optionalUseLLM,
            optionalTemperature: c.optionalTemperature,
            optionalTone: c.optionalTone
        )
    }

    /// Copies every drafted field onto `record`. Never touches `uuid` or the
    /// record's `config` relationship — only the config's field values.
    @MainActor
    func apply(to record: GameRecord) {
        record.sgf = game.sgf
        record.currentIndex = game.currentIndex
        record.name = game.name
        record.lastModificationDate = game.lastModificationDate
        record.comments = game.comments
        record.thumbnail = game.thumbnail
        record.scoreLeads = game.scoreLeads
        record.bestMoves = game.bestMoves
        record.winRates = game.winRates
        record.deadBlackStones = game.deadBlackStones
        record.deadWhiteStones = game.deadWhiteStones
        record.blackSchrodingerStones = game.blackSchrodingerStones
        record.whiteSchrodingerStones = game.whiteSchrodingerStones
        record.moves = game.moves
        record.blackStones = game.blackStones
        record.whiteStones = game.whiteStones
        record.ownershipWhiteness = game.ownershipWhiteness
        record.ownershipScales = game.ownershipScales
        record.width = game.width
        record.height = game.height

        let c = record.concreteConfig
        c.boardWidth = config.boardWidth
        c.boardHeight = config.boardHeight
        c.rule = config.rule
        c.komi = config.komi
        c.playoutDoublingAdvantage = config.playoutDoublingAdvantage
        c.analysisWideRootNoise = config.analysisWideRootNoise
        c.maxAnalysisMoves = config.maxAnalysisMoves
        c.analysisInterval = config.analysisInterval
        c.analysisInformation = config.analysisInformation
        c.hiddenAnalysisVisitRatio = config.hiddenAnalysisVisitRatio
        c.stoneStyle = config.stoneStyle
        c.showCoordinate = config.showCoordinate
        c.humanSLRootExploreProbWeightful = config.humanSLRootExploreProbWeightful
        c.humanSLProfile = config.humanSLProfile
        c.optionalAnalysisForWhom = config.optionalAnalysisForWhom
        c.optionalShowOwnership = config.optionalShowOwnership
        c.optionalHumanRatioForWhite = config.optionalHumanRatioForWhite
        c.optionalHumanProfileForWhite = config.optionalHumanProfileForWhite
        c.optionalSoundEffect = config.optionalSoundEffect
        c.optionalShowComments = config.optionalShowComments
        c.optionalShowPass = config.optionalShowPass
        c.optionalVerticalFlip = config.optionalVerticalFlip
        c.optionalBlackMaxTime = config.optionalBlackMaxTime
        c.optionalWhiteMaxTime = config.optionalWhiteMaxTime
        c.optionalKoRule = config.optionalKoRule
        c.optionalScoringRule = config.optionalScoringRule
        c.optionalTaxRule = config.optionalTaxRule
        c.optionalMultiStoneSuicideLegal = config.optionalMultiStoneSuicideLegal
        c.optionalHasButton = config.optionalHasButton
        c.optionalWhiteHandicapBonusRule = config.optionalWhiteHandicapBonusRule
        c.optionalShowWinrateBar = config.optionalShowWinrateBar
        c.optionalAnalysisStyle = config.optionalAnalysisStyle
        c.optionalShowCharts = config.optionalShowCharts
        c.optionalUseLLM = config.optionalUseLLM
        c.optionalTemperature = config.optionalTemperature
        c.optionalTone = config.optionalTone
    }
}
```

- [ ] **Step 4: Add the file to both targets**

```bash
cd "ios/KataGo iOS" && ruby -e '
require "xcodeproj"
p_ = Xcodeproj::Project.open("KataGo Anytime.xcodeproj")
app  = p_.targets.find { |t| t.name == "KataGo Anytime Mac" }
test = p_.targets.find { |t| t.name == "KataGo Anytime MacTests" }
group = p_.main_group.find_subpath("KataGo Anytime Mac/Draft", true)
ref = group.new_reference("DraftSnapshot.swift")
app.add_file_references([ref])
test.add_file_references([ref])
p_.save
puts "added DraftSnapshot.swift to both targets"'
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd "ios/KataGo iOS" && xcodebuild test -project "KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime Mac" -destination 'platform=macOS' \
  -only-testing:"KataGo Anytime MacTests/DraftSnapshotTests" 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, five tests passing.

- [ ] **Step 6: Commit**

```bash
git add "ios/KataGo iOS/KataGo Anytime Mac/Draft/DraftSnapshot.swift" \
        "ios/KataGo iOS/KataGo Anytime MacTests/DraftSnapshotTests.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj"
git commit -m "$(cat <<'EOF'
feat(mac): add DraftSnapshot, the one place the drafted fields are listed

It serves as the dirty/conflict baseline, the Save-time field copy, and
the crash-mirror payload, so a field missing here is silently lost by
all three. It carries no uuid: applying a snapshot must never change
the identity of the record it lands on.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
)"
```

---

### Task 5: `DraftComparator`

One comparison function, two questions. `differs(draft, baseline)` is *dirty*; `differs(origin, baseline)` is *conflict*.

**Files:**
- Create: `ios/KataGo iOS/KataGo Anytime Mac/Draft/DraftComparator.swift`
- Test: `ios/KataGo iOS/KataGo Anytime MacTests/DraftComparatorTests.swift`

**Interfaces:**
- Consumes: `DraftSnapshot`.
- Produces: `enum DraftComparator { static func differs(_ a: DraftSnapshot, _ b: DraftSnapshot) -> Bool }`

- [ ] **Step 1: Write the failing test**

Create `ios/KataGo iOS/KataGo Anytime MacTests/DraftComparatorTests.swift`:

```swift
//
//  DraftComparatorTests.swift
//  KataGo Anytime MacTests
//

import Testing
import Foundation
@testable import KataGoGameStore

@MainActor
struct DraftComparatorTests {

    private func baseRecord() -> GameRecord {
        let record = GameRecord(config: Config())
        record.sgf = "(;FF[4]GM[1]SZ[19];B[dd])"
        record.name = "Base"
        record.comments = [0: "hi"]
        record.currentIndex = 1
        return record
    }

    private func snapshot(_ record: GameRecord) -> DraftSnapshot {
        DraftSnapshot(record: record, originUUID: nil)
    }

    @Test func identicalSnapshotsDoNotDiffer() {
        let record = baseRecord()
        #expect(!DraftComparator.differs(snapshot(record), snapshot(record)))
    }

    @Test func changingTheSgfDiffers() {
        let record = baseRecord()
        let before = snapshot(record)
        record.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp])"
        #expect(DraftComparator.differs(snapshot(record), before))
    }

    @Test func changingTheNameDiffers() {
        let record = baseRecord()
        let before = snapshot(record)
        record.name = "Renamed"
        #expect(DraftComparator.differs(snapshot(record), before))
    }

    @Test func changingACommentDiffers() {
        let record = baseRecord()
        let before = snapshot(record)
        record.comments = [0: "changed"]
        #expect(DraftComparator.differs(snapshot(record), before))
    }

    @Test func changingAConfigFieldDiffers() {
        let record = baseRecord()
        let before = snapshot(record)
        record.concreteConfig.komi = 0.5
        #expect(DraftComparator.differs(snapshot(record), before))
    }

    @Test func changingTheCursorDoesNotDiffer() {
        let record = baseRecord()
        let before = snapshot(record)
        record.currentIndex = 0
        #expect(!DraftComparator.differs(snapshot(record), before))
    }

    @Test func changingAnalysisDataDoesNotDiffer() {
        // The whole point: analysis rewrites these every few hundred
        // milliseconds, and must never light up the dirty marker.
        let record = baseRecord()
        let before = snapshot(record)
        record.winRates = [1: 0.7]
        record.scoreLeads = [1: 2.5]
        record.bestMoves = [1: "Q16"]
        record.ownershipWhiteness = [1: [0.5]]
        record.ownershipScales = [1: [0.5]]
        record.moves = [0: "D16"]
        record.blackStones = [1: "D16"]
        record.whiteStones = [1: ""]
        record.lastModificationDate = Date(timeIntervalSince1970: 999)
        #expect(!DraftComparator.differs(snapshot(record), before))
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd "ios/KataGo iOS" && xcodebuild test -project "KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime Mac" -destination 'platform=macOS' \
  -only-testing:"KataGo Anytime MacTests/DraftComparatorTests" 2>&1 | tail -20
```

Expected: FAIL — `cannot find 'DraftComparator' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ios/KataGo iOS/KataGo Anytime Mac/Draft/DraftComparator.swift`:

```swift
//
//  DraftComparator.swift
//  KataGo Anytime Mac
//

import Foundation

/// One comparison serving two questions, both against the baseline snapshot
/// taken when the draft opened (the common ancestor):
///
///   * `differs(draft, baseline)`  — *dirty*: the user changed something.
///   * `differs(origin, baseline)` — *conflict*: another device changed the
///     saved game while the draft was open.
///
/// It compares exactly four things: `sgf`, `name`, `comments`, and every
/// `Config` field. All of `Config` rather than a hand-picked subset, so the
/// list cannot silently drift out of date as settings are added.
///
/// Everything else is ignored on purpose — cursor position and derived
/// analysis data. `maybeUpdateAnalysisData` rewrites `winRates`/`scoreLeads`/
/// `bestMoves`/`ownership*` every few hundred milliseconds while analysis
/// runs; counting those would light up the dirty marker the instant a game is
/// unlocked and make "Save changes?" fire for work the user never did.
enum DraftComparator {
    static func differs(_ a: DraftSnapshot, _ b: DraftSnapshot) -> Bool {
        a.game.sgf != b.game.sgf
            || a.game.name != b.game.name
            || a.game.comments != b.game.comments
            || a.config != b.config
    }
}
```

- [ ] **Step 4: Add the file to both targets**

```bash
cd "ios/KataGo iOS" && ruby -e '
require "xcodeproj"
p_ = Xcodeproj::Project.open("KataGo Anytime.xcodeproj")
app  = p_.targets.find { |t| t.name == "KataGo Anytime Mac" }
test = p_.targets.find { |t| t.name == "KataGo Anytime MacTests" }
group = p_.main_group.find_subpath("KataGo Anytime Mac/Draft", true)
ref = group.new_reference("DraftComparator.swift")
app.add_file_references([ref])
test.add_file_references([ref])
p_.save
puts "added DraftComparator.swift to both targets"'
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd "ios/KataGo iOS" && xcodebuild test -project "KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime Mac" -destination 'platform=macOS' \
  -only-testing:"KataGo Anytime MacTests/DraftComparatorTests" 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, seven tests passing.

- [ ] **Step 6: Commit**

```bash
git add "ios/KataGo iOS/KataGo Anytime Mac/Draft/DraftComparator.swift" \
        "ios/KataGo iOS/KataGo Anytime MacTests/DraftComparatorTests.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj"
git commit -m "$(cat <<'EOF'
feat(mac): add DraftComparator for dirty and conflict detection

Against the baseline taken when the draft opened, differs(draft,
baseline) is dirty and differs(origin, baseline) is conflict. It
ignores cursor position and derived analysis data on purpose: those are
rewritten every few hundred milliseconds while analysis runs, and
counting them would ask the user to save work they never did.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
)"
```

---

### Task 6: `GameDraft`

**Files:**
- Create: `ios/KataGo iOS/KataGo Anytime Mac/Draft/GameDraft.swift`
- Test: `ios/KataGo iOS/KataGo Anytime MacTests/GameDraftTests.swift`

**Interfaces:**
- Consumes: `GameRecord.detachedDraftCopy()`, `DraftSnapshot`, `DraftComparator`, `SgfHeaderScan`.
- Produces:
  - `final class GameDraft` with `record: GameRecord`, `origin: GameRecord?`, `baseline: DraftSnapshot`
  - `init(origin: GameRecord)` / `init(untitled: GameRecord)`
  - `var isDirty: Bool`, `var hasConflict: Bool`, `var moveCount: Int`
  - `func snapshot() -> DraftSnapshot`
  - `enum SaveOutcome { case updatedOrigin(GameRecord); case insertedNew(GameRecord) }`
  - `func save(into context: ModelContext) throws -> SaveOutcome`
  - `func saveAsNewGame(into context: ModelContext) throws -> GameRecord`
  - `func rebaseline()`

- [ ] **Step 1: Write the failing test**

Create `ios/KataGo iOS/KataGo Anytime MacTests/GameDraftTests.swift`:

```swift
//
//  GameDraftTests.swift
//  KataGo Anytime MacTests
//

import Testing
import Foundation
import SwiftData
@testable import KataGoGameStore

@MainActor
struct GameDraftTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: GameRecord.self, Config.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func storedGame(in context: ModelContext,
                            sgf: String = "(;FF[4]GM[1]SZ[19];B[dd])",
                            name: String = "Saved") throws -> GameRecord {
        let record = GameRecord(config: Config())
        record.sgf = sgf
        record.name = name
        record.currentIndex = 1
        context.insert(record)
        try context.save()
        return record
    }

    // MARK: - Dirty

    @Test func aFreshDraftIsClean() throws {
        let context = try container().mainContext
        let draft = GameDraft(origin: try storedGame(in: context))
        #expect(!draft.isDirty)
    }

    @Test func playingAMoveMakesTheDraftDirty() throws {
        let context = try container().mainContext
        let draft = GameDraft(origin: try storedGame(in: context))
        draft.record.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp])"
        #expect(draft.isDirty)
    }

    @Test func analysisDataDoesNotMakeTheDraftDirty() throws {
        let context = try container().mainContext
        let draft = GameDraft(origin: try storedGame(in: context))
        draft.record.winRates = [1: 0.6]
        draft.record.currentIndex = 0
        #expect(!draft.isDirty)
    }

    @Test func anEmptyUntitledDraftIsClean() throws {
        let untitled = GameRecord(config: Config())
        untitled.sgf = GameRecord.defaultSgf
        let draft = GameDraft(untitled: untitled)
        #expect(!draft.isDirty)
    }

    @Test func anUntitledDraftWithAMoveIsDirty() throws {
        let untitled = GameRecord(config: Config())
        untitled.sgf = "(;FF[4]GM[1]SZ[19];B[dd])"
        let draft = GameDraft(untitled: untitled)
        #expect(draft.isDirty)
    }

    @Test func anUntitledDraftWithACommentIsDirty() throws {
        let untitled = GameRecord(config: Config())
        untitled.sgf = GameRecord.defaultSgf
        untitled.comments = [0: "opening thoughts"]
        let draft = GameDraft(untitled: untitled)
        #expect(draft.isDirty)
    }

    // MARK: - Isolation

    @Test func editingTheDraftDoesNotTouchTheStore() throws {
        let ctx = try container().mainContext
        let origin = try storedGame(in: ctx)
        let draft = GameDraft(origin: origin)

        draft.record.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp];B[cc])"
        draft.record.name = "Edited"
        try ctx.save()

        #expect(origin.sgf == "(;FF[4]GM[1]SZ[19];B[dd])")
        #expect(origin.name == "Saved")
        #expect(try ctx.fetch(FetchDescriptor<GameRecord>()).count == 1)
    }

    // MARK: - Save

    @Test func saveAppliesTheDraftOntoTheOrigin() throws {
        let ctx = try container().mainContext
        let origin = try storedGame(in: ctx)
        let draft = GameDraft(origin: origin)
        draft.record.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp])"

        let outcome = try draft.save(into: ctx)

        guard case .updatedOrigin(let saved) = outcome else {
            Issue.record("expected updatedOrigin, got \(outcome)")
            return
        }
        #expect(saved === origin)
        #expect(origin.sgf == "(;FF[4]GM[1]SZ[19];B[dd];W[pp])")
        #expect(try ctx.fetch(FetchDescriptor<GameRecord>()).count == 1)
    }

    @Test func saveClearsDirtyAndStampsTheModificationDate() throws {
        let ctx = try container().mainContext
        let origin = try storedGame(in: ctx)
        origin.lastModificationDate = Date(timeIntervalSince1970: 0)
        let draft = GameDraft(origin: origin)
        draft.record.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp])"

        _ = try draft.save(into: ctx)

        #expect(!draft.isDirty)
        #expect((origin.lastModificationDate ?? .distantPast) > Date(timeIntervalSince1970: 1))
    }

    @Test func savingAnUntitledDraftInsertsANewRecord() throws {
        let ctx = try container().mainContext
        let untitled = GameRecord(config: Config())
        untitled.sgf = "(;FF[4]GM[1]SZ[19];B[dd])"
        untitled.name = "Brand New"
        let draft = GameDraft(untitled: untitled)

        let outcome = try draft.save(into: ctx)

        guard case .insertedNew(let inserted) = outcome else {
            Issue.record("expected insertedNew, got \(outcome)")
            return
        }
        #expect(inserted.name == "Brand New")
        #expect(inserted.sgf == "(;FF[4]GM[1]SZ[19];B[dd])")
        #expect(try ctx.fetch(FetchDescriptor<GameRecord>()).count == 1)
        #expect(draft.origin === inserted)
        #expect(!draft.isDirty)
    }

    @Test func savingAnOriginThatWasDeletedInsertsInstead() throws {
        let ctx = try container().mainContext
        let origin = try storedGame(in: ctx)
        let draft = GameDraft(origin: origin)
        draft.record.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp])"

        ctx.delete(origin)
        try ctx.save()

        let outcome = try draft.save(into: ctx)

        guard case .insertedNew = outcome else {
            Issue.record("expected insertedNew after the origin was deleted")
            return
        }
        #expect(try ctx.fetch(FetchDescriptor<GameRecord>()).count == 1)
    }

    // MARK: - Conflict

    @Test func aDraftWithAnUntouchedOriginHasNoConflict() throws {
        let ctx = try container().mainContext
        let draft = GameDraft(origin: try storedGame(in: ctx))
        draft.record.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp])"
        #expect(!draft.hasConflict)
    }

    @Test func anOriginChangedUnderneathIsAConflict() throws {
        let ctx = try container().mainContext
        let origin = try storedGame(in: ctx)
        let draft = GameDraft(origin: origin)

        // Stands in for a CloudKit import from another device.
        origin.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[qq])"

        #expect(draft.hasConflict)
    }

    @Test func anUntitledDraftNeverConflicts() throws {
        let untitled = GameRecord(config: Config())
        untitled.sgf = "(;FF[4]GM[1]SZ[19];B[dd])"
        #expect(!GameDraft(untitled: untitled).hasConflict)
    }

    @Test func saveAsNewGameLeavesTheOriginIntact() throws {
        let ctx = try container().mainContext
        let origin = try storedGame(in: ctx)
        let draft = GameDraft(origin: origin)
        draft.record.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp])"

        let inserted = try draft.saveAsNewGame(into: ctx)

        #expect(origin.sgf == "(;FF[4]GM[1]SZ[19];B[dd])")
        #expect(inserted.sgf == "(;FF[4]GM[1]SZ[19];B[dd];W[pp])")
        #expect(inserted.name == "Saved (conflicted copy)")
        #expect(inserted.uuid != origin.uuid)
        #expect(try ctx.fetch(FetchDescriptor<GameRecord>()).count == 2)
    }

    // MARK: - Move count

    @Test func moveCountReadsTheDraftSgf() throws {
        let ctx = try container().mainContext
        let draft = GameDraft(origin: try storedGame(in: ctx))
        #expect(draft.moveCount == 1)
        draft.record.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp];B[cc])"
        #expect(draft.moveCount == 3)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd "ios/KataGo iOS" && xcodebuild test -project "KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime Mac" -destination 'platform=macOS' \
  -only-testing:"KataGo Anytime MacTests/GameDraftTests" 2>&1 | tail -20
```

Expected: FAIL — `cannot find 'GameDraft' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ios/KataGo iOS/KataGo Anytime Mac/Draft/GameDraft.swift`:

```swift
//
//  GameDraft.swift
//  KataGo Anytime Mac
//

import Foundation
import SwiftData
import KataGoGameStore
import KataGoAnalysisKit

/// An unsaved editing session over one game.
///
/// `record` is a DETACHED `GameRecord` — never inserted into any
/// `ModelContext`. That is the structural safety property the whole design
/// rests on: an unregistered object cannot be autosaved, cannot be reached by
/// `context.save()`, and cannot be exported to CloudKit, no matter what code
/// runs while it is being edited.
///
/// `origin` is the saved record it came from, or nil while untitled (a game
/// created with the New Game sheet that has never been saved, so it has no
/// library row).
@MainActor
final class GameDraft {
    /// The detached record the board, engine and inspector all read and write.
    let record: GameRecord
    /// The saved record to write back to, or nil while untitled.
    private(set) var origin: GameRecord?
    /// The common ancestor: the state at the moment the draft opened.
    private(set) var baseline: DraftSnapshot

    enum SaveOutcome {
        case updatedOrigin(GameRecord)
        case insertedNew(GameRecord)
    }

    /// Opens a draft over an existing saved game.
    init(origin: GameRecord) {
        self.record = origin.detachedDraftCopy()
        self.origin = origin
        self.baseline = DraftSnapshot(record: origin, originUUID: origin.uuid)
    }

    /// Opens a draft over a brand-new game that is not in the library. The
    /// record must already be detached; the caller builds it from the New Game
    /// sheet's board size, komi and rules.
    init(untitled record: GameRecord) {
        self.record = record
        self.origin = nil
        self.baseline = DraftSnapshot(record: record, originUUID: nil)
    }

    /// Restores a draft recovered from the crash mirror, whose baseline may
    /// predate changes another device has since made to `origin`.
    init(record: GameRecord, origin: GameRecord?, baseline: DraftSnapshot) {
        self.record = record
        self.origin = origin
        self.baseline = baseline
    }

    func snapshot() -> DraftSnapshot {
        DraftSnapshot(record: record, originUUID: origin?.uuid)
    }

    /// Moves on the draft's mainline. Read via the bridge-free `SgfHeaderScan`
    /// rather than `SgfOperations`, which lives in `KataGoUICore` and would
    /// drag the C++ bridge into the non-hosted test bundle.
    var moveCount: Int {
        SgfHeaderScan(sgf: record.sgf)?.moveCount ?? 0
    }

    /// True when the user has changed something worth saving.
    ///
    /// For an untitled draft there is no meaningful baseline to compare
    /// against — it was captured from an empty board — so it is dirty once it
    /// has real content instead. Otherwise abandoning a ⌘N you immediately
    /// changed your mind about would prompt for nothing.
    var isDirty: Bool {
        if origin == nil {
            return moveCount > 0 || !(record.comments?.isEmpty ?? true)
        }
        return DraftComparator.differs(snapshot(), baseline)
    }

    /// True when the saved game changed under the draft — another device's
    /// CloudKit import landed after the draft opened.
    var hasConflict: Bool {
        guard let origin, !origin.isDeleted else { return false }
        return DraftComparator.differs(
            DraftSnapshot(record: origin, originUUID: origin.uuid), baseline)
    }

    /// Writes the draft through: onto the origin when there is one, otherwise
    /// as a new record. An origin that has been deleted (locally or by a
    /// remote delete) falls back to inserting, so the user's work survives
    /// rather than being written onto a tombstone.
    @discardableResult
    func save(into context: ModelContext) throws -> SaveOutcome {
        record.lastModificationDate = .now

        if let origin, !origin.isDeleted {
            snapshot().apply(to: origin)
            try context.save()
            rebaseline()
            return .updatedOrigin(origin)
        }

        let inserted = record.detachedDraftCopy()
        inserted.uuid = UUID()
        context.insert(inserted)
        try context.save()
        origin = inserted
        rebaseline()
        return .insertedNew(inserted)
    }

    /// The conflict sheet's non-destructive escape hatch: insert the draft as
    /// a separate game and leave the incoming version untouched, so nothing is
    /// lost on either side.
    @discardableResult
    func saveAsNewGame(into context: ModelContext) throws -> GameRecord {
        let copy = record.detachedDraftCopy()
        copy.uuid = UUID()
        copy.name = "\(record.name) (conflicted copy)"
        copy.lastModificationDate = .now
        context.insert(copy)
        try context.save()
        return copy
    }

    /// Re-reads the baseline from the origin after a successful save, so the
    /// draft object can stay live and selected without churning identity.
    func rebaseline() {
        if let origin, !origin.isDeleted {
            baseline = DraftSnapshot(record: origin, originUUID: origin.uuid)
        } else {
            baseline = snapshot()
        }
    }
}
```

- [ ] **Step 4: Add the file to both targets**

```bash
cd "ios/KataGo iOS" && ruby -e '
require "xcodeproj"
p_ = Xcodeproj::Project.open("KataGo Anytime.xcodeproj")
app  = p_.targets.find { |t| t.name == "KataGo Anytime Mac" }
test = p_.targets.find { |t| t.name == "KataGo Anytime MacTests" }
group = p_.main_group.find_subpath("KataGo Anytime Mac/Draft", true)
ref = group.new_reference("GameDraft.swift")
app.add_file_references([ref])
test.add_file_references([ref])
p_.save
puts "added GameDraft.swift to both targets"'
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd "ios/KataGo iOS" && xcodebuild test -project "KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime Mac" -destination 'platform=macOS' \
  -only-testing:"KataGo Anytime MacTests/GameDraftTests" 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`, sixteen tests passing.

- [ ] **Step 6: Commit**

```bash
git add "ios/KataGo iOS/KataGo Anytime Mac/Draft/GameDraft.swift" \
        "ios/KataGo iOS/KataGo Anytime MacTests/GameDraftTests.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj"
git commit -m "$(cat <<'EOF'
feat(mac): add GameDraft, an unsaved editing session over one game

The draft's record is detached and never inserted, so nothing it
receives can be autosaved or synced. Save applies it onto the origin,
or inserts when the game is untitled or its origin has been deleted;
saveAsNewGame is the conflict sheet's non-destructive escape hatch.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
)"
```

---

### Task 7: `DraftExitDecision`

**Files:**
- Create: `ios/KataGo iOS/KataGo Anytime Mac/Draft/DraftExitDecision.swift`
- Test: `ios/KataGo iOS/KataGo Anytime MacTests/DraftExitDecisionTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum DraftExitTrigger { case switchGame, closeWindow, quit, lock, deleteOrigin }`
  - `enum DraftExitDecision { case proceed, prompt }`
  - `static func decide(hasDraft: Bool, isDirty: Bool, trigger: DraftExitTrigger) -> DraftExitDecision`
  - `enum DraftExitAnswer { case save, discard, cancel }`

- [ ] **Step 1: Write the failing test**

Create `ios/KataGo iOS/KataGo Anytime MacTests/DraftExitDecisionTests.swift`:

```swift
//
//  DraftExitDecisionTests.swift
//  KataGo Anytime MacTests
//

import Testing

struct DraftExitDecisionTests {

    private let allTriggers: [DraftExitTrigger] =
        [.switchGame, .closeWindow, .quit, .lock, .deleteOrigin]

    @Test func noDraftAlwaysProceeds() {
        for trigger in allTriggers {
            #expect(DraftExitDecision.decide(hasDraft: false, isDirty: false,
                                             trigger: trigger) == .proceed)
        }
    }

    @Test func cleanDraftAlwaysProceeds() {
        for trigger in allTriggers {
            #expect(DraftExitDecision.decide(hasDraft: true, isDirty: false,
                                             trigger: trigger) == .proceed)
        }
    }

    @Test func dirtyDraftAlwaysPrompts() {
        for trigger in allTriggers {
            #expect(DraftExitDecision.decide(hasDraft: true, isDirty: true,
                                             trigger: trigger) == .prompt)
        }
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd "ios/KataGo iOS" && xcodebuild test -project "KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime Mac" -destination 'platform=macOS' \
  -only-testing:"KataGo Anytime MacTests/DraftExitDecisionTests" 2>&1 | tail -20
```

Expected: FAIL — `cannot find 'DraftExitDecision' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ios/KataGo iOS/KataGo Anytime Mac/Draft/DraftExitDecision.swift`:

```swift
//
//  DraftExitDecision.swift
//  KataGo Anytime Mac
//

import Foundation

/// Every way a user can leave the game they are editing.
enum DraftExitTrigger: Equatable {
    case switchGame
    case closeWindow
    case quit
    case lock
    case deleteOrigin
}

/// What the user chose in the Save · Discard · Cancel sheet.
enum DraftExitAnswer: Equatable {
    case save
    case discard
    case cancel
}

/// Whether leaving needs to ask first.
///
/// Uniform on purpose: the trigger does not change the answer. Its only job is
/// to be reported to the user in the sheet's wording, so the rule stays one
/// line and no exit path can quietly acquire different semantics from the
/// others.
enum DraftExitDecision: Equatable {
    case proceed
    case prompt

    static func decide(hasDraft: Bool,
                       isDirty: Bool,
                       trigger: DraftExitTrigger) -> DraftExitDecision {
        (hasDraft && isDirty) ? .prompt : .proceed
    }
}
```

- [ ] **Step 4: Add the file to both targets**

```bash
cd "ios/KataGo iOS" && ruby -e '
require "xcodeproj"
p_ = Xcodeproj::Project.open("KataGo Anytime.xcodeproj")
app  = p_.targets.find { |t| t.name == "KataGo Anytime Mac" }
test = p_.targets.find { |t| t.name == "KataGo Anytime MacTests" }
group = p_.main_group.find_subpath("KataGo Anytime Mac/Draft", true)
ref = group.new_reference("DraftExitDecision.swift")
app.add_file_references([ref])
test.add_file_references([ref])
p_.save
puts "added DraftExitDecision.swift to both targets"'
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd "ios/KataGo iOS" && xcodebuild test -project "KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime Mac" -destination 'platform=macOS' \
  -only-testing:"KataGo Anytime MacTests/DraftExitDecisionTests" 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, three tests passing.

- [ ] **Step 6: Commit**

```bash
git add "ios/KataGo iOS/KataGo Anytime Mac/Draft/DraftExitDecision.swift" \
        "ios/KataGo iOS/KataGo Anytime MacTests/DraftExitDecisionTests.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj"
git commit -m "$(cat <<'EOF'
feat(mac): add the draft exit-decision rule

The trigger deliberately does not change the answer - it only shapes
the sheet's wording - so no exit path can quietly acquire different
semantics from the others.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
)"
```

---

### Task 8: `DraftMirrorStore`

**Files:**
- Create: `ios/KataGo iOS/KataGo Anytime Mac/Draft/DraftMirrorStore.swift`
- Test: `ios/KataGo iOS/KataGo Anytime MacTests/DraftMirrorStoreTests.swift`

**Interfaces:**
- Consumes: `DraftSnapshot`.
- Produces:
  - `struct DraftMirror: Codable, Equatable { var version: Int; var draft: DraftSnapshot; var baseline: DraftSnapshot }`
  - `final class DraftMirrorStore { init(directory: URL); func write(_:); func read() -> DraftMirror?; func clear() }`

- [ ] **Step 1: Write the failing test**

Create `ios/KataGo iOS/KataGo Anytime MacTests/DraftMirrorStoreTests.swift`:

```swift
//
//  DraftMirrorStoreTests.swift
//  KataGo Anytime MacTests
//

import Testing
import Foundation
@testable import KataGoGameStore

@MainActor
struct DraftMirrorStoreTests {

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "draft-mirror-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func mirror() -> DraftMirror {
        let record = GameRecord(config: Config())
        record.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp])"
        record.name = "Mirrored"
        let originUUID = UUID()
        let draft = DraftSnapshot(record: record, originUUID: originUUID)

        let base = GameRecord(config: Config())
        base.sgf = "(;FF[4]GM[1]SZ[19];B[dd])"
        base.name = "Mirrored"
        let baseline = DraftSnapshot(record: base, originUUID: originUUID)

        return DraftMirror(draft: draft, baseline: baseline)
    }

    @Test func readReturnsNilWhenNothingWasWritten() throws {
        let store = DraftMirrorStore(directory: try tempDirectory())
        #expect(store.read() == nil)
    }

    @Test func writtenMirrorRoundTrips() throws {
        let store = DraftMirrorStore(directory: try tempDirectory())
        let original = mirror()
        store.write(original)
        #expect(store.read() == original)
    }

    @Test func clearRemovesTheMirror() throws {
        let store = DraftMirrorStore(directory: try tempDirectory())
        store.write(mirror())
        store.clear()
        #expect(store.read() == nil)
    }

    @Test func corruptMirrorIsTreatedAsAbsentAndMovedAside() throws {
        let directory = try tempDirectory()
        let store = DraftMirrorStore(directory: directory)
        try Data("not json".utf8).write(to: store.fileURL)

        #expect(store.read() == nil)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))

        let salvaged = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(salvaged.contains { $0.hasSuffix(".corrupt") })
    }

    @Test func mirrorFromAFutureVersionIsTreatedAsAbsent() throws {
        let directory = try tempDirectory()
        let store = DraftMirrorStore(directory: directory)
        store.write(mirror())

        // Rewrite with a version this build does not understand.
        var json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: store.fileURL)) as! [String: Any]
        json["version"] = DraftMirror.currentVersion + 1
        try JSONSerialization.data(withJSONObject: json).write(to: store.fileURL)

        #expect(store.read() == nil)
    }

    @Test func writeIsAtomic() throws {
        // Overwriting must never leave a half-written file behind.
        let store = DraftMirrorStore(directory: try tempDirectory())
        store.write(mirror())
        for _ in 0..<20 { store.write(mirror()) }
        #expect(store.read() != nil)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd "ios/KataGo iOS" && xcodebuild test -project "KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime Mac" -destination 'platform=macOS' \
  -only-testing:"KataGo Anytime MacTests/DraftMirrorStoreTests" 2>&1 | tail -20
```

Expected: FAIL — `cannot find 'DraftMirrorStore' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ios/KataGo iOS/KataGo Anytime Mac/Draft/DraftMirrorStore.swift`:

```swift
//
//  DraftMirrorStore.swift
//  KataGo Anytime Mac
//

import Foundation
import OSLog

/// The crash-safe payload.
///
/// It carries the BASELINE as well as the draft, not just the draft: a
/// restored draft rests on an ancestor that may since have gone stale, and
/// without the baseline the conflict check cannot run after a restore.
struct DraftMirror: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var draft: DraftSnapshot
    var baseline: DraftSnapshot

    init(draft: DraftSnapshot, baseline: DraftSnapshot) {
        self.version = Self.currentVersion
        self.draft = draft
        self.baseline = baseline
    }
}

/// Reads and writes the single draft mirror file.
///
/// Single, not a collection: leaving a dirty game always forces Save · Discard
/// · Cancel, so at most one draft is ever open.
///
/// It lives outside SwiftData because the `@Model` schema is CloudKit-frozen —
/// drafts cannot be flagged inside the store — and because the entire point is
/// that a draft never enters the synced store.
final class DraftMirrorStore {
    private static let logger = Logger(subsystem: "KataGo Anytime", category: "DraftMirror")
    private static let fileName = "mac-draft.json"

    let fileURL: URL
    private let directory: URL

    init(directory: URL = URL.applicationSupportDirectory) {
        self.directory = directory
        self.fileURL = directory.appending(path: Self.fileName)
    }

    /// A failed write is logged and swallowed: losing the crash mirror is bad,
    /// but blocking the user's editing over a full disk is worse.
    func write(_ mirror: DraftMirror) {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(mirror)
            // Atomic so a crash mid-write cannot leave a half-file behind.
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("draft mirror write failed: \(error.localizedDescription)")
        }
    }

    /// Returns the stored mirror, or nil when there is none, it is unreadable,
    /// or it was written by a newer build. In the latter two cases the file is
    /// moved aside rather than deleted, so a bad decode never silently destroys
    /// the only copy of the user's work.
    func read() -> DraftMirror? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            let mirror = try JSONDecoder().decode(DraftMirror.self, from: data)
            guard mirror.version == DraftMirror.currentVersion else {
                Self.logger.error("draft mirror version \(mirror.version) is not readable by this build")
                moveAside()
                return nil
            }
            return mirror
        } catch {
            Self.logger.error("draft mirror unreadable: \(error.localizedDescription)")
            moveAside()
            return nil
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func moveAside() {
        let salvage = fileURL.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: salvage)
        try? FileManager.default.moveItem(at: fileURL, to: salvage)
    }
}
```

- [ ] **Step 4: Add the file to both targets**

```bash
cd "ios/KataGo iOS" && ruby -e '
require "xcodeproj"
p_ = Xcodeproj::Project.open("KataGo Anytime.xcodeproj")
app  = p_.targets.find { |t| t.name == "KataGo Anytime Mac" }
test = p_.targets.find { |t| t.name == "KataGo Anytime MacTests" }
group = p_.main_group.find_subpath("KataGo Anytime Mac/Draft", true)
ref = group.new_reference("DraftMirrorStore.swift")
app.add_file_references([ref])
test.add_file_references([ref])
p_.save
puts "added DraftMirrorStore.swift to both targets"'
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd "ios/KataGo iOS" && xcodebuild test -project "KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime Mac" -destination 'platform=macOS' \
  -only-testing:"KataGo Anytime MacTests/DraftMirrorStoreTests" 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, six tests passing.

- [ ] **Step 6: Commit**

```bash
git add "ios/KataGo iOS/KataGo Anytime Mac/Draft/DraftMirrorStore.swift" \
        "ios/KataGo iOS/KataGo Anytime MacTests/DraftMirrorStoreTests.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj"
git commit -m "$(cat <<'EOF'
feat(mac): add the crash-safe draft mirror store

The payload carries the baseline as well as the draft: a restored draft
rests on an ancestor that may have gone stale, and without it the
conflict check cannot run after a restore. Writes are atomic, and an
unreadable file is moved aside rather than deleted so a bad decode never
destroys the only copy of the user's work.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
)"
```

---

### Task 9: `DraftController`

The Mac-target owner. AppKit-adjacent, so it is not unit-tested; the pure logic it delegates to already is.

**Files:**
- Create: `ios/KataGo iOS/KataGo Anytime Mac/Draft/DraftController.swift`

**Interfaces:**
- Consumes: `GameDraft`, `DraftMirrorStore`, `DraftExitDecision`, `ModelContext`.
- Produces:
  - `final class DraftController` with `var draft: GameDraft?`, `var isDirty: Bool`, `var hasConflict: Bool`
  - `func open(origin: GameRecord) -> GameRecord` (returns the detached record to select)
  - `func openUntitled(_ record: GameRecord) -> GameRecord`
  - `func close()`
  - `func resolvedRecord(_ record: GameRecord?) -> GameRecord?` — maps a draft back to its origin
  - `func save(into: ModelContext) throws -> GameDraft.SaveOutcome?`
  - `func saveAsNewGame(into: ModelContext) throws -> GameRecord?`
  - `func noteChanged()` — recompute dirty, schedule the mirror write
  - `func decision(for: DraftExitTrigger) -> DraftExitDecision`
  - `func restore(from: DraftMirror, origin: GameRecord?) -> GameRecord`
  - `var mirrorStore: DraftMirrorStore`

- [ ] **Step 1: Write the implementation**

Create `ios/KataGo iOS/KataGo Anytime Mac/Draft/DraftController.swift`:

```swift
//
//  DraftController.swift
//  KataGo Anytime Mac
//

import Foundation
import SwiftData
import KataGoGameStore

/// Owns the single open draft and everything around it: the detached record
/// the session points at, the debounced crash mirror, and the exit rule.
///
/// The AppKit wiring (menus, sheets, window chrome) lives in
/// `MainWindowController`; this type holds no UI so the parts worth testing
/// stay in `GameDraft` / `DraftComparator` / `DraftExitDecision`, which are
/// unit-tested.
@MainActor
final class DraftController {
    private(set) var draft: GameDraft?
    let mirrorStore: DraftMirrorStore

    /// Fired whenever the dirty or conflict state may have changed, so the
    /// window controller can refresh the title, the dirty dot, and the
    /// "Changed on another device" subtitle.
    var onStateChanged: (() -> Void)?

    private var mirrorWriteTask: Task<Void, Never>?
    private static let mirrorDebounce = Duration.seconds(1)

    init(mirrorStore: DraftMirrorStore = DraftMirrorStore()) {
        self.mirrorStore = mirrorStore
    }

    var isDirty: Bool { draft?.isDirty ?? false }
    var hasConflict: Bool { draft?.hasConflict ?? false }
    var isUntitled: Bool { draft != nil && draft?.origin == nil }

    /// The name to put in the window title.
    var displayName: String? { draft?.record.name }

    // MARK: - Opening and closing

    /// Opens a draft over `origin` and returns the DETACHED record the session
    /// should select. No `loadGame` is needed at the call site: the content is
    /// identical, so the engine and board must not move — only object identity
    /// changes.
    @discardableResult
    func open(origin: GameRecord) -> GameRecord {
        let draft = GameDraft(origin: origin)
        self.draft = draft
        onStateChanged?()
        return draft.record
    }

    /// Opens a draft over a brand-new detached record that is not in the
    /// library. Unlike `open(origin:)` the caller DOES need to load the board,
    /// because the game really is different.
    @discardableResult
    func openUntitled(_ record: GameRecord) -> GameRecord {
        let draft = GameDraft(untitled: record)
        self.draft = draft
        onStateChanged?()
        return draft.record
    }

    /// Restores a draft recovered from the mirror after a crash.
    @discardableResult
    func restore(from mirror: DraftMirror, origin: GameRecord?) -> GameRecord {
        let record: GameRecord
        if let origin {
            record = origin.detachedDraftCopy()
        } else {
            record = GameRecord(config: Config())
        }
        mirror.draft.apply(to: record)

        let draft = GameDraft(record: record, origin: origin, baseline: mirror.baseline)
        self.draft = draft
        onStateChanged?()
        return record
    }

    /// Drops the draft without saving, and removes the mirror.
    func close() {
        mirrorWriteTask?.cancel()
        mirrorWriteTask = nil
        draft = nil
        mirrorStore.clear()
        onStateChanged?()
    }

    // MARK: - Identity

    /// Maps a record back to the saved object it stands for.
    ///
    /// The sidebar highlights rows by object identity, and library actions
    /// (delete, rename, share) must act on the real record. While a draft is
    /// open the selected record is the detached clone, so every such site has
    /// to resolve through here. Returns nil for an untitled draft, which has
    /// no saved counterpart and therefore no row.
    func resolvedRecord(_ record: GameRecord?) -> GameRecord? {
        guard let record, let draft, record === draft.record else { return record }
        return draft.origin
    }

    /// True when `record` is the live draft rather than a stored game.
    func isDraftRecord(_ record: GameRecord?) -> Bool {
        guard let record, let draft else { return false }
        return record === draft.record
    }

    // MARK: - Change notification

    /// Called after any mutation that could have changed the draft. Recomputes
    /// state for the window chrome and schedules a debounced mirror write.
    func noteChanged() {
        onStateChanged?()
        scheduleMirrorWrite()
    }

    private func scheduleMirrorWrite() {
        mirrorWriteTask?.cancel()
        guard let draft, draft.isDirty else {
            mirrorStore.clear()
            return
        }
        mirrorWriteTask = Task { [weak self] in
            try? await Task.sleep(for: Self.mirrorDebounce)
            guard !Task.isCancelled, let self, let draft = self.draft, draft.isDirty
            else { return }
            self.mirrorStore.write(
                DraftMirror(draft: draft.snapshot(), baseline: draft.baseline))
        }
    }

    // MARK: - Saving

    @discardableResult
    func save(into context: ModelContext) throws -> GameDraft.SaveOutcome? {
        guard let draft else { return nil }
        let outcome = try draft.save(into: context)
        mirrorWriteTask?.cancel()
        mirrorStore.clear()
        onStateChanged?()
        return outcome
    }

    @discardableResult
    func saveAsNewGame(into context: ModelContext) throws -> GameRecord? {
        guard let draft else { return nil }
        let inserted = try draft.saveAsNewGame(into: context)
        draft.rebaseline()
        mirrorWriteTask?.cancel()
        mirrorStore.clear()
        onStateChanged?()
        return inserted
    }

    // MARK: - Exits

    func decision(for trigger: DraftExitTrigger) -> DraftExitDecision {
        DraftExitDecision.decide(hasDraft: draft != nil,
                                 isDirty: isDirty,
                                 trigger: trigger)
    }
}
```

- [ ] **Step 2: Add the file to the app target only**

`DraftController` is not unit-tested, so it goes into the app target alone.

```bash
cd "ios/KataGo iOS" && ruby -e '
require "xcodeproj"
p_ = Xcodeproj::Project.open("KataGo Anytime.xcodeproj")
app = p_.targets.find { |t| t.name == "KataGo Anytime Mac" }
group = p_.main_group.find_subpath("KataGo Anytime Mac/Draft", true)
ref = group.new_reference("DraftController.swift")
app.add_file_references([ref])
p_.save
puts "added DraftController.swift to the app target"'
```

- [ ] **Step 3: Verify the app builds**

```bash
cd "ios/KataGo iOS" && xcodebuild build -project "KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime Mac" -destination 'platform=macOS' \
  -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Verify the existing tests still pass**

```bash
cd "ios/KataGo iOS" && xcodebuild test -project "KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime Mac" -destination 'platform=macOS' \
  -only-testing:"KataGo Anytime MacTests" 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add "ios/KataGo iOS/KataGo Anytime Mac/Draft/DraftController.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj"
git commit -m "$(cat <<'EOF'
feat(mac): add DraftController to own the single open draft

Holds no UI: the AppKit wiring lands in MainWindowController so the
parts worth testing stay in GameDraft, DraftComparator and
DraftExitDecision, which are unit-tested. resolvedRecord is the seam
every identity-sensitive library site goes through.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
)"
```

---

### Task 10: Open and close the draft on the `isEditing` edge

**Files:**
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/MainWindowController.swift` (property block near `:1508`; `handleAutoPlayChange` at `:1520-1548`)
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/LibrarySidebarViewController.swift:142,231,274`

**Interfaces:**
- Consumes: `DraftController.open(origin:)`, `.close()`, `.resolvedRecord(_:)`, `.noteChanged()`.
- Produces: `MainWindowController.draftController: DraftController`, and a sidebar that keeps highlighting the origin row while a draft is open.

- [ ] **Step 1: Add the controller property**

In `MainWindowController.swift`, next to `private var lastIsEditing = false`, add:

```swift
    /// Owns the unsaved editing session. While a draft is open,
    /// `navigationContext.selectedGameRecord` is the draft's DETACHED record
    /// rather than a stored game, which is what keeps every existing write
    /// path from reaching SwiftData or iCloud.
    let draftController = DraftController()
```

- [ ] **Step 2: Open and close the draft on the `isEditing` edge**

In `handleAutoPlayChange()`, replace this block:

```swift
        if !gobanState.isEditing && lastIsEditing {
            gobanState.isAutoPlaying = false
            gobanState.clearAutoPlayStep()
        }
```

with:

```swift
        if !gobanState.isEditing && lastIsEditing {
            gobanState.isAutoPlaying = false
            gobanState.clearAutoPlayStep()
        }

        // Draft lifecycle rides the same edge. Unlocking opens a draft over the
        // selected game and re-points the session at the DETACHED clone; from
        // here every existing write path writes into the clone instead of the
        // stored record. No `loadGame`: the content is identical, so the engine
        // and board must not move — only object identity changes.
        //
        // The lock direction only reaches here for a CLEAN draft; a dirty one is
        // intercepted by `resolve(then:)` before `isEditing` is ever flipped.
        if gobanState.isEditing && !lastIsEditing, draftController.draft == nil,
           let origin = navigationContext.selectedGameRecord {
            navigationContext.selectedGameRecord = draftController.open(origin: origin)
            refreshDraftChrome()
        } else if !gobanState.isEditing && lastIsEditing, draftController.draft != nil {
            let origin = draftController.resolvedRecord(navigationContext.selectedGameRecord)
            draftController.close()
            navigationContext.selectedGameRecord = origin
            refreshDraftChrome()
        }
```

- [ ] **Step 3: Feed change notifications to the draft controller**

At the end of `handleStonesReadyChange()`, immediately before the closing brace, add:

```swift
        // Every played move, undo and analysis update lands here, so this is
        // the one place that has to tell the draft its content may have moved.
        draftController.noteChanged()
```

- [ ] **Step 4: Add the chrome refresh stub**

Add near `refreshLockSlotToolbarItem()`:

```swift
    /// Window title and dirty dot. Filled in by the Save/Revert task; defined
    /// here so the draft lifecycle above has something to call.
    func refreshDraftChrome() {
        window?.isDocumentEdited = draftController.isDirty
    }
```

- [ ] **Step 5: Resolve draft identity in the sidebar**

The sidebar's only back-reference is `weak var actionsDelegate: LibraryActionsDelegate?`
(`LibrarySidebarViewController.swift:38`), so the resolution goes through that
protocol rather than a concrete window-controller reference.

Add to the `LibraryActionsDelegate` protocol declaration:

```swift
    /// Maps a possibly-draft record back to the saved game it stands for.
    /// Returns nil for an untitled draft, which has no library row.
    func resolvedStoredRecord(_ record: GameRecord?) -> GameRecord?
```

`MainWindowController` already conforms; implement it in the `LibraryActions.swift`
extension:

```swift
    func resolvedStoredRecord(_ record: GameRecord?) -> GameRecord? {
        draftController.resolvedRecord(record)
    }
```

Then in `LibrarySidebarViewController.swift`, the three identity comparisons must
compare against the ORIGIN or the highlight is lost the moment a draft opens.
Add a helper near the top of the class:

```swift
    /// While a draft is open the selected record is a detached clone that is
    /// not in `store.games`, so comparisons must resolve back to the saved
    /// game the draft stands for.
    private var selectedStoredGame: GameRecord? {
        actionsDelegate?.resolvedStoredRecord(navigationContext.selectedGameRecord)
            ?? navigationContext.selectedGameRecord
    }
```

Then replace at line 142:

```swift
        let targetRow = store.games.firstIndex { $0 === selectedStoredGame }
```

at line 231:

```swift
            return game === selectedStoredGame
```

and at line 274:

```swift
        guard selected !== selectedStoredGame else { return }
```

- [ ] **Step 6: Build**

```bash
cd "ios/KataGo iOS" && xcodebuild build -project "KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime Mac" -destination 'platform=macOS' \
  -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Interactive check**

Launch a **signed** Debug build (an unsigned one crashes at CloudKit setup). Select a saved game, press ⌘E to unlock, click an empty board point, and confirm:
- a stone appears and analysis continues normally,
- the sidebar row stays highlighted on the same game,
- the row's **Modified** date does **not** change.

- [ ] **Step 8: Commit**

```bash
git add "ios/KataGo iOS/KataGo Anytime Mac/MainWindowController.swift" \
        "ios/KataGo iOS/KataGo Anytime Mac/LibrarySidebarViewController.swift"
git commit -m "$(cat <<'EOF'
feat(mac): route unlocked edits into a detached draft record

Unlocking now re-points the session at a detached clone, so every
existing write path writes there instead of into the stored game. No
loadGame runs on open: the content is identical, so only object
identity changes. The sidebar resolves draft to origin to keep the
right row highlighted.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
)"
```

---

### Task 11: Save, Revert, window title and the dirty dot

**Files:**
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/AppDelegate.swift` (`fileMenu()` at `:188-226`)
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/MainWindowController.swift` (`refreshDraftChrome`, `validateMenuItem` at `:3104`)

**Interfaces:**
- Consumes: `DraftController.save(into:)`, `.close()`, `.isDirty`, `.displayName`.
- Produces: `MainWindowController.saveGame(_:)`, `.revertGame(_:)`.

- [ ] **Step 1: Widen `load(game:previous:)` so other files can call it**

`MainWindowController.swift:625` declares it `private`, which in Swift is
file-scoped — the `LibraryActions.swift` call sites added in this task and in
Task 13 would not compile. Drop the modifier:

```swift
    func load(game: GameRecord?, previous: GameRecord?) {
```

- [ ] **Step 2: Add the menu items**

In `AppDelegate.fileMenu()`, after the `Import…` item and before the first separator, add:

```swift
        menu.addItem(.separator())
        // File ▸ Save (⌘S): commits the open draft to SwiftData, from where it
        // syncs to iCloud. Until this runs, an unlocked game's edits exist only
        // in a detached record and a local mirror file.
        menu.addItem(withTitle: "Save",
                     action: #selector(MainWindowController.saveGame(_:)),
                     keyEquivalent: "s")
        // Throws the draft away and reloads the saved game. No key equivalent:
        // it is destructive and infrequent.
        menu.addItem(withTitle: "Revert to Saved",
                     action: #selector(MainWindowController.revertGame(_:)),
                     keyEquivalent: "")
```

- [ ] **Step 3: Implement the actions**

In `MainWindowController.swift`, near `toggleEditing(_:)`, add:

```swift
    // MARK: - Draft save / revert

    /// File ▸ Save (⌘S). Writes the draft through to the store: onto the
    /// origin when there is one, otherwise as a newly inserted record. The
    /// draft object stays live and selected afterwards, so saving never churns
    /// object identity or reloads the board.
    @objc func saveGame(_ sender: Any?) {
        guard draftController.draft != nil else { return }

        if draftController.hasConflict {
            presentConflictAlert()
            return
        }

        commitDraft()
    }

    /// The unconditional half of Save, shared with the exit sheet and the
    /// conflict sheet's Overwrite button.
    ///
    /// No selection change is needed after an insert: the draft object stays
    /// live and `draft.origin` now points at the newly inserted record, so
    /// `resolvedRecord` maps the selection onto the new sidebar row by itself.
    func commitDraft() {
        do {
            guard try draftController.save(into: modelContainer.mainContext) != nil
            else { return }
            libraryStore.refetch()
            WidgetCenter.shared.reloadAllTimelines()
            refreshDraftChrome()
        } catch {
            presentSaveFailureAlert(error)
        }
    }

    /// File ▸ Revert to Saved. Drops the draft and reloads the saved game so
    /// the engine and board resync — the same path a game switch takes.
    @objc func revertGame(_ sender: Any?) {
        guard draftController.draft != nil else { return }
        discardDraftAndReload()
    }

    /// Shared by Revert and the exit sheet's Discard button.
    func discardDraftAndReload() {
        let previous = navigationContext.selectedGameRecord
        let origin = draftController.resolvedRecord(previous)
        draftController.close()
        session.gobanState.isEditing = false

        if let origin {
            navigationContext.selectedGameRecord = origin
            load(game: origin, previous: previous)
        } else {
            // An untitled draft has no saved counterpart: fall back to the
            // most-recent game, or the empty state.
            let fetched = (try? GameRecord.fetchGameRecords(container: modelContainer)) ?? []
            let target = fetched.first
            navigationContext.selectedGameRecord = target
            load(game: target, previous: previous)
        }
        libraryStore.refetch()
        refreshDraftChrome()
    }

    private func presentSaveFailureAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not save this game."
        // The draft is deliberately left open and dirty: nothing is discarded
        // on a failed save.
        alert.informativeText = "\(error.localizedDescription)\n\nYour changes are still here and unsaved."
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window) }
    }
```

- [ ] **Step 4: Fill in the chrome refresh**

Replace the `refreshDraftChrome()` stub from Task 10 with:

```swift
    /// Window title, dirty dot and conflict subtitle.
    ///
    /// The title was a static "KataGo Anytime", which left an untitled game
    /// with nothing on screen naming it — it has no sidebar row either.
    func refreshDraftChrome() {
        let name = draftController.displayName
            ?? navigationContext.selectedGameRecord?.name
        window?.title = name ?? "KataGo Anytime"
        window?.subtitle = draftController.hasConflict ? "Changed on another device" : ""
        window?.isDocumentEdited = draftController.isDirty
    }
```

- [ ] **Step 5: Gate the menu items**

In `validateMenuItem(_:)`, add before `default:`:

```swift
        // File ▸ Save / Revert to Saved: only meaningful with unsaved changes.
        case #selector(saveGame(_:)), #selector(revertGame(_:)):
            return draftController.isDirty
```

- [ ] **Step 6: Build**

```bash
cd "ios/KataGo iOS" && xcodebuild build -project "KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime Mac" -destination 'platform=macOS' \
  -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
```

Expected: `** BUILD SUCCEEDED **`

`presentConflictAlert()` is written in full by Task 14. So that this task builds
and behaves correctly on its own, add this beside `presentSaveFailureAlert` —
it is today's behavior (last-writer-wins), which Task 14 then replaces with the
three-choice sheet:

```swift
    /// Replaced by the real conflict sheet in the conflict-handling task. Until
    /// then this is the pre-existing last-writer-wins behavior, so Save is never
    /// a no-op while the feature is half-landed.
    func presentConflictAlert() { commitDraft() }
```

- [ ] **Step 7: Interactive check**

Signed Debug build. Unlock a game, play a move, and confirm:
- the window title shows the game's name,
- a dot appears in the close button,
- File ▸ Save is enabled and ⌘S clears the dot,
- the sidebar's Modified date updates only after ⌘S.

- [ ] **Step 8: Commit**

```bash
git add "ios/KataGo iOS/KataGo Anytime Mac/AppDelegate.swift" \
        "ios/KataGo iOS/KataGo Anytime Mac/MainWindowController.swift"
git commit -m "$(cat <<'EOF'
feat(mac): add File > Save and Revert to Saved for drafts

Also gives the window real document chrome: the title was a static
"KataGo Anytime", which left an untitled game with nothing naming it,
since it has no sidebar row either. A failed save leaves the draft open
and dirty rather than discarding it.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
)"
```

---

### Task 12: The exit chokepoint

**Files:**
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/MainWindowController.swift` (`selectGame(_:)` at `:583`, `applyPendingSelection` at `:658`, `toggleEditing` at `:2570`, `NSWindowDelegate` extension at `:3024`)
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/AppDelegate.swift`
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/LibraryActions.swift` (`deleteSelectedGame` at `:383`)

**Interfaces:**
- Consumes: `DraftController.decision(for:)`.
- Produces: `MainWindowController.resolveDraft(for:then:)`, `MainWindowController.hasUnresolvedDraft`.

- [ ] **Step 1: Add the chokepoint**

In `MainWindowController.swift`, near the draft save/revert actions, add:

```swift
    // MARK: - Draft exit chokepoint

    /// Every way of leaving the game being edited goes through here.
    ///
    /// Clean (or no draft) runs `continuation` straight through. Dirty presents
    /// Save · Discard · Cancel, and Cancel abandons the continuation entirely —
    /// the caller must NOT have performed any part of the exit before calling.
    func resolveDraft(for trigger: DraftExitTrigger,
                      then continuation: @escaping () -> Void) {
        guard draftController.decision(for: trigger) == .prompt else {
            continuation()
            return
        }
        guard let window else {
            continuation()
            return
        }

        let name = draftController.displayName ?? "this game"
        let alert = NSAlert()
        alert.messageText = "Save changes to \(name)?"
        alert.informativeText = "Your changes have not been saved to iCloud yet. If you don't save them, they will be lost."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.commitDraft()
                self.draftController.close()
                continuation()
            case .alertSecondButtonReturn:
                self.draftController.close()
                continuation()
            default:
                break   // Cancel: the continuation is abandoned.
            }
        }
    }

    /// True while a dirty draft is waiting on the user.
    var hasUnresolvedDraft: Bool { draftController.isDirty }
```

- [ ] **Step 2: Route the game switch**

Rename the existing `selectGame(_:)` body into `performSelectGame(_:)` and add a
new gated entry point:

```swift
    /// Public entry: every sidebar click, deep link and drain lands here, so
    /// this is where an unsaved draft is resolved before the board moves on.
    func selectGame(_ game: GameRecord?) {
        // Re-selecting the game the draft stands for is not an exit.
        if let game, draftController.resolvedRecord(
            navigationContext.selectedGameRecord) === game {
            return
        }
        resolveDraft(for: .switchGame) { [weak self] in
            self?.performSelectGame(game)
        }
    }
```

In `applyPendingSelection()`, replace `navigationContext.selectedGameRecord = target` / `load(...)` with a call to `performSelectGame(target)` guarded the same way:

```swift
        resolveDraft(for: .switchGame) { [weak self] in
            guard let self else { return }
            self.navigationContext.selectedGameRecord = target
            self.load(game: target, previous: nil)
        }
```

- [ ] **Step 3: Route the lock toggle**

Replace `toggleEditing(_:)`'s body:

```swift
    @objc func toggleEditing(_ sender: Any?) {
        let gobanState = session.gobanState
        // Locking with unsaved changes is an exit: resolve before the flag
        // flips, or the draft-close branch in `handleAutoPlayChange` would
        // silently drop them.
        if gobanState.isEditing {
            resolveDraft(for: .lock) { [weak self] in
                self?.session.gobanState.isEditing = false
            }
        } else {
            gobanState.isEditing = true
        }
    }
```

- [ ] **Step 4: Route window close**

In the `NSWindowDelegate` extension, add:

```swift
    /// Blocks the close while a dirty draft is open, re-issuing it once the
    /// user answers. `performClose` rather than `close` so the delegate chain
    /// runs again from a now-clean state.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard hasUnresolvedDraft else { return true }
        resolveDraft(for: .closeWindow) { [weak self] in
            self?.window?.performClose(nil)
        }
        return false
    }
```

- [ ] **Step 5: Route quit**

In `AppDelegate.swift`, add:

```swift
    /// ⌘Q with unsaved changes: defer termination until the sheet is answered.
    /// `.terminateLater` keeps the app alive; the reply resumes or aborts it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let wc = windowController, wc.hasUnresolvedDraft else { return .terminateNow }
        wc.resolveDraft(for: .quit) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
```

- [ ] **Step 6: Route delete**

In `LibraryActions.swift`, replace `deleteSelectedGame(_:)`:

```swift
    /// Edit ▸ Delete (⌫): delete the currently-selected library game. Resolves
    /// an unsaved draft first — deleting the record a draft is editing would
    /// otherwise strand the draft on a tombstone.
    @objc func deleteSelectedGame(_ sender: Any?) {
        guard let game = draftController.resolvedRecord(
            navigationContext.selectedGameRecord) else { return }
        resolveDraft(for: .deleteOrigin) { [weak self] in
            self?.deleteGame(game)
        }
    }
```

**Leave `renameSelectedGame(_:)` and `shareSelectedGame(_:)` untouched.** Delete is
the only one that must resolve, because you cannot delete a detached object.
The other two correctly operate on what is on screen:

- **Rename** — `name` is a drafted field and a name change is one of the four
  things that makes a draft dirty. Renaming the origin directly would bypass
  the draft and sync to iCloud immediately, which is the exact bug this feature
  removes.
- **Share** — exports the SGF the user is looking at, which is the draft.

- [ ] **Step 7: Build**

```bash
cd "ios/KataGo iOS" && xcodebuild build -project "KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime Mac" -destination 'platform=macOS' \
  -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 8: Interactive check**

Signed Debug build. With a dirty draft, confirm each of these prompts and that **Cancel** leaves you exactly where you were:
- clicking a different game in the sidebar,
- ⌘E to lock,
- closing the window,
- ⌘Q,
- Edit ▸ Delete.

- [ ] **Step 9: Commit**

```bash
git add "ios/KataGo iOS/KataGo Anytime Mac/MainWindowController.swift" \
        "ios/KataGo iOS/KataGo Anytime Mac/AppDelegate.swift" \
        "ios/KataGo iOS/KataGo Anytime Mac/LibraryActions.swift"
git commit -m "$(cat <<'EOF'
feat(mac): funnel every draft exit through one Save/Discard/Cancel gate

Switching games, locking, closing the window, quitting and deleting the
edited game all resolve through resolveDraft(for:then:), so Cancel
genuinely leaves the user where they were. Rename and Share now act on
the saved record rather than the draft clone.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
)"
```

---

### Task 13: ⌘N creates an untitled game with no library row

**Files:**
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/LibraryActions.swift` (`newGame(_:)` at `:36-47`)

**Interfaces:**
- Consumes: `DraftController.openUntitled(_:)`, `GameRecord.createGameRecord(sgf:name:)`.
- Produces: no new API.

- [ ] **Step 1: Replace `newGame(_:)`**

```swift
    /// File ▸ New Game (⌘N) and the toolbar `New` item.
    ///
    /// The sheet still runs first, because board size, komi and rules must be
    /// fixed before a first move can exist — so the unsaved game already
    /// carries the name the user typed and Save needs no naming dialog.
    ///
    /// Unlike before, the record is NOT inserted: a new game has no library row
    /// until it is saved. Any unsaved draft is resolved first.
    @objc func newGame(_ sender: Any?) {
        resolveDraft(for: .switchGame) { [weak self] in
            guard let self else { return }
            let dialog = NewGameViewController(maxBoardLength: self.launchedMaxBoardLength) {
                [weak self] sgf, name in
                guard let self else { return }
                let previous = self.navigationContext.selectedGameRecord
                let untitled = GameRecord.createGameRecord(sgf: sgf, name: name)
                let record = self.draftController.openUntitled(untitled)
                self.navigationContext.selectedGameRecord = record
                // The board really does change here, so unlike unlocking an
                // existing game this DOES need a load.
                self.load(game: record, previous: previous)
                self.session.gobanState.isEditing = true
                self.libraryStore.refetch()
                self.refreshDraftChrome()
            }
            self.contentViewController?.presentAsSheet(dialog)
        }
    }
```

- [ ] **Step 2: Build**

```bash
cd "ios/KataGo iOS" && xcodebuild build -project "KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime Mac" -destination 'platform=macOS' \
  -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Interactive check**

Signed Debug build:
- ⌘N, fill the sheet, Create → the board appears, the window title shows the typed name, **no new sidebar row**.
- Play one move → the dirty dot appears.
- ⌘S → the row appears in the sidebar and the dot clears.
- ⌘N again, Create, then ⌘Q without playing → quits with **no** prompt (an empty untitled game is clean).

- [ ] **Step 4: Commit**

```bash
git add "ios/KataGo iOS/KataGo Anytime Mac/LibraryActions.swift"
git commit -m "$(cat <<'EOF'
feat(mac): keep a new game out of the library until it is saved

The New Game sheet still runs first, because board size, komi and rules
must be fixed before a first move exists - so the unsaved game already
carries its name and Save needs no naming dialog. An empty untitled
game counts as clean, so abandoning a New Game never prompts.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
)"
```

---

### Task 14: Conflict detection and the conflict sheet

**Files:**
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/MainWindowController.swift` (replace the `presentConflictAlert()` stub from Task 11)
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/LibraryStore.swift:60` (remote-change observer)

**Interfaces:**
- Consumes: `DraftController.hasConflict`, `.saveAsNewGame(into:)`, `GameDraft.moveCount`.
- Produces: `MainWindowController.presentConflictAlert()`.

- [ ] **Step 1: Replace the stub with the real sheet**

```swift
    /// Save found the saved game changed underneath the draft — another
    /// device's CloudKit import landed after the draft opened.
    ///
    /// Save as New Game is the default because nothing is lost either way:
    /// the draft becomes its own record and the incoming version stays intact.
    /// Discarding the user's own side is already File ▸ Revert to Saved, so it
    /// is named in the body rather than given a button.
    func presentConflictAlert() {
        guard let window, let draft = draftController.draft, let origin = draft.origin
        else { return }

        let theirMoves = SgfHeaderScan(sgf: origin.sgf)?.moveCount ?? 0
        let mine = draft.moveCount

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        let changedAt = origin.lastModificationDate.map { formatter.string(from: $0) }
            ?? "another device"

        let alert = NSAlert()
        alert.messageText = "\"\(draft.record.name)\" was changed on another device."
        alert.informativeText = """
            The saved game now has \(theirMoves) moves; yours has \(mine). \
            It was last changed \(changedAt).

            To keep the other version instead, cancel and choose File > \
            Revert to Saved.
            """
        alert.addButton(withTitle: "Save as New Game")
        alert.addButton(withTitle: "Overwrite")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                do {
                    _ = try self.draftController.saveAsNewGame(into: self.modelContainer.mainContext)
                    self.libraryStore.refetch()
                    WidgetCenter.shared.reloadAllTimelines()
                    self.refreshDraftChrome()
                } catch {
                    self.presentSaveFailureAlert(error)
                }
            case .alertSecondButtonReturn:
                self.commitDraft()
            default:
                break   // Cancel: the draft stays open and dirty.
            }
        }
    }
```

Add `import KataGoAnalysisKit` at the top of `MainWindowController.swift` if it is not already there.

Also change `presentSaveFailureAlert` from `private` to internal so the sheet above can call it.

- [ ] **Step 2: Detect conflicts live**

In `LibraryStore.swift`, the `.NSPersistentStoreRemoteChange` observer already
coalesces CloudKit bursts on the main queue. Add a hook so the window
controller can re-evaluate:

```swift
    /// Called after a coalesced remote-change refetch, so the window controller
    /// can re-check whether the game being edited was changed elsewhere.
    var onRemoteChange: (() -> Void)?
```

and call `onRemoteChange?()` at the end of the coalesced refetch handler.

In `MainWindowController`, where `libraryStore` is created, add:

```swift
        libraryStore.onRemoteChange = { [weak self] in
            // Surfaces as the window subtitle, so a conflict never ambushes
            // the user at Save time.
            self?.refreshDraftChrome()
        }
```

- [ ] **Step 3: Build**

```bash
cd "ios/KataGo iOS" && xcodebuild build -project "KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime Mac" -destination 'platform=macOS' \
  -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Interactive check**

With two devices (or the iOS Simulator signed into the same iCloud account):
unlock a game on the Mac and play a move; on the other device add a move to the
same game and let it sync. Confirm the Mac window subtitle reads "Changed on
another device", and that ⌘S offers Save as New Game · Overwrite · Cancel, with
correct move counts on both sides.

- [ ] **Step 5: Commit**

```bash
git add "ios/KataGo iOS/KataGo Anytime Mac/MainWindowController.swift" \
        "ios/KataGo iOS/KataGo Anytime Mac/LibraryStore.swift"
git commit -m "$(cat <<'EOF'
feat(mac): detect and resolve draft conflicts instead of overwriting

The baseline taken when a draft opens is the common ancestor, so the
same comparator that reports dirty also reports that another device
changed the saved game. Detection is live off the existing coalesced
remote-change observer, surfaced as the window subtitle, so Save is
never an ambush. Save as New Game is the default: nothing is lost
either way.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
)"
```

---

### Task 15: Crash restore on launch

**Files:**
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/MainWindowController.swift` (`restoreWindowStateOnLaunch` at `:378`, or the engine-ready drain)

**Interfaces:**
- Consumes: `DraftMirrorStore.read()`, `DraftController.restore(from:origin:)`.
- Produces: `MainWindowController.offerDraftRestoreIfNeeded()`.

- [ ] **Step 1: Add the restore offer**

```swift
    /// If a mirror file survived a crash or force-quit, offer to restore it.
    ///
    /// Restore is always a conscious choice, never automatic: a stale draft
    /// silently reattaching itself to a saved game is exactly the class of
    /// surprise this whole feature exists to remove.
    ///
    /// Called once the engine is ready, because Restore selects a game and
    /// that drives GTP.
    func offerDraftRestoreIfNeeded() {
        guard draftController.draft == nil,
              let mirror = draftController.mirrorStore.read(),
              let window else { return }

        let name = mirror.draft.game.name
        let alert = NSAlert()
        alert.messageText = "KataGo Anytime has unsaved changes to \"\(name)\"."
        alert.informativeText = "These changes were never saved to iCloud. Restore them, or discard them and open the saved game."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Discard")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else {
                self.draftController.mirrorStore.clear()
                return
            }

            // The origin may have been deleted, or synced away, while the app
            // was gone; restoring untitled keeps the work either way.
            let origin = mirror.draft.originUUID.flatMap {
                GameRecord.resolveDeepLinkTarget(id: $0, container: self.modelContainer)
            }
            let previous = self.navigationContext.selectedGameRecord
            let record = self.draftController.restore(from: mirror, origin: origin)
            self.navigationContext.selectedGameRecord = record
            self.load(game: record, previous: previous)
            self.session.gobanState.isEditing = true
            self.refreshDraftChrome()
        }
    }
```

- [ ] **Step 2: Call it once the engine is ready**

At the end of `applyPendingSelection()`, after the selection drain, add:

```swift
        offerDraftRestoreIfNeeded()
```

`applyPendingSelection` runs on every engine-ready edge, including each engine
relaunch after a model switch, so this is called more than once per session.
That is safe by construction: the `draftController.draft == nil` guard stops a
second offer while a draft is open, and both sheet buttons clear the mirror, so
a resolved offer never returns.

- [ ] **Step 3: Build**

```bash
cd "ios/KataGo iOS" && xcodebuild build -project "KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime Mac" -destination 'platform=macOS' \
  -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Interactive check**

Signed Debug build. Unlock a game, play two moves, wait ~2 s (past the debounce),
then:

```bash
pkill -9 -f "KataGo Anytime Mac"
ls -l ~/Library/Application\ Support/mac-draft.json
```

Relaunch and confirm the Restore sheet names the game, that **Restore** brings
back both moves with the dirty dot set, and that **Discard** opens the saved
game and deletes the mirror file.

- [ ] **Step 5: Commit**

```bash
git add "ios/KataGo iOS/KataGo Anytime Mac/MainWindowController.swift"
git commit -m "$(cat <<'EOF'
feat(mac): offer to restore an unsaved draft after a crash

Restore is a conscious choice rather than automatic: a stale draft
silently reattaching itself to a saved game is the class of surprise
this feature exists to remove. If the origin vanished while the app was
gone, the draft restores untitled so the work survives either way.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
)"
```

---

### Task 16: Branch/draft mutual exclusion, docs, and the full sweep

**Files:**
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/MainWindowController.swift` (`validateMenuItem`, `toggleEditing` case at `:3121`)
- Modify: `ios/KataGo iOS/README.md`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing new.

- [ ] **Step 1: Disable Allow Editing while a branch is active**

Branches form only while locked, so the toolbar cannot produce both — but ⌘E
can, which would leave two independent uncommitted lines with two different
commit paths. In `validateMenuItem`, replace the `toggleEditing` case:

```swift
        // Game menu "Allow Editing": checkmark reflects the live `isEditing`
        // (true == unlocked), enabled when a game is selected.
        //
        // Disabled while a branch is active. A branch and a draft are both
        // uncommitted lines with different commit paths (Replace/Discard vs
        // Save/Revert), and unlocking on top of a branch would leave both live
        // at once. Deactivate Branch first, as the toolbar already forces.
        case #selector(toggleEditing(_:)):
            menuItem.state = gobanState.isEditing ? .on : .off
            return hasGame && !gobanState.isBranchActive
```

- [ ] **Step 2: Update the README**

In the macOS section, alongside the existing "Allow Editing ⌘E" entry, add:

```markdown
- **Save** ⌘S — commit the game you are editing to iCloud. While a game is
  unlocked its changes are unsaved: they live in memory and in a local
  recovery file, and never reach iCloud until you save.
- **Revert to Saved** — throw away unsaved changes and reload the saved game.

A new game (⌘N) has no library row until you save it. Switching games,
closing the window or quitting with unsaved changes asks first.
```

- [ ] **Step 3: Run the full Mac test suite**

```bash
cd "ios/KataGo iOS" && xcodebuild test -project "KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime Mac" -destination 'platform=macOS' \
  -only-testing:"KataGo Anytime MacTests" 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 4: Prove the other platforms did not move**

No file under `KataGoUICore/` was modified, so this should be a formality —
verify that first, then run the iOS suite.

```bash
cd /Users/chinchangyang/Code/KataGo-ios-dev && \
  git diff --name-only master...HEAD -- "ios/KataGo iOS/KataGoUICore/" | head
```

Expected: **no output**. If anything is listed, stop and justify it.

```bash
cd "ios/KataGo iOS" && xcodebuild test -project "KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' \
  2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **` (the existing suite, all green).

- [ ] **Step 5: Build every other platform**

Run these **one at a time** — concurrent `xcodebuild` invocations produce
spurious failures from the DerivedData lock.

```bash
cd "ios/KataGo iOS"
for s in "KataGo Anytime Vision:platform=visionOS Simulator,name=Apple Vision Pro" \
         "KataGo Anytime TV:platform=tvOS Simulator,name=Apple TV" \
         "KataGo Anytime Watch:platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)"; do
  scheme="${s%%:*}"; dest="${s#*:}"
  echo "=== $scheme ==="
  xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "$scheme" \
    -destination "$dest" 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
done
```

Expected: `** BUILD SUCCEEDED **` three times.

- [ ] **Step 6: Interactive QA — the scenario that started this**

Signed Debug build:

1. Open a saved game with a known move count and note its **Modified** date.
2. ⌘E to unlock.
3. Click an empty board point — a stone lands.
4. **Confirm the sidebar's Modified date has NOT changed.**
5. File ▸ Revert to Saved.
6. Confirm the game is back to its original move count and the date is untouched.

Then repeat step 3 and use ⌘S instead: the move persists and the date updates.

- [ ] **Step 7: Scan the whole diff for policy violations**

```bash
cd /Users/chinchangyang/Code/KataGo-ios-dev && \
  git diff master...HEAD | LC_ALL=C grep -nP '[\x{4E00}-\x{9FFF}\x{3000}-\x{303F}\x{FF00}-\x{FFEF}]' | head
```

Expected: no output (no CJK anywhere in the diff).

```bash
git diff master...HEAD | grep -niE 'gmail|taiwan|taipei' | head
```

Expected: no output.

- [ ] **Step 8: Commit**

```bash
git add "ios/KataGo iOS/KataGo Anytime Mac/MainWindowController.swift" \
        "ios/KataGo iOS/README.md"
git commit -m "$(cat <<'EOF'
fix(mac): stop a branch and a draft being open at the same time

Branches form only while locked, so the toolbar cannot produce both -
but the Allow Editing menu item could, leaving two uncommitted lines
with two different commit paths live at once. Deactivate Branch first,
as the toolbar already forces.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
)"
```

---

## Notes for the implementer

**The single most important invariant.** The draft's `GameRecord` must never be
passed to `modelContext.insert(_:)` while it is the live draft. `GameDraft.save`
inserts a *copy*, never `record` itself. If you find yourself inserting the
draft, stop — that silently restores the old auto-save behavior and every test
here will still pass.

**Why no `loadGame` when a draft opens.** The clone's content is identical to
the origin's, so the engine's board already matches. Calling `loadGame` would
send `loadsgf` and rebuild the position for no reason, visibly flickering the
board on every ⌘E. `openUntitled` is the exception: the game really is
different there.

**Cancel must be genuinely free.** `resolveDraft(for:then:)` runs the exit as a
continuation precisely so that Cancel can abandon it. Never perform part of an
exit before calling it — for example, never set `selectedGameRecord` and then
ask.

**Known deferrals.** `ensureSelectedGameRecord` still auto-creates and inserts a
real record when the library is empty at launch; that boot path is deliberately
untouched. It then loads unlocked, opening a clean draft, which is consistent.
