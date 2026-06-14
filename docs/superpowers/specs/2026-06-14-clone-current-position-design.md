# Clone Current Position — Design

**Date:** 2026-06-14
**Status:** Approved

## Problem

The **Clone** menu item (`PlusMenuView`) makes a full deep copy of the
selected game (`GameRecord.clone()` — full SGF, `currentIndex`, and every
per-index dictionary). There is no way to copy only the line up to the
position the user is currently viewing.

## Goal

Tapping **Clone** opens a dialog offering two options:

1. **Clone Whole Game** — today's behavior, unchanged.
2. **Clone Current Position** — a new game containing only the moves from the
   start up to `gameRecord.currentIndex`; later moves are not included, so the
   user cannot navigate forward to them. Useful for practicing a particular
   position later.

## Background (current behavior)

- `PlusMenuView` (inside `if let gameRecord { … }`) has a Clone `Button` whose
  action is `withAnimation { let new = gameRecord.clone(); modelContext.insert(new); navigationContext.selectedGameRecord = new }`.
- `GameRecord.clone()` (GameRecord.swift:248) deep-copies `sgf`,
  `currentIndex`, the `Config`, and all per-index dictionaries
  (`comments`, `scoreLeads`, `bestMoves`, `winRates`, dead/Schrödinger stone
  dicts, `moves`, `blackStones`, `whiteStones`, `ownershipWhiteness`,
  `ownershipScales`), naming the copy `name + " (copy)"`.
- `GameRecord.clearData(after:)` (GameRecord.swift:285) filters every one of
  those per-index dictionaries to keys `<= index`.
- `currentIndex` is the number of moves played; SGF move indices
  `0..<currentIndex` are the played moves. The stored SGF is a linear
  `printsgf` mainline: `(;<root props>;B[..];W[..];…)`. The bridged
  `SgfCpp`/`SgfHelper` are read-only (no SGF serialization), so truncation is
  done Swift-side.

## Components

### 1. SGF truncation helper (new, pure, unit-tested)

A pure function — e.g. `enum SgfTruncation { static func truncate(_ sgf: String, toMoveCount n: Int) -> String }` (own file `SgfTruncation.swift`, app target).

Algorithm (single left-to-right scan, bracket-aware so comments can't break it):

- Track `inBracket` (toggled on `[` / `]`); inside a bracket, a backslash
  escapes the next char (`\]` is a literal `]`, not a close). Semicolons and
  other delimiters inside `[...]` are ignored.
- Count top-level `;` (those with `inBracket == false`). The 1st top-level `;`
  opens the **root** node; the (k+1)-th opens **move node k**.
- To keep `n` moves: scan until the `(n+2)`-th top-level `;` (the start of
  move `n+1`); truncate the string immediately before it and append `")"`.
  Result: `(` + root node + first `n` move nodes + `)`.
- If the SGF has `<= n` moves (the `(n+2)`-th `;` is never reached), return the
  original string unchanged.
- `n == 0` → keep only the root node → `(;<root props>)`.

Linear SGFs only (the app never saves variations); documented as such.

### 2. `GameRecord.clone(upToMove:)` (new)

```
func clone(upToMove index: Int) -> GameRecord
```

Mirrors `clone()` but: builds the new record with
`sgf = SgfTruncation.truncate(self.sgf, toMoveCount: index)` and
`currentIndex = index`, copying the same per-index dictionaries; then calls
`clearData(after: index)` on the new record to drop per-index data after the
current move. Name remains `name + " (copy)"`. No SwiftData schema change.

### 3. Clone dialog (`PlusMenuView`)

- The Clone `Button` action sets a new `@State private var confirmingClone = true`
  instead of cloning directly.
- A `.confirmationDialog` (attached to `PlusMenuView`, like its existing
  `.sheet`s) presents: **Clone Whole Game** → `gameRecord.clone()`;
  **Clone Current Position** → `gameRecord.clone(upToMove: gameRecord.currentIndex)`;
  **Cancel**. Each clone action runs the existing
  `withAnimation { insert; select }` flow.
- If presenting a dialog immediately after the `Menu` item dismisses proves
  unreliable (the chained present-while-dismissing gotcha seen with the branch
  dialogs), defer the flag set with `Task { @MainActor in confirmingClone = true }`.

## Data flow

Tap Clone → dialog → choose option → build new `GameRecord`
(`clone()` or `clone(upToMove: currentIndex)`) → `modelContext.insert` →
`navigationContext.selectedGameRecord = new`. The Current-Position path differs
only in producing a truncated SGF + trimmed per-index data.

## Edge cases

- `currentIndex == 0` → root-only SGF (empty starting position); valid.
- `currentIndex >= move count` → truncation returns the full SGF; identical to
  Clone Whole Game.
- Passes (`;B[]`) are move nodes and are counted.
- Comments containing `;` or escaped `]` do not break truncation (bracket-aware
  scan).
- An active branch IS honored: "current position" means the line on screen.
  While a branch is active `gameRecord.sgf`/`currentIndex` stay frozen at the
  divergence point, so `GobanState.cloneCurrentPosition(gameRecord:)` clones the
  live `branchSgf` truncated to `branchIndex`. Per-index data (which still
  describes the old mainline) is only valid up to the divergence point, so it is
  trimmed to `min(gameRecord.currentIndex, branchIndex)` — mirroring
  `commitBranch`. Off-branch this reduces to the saved mainline position.

## Testing

- Unit tests (CI-run, `KataGo AnytimeTests`) for `SgfTruncation.truncate`:
  truncate a multi-move SGF to N (keeps root + N move nodes, `SgfHelper(result).moveSize == N`);
  N = 0 → root only; N ≥ move count → unchanged; a comment value containing `;`
  is preserved and doesn't shift the cut; a pass move is counted.
- Unit test for `clone(upToMove:)` (in-memory, like the existing `clearData`
  tests): truncated `sgf`, `currentIndex == index`, per-index dictionaries
  filtered to `<= index`, name has `" (copy)"`.
- Builds on iOS/macOS/visionOS; quick on-device check of the dialog + that the
  cloned current-position game can't navigate past the cloned move.

## Decisions

- Truncate the SGF Swift-side with a bracket-aware string scan (vs. rebuilding
  via `SgfHelper` or an engine round-trip) — synchronous, self-contained, and
  unit-testable in CI.
- Reuse `clearData(after:)` for per-index trimming rather than duplicating the
  filter logic.
- Button labels: **Clone Whole Game** / **Clone Current Position** (tunable).
