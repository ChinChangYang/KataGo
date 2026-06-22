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

Set `isEditing = true` inside `GobanState.commitBranch(gameRecord:)`, immediately before
`deactivateBranch()`:

```swift
public func commitBranch(gameRecord: GameRecord) {
    guard isBranchActive else { return }

    gameRecord.clearData(after: gameRecord.currentIndex)
    gameRecord.sgf = branchSgf
    gameRecord.currentIndex = branchIndex
    gameRecord.lastModificationDate = Date.now
    isEditing = true   // replacing the original game is an explicit edit
    deactivateBranch()
}
```

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

- `KataGoUICore/Sources/KataGoUICore/Model/GobanState.swift` — `commitBranch` (one line).

## Testing

### Unit (shared, `GobanStateBranchTests`)

1. `commitBranchUnlocksEditing` — start locked (`isEditing == false`) with an active
   branch; after `commitBranch`, `isEditing == true`.
2. `deactivateBranchKeepsLocked` (guard for "only this case") — with an active branch and
   `isEditing == false`, `deactivateBranch()` leaves `isEditing == false`.

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
