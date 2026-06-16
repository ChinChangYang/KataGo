# Phase 2 — Mac Library Sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Replace the Mac app's placeholder sidebar with a real **native game Library**: an `NSTableView` of saved games (thumbnail, name, date, first comment) with search, selection that **reloads the board**, full CRUD (New / Clone / Clone-position / Rename / Delete), SGF **import** (open panel, drag-drop, deep-link) and **share** — all backed by the existing SwiftData store + reused package APIs.

**Architecture:** First extract the game-switch **reload** logic out of the iOS `GameSplitView.processChange` into a reusable `GobanState.loadGame(...)` in `KataGoUICore` (so both the iOS view and the Mac sidebar drive the identical reload), then build the AppKit library on top. `navigationContext.selectedGameRecord` stays the single source of truth; selecting a row sets it and calls `loadGame(...)`. SwiftData has no `@Query` in AppKit, so a small `@MainActor LibraryStore` fetches `GameRecord.fetchGameRecords(container:)` and refreshes on context-change notifications (covers CloudKit sync + CRUD). SwiftUI-only affordances are swapped for native ones: `fileImporter`→`NSOpenPanel`, `ShareLink`→`NSSharingServicePicker`, `.confirmationDialog`→`NSAlert`, list selection→`NSTableView` selection.

**Tech Stack:** Swift 6, AppKit (`NSTableView`/`NSTableCellView`/`NSSearchField`/`NSAlert`/`NSOpenPanel`/`NSSharingServicePicker`), SwiftData, the `KataGoUICore` package, `xcodebuild`, the `xcodeproj` gem.

**Out of scope (later phases):** the analysis overlay wiring (Phase 3), inspector tabs (Phase 4), Models/Settings windows (Phase 5), branching/book/AppIntents (Phase 6). Date-section grouping in the sidebar is a nice-to-have; ship a flat, date-sorted list first.

---

## Conventions (every task)
- Run from `cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"`, always pass `-derivedDataPath "DerivedData/KataGo Anytime"`. Sequential xcodebuilds. Grep logs for `** BUILD SUCCEEDED **`/`** TEST SUCCEEDED **`/`warning:`/`error:`. **0 warnings** house rule (force a clean compile when needed — incremental builds hide warnings).
- **iOS regression gate:** build iOS + `xcodebuild test … -testPlan FullTestPlan` (247 unit tests are the reliable gate; the CoreMLCacheFooter engine-launch *UI* tests are known-flaky on a cold-cache sim and never run in CI — don't treat those as regressions).
- **Mac gate:** build `-scheme "KataGo Anytime Mac" -destination 'platform=macOS'`, 0 warnings.
- **Mac visual check:** the committed `KATAGO_MAC_SNAPSHOT=1` affordance renders the SwiftUI board; for the *native* sidebar use `cacheDisplay` of the sidebar VC's view (AppKit, not layer-backed-SwiftUI, so `cacheDisplay` is faithful) OR just rely on build + the iOS-proven reused logic. `screencapture` is TCC-blocked in this env.
- Branch `ios-dev`; commit after each green task; no push. End commit messages with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. Don't stage `Libraries/` or `.derived-data-log-*`.
- Use `trash` not `rm`. pbxproj edits via the `xcodeproj` gem.

---

## File structure (end state)
```
KataGoUICore/Sources/KataGoUICore/Model/
  GobanState.swift                 (+ loadGame(...) extracted reload logic)
KataGo Anytime Mac/
  LibraryStore.swift               NEW @MainActor: fetch + observe GameRecords, search filter
  LibrarySidebarViewController.swift NEW: NSTableView of games + search; selection→loadGame; context menu
  GameRowView.swift                NEW: NSTableCellView (thumbnail + name + date + first comment)
  LibraryActions.swift             NEW: New/Clone/Clone-position/Rename/Delete/Import/Share (package APIs)
  MainSplitViewController.swift     (sidebar item now hosts LibrarySidebarViewController)
  MainWindowController.swift        (toolbar New/Import/Share actions → LibraryActions; game-load on selection)
  AppDelegate.swift                 (application(_:open:) deep-link import; File/Edit menu actions)
KataGo iOS/GameSplitView.swift      (processChange now calls gobanState.loadGame(...))
```

---

## Task 1: Extract `GobanState.loadGame(...)` (reusable game-switch reload) + adopt in iOS

**Files:** modify `KataGoUICore/Sources/KataGoUICore/Model/GobanState.swift` (add `loadGame`), `KataGo iOS/KataGo iOS/GameSplitView.swift` (call it). **Zero iOS behavior change** — move the logic verbatim.

The iOS reload lives in `GameSplitView.processChange(oldGameRecord:newGameRecord:)` (~lines 477–533). It uses the `@Environment` objects `GobanState`, `Turn` (player), `BookLookup`, `MessageList`, `Stones`. Extract its body — EXCEPT the iOS-view-only `createThumbnail(for:)` call (which stays in the `onChange` wrapper) — into:
```swift
// GobanState.swift
public func loadGame(gameRecord newGameRecord: GameRecord?,
                     previous oldGameRecord: GameRecord?,
                     player: Turn,
                     bookLookup: BookLookup,
                     messageList: MessageList,
                     stones: Stones) {
    // VERBATIM body of processChange (minus createThumbnail), using `self` for
    // the gobanState calls: deactivateBranch / clearPendingMove / resetToRoot,
    // book compat (loadIfNeeded / eyeStatus), updateToLatestVersion, isEditing,
    // currentIndex reset + maybeLoadSgf + undo loop, rule sync from SgfHelper,
    // placeLoadingBoard on board-size change, the appendAndSend rule/komi/PDA/
    // wide-root/human-analysis commands, and sendShowBoardCommand.
}
```

- [ ] **Step 1: Green baseline** — iOS build + FullTestPlan. If red, STOP.
- [ ] **Step 2: Add `GobanState.loadGame(...)`** by moving the `processChange` body verbatim (replace `player.` references with the `player` param, `bookLookup`/`messageList`/`stones` with params, `gobanState.X`→`self.X`/`X`). Anything `placeLoadingBoard` does that's view-specific (it sends a board-size/blank-board command sequence — inspect it; if it's pure message-sending it moves in; if it touches a view, parameterize or keep a small hook). Make `loadGame` `public`.
- [ ] **Step 3: iOS `GameSplitView.processChange`** becomes:
```swift
private func processChange(oldGameRecord: GameRecord?, newGameRecord: GameRecord?) {
    gobanState.loadGame(gameRecord: newGameRecord, previous: oldGameRecord,
                        player: player, bookLookup: bookLookup,
                        messageList: messageList, stones: stones)
}
```
(Keep the `onChange` wrapper's `createThumbnail(for: oldGameRecord)` call before it.)
- [ ] **Step 4: iOS build** → SUCCEEDED 0 warnings.
- [ ] **Step 5: iOS FullTestPlan** → TEST SUCCEEDED (behavior gate — `GobanStateBranchTests` etc.).
- [ ] **Step 6: macOS + visionOS builds** → SUCCEEDED.
- [ ] **Step 7: Commit** `refactor(core): extract GobanState.loadGame for reusable game switching`.

**Fallback:** if Step 5 destabilizes iOS and can't be made green, revert the `GameSplitView` change (keep `loadGame` in the package for Mac), report DONE_WITH_CONCERNS noting iOS keeps its own `processChange` (temporary duplication).

---

## Task 2: `LibraryStore` — fetch + observe games for AppKit

**Files:** create `KataGo Anytime Mac/LibraryStore.swift`; register in the Mac target Sources phase (xcodeproj gem).

- [ ] **Step 1: Create `LibraryStore`:**
```swift
@MainActor final class LibraryStore {
    private let container: ModelContainer
    private(set) var games: [GameRecord] = []
    var searchText: String = "" { didSet { applyFilter() } }
    var onChange: (() -> Void)?            // table reloads on this
    private var allGames: [GameRecord] = []
    private var observer: NSObjectProtocol?

    init(container: ModelContainer) {
        self.container = container
        refetch()
        // Re-fetch when SwiftData persists changes (CRUD + CloudKit sync import).
        observer = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refetch() }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func refetch() {
        allGames = (try? GameRecord.fetchGameRecords(container: container)) ?? []
        applyFilter()
    }
    private func applyFilter() {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        games = q.isEmpty ? allGames
                          : allGames.filter { $0.name.localizedStandardContains(q) }
        onChange?()
    }
}
```
(`ModelContext.didSave` is the SwiftData notification name — confirm the exact symbol; if unavailable, observe `Notification.Name("NSManagedObjectContextDidSave")` or call `refetch()` explicitly after each CRUD op + a periodic CloudKit poll. The CRUD tasks also call `refetch()` directly so the list updates immediately regardless.)
- [ ] **Step 2: Build Mac** → SUCCEEDED 0 warnings.
- [ ] **Step 3: Commit** `feat(mac): add LibraryStore (fetch + observe GameRecords)`.

---

## Task 3: `LibrarySidebarViewController` — the NSTableView library

**Files:** create `GameRowView.swift`, `LibrarySidebarViewController.swift`; modify `MainSplitViewController.swift` (host it in the sidebar item), `MainWindowController.swift` (give the sidebar VC the `LibraryStore` + `session`/`navigationContext` + a `loadSelectedGame` hook).

- [ ] **Step 1: `GameRowView: NSTableCellView`** — a view-based cell laying out: an `NSImageView` (from `gameRecord.image` → its `NSImage`; the `image` property returns a SwiftUI `Image` on macOS, so instead read `gameRecord.thumbnail` `Data` → `NSImage(data:)` directly for the cell — add a `public var thumbnailNSImage: NSImage?` accessor to `GameRecord` *(or read `thumbnail` directly since it's public)*), a name label (bold), a date label (`lastModificationDate`, short style), and a first-comment label (`comments?[0]`, secondary, truncated). Auto Layout, `translatesAutoresizingMaskIntoConstraints = false`.
- [ ] **Step 2: `LibrarySidebarViewController: NSViewController`** — an `NSSearchField` (top) + an `NSScrollView`+`NSTableView` (view-based, single column, source-list style). `NSTableViewDataSource`/`Delegate` over `store.games`; `store.onChange = { tableView.reloadData() }`; search field updates `store.searchText`. On `tableViewSelectionDidChange`, set `navigationContext.selectedGameRecord = store.games[selectedRow]` and call the window controller's `loadSelectedGame()` (which calls `session.gobanState.loadGame(gameRecord:previous:player:bookLookup:messageList:stones:)` from Task 1, tracking the previous selection). Restore selection to the currently-selected record on reload.
- [ ] **Step 3: `MainWindowController.loadSelectedGame(previous:)`** — wraps the Task-1 `loadGame` call with the session's collaborators; also used by CRUD when it changes the selection. Replace the launch-time single-game load (`initializeSession`) to route through the same path so first-load and switch-load share code.
- [ ] **Step 4: `MainSplitViewController`** — replace the placeholder sidebar VC with `LibrarySidebarViewController(store:navigationContext:onSelect:)`.
- [ ] **Step 5: Build Mac** → SUCCEEDED 0 warnings. Snapshot the sidebar via `cacheDisplay` (native view, faithful) OR confirm structurally + the board reloads on selection (the reused `loadGame`).
- [ ] **Step 6: Commit** `feat(mac): native library sidebar (NSTableView) with game switching`.

---

## Task 4: CRUD + context menu

**Files:** create `LibraryActions.swift` (or methods on the window/sidebar controller); wire toolbar `New`, the **File** menu (New Game ⌘N), **Edit** (Rename ⏎, Delete ⌫), and a right-click **context menu** on the table.

- [ ] **Step 1: Actions** (each then `store.refetch()` + select the result where appropriate):
  - New: `GameRecord.createGameRecord(maxBoardLength: 19)` → `modelContext.insert` → select + `loadSelectedGame`.
  - Clone: `selected.clone()` → insert → select.
  - Clone current position: `session.gobanState.cloneCurrentPosition(gameRecord: selected)` → insert → select.
  - Rename: present an `NSAlert` with an `NSTextField` accessory (or inline-edit the table cell) → set `selected.name = newName`.
  - Delete: `NSAlert` (destructive confirm) → clear selection → `modelContext.delete(selected)` → refetch. (AppKit is main-thread; the iOS `safelyDelete` async wrap isn't needed — direct `delete`.)
- [ ] **Step 2: Context menu** on the table (`menu(for:)` / `NSMenu`): Clone · Clone Current Position · Rename · Share · Delete, acting on the right-clicked row.
- [ ] **Step 3: Wire** the toolbar `New` (`newGame:`) + File/Edit menu items (replace the Task-3-phase stubs) to these actions via the responder chain.
- [ ] **Step 4: Build Mac** → SUCCEEDED 0 warnings; iOS build still green (no iOS change here).
- [ ] **Step 5: Commit** `feat(mac): library CRUD (new/clone/rename/delete) + context menu`.

---

## Task 5: SGF import + share

**Files:** modify `MainWindowController`/`LibraryActions` (import/share), `AppDelegate` (deep link + Import menu), the sidebar/window view (drag-drop).

- [ ] **Step 1: Import via `NSOpenPanel`** — File ▸ Import… (`importSGF:`, ⌘O): `NSOpenPanel` (allowedContentTypes `[.init(filenameExtension: "sgf")!, .text]`, `allowsMultipleSelection = true`) → for each url `GameRecord.importGameRecord(from: url, in: modelContext)`; insert when `isNew`; select the last; `store.refetch()`.
- [ ] **Step 2: Drag-and-drop** — register the sidebar's `NSTableView` (or the window content) for dragged file URLs (`registerForDraggedTypes([.fileURL])`, implement `draggingEntered`/`performDragOperation`): read each dropped `.sgf`/`.txt` URL via `GameRecord.importGameRecord(from:in:)` → insert/select/refetch.
- [ ] **Step 3: Deep link** — `AppDelegate.application(_:open urls:)` → for each url `GameRecord.importGameRecord(from: url, in: modelContainer.mainContext)` → insert/select via the window controller. (Register the `sgf` document type / `CFBundleDocumentTypes` in Info.plist so the app receives `.sgf` opens.)
- [ ] **Step 4: Share via `NSSharingServicePicker`** — from the context menu / a toolbar Share item: write `selected.sgf` to a temp `"<name>.sgf"` file, then `NSSharingServicePicker(items: [fileURL]).show(relativeTo:of:preferredEdge:)`. (Reuse `TransferableSgf`'s notion but native; a temp `.sgf` file is the shareable item.)
- [ ] **Step 5: Build Mac** → SUCCEEDED 0 warnings. Smoke: import an SGF (open panel / drag) creates + selects a game and the board loads it; share presents the picker.
- [ ] **Step 6: Commit** `feat(mac): SGF import (open panel/drag/deep-link) and share`.

---

## Task 6: Verify + tidy + tag

- [ ] **Step 1:** Cold Mac build (trash DerivedData) → SUCCEEDED, **0 warnings**.
- [ ] **Step 2:** iOS build + FullTestPlan (247 unit tests pass); macOS + visionOS (existing app scheme) build green — the Task-1 `loadGame` extraction must not have regressed iOS.
- [ ] **Step 3:** Mac smoke (manual/snapshot): the sidebar lists games (CloudKit-synced ones appear), search filters, selecting a game **reloads the board to that game's position**, New/Clone/Rename/Delete work, Import (panel + drag) adds a game, Share presents the picker.
- [ ] **Step 4:** Address any accumulated review nits; refresh stale comments. Commit; tag `mac-phase2-library`.

---

## Risks & Mitigations
- **Task 1 iOS extraction is the riskiest** (touches the working `processChange`). Mitigate: verbatim move, FullTestPlan gate, documented fallback. `placeLoadingBoard` may have a view dependency — inspect; if so, keep a thin hook rather than forcing it into the package.
- **SwiftData change observation in AppKit:** `@Query` has no AppKit equivalent. Primary mechanism = `LibraryStore.refetch()` called explicitly after every CRUD op (immediate, deterministic); the `ModelContext.didSave` observer is a secondary net for CloudKit-sync imports. If the notification symbol/behavior is unreliable, rely on explicit refetch + a light timer for sync.
- **CloudKit timing:** synced games may arrive after launch; the `didSave`/remote-change refetch handles late arrivals. Don't insert demo/placeholder records (CloudKit pollution).
- **Selection ↔ load loop:** guard against re-entrancy — only call `loadGame` when the selected record actually changed (track `previous`), and set the table selection programmatically without re-triggering a load.
- **Frozen SwiftData schema:** do not add stored `@Model` fields; a `thumbnailNSImage` accessor (computed) on `GameRecord` is fine (no stored property).
- **Thumbnails:** `GameRecord.image` returns a SwiftUI `Image` on macOS; for an `NSImageView` read the public `thumbnail: Data?` → `NSImage(data:)` directly (no schema change).
