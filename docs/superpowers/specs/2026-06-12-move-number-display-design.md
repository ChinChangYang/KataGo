# Move Number Display Setting — Design

**Date:** 2026-06-12
**Status:** Approved

## Problem

The board always annotates the last three moves with relative 1-2-3 numbers
(parsed from KataGo's `showboard` output). Users cannot choose a different
move-number presentation.

## Goal

Add a global setting that lets the user choose how move numbers are shown:

1. **Last 3 moves** — existing relative 1-2-3 markers (default; current behavior).
2. **Last move** — the absolute game move number (e.g. "57") on the last move only.
3. **All moves** — absolute move numbers on every stone currently on the board.
4. **Marker** — a small red filled dot on the last move, no number.

## Approach

Derive numbering Swift-side from the active game's SGF. The app already holds
the full move history: `GameRecord.sgf` (or `GobanState.branchSgf` when a
branch is active), the active index via `GobanState.getCurrentIndex`, and
`SgfHelper.getMove(at:)` returning each move's `Location` and player. The
existing `BoardPoint(location:width:height:)` initializer converts SGF
locations to board points.

Rejected alternatives:

- **Extend `showboard`/GTP in C++** — touches the fork, complicates upstream
  merges, and the fixed-width board text is hostile to multi-digit numbers.
- **Track history incrementally in Swift** as play/undo commands fire —
  fragile across branch switches, SGF import, and iCloud sync.

## Components

### Setting storage and UI

Follows the existing `stoneStyle` pattern exactly:

- `Config` gains **static constants only** (the SwiftData `@Model` schema is
  frozen — no new stored properties):
  `moveNumberStyles = ["Last 3 moves", "Last move", "All moves", "Marker"]`,
  `defaultMoveNumberStyle = 0`, `defaultMoveNumberStyleText`, plus the
  index↔text helpers mirroring `stoneStyles`.
- `GobanState.moveNumberStyle: Int` with computed conveniences for the
  rendering switch.
- `GlobalPreferenceSync` (GameSplitView.swift) gains
  `@AppStorage("GlobalSettings.moveNumberStyle")` with the standard
  `onAppear` seed + `onChange` write-back pair.
- `GlobalSettingsView`'s **Board** section gains a `ConfigTextPicker`
  ("Move numbers") mirroring the Stone style picker.

### Number derivation

A small pure helper (new file `MoveNumbers.swift`, registered in
`project.pbxproj` via the `xcodeproj` Ruby gem):

- Input: SGF string, current index, board width/height.
- Walk moves `0..<currentIndex` via `SgfHelper.getMove(at:)`, skip passes,
  map each location to `BoardPoint` with number `i + 1`; later moves
  overwrite earlier ones at the same point (ko/recapture shows the latest
  number — standard SGF-editor behavior).
- Output: `[BoardPoint: Int]` plus the last move's point and number.
- Capture handling happens at render time: only points present in
  `stones.blackPoints`/`stones.whitePoints` are drawn, so captured stones
  never show stale numbers.

### Rendering

`MoveNumberView` switches on the style:

- **Last 3 moves** — existing showboard-driven `stones.moveOrder` rendering,
  untouched.
- **Last move** — absolute number on the last move's stone, same text styling
  (monospaced, auto-scaling, contrasting color: white text on black stones,
  black on white).
- **All moves** — numbers on every stone from the derived map, same styling.
- **Marker** — small red filled dot centered on the last move's stone,
  roughly one third of the square size. Red stays visible on both stone
  colors and over the grayscale ownership square, which is drawn beneath
  this view in `BoardView`'s ZStack.

## Data flow

SGF + active index (GobanState) → derivation helper → `[BoardPoint: Int]` →
`MoveNumberView` filters to on-board stones and renders per the selected
style. The 1-2-3 mode keeps its existing showboard → `stones.moveOrder` path.

## Error handling

- Invalid/empty SGF: `SgfHelper` returns no moves → empty map → nothing drawn.
- Index past the move list: `getMove(at:)` returns nil → walk stops naturally.
- Out-of-range stored style index: fall back to the default style (mirrors
  `stoneStyleText`'s guard).

## Testing

Unit tests for the derivation helper: pass moves skipped, ko/recapture
latest-wins, empty SGF, index mid-game (after undo), last-move point/number
correctness. Render-time capture filtering is covered by the on-board-points
filter being part of the view test surface; builds verified on iOS, macOS,
and visionOS.

## Decisions

- "Last move" shows the **absolute** move number (user choice).
- Marker style is a **red filled dot** (user choice, revised on device:
  the original triangle outline — and a corner-offset variant — read
  poorly under/next to the ownership square).
- Default remains the existing 1-2-3 behavior; setting is per-device
  (`@AppStorage`), not synced game config.
