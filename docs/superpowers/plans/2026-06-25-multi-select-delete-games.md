# Multi-Select Delete for the Game List — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user enter a "Select" mode from the game-list dots menu, check multiple games via per-row circles, and bulk-delete them through a floating bottom toolbar with a confirmation dialog.

**Architecture:** Selection state (`isSelecting`, a `Set<PersistentIdentifier>`, and a `confirmingBulkDeletion` flag) lives in the existing shared `TopUIState` `@Observable`. The dots menu toggles select mode; the list renders circles and toggles selection on row tap (instead of navigating); a `.bottomBar` Delete button drives a confirmation dialog in `GameSplitView` that deletes via a new `ModelContext.bulkDelete` seam and reuses the existing widget-reload path.

**Tech Stack:** SwiftUI, SwiftData, Swift Testing, WidgetKit. iOS + visionOS app target (`KataGo_Anytime`) + shared `KataGoUICore` package.

## Global Constraints

- Platforms in scope: **iOS 26+ and visionOS 26+** only (shared SwiftUI app target). macOS is out of scope but the shared package change **must still compile** for macOS.
- **Never modify the SwiftData `@Model` schema** (`GameRecord`, `Config` are frozen). This feature adds none.
- App is **unreleased** — no migration/back-compat code.
- Tests use the **Swift Testing** framework (`import Testing`, `@Test`, `#expect`), not XCTest.
- **No new files** are created — every change edits an existing file, so **no `project.pbxproj` edits are needed**.
- All build/test commands run from the directory `ios/KataGo iOS`.
- Test target name for `-only-testing` is `KataGo AnytimeTests`; use **suite-level** `-only-testing` (per-test filtering has bitten this suite before).
- App target module name (for `@testable import`) is `KataGo_Anytime`.
- Commit messages end with the two footer lines shown in the commit steps.

### Standard commands (referenced by tasks)

Build iOS (from `ios/KataGo iOS`):
```bash
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug
```
Build visionOS:
```bash
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug
```
Build macOS:
```bash
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS' -configuration Debug
```
Run a test suite:
```bash
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/GameRecordTests"
```

---

### Task 1: Selection state on `TopUIState`

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/KataGoModel.swift` (the `TopUIState` class, around lines 699–704)
- Test: `ios/KataGo iOS/KataGo iOSTests/GameRecordTests.swift` (append new `@Test` methods)

**Interfaces:**
- Consumes: nothing (first task). `GameRecordTests.makeInMemoryContainer()` already exists in the test file and returns a `ModelContainer` for `Schema([GameRecord.self, Config.self])`.
- Produces (used by Tasks 3–6):
  - `TopUIState.isSelecting: Bool` (default `false`)
  - `TopUIState.selectedGameIDs: Set<PersistentIdentifier>` (default `[]`)
  - `TopUIState.confirmingBulkDeletion: Bool` (default `false`)
  - `TopUIState.toggle(_ id: PersistentIdentifier)` — inserts the id if absent, removes if present
  - `TopUIState.exitSelection()` — sets `isSelecting = false` and empties `selectedGameIDs`
  - `TopUIState.selectionCount: Int` — `selectedGameIDs.count`

- [ ] **Step 1: Write the failing tests**

Append to `ios/KataGo iOS/KataGo iOSTests/GameRecordTests.swift`, inside the `struct GameRecordTests { ... }` body (before the closing brace):

```swift
    // MARK: - TopUIState multi-select state

    @Test func topUIState_toggle_addsAbsentID() async throws {
        let container = try GameRecordTests.makeInMemoryContainer()
        let context = ModelContext(container)
        let record = GameRecord.createGameRecord(name: "A")
        context.insert(record)
        try context.save()

        let state = TopUIState()
        state.toggle(record.persistentModelID)

        #expect(state.selectedGameIDs.contains(record.persistentModelID))
        #expect(state.selectionCount == 1)
    }

    @Test func topUIState_toggle_removesPresentID() async throws {
        let container = try GameRecordTests.makeInMemoryContainer()
        let context = ModelContext(container)
        let record = GameRecord.createGameRecord(name: "A")
        context.insert(record)
        try context.save()

        let state = TopUIState()
        state.selectedGameIDs = [record.persistentModelID]
        state.toggle(record.persistentModelID)

        #expect(state.selectedGameIDs.isEmpty)
        #expect(state.selectionCount == 0)
    }

    @Test func topUIState_exitSelection_clearsFlagAndSet() async throws {
        let container = try GameRecordTests.makeInMemoryContainer()
        let context = ModelContext(container)
        let a = GameRecord.createGameRecord(name: "A")
        let b = GameRecord.createGameRecord(name: "B")
        context.insert(a)
        context.insert(b)
        try context.save()

        let state = TopUIState()
        state.isSelecting = true
        state.selectedGameIDs = [a.persistentModelID, b.persistentModelID]
        state.exitSelection()

        #expect(state.isSelecting == false)
        #expect(state.selectedGameIDs.isEmpty)
        #expect(state.selectionCount == 0)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run (from `ios/KataGo iOS`):
```bash
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/GameRecordTests" 2>&1 | tail -30
```
Expected: **compile failure** — `value of type 'TopUIState' has no member 'toggle'` / `'selectedGameIDs'` / `'selectionCount'` / `'exitSelection'`.

- [ ] **Step 3: Add the state to `TopUIState`**

In `KataGoModel.swift`, locate the `TopUIState` class:
```swift
@Observable
public class TopUIState {
    public init() {}

    public var importing = false
    public var confirmingDeletion = false
```
Insert immediately after `public var confirmingDeletion = false`:
```swift

    /// True while the game list is in multi-select mode (circles shown per row).
    public var isSelecting = false

    /// Persistent IDs of the games currently checked in multi-select mode.
    /// Keyed by stable persistent ID so the set survives `@Query` refreshes.
    public var selectedGameIDs: Set<PersistentIdentifier> = []

    /// Drives the bulk-deletion confirmation dialog (distinct from the
    /// single-game `confirmingDeletion`).
    public var confirmingBulkDeletion = false

    /// Number of games currently checked.
    public var selectionCount: Int { selectedGameIDs.count }

    /// Toggle one game's membership in the selection.
    public func toggle(_ id: PersistentIdentifier) {
        if selectedGameIDs.contains(id) {
            selectedGameIDs.remove(id)
        } else {
            selectedGameIDs.insert(id)
        }
    }

    /// Leave multi-select mode and clear all checks.
    public func exitSelection() {
        isSelecting = false
        selectedGameIDs.removeAll()
    }
```

(`KataGoModel.swift` already imports SwiftData, so `PersistentIdentifier` is in scope.)

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/GameRecordTests" 2>&1 | tail -30
```
Expected: **PASS** (the three new tests plus the existing `GameRecordTests`).

- [ ] **Step 5: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/KataGoModel.swift" "ios/KataGo iOS/KataGo iOSTests/GameRecordTests.swift"
git commit -m "feat: add multi-select state to TopUIState

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WoQvc49FJf5btyZsHLawb3"
```

---

### Task 2: `ModelContext.bulkDelete` seam

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/GameList/GameListView.swift` (the `extension ModelContext` block, around lines 101–116, where `safelyDelete` lives)
- Test: `ios/KataGo iOS/KataGo iOSTests/GameRecordTests.swift` (append new `@Test` methods)

**Interfaces:**
- Consumes: `GameRecordTests.makeInMemoryContainer()`.
- Produces (used by Task 6):
  - `ModelContext.bulkDelete(gameIDs: Set<PersistentIdentifier>) -> [PersistentIdentifier]` — fetches all `GameRecord`s, deletes those whose `persistentModelID` is in `gameIDs`, returns the IDs actually deleted. Empty input returns `[]`. Stale/unknown IDs are ignored. **Not** `@MainActor` (synchronous; safe to call from the MainActor dialog action and from tests).

- [ ] **Step 1: Write the failing tests**

Append to `ios/KataGo iOS/KataGo iOSTests/GameRecordTests.swift`, inside `struct GameRecordTests`:

```swift
    // MARK: - ModelContext.bulkDelete

    @Test func bulkDelete_subset_removesOnlySelected() async throws {
        let container = try GameRecordTests.makeInMemoryContainer()
        let context = ModelContext(container)
        let a = GameRecord.createGameRecord(name: "A")
        let b = GameRecord.createGameRecord(name: "B")
        let c = GameRecord.createGameRecord(name: "C")
        context.insert(a); context.insert(b); context.insert(c)
        try context.save()

        let deleted = context.bulkDelete(gameIDs: [a.persistentModelID, c.persistentModelID])
        try context.save()

        #expect(Set(deleted) == Set([a.persistentModelID, c.persistentModelID]))
        let remaining = try context.fetch(FetchDescriptor<GameRecord>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.name == "B")
    }

    @Test func bulkDelete_all_emptiesStore() async throws {
        let container = try GameRecordTests.makeInMemoryContainer()
        let context = ModelContext(container)
        let a = GameRecord.createGameRecord(name: "A")
        let b = GameRecord.createGameRecord(name: "B")
        context.insert(a); context.insert(b)
        try context.save()

        let deleted = context.bulkDelete(gameIDs: [a.persistentModelID, b.persistentModelID])
        try context.save()

        #expect(deleted.count == 2)
        let remaining = try context.fetch(FetchDescriptor<GameRecord>())
        #expect(remaining.isEmpty)
    }

    @Test func bulkDelete_emptySet_isNoOp() async throws {
        let container = try GameRecordTests.makeInMemoryContainer()
        let context = ModelContext(container)
        let a = GameRecord.createGameRecord(name: "A")
        context.insert(a)
        try context.save()

        let deleted = context.bulkDelete(gameIDs: [])
        try context.save()

        #expect(deleted.isEmpty)
        let remaining = try context.fetch(FetchDescriptor<GameRecord>())
        #expect(remaining.count == 1)
    }

    @Test func bulkDelete_staleID_isIgnored() async throws {
        let container = try GameRecordTests.makeInMemoryContainer()
        let context = ModelContext(container)
        let a = GameRecord.createGameRecord(name: "A")
        let b = GameRecord.createGameRecord(name: "B")
        context.insert(a); context.insert(b)
        try context.save()

        // Make A's ID stale by deleting A directly first.
        let staleID = a.persistentModelID
        context.delete(a)
        try context.save()

        let deleted = context.bulkDelete(gameIDs: [staleID, b.persistentModelID])
        try context.save()

        #expect(deleted == [b.persistentModelID])
        let remaining = try context.fetch(FetchDescriptor<GameRecord>())
        #expect(remaining.isEmpty)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/GameRecordTests" 2>&1 | tail -30
```
Expected: **compile failure** — `value of type 'ModelContext' has no member 'bulkDelete'`.

- [ ] **Step 3: Implement `bulkDelete`**

In `GameListView.swift`, find:
```swift
extension ModelContext {
    @MainActor
    func safelyDelete(gameRecord: GameRecord) {
        Task {
            // Yield control to prevent potential race conditions caused by
            // simultaneous access to the game record.
            await Task.yield()

            // Perform the deletion of the game record on the main actor to
            // ensure thread safety.
            await MainActor.run {
                delete(gameRecord)
            }
        }
    }
}
```
Add a second method inside the same `extension ModelContext { ... }` block, after `safelyDelete`:
```swift

    /// Delete every `GameRecord` whose persistent ID is in `gameIDs`, returning
    /// the IDs actually deleted. Fetch-and-filter (rather than `model(for:)`) so
    /// stale/unknown IDs are simply skipped. Synchronous: it runs inside the
    /// bulk-delete confirmation action (already on the main actor) — unlike the
    /// swipe path, there's no in-flight list-removal animation to race with, so
    /// the deferred `safelyDelete` hop isn't needed.
    func bulkDelete(gameIDs: Set<PersistentIdentifier>) -> [PersistentIdentifier] {
        guard !gameIDs.isEmpty else { return [] }
        let all = (try? fetch(FetchDescriptor<GameRecord>())) ?? []
        var deleted: [PersistentIdentifier] = []
        for record in all where gameIDs.contains(record.persistentModelID) {
            delete(record)
            deleted.append(record.persistentModelID)
        }
        return deleted
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/GameRecordTests" 2>&1 | tail -30
```
Expected: **PASS** (the four new `bulkDelete` tests plus everything from Task 1).

- [ ] **Step 5: Commit**

```bash
git add "ios/KataGo iOS/KataGo iOS/GameList/GameListView.swift" "ios/KataGo iOS/KataGo iOSTests/GameRecordTests.swift"
git commit -m "feat: add ModelContext.bulkDelete seam for multi-select delete

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WoQvc49FJf5btyZsHLawb3"
```

---

### Task 3: "Select" / "Done" item in the dots menu

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/GameList/PlusMenuView.swift` (inside the `if thumbnailModel.isGameListViewAppeared { ... }` block, around lines 72–84)

**Interfaces:**
- Consumes: `TopUIState.isSelecting` and `TopUIState.exitSelection()` (Task 1). `PlusMenuView` already declares `@Environment(TopUIState.self) var topUIState`.
- Produces: a menu button that sets `topUIState.isSelecting = true` (label "Select") or calls `topUIState.exitSelection()` (label "Done"). No new symbols for later tasks.

This is a UI-only task; its gate is a successful build (the codebase verifies views manually, logic via unit tests). Behavior is verified in Task 7.

- [ ] **Step 1: Add the Select/Done button**

In `PlusMenuView.swift`, find:
```swift
            if thumbnailModel.isGameListViewAppeared {
#if !os(visionOS)
                Divider()
#endif
                Button {
                    withAnimation {
                        thumbnailModel.isLarge.toggle()
                        thumbnailModel.save()
                    }
                } label: {
                    Label(thumbnailModel.title, systemImage: "photo")
                }
            }
```
Replace it with (adds the Select/Done button after the photo toggle, still inside the same block):
```swift
            if thumbnailModel.isGameListViewAppeared {
#if !os(visionOS)
                Divider()
#endif
                Button {
                    withAnimation {
                        thumbnailModel.isLarge.toggle()
                        thumbnailModel.save()
                    }
                } label: {
                    Label(thumbnailModel.title, systemImage: "photo")
                }

                Button {
                    withAnimation {
                        if topUIState.isSelecting {
                            topUIState.exitSelection()
                        } else {
                            topUIState.isSelecting = true
                        }
                    }
                } label: {
                    Label(topUIState.isSelecting ? "Done" : "Select",
                          systemImage: topUIState.isSelecting ? "checkmark.circle.fill" : "checkmark.circle")
                }
            }
```

- [ ] **Step 2: Build to verify it compiles**

Run (from `ios/KataGo iOS`):
```bash
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add "ios/KataGo iOS/KataGo iOS/GameList/PlusMenuView.swift"
git commit -m "feat: add Select/Done toggle to the game-list dots menu

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WoQvc49FJf5btyZsHLawb3"
```

---

### Task 4: Per-row selection circles in the list

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/GameList/GameListView.swift` (the `GameLinksView` struct, lines 13–61)

**Interfaces:**
- Consumes: `TopUIState.isSelecting`, `TopUIState.selectedGameIDs`, `TopUIState.toggle(_:)` (Task 1).
- Produces: in-place selection UI. No new symbols for later tasks.

UI-only task; gate is a successful build. Behavior verified in Task 7.

- [ ] **Step 1: Add the `TopUIState` environment and conditional row rendering**

In `GameListView.swift`, find the `GameLinksView` declaration and its environment block:
```swift
struct GameLinksView: View {
    @Binding var selectedGameRecord: GameRecord?
    @Binding var searchText: String
    @Query var gameRecords: [GameRecord]
    @Environment(\.modelContext) private var modelContext
```
Add the `TopUIState` environment line:
```swift
struct GameLinksView: View {
    @Binding var selectedGameRecord: GameRecord?
    @Binding var searchText: String
    @Query var gameRecords: [GameRecord]
    @Environment(\.modelContext) private var modelContext
    @Environment(TopUIState.self) private var topUIState
```

Then find the `body`:
```swift
    var body: some View {
        ForEach(gameRecords) { gameRecord in
            NavigationLink(value: gameRecord) {
                GameLinkView(gameRecord: gameRecord)
            }
        }
        .onDelete { indexSet in
            for index in indexSet {
                let record = gameRecords[index]
                if selectedGameRecord?.persistentModelID == record.persistentModelID {
                    selectedGameRecord = nil
                }
                modelContext.safelyDelete(gameRecord: record)
            }
            WidgetCenter.shared.reloadAllTimelines()
        }

        if isSearchActive {
            Button("Clear Search") { searchText = "" }
                .tint(.primary)
        }
    }
```
Replace the whole `body` with:
```swift
    var body: some View {
        ForEach(gameRecords) { gameRecord in
            if topUIState.isSelecting {
                selectableRow(for: gameRecord)
            } else {
                NavigationLink(value: gameRecord) {
                    GameLinkView(gameRecord: gameRecord)
                }
            }
        }
        .onDelete(perform: topUIState.isSelecting ? nil : deleteRecords)

        if isSearchActive {
            Button("Clear Search") { searchText = "" }
                .tint(.primary)
        }
    }

    @ViewBuilder
    private func selectableRow(for gameRecord: GameRecord) -> some View {
        let isSelected = topUIState.selectedGameIDs.contains(gameRecord.persistentModelID)
        HStack {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .imageScale(.large)
            GameLinkView(gameRecord: gameRecord)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation {
                topUIState.toggle(gameRecord.persistentModelID)
            }
        }
    }

    private func deleteRecords(at indexSet: IndexSet) {
        for index in indexSet {
            let record = gameRecords[index]
            if selectedGameRecord?.persistentModelID == record.persistentModelID {
                selectedGameRecord = nil
            }
            modelContext.safelyDelete(gameRecord: record)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
```

(`.onDelete(perform:)` accepts an optional closure; passing `nil` disables swipe-to-delete while selecting. The existing delete logic is unchanged — just extracted into `deleteRecords`.)

- [ ] **Step 2: Build to verify it compiles**

Run:
```bash
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add "ios/KataGo iOS/KataGo iOS/GameList/GameListView.swift"
git commit -m "feat: show per-row selection circles in game list select mode

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WoQvc49FJf5btyZsHLawb3"
```

---

### Task 5: Floating bottom Delete toolbar + auto-exit on disappear

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/GameList/GameListView.swift` (the `GameListView` struct, lines 63–99)

**Interfaces:**
- Consumes: `TopUIState.isSelecting`, `TopUIState.selectionCount`, `TopUIState.confirmingBulkDeletion`, `TopUIState.exitSelection()` (Task 1).
- Produces: a `.bottomBar` Delete button that sets `confirmingBulkDeletion = true`; `onDisappear` clears select mode. No new symbols for later tasks.

UI-only task; gate is a successful build. Behavior verified in Task 7.

- [ ] **Step 1: Add the `TopUIState` environment, bottom bar, and onDisappear reset**

In `GameListView.swift`, find the `GameListView` struct header:
```swift
struct GameListView: View {
    @Binding var isEditorPresented: Bool
    @Binding var selectedGameRecord: GameRecord?
    @State var searchText = ""
    @Binding var isGameListViewAppeared: Bool
    @Environment(ThumbnailModel.self) var thumbnailModel
```
Add the `TopUIState` environment line:
```swift
struct GameListView: View {
    @Binding var isEditorPresented: Bool
    @Binding var selectedGameRecord: GameRecord?
    @State var searchText = ""
    @Binding var isGameListViewAppeared: Bool
    @Environment(ThumbnailModel.self) var thumbnailModel
    @Environment(TopUIState.self) private var topUIState
```

Then find the `body`:
```swift
    var body: some View {
        List(selection: $selectedGameRecord) {
            GameLinksView(selectedGameRecord: $selectedGameRecord,
                          searchText: $searchText)
        }
        .navigationTitle("Games")
        .sheet(isPresented: $isEditorPresented) {
            NameEditorView(gameRecord: selectedGameRecord)
        }
        .searchable(text: $searchText)
        .onAppear {
            isGameListViewAppeared = true
            thumbnailModel.isGameListViewAppeared = true
            if let selectedGameRecord {
                // reduces unnecessary updates and filters out unrelated game records when a game is edited.
                searchText = selectedGameRecord.name
            }
        }
        .onDisappear {
            isGameListViewAppeared = false
            thumbnailModel.isGameListViewAppeared = false
        }
        .onChange(of: selectedGameRecord?.name) {
            if let name = selectedGameRecord?.name {
                // reduces unnecessary updates and filters out unrelated game records when a game is edited.
                searchText = name
            }
        }
    }
```
Replace it with (adds the `.toolbar` bottom bar and the `exitSelection()` call in `onDisappear`):
```swift
    var body: some View {
        List(selection: $selectedGameRecord) {
            GameLinksView(selectedGameRecord: $selectedGameRecord,
                          searchText: $searchText)
        }
        .navigationTitle("Games")
        .sheet(isPresented: $isEditorPresented) {
            NameEditorView(gameRecord: selectedGameRecord)
        }
        .searchable(text: $searchText)
        .toolbar {
            if topUIState.isSelecting {
                ToolbarItemGroup(placement: .bottomBar) {
                    Spacer()
                    Button(role: .destructive) {
                        topUIState.confirmingBulkDeletion = true
                    } label: {
                        Label("Delete (\(topUIState.selectionCount))", systemImage: "trash")
                    }
                    .tint(.red)
                    .disabled(topUIState.selectionCount == 0)
                }
            }
        }
        .onAppear {
            isGameListViewAppeared = true
            thumbnailModel.isGameListViewAppeared = true
            if let selectedGameRecord {
                // reduces unnecessary updates and filters out unrelated game records when a game is edited.
                searchText = selectedGameRecord.name
            }
        }
        .onDisappear {
            isGameListViewAppeared = false
            thumbnailModel.isGameListViewAppeared = false
            // Don't let select mode (and its bottom bar) linger if the list goes away.
            topUIState.exitSelection()
        }
        .onChange(of: selectedGameRecord?.name) {
            if let name = selectedGameRecord?.name {
                // reduces unnecessary updates and filters out unrelated game records when a game is edited.
                searchText = name
            }
        }
    }
```

- [ ] **Step 2: Build to verify it compiles (iOS and visionOS)**

Run iOS:
```bash
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | tail -5
```
Run visionOS (confirms `.bottomBar` is valid on visionOS too):
```bash
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug 2>&1 | tail -5
```
Expected: both `** BUILD SUCCEEDED **`. If visionOS rejects `.bottomBar`, wrap the `ToolbarItemGroup(placement: .bottomBar)` block in `#if !os(visionOS)` and use `.bottomOrnament` placement for visionOS instead, then rebuild.

- [ ] **Step 3: Commit**

```bash
git add "ios/KataGo iOS/KataGo iOS/GameList/GameListView.swift"
git commit -m "feat: floating bottom Delete bar for game-list select mode

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WoQvc49FJf5btyZsHLawb3"
```

---

### Task 6: Bulk-delete confirmation dialog

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/Game/GameSplitView.swift` (the `body`, around lines 42–71, next to the existing single-game `confirmingDeletion` dialog)

**Interfaces:**
- Consumes: `TopUIState.confirmingBulkDeletion`, `TopUIState.selectionCount`, `TopUIState.selectedGameIDs`, `TopUIState.exitSelection()` (Task 1); `ModelContext.bulkDelete(gameIDs:)` (Task 2). `GameSplitView.body` already has `@Bindable var topUIState = topUIState`, plus `navigationContext` and `modelContext` in scope, and imports `WidgetKit`.
- Produces: the wired bulk-delete action. Terminal task — no symbols for later tasks.

UI-wiring task; gate is a successful build. Behavior verified in Task 7.

- [ ] **Step 1: Add the bulk-delete confirmation dialog**

In `GameSplitView.swift`, find the existing single-game dialog in `body`:
```swift
        splitView
            .confirmationDialog(
                "Are you sure you want to delete this game? THIS ACTION IS IRREVERSIBLE!",
                isPresented: $topUIState.confirmingDeletion,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let gameRecord = navigationContext.selectedGameRecord {
                        navigationContext.selectedGameRecord = nil
                        modelContext.safelyDelete(gameRecord: gameRecord)
                        WidgetCenter.shared.reloadAllTimelines()
                    }
                }

                Button("Cancel", role: .cancel) {
                    topUIState.confirmingDeletion = false
                }
            }
```
Insert a second `.confirmationDialog` immediately after that one (before `.fileImporter`):
```swift
            .confirmationDialog(
                "Are you sure you want to delete \(topUIState.selectionCount) game\(topUIState.selectionCount == 1 ? "" : "s")? THIS ACTION IS IRREVERSIBLE!",
                isPresented: $topUIState.confirmingBulkDeletion,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    let ids = topUIState.selectedGameIDs
                    // Clear the open game first if it's among those being deleted.
                    if let open = navigationContext.selectedGameRecord,
                       ids.contains(open.persistentModelID) {
                        navigationContext.selectedGameRecord = nil
                    }
                    _ = modelContext.bulkDelete(gameIDs: ids)
                    topUIState.exitSelection()
                    WidgetCenter.shared.reloadAllTimelines()
                }

                Button("Cancel", role: .cancel) {
                    topUIState.confirmingBulkDeletion = false
                }
            }
```

- [ ] **Step 2: Build to verify it compiles**

Run:
```bash
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add "ios/KataGo iOS/KataGo iOS/Game/GameSplitView.swift"
git commit -m "feat: confirm and perform multi-select bulk delete

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WoQvc49FJf5btyZsHLawb3"
```

---

### Task 7: Full verification (all platforms + test suite + manual smoke)

**Files:** none (verification only).

**Interfaces:** Consumes the whole feature.

- [ ] **Step 1: Run the full unit-test suite (iOS Simulator)**

Run (from `ios/KataGo iOS`):
```bash
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`, zero failures (the existing suite plus the 7 new tests from Tasks 1–2).

- [ ] **Step 2: Build all three platforms**

```bash
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | tail -3
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug 2>&1 | tail -3
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS' -configuration Debug 2>&1 | tail -3
```
Expected: three `** BUILD SUCCEEDED **` (the macOS build confirms the shared `TopUIState` change still compiles for macOS).

- [ ] **Step 3: Manual smoke test (iOS Simulator)**

Launch the iOS app and verify the full flow:
1. Dots menu shows **Select**; tapping it enters select mode and the item becomes **Done** (filled check).
2. Every game row shows a leading circle; tapping a row toggles circle ⇄ filled check.
3. The floating bottom **Delete (N)** bar appears; N tracks the checked count; it is disabled at 0.
4. With ≥1 selected, **Delete (N)** opens the confirmation dialog (correct count, singular "game" at N=1); **Cancel** keeps selection; **Delete** removes exactly the checked games, exits select mode, and the list updates.
5. Deleting the currently-open game clears the detail selection.
6. **Done** exits select mode and clears checks without deleting.
7. Swipe-to-delete still works when **not** in select mode and is disabled while selecting.

- [ ] **Step 4: Final no-op commit check**

```bash
git status
```
Expected: clean working tree (all task commits already made; this plan file and the spec were committed earlier). If anything is uncommitted from the manual pass, there should be no code changes — nothing to commit.

---

## Self-Review

**Spec coverage:**
- Select item in dots menu (toggles to Done/check) → Task 3. ✓
- Per-row circle that toggles circle ⇄ check on tap → Task 4. ✓
- Floating bottom Delete toolbar, count badge, disabled when empty → Task 5. ✓
- Confirmation dialog + actual deletion + widget reload → Task 6 (+ `bulkDelete` Task 2). ✓
- Selection state in `TopUIState` → Task 1. ✓
- Edge cases: empty→disabled (Task 5), open-game cleared (Task 6), onDisappear exit (Task 5), stale IDs ignored (Task 2). ✓
- iOS + visionOS only; macOS still compiles → Task 7 Step 2. ✓
- Tests for `bulkDelete` and `TopUIState` → Tasks 1–2. ✓
- No schema change, no new files → honored throughout. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code; every run step shows the command and expected output.

**Type consistency:** `isSelecting`, `selectedGameIDs`, `confirmingBulkDeletion`, `selectionCount`, `toggle(_:)`, `exitSelection()`, and `bulkDelete(gameIDs:) -> [PersistentIdentifier]` are defined in Tasks 1–2 and consumed with identical names/signatures in Tasks 3–6. The bottom-bar label, dialog title, and `.onDelete(perform:)` optional-closure usage all reference only those defined members.
