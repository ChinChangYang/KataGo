# Unlock the game when a branch replaces the original

**Date:** 2026-06-22
**Status:** Approved
**Platforms:** iOS, visionOS, macOS (shared `KataGoUICore`)

## Problem

A branch only ever forms while the game is *locked* (`GobanState.isEditing == false`):
playing an off-mainline move when locked seeds `branchSgf`/`branchIndex`
(`GobanState.swift:375-383`, mirrored in `playAIMove`). While a branch is active the
toolbar replaces the lock button with "Deactivate Branch" (`TopToolbarView.swift:20`),
so the user cannot toggle the lock during a branch.

When the user chooses **Replace** ("Replace the original game with this branch"),
`commitBranch` writes the branch into the saved `GameRecord` but never touches
`isEditing` (`GobanState.swift:468-476`). The game therefore stays **locked** after the
replace.

This is bad UX: choosing to replace the original game is an explicit declaration that
the user wants to *change* the original game. They should land in unlocked (editing)
mode, not be locked back out.

## Goal

When — and only when — the user confirms **Replace the original game with this branch**,
the game becomes unlocked (`isEditing == true`). All other branch exits (Discard,
Deactivate, Cancel) keep the current locked state.

## Design

> **Revision (after runtime verification).** Setting `isEditing = true` inside
> `commitBranch` alone is **not sufficient**. `commitBranch` ends by calling
> `deactivateBranch()`, which flips `branchSgf` to inactive. That transition drives a
> board reload through the shared `GobanState.loadGame(...)` — on iOS via
> `GameSplitView`'s `onChange(of: branchSgf)` → `processChange(oldBranchStateSgf:)`
> (`GameSplitView.swift:104,562`), and on macOS via `MainWindowController`'s branch
> reload observer (`MainWindowController.swift:1901-1914`). `loadGame` is the **last
> writer** of `isEditing` and resets it to `false` for any non-default sgf
> (`GobanState.swift:794-797`), clobbering the unlock. The running app confirmed the
> game stayed locked after Replace. The fix below threads the unlock intent through the
> reload. Because the reload path is shared, this remains a single shared change.

The fix has three parts, all in `GobanState`:

1. A transient intent flag, set by `commitBranch` and consumed by `loadGame`:

```swift
/// Set by commitBranch so the board reload it triggers (via branch
/// deactivation) lands unlocked. Consumed (reset) by loadGame.
public var unlockEditingOnReload = false
```

2. `commitBranch` sets `isEditing = true` (the immediate, no-reload-case intent) **and**
   the flag, before `deactivateBranch()`:

```swift
public func commitBranch(gameRecord: GameRecord) {
    guard isBranchActive else { return }

    gameRecord.clearData(after: gameRecord.currentIndex)
    gameRecord.sgf = branchSgf
    gameRecord.currentIndex = branchIndex
    gameRecord.lastModificationDate = Date.now
    isEditing = true             // immediate unlock (replacing == explicit edit)
    unlockEditingOnReload = true // survive the reload deactivateBranch triggers
    deactivateBranch()
}
```

3. A pure decision helper used by `loadGame`, which reads-and-clears the flag:

```swift
static func editingAfterLoad(sgf: String, unlockRequested: Bool) -> Bool {
    sgf == GameRecord.defaultSgf || unlockRequested
}
```

In `loadGame`, the existing `if newGameRecord.sgf == defaultSgf { isEditing = true } else
{ isEditing = false }` becomes a read-and-clear of the flag plus a call to the helper.
`deactivateBranch` is intentionally **not** changed — it must not clear the flag, since
`commitBranch` sets the flag and then calls `deactivateBranch`. The Discard / Cancel path
(`deactivateBranch` with no commit) never sets the flag, so it stays locked.

### Why this is correct and scoped to "only this case"

- `commitBranch` is invoked from exactly one place per platform — the **Replace**
  confirmation: `GameSplitView.swift:228` (iOS/visionOS) and
  `MainWindowController.swift:1803` (macOS). No other caller exists (verified by grep).
- The Discard, Deactivate, and Cancel paths call only `deactivateBranch()` (or nothing),
  which does not touch `isEditing` — so they correctly remain locked.
- At commit time `isEditing` is guaranteed `false` (branches form only while locked, and
  the lock toggle is hidden during a branch), so this is always a genuine lock→unlock.
- Flipping `isEditing` to `true` is side-effect-free on both platforms. The reactive
  observers only act on the `→false` edge: iOS `processIsEditingChange` guards on
  `if !newIsEditing` (`GameSplitView.swift:352`); the Mac observer guards on
  `if !gobanState.isEditing && lastIsEditing` (`MainWindowController.swift:1287`).

### No UI changes

Once `commitBranch` deactivates the branch, `isBranchActive` becomes `false`, so
`TopToolbarView` re-shows the lock button — now reflecting `isEditing == true`
(open padlock / "Unlock"). The board becomes editable. No view code changes.

## Components affected

- `KataGoUICore/Sources/KataGoUICore/Model/GobanState.swift` — new `unlockEditingOnReload`
  flag; `commitBranch` (sets `isEditing` + flag); new `editingAfterLoad` helper; `loadGame`
  (reads/clears the flag, uses the helper).

## Testing

### Unit (shared, `GobanStateBranchTests`)

1. `commitBranchUnlocksEditing` — active branch + `isEditing == false`; after
   `commitBranch`, `isEditing == true` (immediate, no-reload case).
2. `commitBranchRequestsUnlockOnReload` — after `commitBranch`,
   `unlockEditingOnReload == true` (wiring into the reload).
3. `deactivateBranchKeepsLockState` (guard for "only this case") — `deactivateBranch()`
   leaves `isEditing == false` …
4. `deactivateBranchDoesNotRequestUnlock` — … and leaves `unlockEditingOnReload == false`,
   so the reload it triggers stays locked.
5. `editingAfterLoadDecidesUnlock` — truth table for the load-time decision: default sgf →
   unlocked; non-default + not requested → locked; non-default + requested → unlocked.

### Build

- iOS scheme `KataGo Anytime` (iOS Simulator).
- macOS scheme `KataGo Anytime Mac` (shared file is compiled there too).

### Manual (iOS Simulator, computer-use)

Lock the game → play an off-mainline move (creates a branch) → Deactivate Branch →
Replace → confirm Replace. Verify the lock button shows the unlocked state (open padlock)
and the board is editable. Then repeat with **Discard** and confirm the game stays locked.

## Out of scope / non-goals

- No change to when branches form, to the confirmation dialog wording, or to the
  Discard/Deactivate/Cancel behavior.
- No migration/back-compat work (app is unreleased).
