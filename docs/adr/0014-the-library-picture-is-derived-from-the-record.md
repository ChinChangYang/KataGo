# 0014 — The library picture is derived from the record, never captured from the screen

Date: 2026-08-26
Status: Accepted

## Context

Every game row in the library showed a small board, decoded from
`GameRecord.thumbnail` — a persisted, CloudKit-synced `Data?`. Those bytes were
produced by one function, `GameSplitView.createThumbnail(for:)`, which
rasterized **whatever was on screen** into **whichever record it was handed**.

The screen belongs to the session, not to any one game. `board`, `stones` and
`analysis` are process-wide singletons, and the only writer of the stones is
`RecordPositionProjector`. So the pairing of "these pixels" with "that record"
was an assumption held by the caller, and a game switch moves the two halves one
at a time.

ADR 0008 made the board record-owned, and with it made the projection
**synchronous**. That closed the gap the old design had been surviving on. The
capture ran from `.onChange(of: selectedGameRecord)`, a sibling of
`.recordPositionSync` on the same view, keyed on the same change, with no
defined order between them:

```swift
.recordPositionSync(session: session,                                     // projects the INCOMING game
                    gameRecord: navigationContext.selectedGameRecord) { … }
.onChange(of: navigationContext.selectedGameRecord) { oldGameRecord, _ in
    createThumbnail(for: oldGameRecord)                                   // writes to the OUTGOING game
```

When the projector won the race, the singletons already held game B and the
renderer stamped B's board onto A's record — then saved it and exported it to
CloudKit, so every device and the widget inherited the wrong picture. Before ADR
0008 the board lagged the record by a GTP round trip and could not have advanced
in time; the line that broke was eight months older than the line that broke it.

The same function had two further defects with the same root. It could be
reached while a scratch **branch** was active, persisting an unsaved line as the
mainline game's picture — and nothing ever re-captured on leaving branch mode,
so it stayed. And every delete path sets the selection to nil *before* deleting,
so the handler fired for the doomed record; for bulk delete, which deletes
synchronously inside the button closure, that was deterministic rather than a
race.

The codebase already had this exact bug one level down, and had fixed it with a
guard. `RecordStoneCache.write` refuses a write whose key names a different
record, and its doc comment describes the failure verbatim: *"the pairing is an
assumption, not a guarantee… Writing under it would stamp the outgoing game's
position into the incoming game's cache."* A second guard would have been a
second instance of the same tax.

## Decision

**A library picture is a projection of the record, not a capture of the screen.**
`GameRecord.thumbnail` is no longer written; a row derives its board from the
record's own `sgf` at the record's own `currentIndex`.

1. **Nothing to mispair.** The row cannot draw another game's board — not
   because a guard refuses, but because the other game's stones are never in
   reach. Branch contamination and the write-to-a-tombstone both disappear as
   consequences, not as separate fixes: a branch lives on `GobanState.branchSgf`
   and is never in the record, and there is no write left to land on a deleted
   one.
2. **One parser, the C++ one.** Resolution goes through `SgfOperations` +
   `RecordReplayBuilder`, the same path the live board uses, so a row and the
   board can never disagree about one game. The bridge-free `SgfHeaderScan` is
   cheaper and `Sendable` and is deliberately *not* used: it collapses every
   mainline AB/AW/AE into index 0, and two parsers for one game is the class of
   bug this removes.
3. **Geometry comes from the replay**, never from `GameRecord.width`/`height` —
   optional cached fields an import can leave disagreeing with the SGF. A grid
   that disagrees with its own stones is worse than no picture.
4. **Stones, grid, and the last move. Nothing else.** No analysis overlay, no
   move numbers, no coordinates. Those describe the session looking at the game,
   not the game; the overlay in particular made two devices render the same
   record differently, which a synced column could not honestly hold.
5. **Rows stay live views, not rasters.** What is cached is the resolved
   position, so stone style, vertical flip and appearance changes reflow with no
   invalidation logic. Only the two consumers whose APIs demand pixels — Now
   Playing artwork and the share sheet — rasterize, once each.
6. **The cache key is `RecordPositionKey`**, reused rather than invented. It
   carries the SGF *by value*, because a played move rewrites the record's SGF
   in place; that is what makes a row self-invalidating when its game gets a
   move.
7. **The column keeps its old bytes.** The schema is frozen for CloudKit, and no
   healing pass is run: once nothing reads the column, the wrong pictures are
   simply invisible.

## Alternatives rejected

- **Add the `RecordStoneCache` identity guard.** Three lines, the house pattern,
  and correct — but it *refuses* on a switch, so the outgoing game never gets a
  fresh picture. On an iPad with a persistently visible sidebar the one trigger
  that would have refreshed it (the sidebar's `onAppear` edge) never fires
  again after launch, and no programmatic selection — deep link, import, New
  Game, Messages handoff — reveals the list at all. It also leaves the class of
  bug in place for the next writer.
- **Capture the outgoing game before the selection moves.** Preserves the
  picture exactly and removes the race, since nothing has moved yet. But it puts
  a synchronous `ImageRenderer` pass inside a `List` selection setter, and every
  future path that sets the selection must route through it or silently lose the
  capture — of which several already exist.
- **Resolve the write target at write time instead of capture time.** The
  cheapest edit and the worst semantics: it inverts the meaning, refreshing the
  *incoming* game's picture on every switch (dirtying it, and pushing a CloudKit
  change) while the outgoing game — the one the user just left — never updates.
- **Drop the picture from the row.** Removes the bug and a feature with it.

## Consequences

- iOS and macOS rows now render from the record. macOS never *wrote* a
  thumbnail — its rows only ever displayed bytes iOS produced and synced — so
  leaving it on the stored column would have shown a placeholder for every new
  game, forever. It hosts the same board through `NSHostingView`.
- A derived board is O(moves) per cache miss where a stored bitmap was O(1)
  forever, and the expensive half is the parse, not the draw. The list's query
  is unbounded and every realized row re-evaluates on any save, so the cache is
  load-bearing rather than an optimisation, and it is pinned by its own
  benchmark: a screenful of twelve 240-move games resolves in ~11 µs warm
  against ~4 ms per row cold.
- `square.grid.3x3` survives on both platforms with a new meaning. There is no
  "no picture yet" state any more — a readable record always has a position — so
  it now says the record's SGF could not be read, matching the board's own
  `isRecordUnreadable`.
- Taking a picture no longer mutates live state. The old capture instantiated
  `AnalysisView`, whose `.onAppear` clears `Analysis` — so generating a
  thumbnail could wipe the running analysis.
- `ThumbnailModel` stays: it still carries the row's size and the Large/Small
  preference. Only its unread `title` is gone.
- `DraftSnapshot` keeps its `thumbnail` field. It is inert once nothing writes
  the column, and removing it would make a macOS draft Save *erase* a legacy
  game's stored blob — a data change this decision explicitly declines.
- Rows and the board are held to agreement by a test, not by a comment: both
  resolve the same key and must land on the same stones.
- tvOS cards derive too, and they are the reason this list has a follow-up. They
  never held a bitmap — but they resolved their position from the per-index
  `blackStones`/`whiteStones` cache, falling back to the highest *visited* move
  when the cursor had no entry there. Only a host running the position projector
  fills that cache, so a record whose cursor outran it drew a different move on
  Apple TV than on the phone; `GobanState.cloneCurrentPosition` mints exactly
  such a record, parking a new game on the branch tip while trimming the
  dictionaries to the divergence point. They now replay like every other row.
- The **Saved Game widget** is the remaining exception, and it is a linkage
  problem rather than a disagreement about the decision: its appex links only
  `KataGoGameStore` and so cannot reach the C++ parser this ADR standardises on.
  Conforming it means replaying with the bridge-free `GoRulesKit` — already
  proven in the Messages extension and the watch app — under a 30 MB jetsam cap
  the Simulator never enforces, which is its own decision to make.
