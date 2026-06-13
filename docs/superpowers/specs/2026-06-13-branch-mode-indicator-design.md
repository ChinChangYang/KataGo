# Branch Mode Indicator & Branch Commit — Design

**Date:** 2026-06-13
**Status:** Approved

## Problem

When the user plays a move while viewing game history (without unlocking
editing), the app enters branch mode: the new stones live only in the
engine and `GobanState.branchSgf`; the saved game (`GameRecord.sgf`) is
untouched. The only cue is a small red undo button in the top-right
toolbar — easy to miss, so users may not realize their new stones are
temporary. And the only exit is destructive in one direction: the branch
is always discarded; there is no way to keep it.

## Goal

1. **Indicator** — a red border around the board whenever branch mode is
   active, an always-visible reminder that the newly played stones are
   temporary.
2. **Branch commit** — when the user taps the branch (undo) toolbar
   button, ask whether to replace the original game with the branch or
   discard the branch. Replacing saves the branch line and loses the
   original's moves after the divergence point, per the user's explicit
   choice.

## Background (current behavior)

- Branch activation (`GobanState.playPendingHumanMove`/`playAIMove`):
  when not editing and the played move diverges from the recorded next
  move, `branchSgf = gameRecord.sgf` and `branchIndex =
  gameRecord.currentIndex` are snapshotted; the move goes to the engine
  only.
- While a branch is active, `printsgf` responses update
  `branchSgf`/`branchIndex` (ContentView.maybeCollectSgf), so `branchSgf`
  is the live branch line. `gameRecord.sgf` stays the original, and
  `gameRecord.currentIndex` stays at the divergence point (branch
  navigation moves `branchIndex` instead).
- The toolbar button (TopToolbarView, red
  `arrow.uturn.backward.circle`) sets `confirmingBranchDeactivation`; the
  dialog in GameSplitView offers only "Restore" → `deactivateBranch()`,
  and `onChange(of: branchSgf)` reloads `gameRecord.sgf` into the engine.

## Components

### 1. Red border indicator (BoardView)

In `BoardView`'s ZStack, drawn late (above stones/analysis layers so it
is never obscured): when `gobanState.isBranchActive`, a
`Rectangle().stroke(.red, lineWidth: max(2, squareLength / 16))` with
frame `gobanWidth × gobanHeight`, positioned at the wood image's center
(`gobanStartX + gobanWidth/2`, `gobanStartY + gobanHeight/2`) — the same
geometry `BoardLineView.drawBoardBackground` uses, so the stroke hugs
the board edge exactly. It appears with the first temporary stone and
disappears on replace/discard. Red matches the toolbar button's tint.

### 2. Branch-exit dialog (GameSplitView) — two-stage

Tapping the toolbar button presents a **first** confirmation dialog
(`confirmingBranchDeactivation`):

- Title: "Branch moves are temporary. Replace the original game with
  this branch, or discard it?"
- **Replace Original with Branch** — primary (no `role`, renders in the
  standard tint, not red); sets `confirmingBranchReplace = true`.
- **Discard Branch** (`.destructive`, red); sets
  `confirmingBranchDiscard = true`.
- **Cancel** — dismissed, branch stays active.

Each choice opens a **second**, tailored confirmation dialog so the
irreversible step is always explicitly confirmed:

- `confirmingBranchReplace`: "Replace the original game with this
  branch? The original game's moves after this point will be
  permanently lost." → **Replace Original with Branch** (`.destructive`)
  → `commitBranch`; **Cancel**.
- `confirmingBranchDiscard`: "Discard this branch? Your newly played
  stones will be lost." → **Discard Branch** (`.destructive`) →
  `deactivateBranch()`; **Cancel**.

Two new `GobanState` Bool flags (`confirmingBranchReplace`,
`confirmingBranchDiscard`) drive the second-stage dialogs. `GobanState`
is a plain `@Observable` class (not a SwiftData model), so adding stored
flags is unconstrained. The second-stage `isPresented` flag is set from
the first dialog's button action; on iOS 26 SwiftUI dismisses the first
action sheet and presents the second. (If the second sheet ever fails to
appear on device, the fix is to defer the flag set to the next runloop —
flagged for the on-device check.)

### 3. `GobanState.commitBranch(gameRecord:)`

New function. Guarded no-op unless `isBranchActive` and the branch
fields are valid. Order matters:

1. `gameRecord.clearData(after: gameRecord.currentIndex)` — drops
   per-index analysis data and comments past the divergence point (the
   indices where original and branch lines differ). Runs BEFORE
   `currentIndex` is reassigned.
2. `gameRecord.sgf = branchSgf`
3. `gameRecord.currentIndex = branchIndex`
4. `gameRecord.lastModificationDate = Date.now`
5. `deactivateBranch()`

## Data flow (replace path)

Tap toolbar button → dialog → `commitBranch` → `branchSgf` transitions
active→inactive → existing `onChange(of: branchSgf)` machinery reloads
`gameRecord.sgf` (now the branch line) into the engine at
`currentIndex` (now `branchIndex`) → the user lands exactly where they
were; the border and branch toolbar button disappear; the game list
re-sorts via `lastModificationDate`. No new special-case state; the
redundant engine reload of an identical position is the price of
reusing the proven restore path.

## Semantics and edge cases

- Indices ≤ divergence are identical in both lines, so their analysis
  data and comments remain valid and are kept.
- Redo-ability is preserved: if the user undid within the branch before
  committing, `sgf` extends past `currentIndex` — the same model normal
  navigation uses.
- The original's tail (moves after the divergence) is lost on replace —
  an explicit, twice-confirmed user choice (primary button in stage one,
  destructive confirm in stage two).
- `commitBranch` with no active branch: no-op (guard).
- The toolbar button is already disabled while the AI is generating a
  move; unchanged.
- No SwiftData schema changes: `sgf`, `currentIndex`,
  `lastModificationDate`, and the per-index dictionaries all exist.

## Testing

- Unit tests for `commitBranch` with an in-memory SwiftData container
  (existing `GameRecordTests` precedent): sgf and currentIndex replaced;
  comments/analysis data cleared only past the divergence point; branch
  fields deactivated; no-op when no branch is active.
- Border and dialog: builds on iOS, macOS, visionOS; on-device visual
  check.

## Decisions

- Build both the indicator and the commit feature (user choice).
- Indicator is a plain red stroke (no pulse/glow), dimensioned to the
  wood board rect (user choice).
- Commit reuses the existing deactivation/reload path rather than
  suppressing the reload with a flag — simplicity over saving one
  redundant `loadsgf`.
- Branch-exit dialog is two-stage: **Replace** is the primary (non-red)
  action and **Discard** is red, and *both* require a tailored
  second-stage confirmation (user choice, revised after the first
  single-stage dialog shipped — two equally-red one-tap buttons blurred
  the keep-vs-discard distinction).
