# Saved Game Widget — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a configurable WidgetKit widget (iOS, macOS, visionOS) that shows a saved game's name, its first-position comment, and a board thumbnail, and opens that game when tapped.

**Architecture:** Extract a bridge-free `KataGoGameStore` SwiftPM target holding the `GameRecord`/`Config` `@Model` types, a shared App-Group `ModelContainer`, the configuration `AppEntity`/`EntityQuery`, and a light board renderer. The widget extension links only that target (never the C++ bridge/MLX). The app and widget share one SwiftData/CloudKit store via an App Group; the widget reads it for its timeline.

**Tech Stack:** Swift 6.2, SwiftData (+CloudKit), WidgetKit, AppIntents, SwiftUI, Swift Testing, Xcodeproj Ruby gem.

## Global Constraints

- Platforms: iOS 26, macOS 26, visionOS 26. Two app schemes: `KataGo Anytime` (iOS/visionOS), `KataGo Anytime Mac` (macOS).
- `DEVELOPMENT_TEAM = 6F82AZ9Z52`. Both apps share `PRODUCT_BUNDLE_IDENTIFIER = chinchangyang.KataGo-iOS.tw`.
- App Group identifier: `group.chinchangyang.KataGo-iOS.tw` (used by iOS app, macOS app, and widget).
- CloudKit container: `iCloud.chinchangyang.KataGo-iOS.tw`.
- Widget extension bundle id: `chinchangyang.KataGo-iOS.tw.widget`.
- Deep-link URL scheme: `katago-anytime` (form: `katago-anytime://open-game?id=<uuid>`).
- Tests use **Swift Testing** (`import Testing`, `@Test`, `struct` suites), not XCTest. App test module is `KataGo_Anytime`; tests live in the `KataGo AnytimeTests` target (runs in the default FastTestPlan).
- **NEVER** rename the `@Model` classes `GameRecord`/`Config` or change/remove/reorder their stored properties, defaults, or `@Relationship` attributes (CloudKit schema corruption risk). Only methods/computed-properties may move.
- Xcode project edits are done via Ruby scripts using the `xcodeproj` gem (pattern: `ios/KataGo iOS/add_engine_helper_target.rb`). Run scripts from `ios/KataGo iOS/`.
- Commit after every task. Do **not** `git push` (Xcode Cloud free-tier rate limit) — pushing is the user's call.
- Build/test commands run from `ios/KataGo iOS/`:
  - iOS build: `xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug`
  - visionOS build: `xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug`
  - macOS build: `xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS' -configuration Debug`
  - Tests: `xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17'`

---

## File Structure

**New files**
- `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/GameRecord.swift` — `@Model GameRecord` body + pure helpers (moved).
- `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/ConfigModel.swift` — `@Model Config` (moved).
- `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/SharedModelContainer.swift` — App-Group container + store migration.
- `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/GameEntity.swift` — `GameEntity` + `GameEntityQuery` (moved & extended).
- `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WidgetBoardView.swift` — light SwiftUI board renderer.
- `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/GameDeepLink.swift` — URL build/parse helpers.
- `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/GameStoreReexport.swift` — `@_exported import KataGoGameStore`.
- `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/GameRecord+SGF.swift` — bridge-using `GameRecord` methods (moved).
- `ios/KataGo iOS/KataGoAnytimeWidget/` — widget extension: `KataGoAnytimeWidgetBundle.swift`, `SavedGameWidget.swift`, `SelectGameIntent.swift`, `SavedGameProvider.swift`, `SavedGameWidgetView.swift`, `Info.plist`, `KataGoAnytimeWidget.entitlements`.
- `ios/KataGo iOS/add_widget_extension_target.rb` — creates/links/embeds the widget target.
- Tests in `ios/KataGo iOS/KataGo iOSTests/`: `SharedModelContainerTests.swift`, `GameEntityQueryTests.swift`, `SavedGameProviderTests.swift`, `GameDeepLinkTests.swift`, `WidgetBoardViewTests.swift`.

**Modified files**
- `ios/KataGo iOS/KataGoUICore/Package.swift` — add `KataGoGameStore` target+product; add it to `KataGoUICore` deps.
- `ios/KataGo iOS/KataGo iOS/App/KataGo_iOSApp.swift` — use `SharedModelContainer.shared`.
- `ios/KataGo iOS/KataGo Anytime Mac/AppDelegate.swift` — use `SharedModelContainer.shared`.
- `ios/KataGo iOS/KataGo iOS/AppIntents/GameEntity.swift` — delete (moved); `GetGameInfo.swift` keeps its container call via shared container.
- `ios/KataGo iOS/KataGo iOS/Game/GameSplitView.swift` — deep-link branch + `WidgetCenter` reloads.
- `ios/KataGo iOS/KataGo Anytime Mac/AppDelegate.swift` / `MainWindowController.swift` — macOS URL handling + reloads.
- `ios/KataGo iOS/KataGo iOS/KataGo iOS.entitlements`, `KataGo Anytime Mac/KataGoAnytimeMac.entitlements` — add App Group.
- `ios/KataGo-iOS-Info.plist`, `KataGo Anytime Mac/Info.plist` — add `CFBundleURLTypes`.

---

## Phase 1 — Extract the bridge-free `KataGoGameStore` target

### Task 1: Add the `KataGoGameStore` target + product to Package.swift

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Package.swift`
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/Placeholder.swift`

**Interfaces:**
- Produces: a static library product `KataGoGameStore` (pure Swift; no `CKataGoBridge`, no Cxx interop) that `KataGoUICore` depends on.

- [ ] **Step 1: Create the new target's source directory with a placeholder so SwiftPM resolves the target**

Create `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/Placeholder.swift`:

```swift
// Placeholder so SwiftPM can resolve the KataGoGameStore target before its
// real sources are moved in. Deleted in Task 3.
```

- [ ] **Step 2: Add the product** to the `products:` array in `Package.swift`, immediately after the `CoreMLCacheKit` product line:

```swift
        // Bridge-free SwiftData models + shared container + widget-facing
        // helpers. The widget extension links ONLY this product, so it must
        // never depend on CKataGoBridge / MLX. SwiftData + SwiftUI + AppIntents
        // only.
        .library(name: "KataGoGameStore", type: .static, targets: ["KataGoGameStore"]),
```

- [ ] **Step 3: Add the target** to the `targets:` array, before the `KataGoUICore` target:

```swift
        // Pure-Swift, bridge-free SwiftData layer. No Cxx interop.
        .target(
            name: "KataGoGameStore"
        ),
```

- [ ] **Step 4: Make `KataGoUICore` depend on it.** Change the `KataGoUICore` target's `dependencies` line from:

```swift
            dependencies: ["CKataGoBridge", "CoreMLCacheKit"],
```
to:
```swift
            dependencies: ["CKataGoBridge", "CoreMLCacheKit", "KataGoGameStore"],
```

- [ ] **Step 5: Resolve & build the package via the iOS app build (verify still green)**

Run: `xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug`
Expected: **BUILD SUCCEEDED** (new empty target compiles; nothing references it yet).

- [ ] **Step 6: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Package.swift" "ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/Placeholder.swift"
git commit -m "build: add bridge-free KataGoGameStore SwiftPM target"
```

---

### Task 2: Move `Config` into `KataGoGameStore` + add re-export

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/ConfigModel.swift`
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/GameStoreReexport.swift`
- Delete: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/ConfigModel.swift`

**Interfaces:**
- Produces: `public final class Config` now lives in `KataGoGameStore`, transparently visible to every `import KataGoUICore` consumer via the re-export.

- [ ] **Step 1: Move the file.** Move `Sources/KataGoUICore/Model/ConfigModel.swift` to `Sources/KataGoGameStore/ConfigModel.swift` verbatim — its contents are already bridge-free (`import Foundation` / `import SwiftData` only). Use:

```bash
git mv "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/ConfigModel.swift" "ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/ConfigModel.swift"
```

The `default*` constants (`defaultBoardWidth`, `defaultKomi`, …) referenced by `Config` must also live in `KataGoGameStore`. Find their file:

Run: `grep -rln "let defaultBoardWidth" "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore"`

- [ ] **Step 2: Move the defaults file too** (whatever file Step 1's grep found, e.g. `Model/ConfigDefaults.swift`) into `Sources/KataGoGameStore/` with `git mv`, **only if** it contains no bridge calls (verify it imports just Foundation/SwiftData). If those constants are declared inside `ConfigModel.swift` already, skip this step.

- [ ] **Step 3: Add the re-export** so existing `import KataGoUICore` code still sees `Config`. Create `Sources/KataGoUICore/GameStoreReexport.swift`:

```swift
// Re-export the bridge-free model layer so existing `import KataGoUICore`
// consumers (app targets, AppIntents, tests) keep seeing GameRecord/Config and
// the shared store without per-file import changes. The widget extension
// instead imports KataGoGameStore directly.
@_exported import KataGoGameStore
```

- [ ] **Step 4: Build the package (iOS)**

Run: `xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug`
Expected: **BUILD SUCCEEDED**. If you see "cannot find type 'Config'", a KataGoUICore file imports it from the old path — the re-export fixes module visibility; no per-file change should be needed.

- [ ] **Step 5: Run the existing tests** (they construct `Schema([GameRecord.self, Config.self])`)

Run: `xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/GameRecordTests"`
Expected: **TEST SUCCEEDED**.

- [ ] **Step 6: Commit**

```bash
git add -A "ios/KataGo iOS/KataGoUICore/Sources"
git commit -m "refactor: move Config @Model into KataGoGameStore (re-exported from KataGoUICore)"
```

---

### Task 3: Split `GameRecord` — `@Model` + pure helpers into `KataGoGameStore`, bridge methods stay

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/GameRecord.swift`
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/GameRecord+SGF.swift`
- Delete: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/GameRecord.swift`, `Sources/KataGoGameStore/Placeholder.swift`

**Interfaces:**
- Produces (in `KataGoGameStore`): `@Model public final class GameRecord` with all stored properties + designated/convenience inits; and pure helpers `static func createFetchDescriptor(fetchLimit:) -> FetchDescriptor<GameRecord>`, `@MainActor static func fetchGameRecords(container:fetchLimit:) throws -> [GameRecord]`, `var image: Image?`, `var concreteConfig: ...`, plus the pure stone/captured/clear helpers.
- Produces (in `KataGoUICore`): `extension GameRecord` with the bridge-using methods `createGameRecord`, `importGameRecord(sgf:name:in:)`, `importGameRecord(from:in:)`, `readSgfContent(from:)`, `findExistingGameRecord(...)`, `updateToLatestVersion()`, `clone(upToMove:fromSgf:dataValidUpTo:)`, `getDead*Stones`, `getSchrodinger*Stones`, `get*SacrificeableStones`.

- [ ] **Step 1: Create `Sources/KataGoGameStore/GameRecord.swift`** containing the `@Model` class body and the **bridge-free** members. Copy verbatim from the current `GameRecord.swift`: the `@Model final class GameRecord { … }` declaration (all stored properties exactly as-is, lines 11–46), its designated `init` (lines ~202–245), `concreteConfig` (~188–200), the captured-stone helpers `getCapturedBlackStones/getCapturedWhiteStones/getCapturedStones` (~48–83), `getBlackSacrificeableStones/getWhiteSacrificeableStones` (~174–186 — verify they don't call `Coordinate`; if they do, move them to Step 2 instead), `clearData(after:)` (~310–324), `undo()` (~304–308), pure `clone()` (~247–276), `createFetchDescriptor` (~326–332), `fetchGameRecords` (~334–339), and `image` (~454–470). Top of file:

```swift
import SwiftUI
import SwiftData
```

Keep class name `GameRecord` and every stored property **byte-identical**.

- [ ] **Step 2: Create `Sources/KataGoUICore/Model/GameRecord+SGF.swift`** containing the **bridge-using** members as an extension. Top of file:

```swift
import SwiftUI
import SwiftData
import KataGoGameStore
```

Then `extension GameRecord { … }` wrapping verbatim: `createGameRecord(...)` (lines ~341–403, uses `SgfOperations`), `importGameRecord(sgf:name:in:)` (~435–452), `importGameRecord(from:in:)` (~427–431), `readSgfContent(from:)` (~405–418), `findExistingGameRecord(...)` (~420–424), `updateToLatestVersion()` (~472–533, uses `SgfOperations`), `clone(upToMove:fromSgf:dataValidUpTo:)` (~296–302, uses `SgfTruncation`), and the `Coordinate`-using `getDeadBlackStones/getDeadWhiteStones/getStones` (~85–130) and `getBlackSchrodingerStones/getWhiteSchrodingerStones/getSchrodingerStones` (~132–172).

Note: any `private` stored property the SGF methods touch (`deadBlackStones`, etc.) is declared on the class in `KataGoGameStore`. Change those four `private var` declarations to `var` (package-internal won't cross modules) — actually make them `public internal(set)` is wrong for `@Model`; instead change `private` → `public`. They are already orphan/unused compatibility fields, so widening access is safe and preserves the stored schema:

```swift
    public var deadBlackStones: [Int: String]?
    public var deadWhiteStones: [Int: String]?
    public var blackSchrodingerStones: [Int: String]?
    public var whiteSchrodingerStones: [Int: String]?
```

- [ ] **Step 3: Delete the originals**

```bash
git rm "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/GameRecord.swift" "ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/Placeholder.swift"
```

- [ ] **Step 4: Build all three platforms**

Run (iOS): `xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug`
Run (visionOS): `xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug`
Run (macOS): `xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS' -configuration Debug`
Expected: all **BUILD SUCCEEDED**. Common failure: a KataGoUICore file calls a bridge method now in the extension — that still works (same type). If "cannot find 'SgfOperations'" appears in `GameRecord+SGF.swift`, add the import the original file used for that symbol (search where `SgfOperations` is declared and import that module if it's separate; it is in `KataGoUICore` itself, so no import is needed beyond being in the same module).

- [ ] **Step 5: Run the full unit test suite** (verifies SwiftData schema still loads & behaves)

Run: `xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: **TEST SUCCEEDED** (same set as before the split).

- [ ] **Step 6: Commit**

```bash
git add -A "ios/KataGo iOS/KataGoUICore/Sources"
git commit -m "refactor: split GameRecord @Model (KataGoGameStore) from its SGF/bridge methods"
```

> **Schema-identity note for the executor:** This task moves the `@Model` classes between Swift modules. Entity identity derives from the class name + properties, not the module, so this is expected to be schema-compatible — but it is the project's highest-risk change. Do **not** ship until Task 16's on-device CloudKit verification passes.

---

## Phase 2 — Shared App-Group container + store migration

### Task 4: Add the App Group entitlement to both apps

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/KataGo iOS.entitlements`
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/KataGoAnytimeMac.entitlements`

- [ ] **Step 1: iOS entitlements** — add this key/array inside the top-level `<dict>` (e.g. after the `icloud-services` array):

```xml
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.chinchangyang.KataGo-iOS.tw</string>
	</array>
```

- [ ] **Step 2: macOS entitlements** — add the same key/array inside its `<dict>` (the sandbox already present means the group container is sandbox-scoped):

```xml
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.chinchangyang.KataGo-iOS.tw</string>
	</array>
```

- [ ] **Step 3: Build both apps to confirm entitlements still sign**

Run (iOS): `xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug`
Run (macOS): `xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS' -configuration Debug`
Expected: both **BUILD SUCCEEDED**. (If macOS signing complains the App Group isn't registered, register `group.chinchangyang.KataGo-iOS.tw` in the Developer portal for team `6F82AZ9Z52`, then rebuild.)

- [ ] **Step 4: Commit**

```bash
git add "ios/KataGo iOS/KataGo iOS/KataGo iOS.entitlements" "ios/KataGo iOS/KataGo Anytime Mac/KataGoAnytimeMac.entitlements"
git commit -m "build: add App Group entitlement to iOS and macOS apps"
```

---

### Task 5: `SharedModelContainer` (App-Group store + one-time migration)

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/SharedModelContainer.swift`
- Test: `ios/KataGo iOS/KataGo iOSTests/SharedModelContainerTests.swift`

**Interfaces:**
- Produces: `public enum SharedModelContainer` with `static let appGroupID: String`, `static let cloudKitContainerID: String`, `static var schema: Schema`, `static let shared: ModelContainer`, and the testable `@discardableResult public static func migrateStore(from oldURL: URL, to newURL: URL) -> Bool` (returns true if a copy happened).

- [ ] **Step 1: Write the failing test** `SharedModelContainerTests.swift`:

```swift
import Testing
import SwiftData
import Foundation
import CoreData
import KataGoUICore   // re-exports KataGoGameStore

struct SharedModelContainerTests {

    /// Writes one GameRecord into a SwiftData store at `url`.
    @MainActor
    private func seedStore(at url: URL, name: String) throws {
        let config = ModelConfiguration(url: url)
        let container = try ModelContainer(for: SharedModelContainer.schema, configurations: config)
        let record = GameRecord()
        record.name = name
        container.mainContext.insert(record)
        try container.mainContext.save()
    }

    @MainActor
    private func names(in url: URL) throws -> [String] {
        let config = ModelConfiguration(url: url)
        let container = try ModelContainer(for: SharedModelContainer.schema, configurations: config)
        return try container.mainContext.fetch(FetchDescriptor<GameRecord>()).map(\.name)
    }

    @Test @MainActor func migrateStore_copiesExistingDataWhenDestinationMissing() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let oldURL = dir.appending(path: "old.store")
        let newURL = dir.appending(path: "new.store")
        try seedStore(at: oldURL, name: "Migrated Game")

        let didCopy = SharedModelContainer.migrateStore(from: oldURL, to: newURL)

        #expect(didCopy == true)
        #expect(try names(in: newURL).contains("Migrated Game"))
    }

    @Test @MainActor func migrateStore_noopWhenDestinationExists() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let oldURL = dir.appending(path: "old.store")
        let newURL = dir.appending(path: "new.store")
        try seedStore(at: oldURL, name: "Old")
        try seedStore(at: newURL, name: "Existing")

        let didCopy = SharedModelContainer.migrateStore(from: oldURL, to: newURL)

        #expect(didCopy == false)
        #expect(try names(in: newURL).contains("Existing"))
    }
}
```

- [ ] **Step 2: Add the test file to the `KataGo AnytimeTests` target** using the project's Ruby pattern (see `reference_adding_swift_files_xcodeproj` / `add_engine_ipc_dependency.rb`). Minimal inline script — create `ios/KataGo iOS/add_test_file.rb` is overkill; instead register it by appending to the test target's source phase. Run this one-off Ruby:

```bash
cd "ios/KataGo iOS" && ruby -e '
require "xcodeproj"
p = Xcodeproj::Project.open("KataGo Anytime.xcodeproj")
t = p.targets.find { |x| x.name == "KataGo AnytimeTests" }
g = p.files.find { |f| f.path&.end_with?("GameRecordTests.swift") }.parent
ref = g.new_reference("SharedModelContainerTests.swift")
t.source_build_phase.add_file_reference(ref)
p.save
'
```

- [ ] **Step 3: Run the test to verify it fails (symbol missing)**

Run: `xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/SharedModelContainerTests"`
Expected: **FAIL/compile error** — `SharedModelContainer` not found.

- [ ] **Step 4: Implement `SharedModelContainer.swift`**:

```swift
import SwiftData
import Foundation
import CoreData

/// Single source of truth for the app↔widget SwiftData store. The store lives
/// in the shared App Group container so the widget extension (a separate
/// process) can read it; CloudKit keeps it in sync across devices.
public enum SharedModelContainer {
    public static let appGroupID = "group.chinchangyang.KataGo-iOS.tw"
    public static let cloudKitContainerID = "iCloud.chinchangyang.KataGo-iOS.tw"

    public static var schema: Schema { Schema([GameRecord.self, Config.self]) }

    /// The container every app process (app, AppIntents, widget) uses.
    public static let shared: ModelContainer = {
        // Best-effort one-time migration of a pre-App-Group store.
        if let appGroupURL = appGroupStoreURL() {
            _ = migrateStore(from: defaultStoreURL(), to: appGroupURL)
        }
        let config = ModelConfiguration(
            schema: schema,
            groupContainer: .identifier(appGroupID),
            cloudKitDatabase: .private(cloudKitContainerID)
        )
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("SharedModelContainer: failed to open store: \(error)")
        }
    }()

    /// Copies a SwiftData/SQLite store (plus -wal/-shm) from `oldURL` to
    /// `newURL` iff `oldURL` exists and `newURL` does not. SwiftData does NOT
    /// auto-migrate a default-location store into an App Group container.
    @discardableResult
    public static func migrateStore(from oldURL: URL, to newURL: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: oldURL.path),
              !fm.fileExists(atPath: newURL.path) else { return false }
        guard let mom = NSManagedObjectModel.makeManagedObjectModel(for: [GameRecord.self, Config.self]) else {
            return false
        }
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: mom)
        do {
            try coordinator.replacePersistentStore(
                at: newURL,
                destinationOptions: nil,
                withPersistentStoreFrom: oldURL,
                sourceOptions: nil,
                type: .sqlite
            )
            return true
        } catch {
            NSLog("SharedModelContainer.migrateStore failed: \(error)")
            return false
        }
    }

    /// Where SwiftData's default (pre-App-Group) store lived.
    static func defaultStoreURL() -> URL {
        URL.applicationSupportDirectory.appending(path: "default.store")
    }

    /// Where SwiftData places the store given `groupContainer: .identifier`.
    static func appGroupStoreURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appending(path: "default.store")
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/SharedModelContainerTests"`
Expected: **TEST SUCCEEDED** (both cases).

- [ ] **Step 6: Commit**

```bash
git add -A "ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/SharedModelContainer.swift" "ios/KataGo iOS/KataGo iOSTests/SharedModelContainerTests.swift" "ios/KataGo iOS/KataGo Anytime.xcodeproj"
git commit -m "feat: SharedModelContainer with App Group store + one-time migration"
```

---

### Task 6: Route all container sites through `SharedModelContainer`

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/App/KataGo_iOSApp.swift:84`
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/AppDelegate.swift:33`
- Modify: `ios/KataGo iOS/KataGo iOS/AppIntents/GetGameInfo.swift:41`

**Interfaces:**
- Consumes: `SharedModelContainer.shared` (Task 5).

- [ ] **Step 1: iOS app** — change `KataGo_iOSApp.swift` body from:

```swift
    var body: some Scene {
        scene.modelContainer(for: GameRecord.self)
    }
```
to:
```swift
    var body: some Scene {
        scene.modelContainer(SharedModelContainer.shared)
    }
```

- [ ] **Step 2: macOS app** — change `AppDelegate.swift:33` from:

```swift
    let modelContainer = try! ModelContainer(for: GameRecord.self)
```
to:
```swift
    let modelContainer = SharedModelContainer.shared
```

- [ ] **Step 3: AppIntents** — in `GetGameInfo.swift`, change `GetLatestGameInfo.perform()`'s `let container = try ModelContainer(for: GameRecord.self)` (line 41) to `let container = SharedModelContainer.shared`. (The `GameEntityQuery` container calls are handled when it moves in Task 9.) Leave the dev-only `removeAllGameRecords()`/`initializeCloutKitDevSchema()` in `KataGo_iOSApp.swift` as-is (both are `#if false`).

- [ ] **Step 4: Build all three platforms**

Run (iOS): `xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug`
Run (visionOS): `xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug`
Run (macOS): `xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS' -configuration Debug`
Expected: all **BUILD SUCCEEDED**.

- [ ] **Step 5: Run full tests**

Run: `xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: **TEST SUCCEEDED**.

- [ ] **Step 6: Commit**

```bash
git add "ios/KataGo iOS/KataGo iOS/App/KataGo_iOSApp.swift" "ios/KataGo iOS/KataGo Anytime Mac/AppDelegate.swift" "ios/KataGo iOS/KataGo iOS/AppIntents/GetGameInfo.swift"
git commit -m "refactor: route all ModelContainer sites through SharedModelContainer"
```

---

## Phase 3 — Widget extension target scaffolding

### Task 7: Create the widget extension target via Ruby

**Files:**
- Create: `ios/KataGo iOS/add_widget_extension_target.rb`
- Create: `ios/KataGo iOS/KataGoAnytimeWidget/Info.plist`
- Create: `ios/KataGo iOS/KataGoAnytimeWidget/KataGoAnytimeWidget.entitlements`

**Interfaces:**
- Produces: an app-extension target `KataGoAnytimeWidget` (bundle id `chinchangyang.KataGo-iOS.tw.widget`), supporting iOS/visionOS/macOS, linking the `KataGoGameStore` product, embedded into both apps' PlugIns.

- [ ] **Step 1: Create the widget Info.plist** `ios/KataGo iOS/KataGoAnytimeWidget/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>$(DEVELOPMENT_LANGUAGE)</string>
	<key>CFBundleDisplayName</key>
	<string>KataGo Anytime Widget</string>
	<key>CFBundleExecutable</key>
	<string>$(EXECUTABLE_NAME)</string>
	<key>CFBundleIdentifier</key>
	<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>CFBundleName</key>
	<string>$(PRODUCT_NAME)</string>
	<key>CFBundlePackageType</key>
	<string>$(PRODUCT_BUNDLE_PACKAGE_TYPE)</string>
	<key>CFBundleShortVersionString</key>
	<string>$(MARKETING_VERSION)</string>
	<key>CFBundleVersion</key>
	<string>$(CURRENT_PROJECT_VERSION)</string>
	<key>NSExtension</key>
	<dict>
		<key>NSExtensionPointIdentifier</key>
		<string>com.apple.widgetkit-extension</string>
	</dict>
</dict>
</plist>
```

- [ ] **Step 2: Create the widget entitlements** `ios/KataGo iOS/KataGoAnytimeWidget/KataGoAnytimeWidget.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.chinchangyang.KataGo-iOS.tw</string>
	</array>
	<key>com.apple.developer.icloud-container-identifiers</key>
	<array>
		<string>iCloud.chinchangyang.KataGo-iOS.tw</string>
	</array>
	<key>com.apple.developer.icloud-services</key>
	<array>
		<string>CloudKit</string>
	</array>
</dict>
</plist>
```

- [ ] **Step 3: Write `add_widget_extension_target.rb`** (model it on `add_engine_helper_target.rb`):

```ruby
#!/usr/bin/env ruby
# Adds the "KataGoAnytimeWidget" WidgetKit app-extension target, links the
# bridge-free KataGoGameStore product, and embeds it into both the iOS app
# (KataGo Anytime) and the macOS app (KataGo Anytime Mac). Idempotent.
require 'xcodeproj'

PROJECT = File.join(__dir__, 'KataGo Anytime.xcodeproj')
WIDGET  = 'KataGoAnytimeWidget'
TEAM    = '6F82AZ9Z52'
IOS_APP = 'KataGo Anytime'
MAC_APP = 'KataGo Anytime Mac'

project = Xcodeproj::Project.open(PROJECT)
if project.targets.any? { |t| t.name == WIDGET }
  puts "Target '#{WIDGET}' already exists — nothing to do."
  exit 0
end

ios_app = project.targets.find { |t| t.name == IOS_APP } or abort("missing #{IOS_APP}")
mac_app = project.targets.find { |t| t.name == MAC_APP } or abort("missing #{MAC_APP}")

# KataGoGameStore product dependency (from the existing KataGoUICore package ref).
pkg = project.root_object.package_references.find do |r|
  r.respond_to?(:relative_path) && r.relative_path == 'KataGoUICore'
end or abort('missing KataGoUICore package reference')

# 1. Create the app-extension target (declared iOS; SUPPORTED_PLATFORMS widened below).
widget = project.new_target(:app_extension, WIDGET, :ios, '26.0')

widget.build_configurations.each do |c|
  s = c.build_settings
  s['PRODUCT_NAME']                       = WIDGET
  s['PRODUCT_BUNDLE_IDENTIFIER']          = 'chinchangyang.KataGo-iOS.tw.widget'
  s['INFOPLIST_FILE']                     = "#{WIDGET}/Info.plist"
  s['GENERATE_INFOPLIST_FILE']            = 'NO'
  s['CODE_SIGN_ENTITLEMENTS']             = "#{WIDGET}/#{WIDGET}.entitlements"
  s['CODE_SIGN_STYLE']                    = 'Automatic'
  s['DEVELOPMENT_TEAM']                   = TEAM
  s['SUPPORTED_PLATFORMS']                = 'iphoneos iphonesimulator macosx xros xrsimulator'
  s['SUPPORTS_MACCATALYST']               = 'NO'
  s['IPHONEOS_DEPLOYMENT_TARGET']         = '26.0'
  s['MACOSX_DEPLOYMENT_TARGET']           = '26.0'
  s['XROS_DEPLOYMENT_TARGET']             = '26.0'
  s['SWIFT_VERSION']                      = '6.0'
  s['SKIP_INSTALL']                       = 'YES'
  s['LD_RUNPATH_SEARCH_PATHS']            = ['$(inherited)', '@executable_path/Frameworks',
                                             '@executable_path/../../Frameworks']
  s['SWIFT_EMIT_LOC_STRINGS']             = 'YES'
end

# 2. Link the bridge-free product.
dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
dep.package = pkg
dep.product_name = 'KataGoGameStore'
widget.package_product_dependencies << dep
bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
bf.product_ref = dep
widget.frameworks_build_phase.files << bf

# 3. Register the widget source files + Info.plist/entitlements in a group.
group = project.main_group.find_subpath(WIDGET, true)
group.set_source_tree('SOURCE_ROOT')
%w[
  KataGoAnytimeWidgetBundle.swift SavedGameWidget.swift SelectGameIntent.swift
  SavedGameProvider.swift SavedGameWidgetView.swift
].each do |f|
  ref = group.new_reference("#{WIDGET}/#{f}")
  widget.source_build_phase.add_file_reference(ref)
end
group.new_reference("#{WIDGET}/Info.plist")
group.new_reference("#{WIDGET}/#{WIDGET}.entitlements")

# 4. Embed into BOTH apps' PlugIns + add a build dependency.
[ios_app, mac_app].each do |app|
  app.add_dependency(widget)
  phase = app.copy_files_build_phases.find { |p| p.name == 'Embed Foundation Extensions' }
  unless phase
    phase = app.new_copy_files_build_phase('Embed Foundation Extensions')
    phase.symbol_dst_subfolder_spec = :plug_ins   # PlugIns/
    phase.dst_path = ''
  end
  ebf = phase.add_file_reference(widget.product_reference)
  ebf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
end

project.save
puts "Added #{WIDGET}, linked KataGoGameStore, embedded into #{IOS_APP} and #{MAC_APP}."
```

- [ ] **Step 4: Run the script**

Run: `cd "ios/KataGo iOS" && ruby add_widget_extension_target.rb`
Expected: prints `Added KataGoAnytimeWidget, …`. (Re-running prints "already exists".)

- [ ] **Step 5: Create placeholder source files** so the target compiles (replaced in Phase 4). Create `ios/KataGo iOS/KataGoAnytimeWidget/KataGoAnytimeWidgetBundle.swift`:

```swift
import WidgetKit
import SwiftUI

@main
struct KataGoAnytimeWidgetBundle: WidgetBundle {
    var body: some Widget {
        SavedGameWidget()
    }
}
```

Create stubs for the other four files so the bundle resolves (each will be fleshed out in Phase 4):

```swift
// SavedGameWidget.swift
import WidgetKit
import SwiftUI

struct SavedGameWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SavedGameWidget", provider: PlaceholderProvider()) { _ in
            Text("KataGo")
        }
    }
}

struct PlaceholderProvider: TimelineProvider {
    func placeholder(in context: Context) -> SimpleEntry { SimpleEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> Void) { completion(SimpleEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SimpleEntry>) -> Void) {
        completion(Timeline(entries: [SimpleEntry(date: .now)], policy: .never))
    }
}

struct SimpleEntry: TimelineEntry { let date: Date }
```

(Leave `SelectGameIntent.swift`, `SavedGameProvider.swift`, `SavedGameWidgetView.swift` as empty files for now — created with `touch`. They get real content in Phase 4.)

- [ ] **Step 6: Build both apps (which build the embedded widget)**

Run (iOS): `xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug`
Run (macOS): `xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS' -configuration Debug`
Expected: both **BUILD SUCCEEDED**, and the build log shows `KataGoAnytimeWidget.appex` being produced and embedded. If signing fails on `chinchangyang.KataGo-iOS.tw.widget`, let Xcode create the provisioning profile (Automatic signing) or register the App ID in the portal.

- [ ] **Step 7: Commit**

```bash
git add "ios/KataGo iOS/add_widget_extension_target.rb" "ios/KataGo iOS/KataGoAnytimeWidget" "ios/KataGo iOS/KataGo Anytime.xcodeproj"
git commit -m "build: add KataGoAnytimeWidget extension target (iOS/macOS/visionOS)"
```

---

## Phase 4 — Widget data, configuration, rendering

### Task 8: Move `GameEntity`/`GameEntityQuery` into `KataGoGameStore` and extend for the widget

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/GameEntity.swift`
- Delete: `ios/KataGo iOS/KataGo iOS/AppIntents/GameEntity.swift`
- Test: `ios/KataGo iOS/KataGo iOSTests/GameEntityQueryTests.swift`

**Interfaces:**
- Produces: `public struct GameEntity: AppEntity` with public `id: UUID`, `name: String`, `firstComment: String`, `thumbnail: Data?`, `boardWidth: Int`, `boardHeight: Int`, `lastBlackStones: [String]`, `lastWhiteStones: [String]`; and `public struct GameEntityQuery: EntityQuery & EntityStringQuery`. Both use `SharedModelContainer.shared`.

- [ ] **Step 1: Write the failing test** `GameEntityQueryTests.swift`:

```swift
import Testing
import SwiftData
import Foundation
import KataGoUICore

struct GameEntityQueryTests {
    @Test @MainActor func gameEntity_capturesNameAndFirstComment() throws {
        let record = GameRecord()
        record.name = "Opening Study"
        record.comments = [0: "Black takes 4-4", 1: "White approaches"]
        record.width = 19
        record.height = 19
        let entity = GameEntity(gameRecord: record)
        #expect(entity.name == "Opening Study")
        #expect(entity.firstComment == "Black takes 4-4")
        #expect(entity.boardWidth == 19)
    }
}
```

- [ ] **Step 2: Register the test file** in the test target (same one-off Ruby as Task 5 Step 2, swapping the filename to `GameEntityQueryTests.swift`).

- [ ] **Step 3: Run it to confirm failure**

Run: `xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/GameEntityQueryTests"`
Expected: **FAIL** — `firstComment`/new initializer not found (the old `GameEntity` lives in the app target, not visible here).

- [ ] **Step 4: Create `Sources/KataGoGameStore/GameEntity.swift`** (move + extend; based on the existing `GameEntity.swift`):

```swift
import AppIntents
import SwiftData
import Foundation

public struct GameEntity: AppEntity {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(stringLiteral: "Computer Go Game")
    }
    public static let defaultQuery = GameEntityQuery()

    public let id: UUID
    @Property(title: "Name") public var name: String
    @Property(title: "Comments") public var comments: [String]

    public var firstComment: String
    public var thumbnail: Data?
    public var boardWidth: Int
    public var boardHeight: Int
    public var lastBlackStones: [String]
    public var lastWhiteStones: [String]

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(firstComment)")
    }

    public init(gameRecord: GameRecord) {
        self.id = gameRecord.uuid ?? UUID()
        self.name = gameRecord.name
        let sortedComments = gameRecord.comments?.keys.sorted().compactMap { gameRecord.comments?[$0] } ?? []
        self.comments = sortedComments
        self.firstComment = gameRecord.comments?[0] ?? sortedComments.first ?? ""
        self.thumbnail = gameRecord.thumbnail
        self.boardWidth = gameRecord.width ?? 19
        self.boardHeight = gameRecord.height ?? 19
        let lastIndex = (gameRecord.blackStones?.keys.max()).map { max($0, gameRecord.whiteStones?.keys.max() ?? 0) }
            ?? gameRecord.whiteStones?.keys.max() ?? 0
        self.lastBlackStones = GameEntity.stoneList(gameRecord.blackStones, at: lastIndex)
        self.lastWhiteStones = GameEntity.stoneList(gameRecord.whiteStones, at: lastIndex)
    }

    /// Stored stone dictionaries map move index → space-joined GTP vertices
    /// (e.g. "Q16 D4"). Returns the vertices for `index`, or [].
    static func stoneList(_ dict: [Int: String]?, at index: Int) -> [String] {
        guard let raw = dict?[index], !raw.isEmpty else { return [] }
        return raw.split(separator: " ").map(String.init)
    }
}

@MainActor
public struct GameEntityQuery: EntityQuery, EntityStringQuery {
    public init() {}

    public func entities(for identifiers: [GameEntity.ID]) async throws -> [GameEntity] {
        try records().filter { identifiers.contains($0.uuid ?? UUID()) }.map(GameEntity.init)
    }

    public func suggestedEntities() async throws -> [GameEntity] {
        try records(limit: 20).map(GameEntity.init)
    }

    public func entities(matching string: String) async throws -> [GameEntity] {
        try records().filter { $0.name.localizedCaseInsensitiveContains(string) }.map(GameEntity.init)
    }

    private func records(limit: Int? = nil) throws -> [GameRecord] {
        try GameRecord.fetchGameRecords(container: SharedModelContainer.shared, fetchLimit: limit)
    }
}
```

> Note: the previous `GameEntityQuery` repaired duplicate UUIDs. If that repair is still needed, move `repairDuplicateUUIDs`/`generateUniqueUUID` here as `private` helpers (they are bridge-free) and call them inside `records()`. Verbatim source is in the old `GameEntity.swift` lines 45–90.

- [ ] **Step 5: Delete the old app-target `GameEntity.swift`** and fix its consumers:

```bash
git rm "ios/KataGo iOS/KataGo iOS/AppIntents/GameEntity.swift"
```
`GetGameInfo.swift` and `KataGoShortcuts.swift` reference `GameEntity`/`GameEntityQuery`; they `import KataGoUICore`, which re-exports `KataGoGameStore`, so they still compile. Confirm `GetGameInfo.swift` still has `import KataGoUICore` (it does).

- [ ] **Step 6: Run the test (passes) + build the iOS app**

Run: `xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/GameEntityQueryTests"`
Expected: **TEST SUCCEEDED**.
Run: `xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug`
Expected: **BUILD SUCCEEDED**.

- [ ] **Step 7: Commit**

```bash
git add -A "ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/GameEntity.swift" "ios/KataGo iOS/KataGo iOS/AppIntents" "ios/KataGo iOS/KataGo iOSTests/GameEntityQueryTests.swift" "ios/KataGo iOS/KataGo Anytime.xcodeproj"
git commit -m "refactor: move GameEntity/GameEntityQuery to KataGoGameStore; add widget fields"
```

---

### Task 9: `WidgetBoardView` — light board renderer

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WidgetBoardView.swift`
- Test: `ios/KataGo iOS/KataGo iOSTests/WidgetBoardViewTests.swift`

**Interfaces:**
- Produces: `public struct WidgetBoardView: View { public init(width: Int, height: Int, blackVertices: [String], whiteVertices: [String]) }`; and `public func parseVertex(_ v: String, height: Int) -> (x: Int, y: Int)?` for GTP-vertex → grid coordinates.

- [ ] **Step 1: Write the failing test** `WidgetBoardViewTests.swift`:

```swift
import Testing
import SwiftUI
import KataGoUICore

struct WidgetBoardViewTests {
    @Test func parseVertex_handlesGTPCoordinates() {
        // 19x19: "A1" is bottom-left → grid (0, 18); "T19" top-right → (18, 0).
        #expect(parseVertex("A1", height: 19)! == (0, 18))
        #expect(parseVertex("T19", height: 19)! == (18, 0))
        #expect(parseVertex("Q16", height: 19)! == (15, 3))
        #expect(parseVertex("", height: 19) == nil)
        #expect(parseVertex("I5", height: 19) == nil) // 'I' is skipped in GTP columns
    }

    @MainActor @Test func widgetBoardView_rendersToImage() {
        let view = WidgetBoardView(width: 19, height: 19,
                                   blackVertices: ["Q16", "D4"], whiteVertices: ["Q4"])
        let renderer = ImageRenderer(content: view.frame(width: 120, height: 120))
        #expect(renderer.uiImage != nil)
    }
}
```

(On macOS the `renderer.uiImage` check is iOS-only; the test target runs on iOS Simulator so `uiImage` is correct.)

- [ ] **Step 2: Register the test file** in the test target (same Ruby pattern; filename `WidgetBoardViewTests.swift`).

- [ ] **Step 3: Run to confirm failure**

Run: `xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/WidgetBoardViewTests"`
Expected: **FAIL** — `parseVertex`/`WidgetBoardView` not found.

- [ ] **Step 4: Implement `WidgetBoardView.swift`**:

```swift
import SwiftUI

/// GTP columns skip the letter 'I'. Returns 0-based grid coordinates where the
/// origin (0,0) is the TOP-LEFT, matching SwiftUI's drawing space. GTP row 1 is
/// the BOTTOM, so y is flipped against `height`.
public func parseVertex(_ vertex: String, height: Int) -> (x: Int, y: Int)? {
    let v = vertex.uppercased()
    guard let first = v.first, first.isLetter, first != "I" else { return nil }
    let columns = Array("ABCDEFGHJKLMNOPQRSTUVWXYZ")
    guard let col = columns.firstIndex(of: first) else { return nil }
    let rowString = v.dropFirst()
    guard let row = Int(rowString), row >= 1, row <= height else { return nil }
    return (x: col, y: height - row)
}

/// Minimal, dependency-free Go board: wooden background, grid lines, filled
/// stones. No Metal, no engine, no GobanState — safe for a widget extension.
public struct WidgetBoardView: View {
    let width: Int
    let height: Int
    let black: [(Int, Int)]
    let white: [(Int, Int)]

    public init(width: Int, height: Int, blackVertices: [String], whiteVertices: [String]) {
        self.width = max(width, 1)
        self.height = max(height, 1)
        self.black = blackVertices.compactMap { parseVertex($0, height: height) }
        self.white = whiteVertices.compactMap { parseVertex($0, height: height) }
    }

    public var body: some View {
        GeometryReader { geo in
            let cell = min(geo.size.width / CGFloat(width), geo.size.height / CGFloat(height))
            let originX = (geo.size.width - cell * CGFloat(width - 1)) / 2
            let originY = (geo.size.height - cell * CGFloat(height - 1)) / 2
            func point(_ x: Int, _ y: Int) -> CGPoint {
                CGPoint(x: originX + CGFloat(x) * cell, y: originY + CGFloat(y) * cell)
            }
            ZStack {
                Color(red: 0.85, green: 0.68, blue: 0.40)
                Path { p in
                    for x in 0..<width {
                        p.move(to: point(x, 0)); p.addLine(to: point(x, height - 1))
                    }
                    for y in 0..<height {
                        p.move(to: point(0, y)); p.addLine(to: point(width - 1, y))
                    }
                }
                .stroke(Color.black.opacity(0.55), lineWidth: 0.5)
                ForEach(Array(white.enumerated()), id: \.offset) { _, s in
                    Circle().fill(.white)
                        .frame(width: cell * 0.92, height: cell * 0.92)
                        .position(point(s.0, s.1))
                }
                ForEach(Array(black.enumerated()), id: \.offset) { _, s in
                    Circle().fill(.black)
                        .frame(width: cell * 0.92, height: cell * 0.92)
                        .position(point(s.0, s.1))
                }
            }
        }
    }
}
```

- [ ] **Step 5: Run the tests to pass**

Run: `xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/WidgetBoardViewTests"`
Expected: **TEST SUCCEEDED**.

- [ ] **Step 6: Commit**

```bash
git add -A "ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WidgetBoardView.swift" "ios/KataGo iOS/KataGo iOSTests/WidgetBoardViewTests.swift" "ios/KataGo iOS/KataGo Anytime.xcodeproj"
git commit -m "feat: WidgetBoardView light board renderer + GTP vertex parser"
```

---

### Task 10: Configuration intent + timeline provider

**Files:**
- Modify (real content): `ios/KataGo iOS/KataGoAnytimeWidget/SelectGameIntent.swift`, `SavedGameProvider.swift`
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/SavedGameSnapshot.swift`
- Test: `ios/KataGo iOS/KataGo iOSTests/SavedGameProviderTests.swift`

**Interfaces:**
- Consumes: `GameEntity`, `GameEntityQuery`, `GameRecord.fetchGameRecords`, `SharedModelContainer.shared`.
- Produces: `public struct SavedGameSnapshot: Sendable` (`name`, `firstComment`, `thumbnail: Data?`, `boardWidth`, `boardHeight`, `lastBlackStones: [String]`, `lastWhiteStones: [String]`, `gameID: UUID?`) with `init(gameEntity:)` and a `static var placeholder`; and a pure `@MainActor public static func resolveSnapshot(for entity: GameEntity?, container: ModelContainer) -> SavedGameSnapshot` selecting the configured game or the most recent.
- `SelectGameIntent: WidgetConfigurationIntent` with `@Parameter var game: GameEntity?`.

- [ ] **Step 1: Create `SavedGameSnapshot.swift`** in `KataGoGameStore` (shared so it's testable from the app test target):

```swift
import SwiftData
import Foundation

public struct SavedGameSnapshot: Sendable {
    public var gameID: UUID?
    public var name: String
    public var firstComment: String
    public var thumbnail: Data?
    public var boardWidth: Int
    public var boardHeight: Int
    public var lastBlackStones: [String]
    public var lastWhiteStones: [String]

    public init(gameEntity e: GameEntity) {
        gameID = e.id; name = e.name; firstComment = e.firstComment
        thumbnail = e.thumbnail; boardWidth = e.boardWidth; boardHeight = e.boardHeight
        lastBlackStones = e.lastBlackStones; lastWhiteStones = e.lastWhiteStones
    }

    public static var placeholder: SavedGameSnapshot {
        SavedGameSnapshot(gameID: nil, name: "No game selected",
                          firstComment: "Open KataGo Anytime to choose a game.",
                          thumbnail: nil, boardWidth: 19, boardHeight: 19,
                          lastBlackStones: [], lastWhiteStones: [])
    }

    public init(gameID: UUID?, name: String, firstComment: String, thumbnail: Data?,
                boardWidth: Int, boardHeight: Int, lastBlackStones: [String], lastWhiteStones: [String]) {
        self.gameID = gameID; self.name = name; self.firstComment = firstComment
        self.thumbnail = thumbnail; self.boardWidth = boardWidth; self.boardHeight = boardHeight
        self.lastBlackStones = lastBlackStones; self.lastWhiteStones = lastWhiteStones
    }

    /// Resolve the snapshot the widget should render: the configured game if
    /// present and still existing, else the most-recently-modified game, else a
    /// placeholder.
    @MainActor
    public static func resolveSnapshot(for entity: GameEntity?, container: ModelContainer) -> SavedGameSnapshot {
        if let entity,
           let match = (try? GameRecord.fetchGameRecords(container: container))?
               .first(where: { $0.uuid == entity.id }) {
            return SavedGameSnapshot(gameEntity: GameEntity(gameRecord: match))
        }
        if let recent = (try? GameRecord.fetchGameRecords(container: container, fetchLimit: 1))?.first {
            return SavedGameSnapshot(gameEntity: GameEntity(gameRecord: recent))
        }
        return .placeholder
    }
}
```

- [ ] **Step 2: Write the failing test** `SavedGameProviderTests.swift`:

```swift
import Testing
import SwiftData
import Foundation
import KataGoUICore

struct SavedGameProviderTests {
    @MainActor
    private func container() throws -> ModelContainer {
        try ModelContainer(for: SharedModelContainer.schema,
                           configurations: ModelConfiguration(schema: SharedModelContainer.schema, isStoredInMemoryOnly: true))
    }

    @Test @MainActor func resolve_fallsBackToMostRecentWhenUnconfigured() throws {
        let c = try container()
        let older = GameRecord(); older.name = "Older"; older.lastModificationDate = Date(timeIntervalSince1970: 1)
        let newer = GameRecord(); newer.name = "Newer"; newer.lastModificationDate = Date(timeIntervalSince1970: 2)
        c.mainContext.insert(older); c.mainContext.insert(newer); try c.mainContext.save()

        let snap = SavedGameSnapshot.resolveSnapshot(for: nil, container: c)
        #expect(snap.name == "Newer")
    }

    @Test @MainActor func resolve_returnsPlaceholderWhenEmpty() throws {
        let c = try container()
        let snap = SavedGameSnapshot.resolveSnapshot(for: nil, container: c)
        #expect(snap.gameID == nil)
        #expect(snap.name == "No game selected")
    }
}
```

- [ ] **Step 3: Register the test file** (same Ruby pattern, `SavedGameProviderTests.swift`), then run to confirm failure:

Run: `xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/SavedGameProviderTests"`
Expected: **FAIL** — `SavedGameSnapshot` not found.

- [ ] **Step 4: Build to make Step 1's type real, then run tests to pass**

Run: `xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/SavedGameProviderTests"`
Expected: **TEST SUCCEEDED**.

- [ ] **Step 5: Fill in `SelectGameIntent.swift`** (widget target):

```swift
import WidgetKit
import AppIntents
import KataGoGameStore

struct SelectGameIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Select Game"
    static let description = IntentDescription("Choose which saved game the widget shows.")

    @Parameter(title: "Game")
    var game: GameEntity?
}
```

- [ ] **Step 6: Fill in `SavedGameProvider.swift`** (widget target):

```swift
import WidgetKit
import SwiftUI
import KataGoGameStore

struct SavedGameEntry: TimelineEntry {
    let date: Date
    let snapshot: SavedGameSnapshot
}

struct SavedGameProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SavedGameEntry {
        SavedGameEntry(date: .now, snapshot: .placeholder)
    }

    func snapshot(for configuration: SelectGameIntent, in context: Context) async -> SavedGameEntry {
        await entry(for: configuration)
    }

    func timeline(for configuration: SelectGameIntent, in context: Context) async -> Timeline<SavedGameEntry> {
        Timeline(entries: [await entry(for: configuration)], policy: .never)
    }

    private func entry(for configuration: SelectGameIntent) async -> SavedGameEntry {
        let snapshot = await MainActor.run {
            SavedGameSnapshot.resolveSnapshot(for: configuration.game, container: SharedModelContainer.shared)
        }
        return SavedGameEntry(date: .now, snapshot: snapshot)
    }
}
```

- [ ] **Step 7: Build both apps (widget compiles against the real provider)**

Run (iOS): `xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug`
Run (macOS): `xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS' -configuration Debug`
Expected: both **BUILD SUCCEEDED**.

- [ ] **Step 8: Commit**

```bash
git add -A "ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/SavedGameSnapshot.swift" "ios/KataGo iOS/KataGoAnytimeWidget" "ios/KataGo iOS/KataGo iOSTests/SavedGameProviderTests.swift" "ios/KataGo iOS/KataGo Anytime.xcodeproj"
git commit -m "feat: widget configuration intent + timeline provider with most-recent fallback"
```

---

### Task 11: Widget view (Small/Medium/Large) + deep-link URL + register the widget

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/GameDeepLink.swift`
- Modify (real content): `ios/KataGo iOS/KataGoAnytimeWidget/SavedGameWidgetView.swift`, `SavedGameWidget.swift`
- Test: `ios/KataGo iOS/KataGo iOSTests/GameDeepLinkTests.swift`

**Interfaces:**
- Produces: `public enum GameDeepLink { static let scheme = "katago-anytime"; public static func url(for id: UUID) -> URL; public static func gameID(from url: URL) -> UUID? }`.

- [ ] **Step 1: Write the failing test** `GameDeepLinkTests.swift`:

```swift
import Testing
import Foundation
import KataGoUICore

struct GameDeepLinkTests {
    @Test func roundTrip_buildsAndParsesGameID() {
        let id = UUID()
        let url = GameDeepLink.url(for: id)
        #expect(url.scheme == "katago-anytime")
        #expect(GameDeepLink.gameID(from: url) == id)
    }

    @Test func gameID_rejectsForeignURLs() {
        #expect(GameDeepLink.gameID(from: URL(string: "file:///tmp/x.sgf")!) == nil)
        #expect(GameDeepLink.gameID(from: URL(string: "katago-anytime://open-game?id=not-a-uuid")!) == nil)
    }
}
```

- [ ] **Step 2: Register the test file** (Ruby pattern, `GameDeepLinkTests.swift`), then run to confirm failure.

Run: `xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/GameDeepLinkTests"`
Expected: **FAIL** — `GameDeepLink` not found.

- [ ] **Step 3: Implement `GameDeepLink.swift`** in `KataGoGameStore`:

```swift
import Foundation

public enum GameDeepLink {
    public static let scheme = "katago-anytime"
    public static let host = "open-game"

    public static func url(for id: UUID) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = host
        c.queryItems = [URLQueryItem(name: "id", value: id.uuidString)]
        return c.url!
    }

    public static func gameID(from url: URL) -> UUID? {
        guard url.scheme == scheme, url.host == host,
              let item = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                  .queryItems?.first(where: { $0.name == "id" }),
              let value = item.value else { return nil }
        return UUID(uuidString: value)
    }
}
```

- [ ] **Step 4: Run the test to pass**

Run: `xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/GameDeepLinkTests"`
Expected: **TEST SUCCEEDED**.

- [ ] **Step 5: Fill in `SavedGameWidgetView.swift`** (widget target):

```swift
import WidgetKit
import SwiftUI
import KataGoGameStore

struct SavedGameWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SavedGameEntry

    private var thumbnail: some View {
        Group {
            if let data = entry.snapshot.thumbnail, let image = decode(data) {
                image.resizable().aspectRatio(contentMode: .fit)
            } else {
                WidgetBoardView(width: entry.snapshot.boardWidth,
                                height: entry.snapshot.boardHeight,
                                blackVertices: entry.snapshot.lastBlackStones,
                                whiteVertices: entry.snapshot.lastWhiteStones)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    var body: some View {
        let snap = entry.snapshot
        Group {
            switch family {
            case .systemSmall:
                VStack(spacing: 4) {
                    thumbnail
                    Text(snap.name).font(.caption).bold().lineLimit(1)
                }
            case .systemLarge:
                VStack(alignment: .leading, spacing: 6) {
                    Text(snap.name).font(.headline).lineLimit(1)
                    thumbnail.frame(maxHeight: .infinity)
                    Text(snap.firstComment).font(.callout).lineLimit(6)
                }
            default: // .systemMedium
                HStack(spacing: 10) {
                    thumbnail
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snap.name).font(.headline).lineLimit(1)
                        Text(snap.firstComment).font(.caption).lineLimit(3)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .widgetURL(snap.gameID.map(GameDeepLink.url(for:)))
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func decode(_ data: Data) -> Image? {
        #if os(macOS)
        NSImage(data: data).map(Image.init(nsImage:))
        #else
        UIImage(data: data).map(Image.init(uiImage:))
        #endif
    }
}
```

- [ ] **Step 6: Replace `SavedGameWidget.swift`** with the real configurable widget (removes the Task 7 placeholder provider/entry):

```swift
import WidgetKit
import SwiftUI

struct SavedGameWidget: Widget {
    let kind = "SavedGameWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind,
                               intent: SelectGameIntent.self,
                               provider: SavedGameProvider()) { entry in
            SavedGameWidgetView(entry: entry)
        }
        .configurationDisplayName("Saved Game")
        .description("Shows a saved game's name, first comment, and board.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
```

- [ ] **Step 7: Build both apps**

Run (iOS): `xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug`
Run (macOS): `xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS' -configuration Debug`
Expected: both **BUILD SUCCEEDED**.

- [ ] **Step 8: Commit**

```bash
git add -A "ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/GameDeepLink.swift" "ios/KataGo iOS/KataGoAnytimeWidget" "ios/KataGo iOS/KataGo iOSTests/GameDeepLinkTests.swift" "ios/KataGo iOS/KataGo Anytime.xcodeproj"
git commit -m "feat: Saved Game widget view (S/M/L) + deep-link URL helpers"
```

---

## Phase 5 — Refresh + deep-link handling

### Task 12: Reload widget timelines when games change

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/Game/GameSplitView.swift`
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/MainWindowController.swift` (or the macOS save/delete path)

**Interfaces:**
- Consumes: `WidgetKit.WidgetCenter.shared.reloadAllTimelines()`.

- [ ] **Step 1: iOS — reload after thumbnail/selection change.** In `GameSplitView.swift`, add `import WidgetKit` to the imports, and in the `.onChange(of: navigationContext.selectedGameRecord)` handler (line ~91) append a reload after `createThumbnail`:

```swift
        .onChange(of: navigationContext.selectedGameRecord) { oldGameRecord, newGameRecord in
            createThumbnail(for: oldGameRecord)
            WidgetCenter.shared.reloadAllTimelines()
            processChange(oldGameRecord: oldGameRecord, newGameRecord: newGameRecord)
        }
```

- [ ] **Step 2: iOS — reload after create/rename/delete.** Find the game create/rename/delete sites (search `modelContext.insert`/`modelContext.delete`/`.name =` in `GameSplitView.swift` and the game-list view). After each mutation that saves, call `WidgetCenter.shared.reloadAllTimelines()`. Run:

Run: `grep -rn "modelContext.delete\|modelContext.insert" "ios/KataGo iOS/KataGo iOS"`

Add the reload call after each such mutation (keep it to game create/delete/rename, not per-move analysis writes).

- [ ] **Step 3: macOS — reload on the equivalent save/delete paths.** In `MainWindowController.swift` add `import WidgetKit` and call `WidgetCenter.shared.reloadAllTimelines()` where the macOS app persists a game thumbnail / creates / deletes / renames a game (mirror the iOS sites). Run:

Run: `grep -rn "thumbnail =\|modelContext\|modelContainer.mainContext" "ios/KataGo iOS/KataGo Anytime Mac"`

- [ ] **Step 4: Build both apps**

Run (iOS): `xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug`
Run (macOS): `xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS' -configuration Debug`
Expected: both **BUILD SUCCEEDED**.

- [ ] **Step 5: Commit**

```bash
git add "ios/KataGo iOS/KataGo iOS/Game/GameSplitView.swift" "ios/KataGo iOS/KataGo Anytime Mac/MainWindowController.swift"
git commit -m "feat: reload widget timelines when games change (iOS + macOS)"
```

---

### Task 13: Register the URL scheme + handle the deep link

**Files:**
- Modify: `ios/KataGo-iOS-Info.plist`
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/Info.plist`
- Modify: `ios/KataGo iOS/KataGo iOS/Game/GameSplitView.swift`
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/AppDelegate.swift`

**Interfaces:**
- Consumes: `GameDeepLink.gameID(from:)` (Task 11), `GameRecord.fetchGameRecords`.

- [ ] **Step 1: Register the scheme in the iOS Info.plist.** In `ios/KataGo-iOS-Info.plist`, add inside the top-level `<dict>`:

```xml
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key>
			<string>chinchangyang.KataGo-iOS.tw.deeplink</string>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>katago-anytime</string>
			</array>
		</dict>
	</array>
```

- [ ] **Step 2: Register the scheme in the macOS Info.plist.** Add the identical `CFBundleURLTypes` block inside `KataGo Anytime Mac/Info.plist`'s top-level `<dict>`.

- [ ] **Step 3: iOS — branch the existing `onOpenURL`.** In `GameSplitView.swift`, change the handler (line ~98) from:

```swift
        .onOpenURL { url in
            importAndSelect(from: url)
        }
```
to:
```swift
        .onOpenURL { url in
            if let id = GameDeepLink.gameID(from: url) {
                selectGame(byID: id)
            } else {
                importAndSelect(from: url)
            }
        }
```

Then add this helper method to the same view (near `importAndSelect`), selecting the matching record so the existing `onChange(of: navigationContext.selectedGameRecord)` drives the rest:

```swift
    @MainActor
    private func selectGame(byID id: UUID) {
        guard let match = try? GameRecord.fetchGameRecords(container: modelContext.container)
            .first(where: { $0.uuid == id }) else { return }
        navigationContext.selectedGameRecord = match
    }
```

(Confirm the view has access to `modelContext` — it uses SwiftData; if it holds `@Environment(\.modelContext) private var modelContext`, this works. If not, add that property.)

- [ ] **Step 4: macOS — handle the URL.** In `AppDelegate.swift`, implement URL handling and select the game in the window controller. Add:

```swift
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let id = GameDeepLink.gameID(from: url) {
                windowController?.selectGame(byID: id)
                return
            }
        }
    }
```

Then add a `selectGame(byID:)` to `MainWindowController` that fetches from `modelContainer` and drives its game selection (mirror how the macOS app selects a game from the sidebar — search `selectedGameRecord` / `useEngine` in `MainWindowController.swift`):

```swift
    @MainActor
    func selectGame(byID id: UUID) {
        guard let match = try? GameRecord.fetchGameRecords(container: modelContainer)
            .first(where: { $0.uuid == id }) else { return }
        // Drive the same selection path the sidebar uses:
        select(gameRecord: match)   // replace with the existing selection method name
    }
```

Run this to find the existing selection method to call:

Run: `grep -rn "func select\|selectedGameRecord\|loadGame" "ios/KataGo iOS/KataGo Anytime Mac/MainWindowController.swift"`

- [ ] **Step 5: Build both apps**

Run (iOS): `xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug`
Run (macOS): `xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS' -configuration Debug`
Expected: both **BUILD SUCCEEDED**.

- [ ] **Step 6: Run the full test suite** (nothing should regress)

Run: `xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: **TEST SUCCEEDED**.

- [ ] **Step 7: Commit**

```bash
git add "ios/KataGo-iOS-Info.plist" "ios/KataGo iOS/KataGo Anytime Mac/Info.plist" "ios/KataGo iOS/KataGo iOS/Game/GameSplitView.swift" "ios/KataGo iOS/KataGo Anytime Mac/AppDelegate.swift" "ios/KataGo iOS/KataGo Anytime Mac/MainWindowController.swift"
git commit -m "feat: katago-anytime:// deep link opens the tapped game (iOS + macOS)"
```

---

## Phase 6 — Verification

### Task 14: Full builds, full tests, and on-device verification

**Files:** none (verification only).

- [ ] **Step 1: Build all three platforms clean**

Run (iOS): `xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug`
Run (visionOS): `xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug`
Run (macOS): `xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS' -configuration Debug`
Expected: all **BUILD SUCCEEDED**, each producing `KataGoAnytimeWidget.appex`.

- [ ] **Step 2: Run the full unit suite**

Run: `xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: **TEST SUCCEEDED**.

- [ ] **Step 3: On-device SwiftData/CloudKit schema verification (CRITICAL — the @Model move).** Install the build on a device/Mac that already has the existing ~584-game library. Verify: (a) all existing games still load with correct names/SGF; (b) the app group store migrated (games visible immediately, not empty); (c) CloudKit sync still works (create a game on one device, it appears on another). If any data is missing, STOP — do not ship; investigate the migration copy and schema identity before proceeding.

- [ ] **Step 4: Manual widget QA on each platform** (widget UI isn't in the CI test plans — record results in the deferred-manual-testing checklist):
  - Add the **Saved Game** widget (Small, Medium, Large) on iOS Home Screen, macOS desktop, visionOS.
  - Before configuring: shows the most-recent game (name + comment + thumbnail).
  - Long-press → Edit Widget → pick a different game → widget updates to it.
  - Tap the widget → the app opens **that** game.
  - Rename the configured game in the app → widget refreshes within a few seconds.
  - Delete the configured game → widget shows the placeholder.
  - A game with no stored thumbnail → widget renders the last position via `WidgetBoardView`.

- [ ] **Step 5: Final commit (docs/checklist update only, if any)**

```bash
git add -A
git commit -m "test: verify Saved Game widget across platforms + CloudKit schema"
```

---

## Notes for the executor

- **Adding a test file to the Xcode test target:** the inline Ruby in Task 5 Step 2 is the template — change only the new filename. All new `*Tests.swift` files must be registered this way or `xcodebuild test` won't see them.
- **Widget process limits:** never import `KataGoUICore`, the C++ bridge, MLX, or the engine from any file under `KataGoAnytimeWidget/` — only `KataGoGameStore` + system frameworks. If a widget file needs a model helper, it belongs in `KataGoGameStore`.
- **macOS App Group nuance:** if the macOS sandbox rejects `group.chinchangyang.KataGo-iOS.tw`, the value may need to be registered in the Developer portal for team `6F82AZ9Z52`; the entitlement string stays the same.
- **Per-platform App Group containers are separate** (iOS device vs Mac): the widget reads its own platform's app-group store, kept in sync with the others via CloudKit. This is expected — no cross-platform local sharing is required.
