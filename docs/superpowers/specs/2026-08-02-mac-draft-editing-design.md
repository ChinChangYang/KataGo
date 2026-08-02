# KataGo Anytime Mac — Draft Editing

Date: 2026-08-02
Status: Approved (design)

## Problem

On macOS every board change is written into the live SwiftData object the
instant it happens, and from there it autosaves and syncs to iCloud. There is
no moment at which the user says "yes, keep this". A single stray click on an
unlocked board permanently appends a move to a real saved game on every device
the user owns, and the app offers no way back: Edit ▸ Undo is the text-field
undo, and the Info tab's "Edit…" opens the config editor, not an SGF editor.

This is not hypothetical. It happened during interactive QA of the previous
change: one misplaced click appended a 44th move to a synced 43-move game and
updated its modification date. The only recovery was to replay the original
move by hand and confirm an overwrite.

The write paths that reach the record today:

| Path | Writes |
|------|--------|
| `GobanState.playPendingHumanMove` / `playAIMove` (unlocked) | `clearData(after:)`, then the `printsgf` reply |
| `GameSession.maybeCollectSgf:430` | `sgf`, `currentIndex`, `lastModificationDate` |
| `GobanState.forwardMoves` / `backwardMoves` | `currentIndex`, on plain browsing |
| `GobanState.maybeUpdateAnalysisData` | `winRates`, `scoreLeads`, `bestMoves`, `ownership*` |
| `GobanState.maybeUpdateMoves` | `moves` |
| `MainWindowController.handleStonesReadyChange` | `blackStones`, `whiteStones`, and `mainContext.save()` |
| `CommentView`, `ConfigView`, rename, `commitBranch` | `comments`, `sgf`, `name`, `Config` |

Locked play is already safe: an off-mainline move is copied into
`gobanState.branchSgf` in memory and only `commitBranch` writes it through.
Branch mode is, in effect, a draft mechanism that covers one narrow case.

## Goal

While a game is being edited on macOS it is an unsaved document. Nothing
reaches SwiftData or iCloud until the user saves. Discarding restores the game
exactly as it was on disk.

## Scope

**In scope.** The macOS target only.

**Out of scope.** iOS, tvOS, visionOS and watchOS keep today's behavior
exactly. Merging divergent game trees is explicitly not part of this: conflict
resolution is whole-record.

## Decisions

These were settled during design and are the premises everything below rests
on.

1. **Uniform rule.** While unlocked, nothing reaches the store — the user's
   moves, the AI's replies, and truncations alike. A crash-safe local mirror
   removes the data-loss risk this creates.
2. **Whole-record scope.** The draft covers the SGF line, cursor, `moves`,
   `comments`, `name`, `Config`, and per-index analysis data. While a draft is
   open the saved record is frozen.

   *Covered* and *counted as a change* are two different things: every field
   above lives in the draft and is written through on Save, but only a subset
   of them makes the draft dirty. See `DraftComparator` below.
3. **Prompt at every exit.** Switching games, closing the window, quitting,
   locking a dirty game, and deep links each present Save · Discard · Cancel.
   A consequence: at most one draft is ever open, so the mirror is a single
   file rather than a collection.
4. **New games are unsaved until first Save.** ⌘N produces no library row. It
   still shows the existing New Game sheet first, because board size, komi and
   rules must be fixed before a first move can exist — so the unsaved game
   already carries the name the user typed, and Save needs no naming dialog.
5. **Branch mode stays.** Locked board clicks still start a branch. Mac keeps
   both mechanisms.
6. **Detached draft record.** The draft is a `GameRecord` clone that is never
   inserted into the model context.
7. **Document chrome only.** Window title plus the standard dirty dot, File ▸
   Save ⌘S and File ▸ Revert to Saved. Nothing is added to the toolbar.
8. **A macOS unit-test target** is created for this work.

## Why a detached record

Every write path in the shared package writes into *whatever record it was
handed*. Pointing `navigationContext.selectedGameRecord` at a detached clone
therefore redirects all of them at once — `maybeCollectSgf`,
`playPendingHumanMove`, `playAIMove`, `maybeUpdateAnalysisData`,
`maybeUpdateMoves`, `handleStonesReadyChange`, `CommentView`, `ConfigView` —
with no change to any of them.

The safety property is structural rather than procedural: an object outside the
context cannot be saved or synced no matter what code runs. The existing
`try? mainContext.save()` calls at `MainWindowController.swift:597` and `:1657`
become harmless, because the clone was never registered.

It also makes decision 4 free — an uninserted record *is* "a game not in the
library".

Two alternatives were rejected:

- **Freeze the store** (disable `autosaveEnabled`, withhold `save()`, snapshot
  for revert). Fewest call sites touched, but the invariant becomes "nobody
  calls `save()`", which no one can enforce — two such calls already exist and
  CloudKit merge activity adds more. It also still needs a detached record for
  ⌘N, so both mechanisms end up in the codebase.
- **Value-type document.** Cleanest boundaries and the most testable, but it
  changes the `gameRecord:` parameter type across roughly twenty shared APIs
  and every view on five targets, contradicting the Mac-only scope.

## Components

### New, in the macOS target

- **`GameDraft`** — the draft: a detached `GameRecord` (never inserted), a
  `origin: GameRecord?` (nil while untitled), and the baseline snapshot taken
  when the draft opened.
- **`DraftSnapshot`** — a versioned `Codable` capture of every drafted field
  plus the origin's UUID, with `apply(to:)` for the field-copy at Save and for
  crash restore. The single place the field list is written down.
- **`DraftComparator`** — one pure field-comparison function serving two
  questions. `differs(draft, baseline)` is *dirty*; `differs(origin, baseline)`
  is *conflict*.

  It compares exactly four things: `sgf`, `name`, `comments`, and **every**
  `Config` field. (All of `Config` rather than a hand-picked subset, so the
  list cannot silently drift out of date as settings are added; `Config` holds
  only user-chosen settings, and the rule/komi fields `loadGame` rewrites from
  the SGF are rewritten before a draft opens, never during one.)

  It ignores `currentIndex`, `moves`, `blackStones`, `whiteStones`, `winRates`,
  `scoreLeads`, `bestMoves`, `ownership*`, `lastModificationDate` and
  `thumbnail` — cursor position and derived analysis data — so browsing a game
  or leaving analysis running can never provoke a save prompt.
- **`DraftExitDecision`** — pure mapping from (dirty, requested action) to
  `.proceed` or `.prompt`, and from the user's answer to `.save`, `.discard` or
  `.cancel`.
- **`DraftController`** — owns the `GameDraft`, opens and closes it, debounces
  the mirror file, and exposes `resolvedRecord(_:)`, `isDirty`, `hasConflict`,
  `save()`, `discard()` and the `resolve(then:)` chokepoint.

### Changed, in the macOS target

- **`MainWindowController`** — `saveGame(_:)` and `revertGame(_:)`; window
  title and `isDocumentEdited`; routing `selectGame(_:)`, `selectGame(byID:)`,
  `applyPendingSelection` and window close through `resolve(then:)`;
  `validateMenuItem` disables Allow Editing while a branch is active.
- **`AppDelegate`** — File ▸ Save ⌘S, File ▸ Revert to Saved, and
  `applicationShouldTerminate`.
- **`LibrarySidebarViewController`** — the three identity comparisons at lines
  142, 231 and 274 resolve draft → origin so the correct row stays selected.
- **`LibraryActions`** — `newGame` stops inserting; delete and rename act on
  the origin.
- **`LibraryStore`** — its existing `.NSPersistentStoreRemoteChange` observer
  (line 60) also runs the conflict check.

### Deliberately unchanged

`GobanState`, `GameSession`, `CommentView`, `ConfigView` and
`handleStonesReadyChange`. No file in `KataGoUICore` is modified, which is what
guarantees the other four platforms cannot regress.

## Lifecycle

### Opening

Triggered by the `isEditing` false → true edge — ⌘E, the toolbar lock slot, the
Chart wand, `LinePlotView.swift:219`, and `commitBranch`'s unlock-on-reload.
That edge is already tracked (`lastIsEditing`, `MainWindowController.swift:1541`).

On open: clone the origin detached, capture the baseline, point
`selectedGameRecord` at the clone. **No `loadGame` runs** — the content is
identical, so the engine and board do not move; only object identity changes.

⌘N is the other entry: the New Game sheet as today, then a detached record with
`origin = nil`, selected and loaded.

The draft clone keeps the origin's `uuid` (it is never inserted, so there is no
collision); an untitled draft gets a fresh one.

### While open

Every existing write path writes into the clone. The sidebar row and the widget
keep showing the last saved state, which is correct for a document model. After
each user-content mutation the comparator reruns, driving `isDocumentEdited`
and the debounced mirror write.

### Save (⌘S)

With an origin: apply the snapshot's fields onto it, stamp
`lastModificationDate`, `context.save()`, `libraryStore.refetch()`,
`WidgetCenter.reloadAllTimelines()`, delete the mirror, re-baseline.

Untitled: build a record from the draft, insert it, adopt it as the origin,
then the same tail.

In both cases **the draft object stays live and selected**, so saving never
churns object identity and never reloads the board.

### Discard / Revert to Saved

Drop the clone, reselect the origin, run `loadGame(gameRecord: origin,
previous: draft)` to resync engine and board, delete the mirror. An untitled
draft falls back to the most-recent game via the existing `resolveDrainTarget`
logic, or to the empty state when the library is empty.

### Exit chokepoint

`resolve(then:)` runs the continuation immediately when clean; when dirty it
presents Save · Discard · Cancel, where Cancel abandons the continuation.
Routed through it: `selectGame(_:)`, `selectGame(byID:)`,
`applyPendingSelection`, locking via `toggleEditing`, `windowShouldClose`,
`applicationShouldTerminate` (via `.terminateLater` and
`reply(toApplicationShouldTerminate:)`), and deleting the origin.

### Crash mirror

Roughly one second after any dirty-making change, a versioned file containing
**both the draft and its baseline** is written to
`URL.applicationSupportDirectory` — alongside the `default.store` that
`SharedModelContainer.swift:414` already puts there — as `mac-draft.json`. It
is deleted on Save and on Discard. Writes are atomic, so a crash mid-write
cannot leave a half-file.

The baseline is stored, not just the draft, because a restored draft rests on
an ancestor that may since have gone stale — without it the conflict check
cannot run after a restore.

On launch, if the file is present: "KataGo Anytime has unsaved changes to
*name* — Restore / Discard". Restore re-attaches by origin UUID, or reopens as
untitled if that game is gone.

## Conflict handling

The baseline is the common ancestor, so the same comparator answers both
questions. `differs(origin, baseline)` means another device changed the saved
game while the draft was open. Content comparison is used rather than
`lastModificationDate`, which carries whatever the other device stamped.

Detection runs authoritatively at Save, where it blocks the write, and also
live off the existing coalesced remote-change observer, surfaced non-modally as
the window subtitle ("Changed on another device") so that Save is never an
ambush.

The Save-time sheet names the game and states the difference concretely — the
move count on each side, and when the other device changed it — and offers:

- **Save as New Game** *(default)* — insert the draft as a separate record
  named `<name> (conflicted copy)`, leaving the incoming version untouched.
  Nothing is lost on either side, which is why it is the default. The longer
  suffix is deliberate; `GameRecord.clone()`'s existing `" (copy)"` does not
  explain itself.
- **Overwrite** — apply the draft over the origin. Today's silent behavior,
  now an explicit choice.
- **Cancel** — the draft stays open and dirty so the user can inspect the other
  version first.

Discarding the user's own side is already File ▸ Revert to Saved, so it stays
out of the button row and is named in the sheet body instead.

## Edge cases

- **Branch and draft must never coexist.** Branches form only while locked, so
  the toolbar cannot produce both — but ⌘E can, which would leave two
  independent uncommitted lines with two different commit paths.
  `validateMenuItem` therefore disables Allow Editing while `isBranchActive`.
- **Empty untitled game** — dirty only once it has at least one move or a
  comment, so abandoning a ⌘N immediately does not prompt.
- **Empty-library launch** — `ensureSelectedGameRecord` keeps auto-creating and
  inserting a real record as today. It then loads unlocked, opening a clean
  draft. The boot path is untouched.
- **Origin deleted** — deleting locally routes through `resolve(then:)` first.
  If the origin is `isDeleted` at Save time, Save falls back to the untitled
  path and inserts a new record rather than discarding the work.
- **Auto-play replay** — sets `isEditing = true`, so a draft opens, but it
  replays recorded moves, leaving the SGF unchanged. The comparator reports
  clean, so there is no spurious prompt.
- **Deep report, GIF export, Share** — all read the selected record, which is
  the draft, which is what is on screen. Correct by construction.
- **Widget** — keeps showing the saved game while editing, by design.

## Error handling

- A mirror write that fails is logged and never blocks editing.
- An unreadable or unknown-version mirror at launch is moved aside and treated
  as absent.
- If `context.save()` throws, an alert is presented and the draft stays open
  and dirty. Nothing is discarded on a failed save.

## Risk: long-lived detached `@Model`

The design rests on holding a detached `GameRecord` for a whole editing session
and rendering SwiftUI from it. Precedent exists — `GameRecord.clone(upToMove:)`
mutates a detached record before the caller inserts it
(`GameRecord+SGF.swift:142`), and `LibraryActions.cloneGame` is
create-then-insert — but the long-lived, observed case is new.

This is gated by a spike **before** the rest of the work: create detached,
mutate, observe from a view, snapshot, apply to a stored record, insert later.
The detached clone also needs its own detached `Config`, which the existing
`Config(config:)` copy initializer provides; inserting the record cascades it.

If the spike fails, the fallback is the "freeze the store" approach, and this
design is revisited before any further work.

## Testing

A new **non-hosted** macOS Swift Testing bundle is added to the project and
joined to the `KataGo Anytime Mac` scheme's Test action. Non-hosted matters: a
`TEST_HOST` bundle launches the app for every run, dragging
`SharedModelContainer`/CloudKit, the engine subprocess, and the app-group
preferences path — the three flakiest things on this platform — into the test.
The bundle links `KataGoGameStore` for `GameRecord`/`Config` and adds the pure
draft sources to both targets' Compile Sources. `DraftController` (AppKit,
windows, sheets) stays out of unit tests.

Xcode Cloud runs no tests, so this is a local gate only.

Unit coverage:

- `DraftComparator` as a dirty detector — content fields flip it; cursor and
  analysis data never do; an empty untitled draft is clean; one with a move is
  dirty.
- `DraftComparator` as a conflict detector — origin mutated after baseline
  yields a conflict; untouched does not.
- `DraftSnapshot` round-trip, `apply(to:)` field coverage, and rejection of an
  unknown version.
- The detached-record spike, against an in-memory container.
- `DraftExitDecision` across clean/dirty × switch, close, quit, lock, delete.
- The three conflict outcomes: overwrite leaves one updated record;
  save-as-new leaves two with the origin intact; cancel leaves the draft open
  and dirty.

Regression proof for the other platforms: the existing iOS suite stays green.
No `KataGoUICore` file is modified, so this is a strong guarantee rather than a
hopeful one.

Interactive QA closes with the scenario that prompted this work: unlock a saved
game, click the board, confirm the sidebar's Modified date does **not** change,
then Discard and confirm the game is byte-identical. Plus ⌘S clearing the dot,
switching games prompting, quit prompting, ⌘N creating no row until saved, and
`kill -9` mid-edit followed by a relaunch offering Restore.
