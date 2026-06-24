# Multi-Select Delete for the Game List — Design

**Date:** 2026-06-25
**Platforms:** iOS + visionOS only (the shared `KataGo iOS` SwiftUI target). macOS (AppKit) is out of scope — its NSTableView sidebar already supports native multi-select + delete.

## Goal

Let the user delete several saved games at once. Add a **Select** item to the game-list "dots" (ellipsis) menu. Tapping it enters a selection mode in which each game row shows a leading circle; tapping a row toggles its circle between an empty circle and a filled check. A floating bottom toolbar shows a **Delete (N)** button. Tapping it asks for confirmation, then removes the checked games.

## User Experience

1. In the game list, the user opens the dots menu and taps **Select**.
2. The menu item changes to **Done** (a filled-check symbol); select mode is now active.
3. A leading circle appears on every visible game row.
4. Tapping a row toggles its indicator: empty `circle` ⇄ filled `checkmark.circle.fill`.
5. A floating bottom toolbar appears with a red **Delete (N)** button, where N is the number of checked games. It is disabled when N is 0.
6. Tapping **Delete (N)** presents a confirmation dialog. On confirm, the checked games are deleted, select mode exits, and the widget timelines reload.
7. The user can leave select mode at any time by opening the dots menu and tapping **Done**; this clears all checks without deleting anything.

### Interaction decisions (approved)

- **Tap target:** the whole row is tappable in select mode; the leading circle is the affordance/indicator (not circle-only).
- **Bottom toolbar:** native SwiftUI `.bottomBar` toolbar placement (reads as a floating bottom bar on iOS/iPad/visionOS), not a custom overlay capsule.
- **Other dots-menu items** (New Game, Clone, Import, Share, Delete, Configurations, Developer Mode) remain visible during select mode; they continue to act on the currently-open game.
- **Conveniences:** count badge + disabled-when-empty Delete only. No "Select All"; no special search-filter handling beyond the default below.

## Architecture

Approach: **custom selection state in the existing shared `TopUIState`, with conditional row rendering.** This matches the described UX literally and avoids fighting SwiftUI's selection/navigation coupling — the game `List` already binds its `selection` to a single `GameRecord?` for `NavigationSplitView` navigation, so a second native multi-select `Set` binding via `EditMode` would be fragile on iOS 26. Selection mode is therefore driven by explicit state plus per-row tap handling.

Selection state lives in `TopUIState` because the three participants live in different view subtrees and `TopUIState` is already the established cross-view coordinator for this exact pattern (the single-game `confirmingDeletion` flows through it):

- the dots menu (`PlusMenuView`, in the toolbar) toggles select mode,
- the list (`GameListView` / `GameLinksView`) renders circles and handles taps,
- the bottom toolbar (`GameListToolbar`) shows the Delete button,
- the confirmation dialog + deletion live in `GameSplitView`.

## Components

### 1. `TopUIState` (KataGoUICore — `Model/KataGoModel.swift`)

Add `import SwiftData` (for `PersistentIdentifier`) and:

- `var isSelecting = false` — select mode on/off.
- `var selectedGameIDs: Set<PersistentIdentifier> = []` — checked games, keyed by stable persistent ID so they survive `@Query` refreshes.
- `var confirmingBulkDeletion = false` — drives the new confirmation dialog.
- `func toggle(_ id: PersistentIdentifier)` — insert/remove from the set.
- `func exitSelection()` — `isSelecting = false`, `selectedGameIDs.removeAll()`.
- `var selectionCount: Int { selectedGameIDs.count }`.

### 2. `PlusMenuView` (the dots menu)

Inside the existing `thumbnailModel.isGameListViewAppeared` block (same list-context gate as the thumbnail-size toggle), add one menu item that toggles:

- when `!topUIState.isSelecting`: `Label("Select", systemImage: "checkmark.circle")` → sets `topUIState.isSelecting = true`.
- when `topUIState.isSelecting`: `Label("Done", systemImage: "checkmark.circle.fill")` → calls `topUIState.exitSelection()`.

No other menu items change.

### 3. `GameLinksView` / `GameLinkView` (the rows)

In `GameLinksView.body`, branch per row:

- `topUIState.isSelecting == true`: render a selectable row — `HStack` of the leading indicator image (`checkmark.circle.fill` when `selectedGameIDs.contains(id)`, else `circle`) and the existing `GameLinkView`. Apply `.contentShape(Rectangle())` and `.onTapGesture { withAnimation { topUIState.toggle(record.persistentModelID) } }`. Not a `NavigationLink`, so the tap toggles instead of navigating, and the `List`'s single-selection binding does not fire.
- `topUIState.isSelecting == false`: the existing `NavigationLink(value:) { GameLinkView(...) }`, unchanged.

The `.onDelete` swipe handler is applied only when **not** selecting (avoid two simultaneous delete paths). `GameLinksView` gains `@Environment(TopUIState.self)`.

### 4. `GameListToolbar` (bottom toolbar)

`GameListToolbar` gains `@Environment(TopUIState.self)`. Add a `.bottomBar` `ToolbarItemGroup` shown only when `topUIState.isSelecting`:

```
ToolbarItemGroup(placement: .bottomBar) {
    if topUIState.isSelecting {
        Spacer()
        Button(role: .destructive) { topUIState.confirmingBulkDeletion = true } label: {
            Label("Delete (\(topUIState.selectionCount))", systemImage: "trash")
        }
        .tint(.red)
        .disabled(topUIState.selectionCount == 0)
    }
}
```

(Exact layout/`Spacer` placement finalized in implementation.)

### 5. `GameSplitView` (confirmation + deletion)

Add a second `.confirmationDialog` next to the existing single-game one, bound to `$topUIState.confirmingBulkDeletion`:

- Title: `"Are you sure you want to delete \(topUIState.selectionCount) games? THIS ACTION IS IRREVERSIBLE!"`
- **Delete** (`role: .destructive`): if `navigationContext.selectedGameRecord`'s ID is in the set, set it to `nil` first; call `modelContext.bulkDelete(gameIDs:)`; call `topUIState.exitSelection()`; call `WidgetCenter.shared.reloadAllTimelines()`.
- **Cancel** (`role: .cancel`): dismiss; selection is preserved.

### 6. Deletion seam (KataGoUICore)

```
extension ModelContext {
    @MainActor
    func bulkDelete(gameIDs: Set<PersistentIdentifier>) -> [PersistentIdentifier]
}
```

Resolves each ID via `model(for:)` and deletes the resulting `GameRecord` using the existing `safelyDelete(gameRecord:)` path; ignores IDs that no longer resolve; returns the IDs actually deleted. This is the unit-testable core of the feature.

## Data Flow

```
PlusMenuView "Select"  ─set→  TopUIState.isSelecting = true
GameLinksView rows     ─read→ isSelecting → render circles; tap → TopUIState.toggle(id)
GameListToolbar        ─read→ isSelecting, selectionCount → bottomBar "Delete (N)"
   tap Delete          ─set→  TopUIState.confirmingBulkDeletion = true
GameSplitView dialog   ─Delete→ clear open game if selected
                                 ModelContext.bulkDelete(selectedGameIDs)
                                 TopUIState.exitSelection()
                                 WidgetCenter.reloadAllTimelines()
PlusMenuView "Done" / exitSelection  ─clear→ isSelecting = false, selectedGameIDs = []
```

## Edge Cases

- **Empty selection** → Delete button disabled (`selectionCount == 0`); the dialog cannot be reached.
- **Currently-open game is deleted** → `navigationContext.selectedGameRecord` cleared before deletion, mirroring the existing single-delete and swipe-`.onDelete` behavior.
- **Search filter active** → selection is by stable ID and persists across filtering. A bulk delete removes every checked ID even if some are currently filtered out of view. Accepted (search-filter scoping was explicitly not requested).
- **Leaving the list while selecting** → `GameListView.onDisappear` calls `topUIState.exitSelection()` so select mode and the bottom bar cannot linger as a phantom UI on another screen.
- **Stale persistent IDs** → `bulkDelete` skips IDs that no longer resolve to a model.

## Testing (Swift Testing, in-memory `ModelContainer`)

`ModelContext.bulkDelete(gameIDs:)`:
- deleting a subset removes exactly those records and leaves the rest;
- deleting all checked IDs empties the store;
- an empty set is a no-op and returns `[]`;
- a nonexistent / stale ID is ignored (no crash), and valid IDs alongside it still delete.

`TopUIState`:
- `toggle` adds an absent ID and removes a present one;
- `exitSelection` clears both `selectedGameIDs` and `isSelecting`;
- `selectionCount` reflects the set size.

(View-level interactions — circle rendering, bottom-bar visibility, dialog presentation — are exercised manually; the deletion and state logic carry the automated tests, consistent with the rest of the codebase.)

## Out of Scope

- macOS (AppKit) multi-select.
- "Select All" / "Deselect All".
- Search-filter-scoped selection or deletion.
- Any change to the SwiftData `GameRecord` / `Config` schema (frozen).
