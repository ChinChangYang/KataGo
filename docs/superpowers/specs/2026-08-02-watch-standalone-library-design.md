# KataGo Anytime Watch v2.0 — Standalone Game Library

Date: 2026-08-02
Status: Approved (design)

## Problem

The watch app is a live mirror and nothing else. Its only data source is the
`WatchSnapshot` the iPhone pushes over WCSession. With no phone in range the
watch shows either the last cached frame, permanently badged stale, or — if it
has never received one — a dead end:

> **No live session** — Start analysis on your iPhone.

Tester feedback asks for three things:

1. show the game library on the watch when the iPhone is not connected,
2. change which game the watch is showing, and
3. change the position within that game.

## Scope

**In scope.** A read-only game browser on the watch, backed by the watch's own
SwiftData store synced from CloudKit. List games, open one, scrub its moves,
and read whatever analysis the phone already cached for those moves.

**Out of scope.** The watch never writes to the store. It does not record a
scrub position, does not play moves offline, and does not switch the phone's
game. Picking a game on the watch is a watch-local act; the phone keeps doing
whatever it was doing.

Rationale: every write from the watch is a CloudKit merge risk against a store
four other platforms already share, and none of the three feedback items needs
one.

## Where we start from

Facts established by reading the tree, because several of them are
counter-intuitive:

- The watch target's **only** package product dependency is `KataGoGameStore` —
  and that module already contains `GameRecord`, `Config`, and
  `SharedModelContainer`. The `@Model` types are already linked into the watch
  binary. It simply never constructs a `ModelContainer`.
- `KataGo Anytime Watch.entitlements` declares the App Group and **nothing
  else**. There is no iCloud container, no CloudKit service, no
  `aps-environment`.
- `KataGoAnalysisKit` and `GoRulesKit` are Foundation-only, with no `#if os(...)`
  guards anywhere. Both are watchOS-clean today.
- `KataGoAnalysisKit/SgfHeaderScan.swift` already walks an SGF's mainline
  engine-free, extracting board size, komi, rules, and move **colors** — but not
  move coordinates.
- `GoRulesKit/GoGame` is a full rules replayer (captures, liberties, ko,
  suicide, scoring), already trusted by the Messages extension.
- `SharedModelContainer` already has a branch for a phoneless, CloudKit-only
  device: tvOS, with a never-crash open ladder.
- `GameRecord.blackStones` / `whiteStones` are per-move-index GTP vertex strings,
  but they are populated **only for indices the phone actually visited**. A game
  imported from an SGF has only its final position.
- The watch target has no test bundle, so watch logic is untestable unless it
  lives in the shared package.

## Architecture

### The store

`SharedModelContainer` gains a `#if os(watchOS)` branch that reuses the tvOS
never-crash ladder — CloudKit → local-only → in-memory — refactored so both
platforms share it. A watch, like a TV, must degrade to a retryable "iCloud
unavailable" state rather than `fatalError`.

Two deliberate differences from the tvOS branch:

- **Store location**: `Application Support`, not `Library/Caches`. The
  `Library/Caches` choice is a tvOS storage restriction that does not apply to
  watchOS.
- **The store does not live in the App Group container.** The watch
  complication reads two `UserDefaults` keys, never the store, so putting the
  store in a group container buys nothing and carries the documented risk that
  a nil `containerURL` silently disables CloudKit. The App Group *entitlement*
  stays — the complication still needs it.

`LibraryStoreMode` / `EmptyLibraryState` / `LibrarySyncPolicy` — written for the
tvOS empty library — are reused verbatim for the watch's empty and
sync-degraded states.

### Entitlements

`KataGo Anytime Watch.entitlements` gains:

- `com.apple.developer.icloud-container-identifiers` = `iCloud.chinchangyang.KataGo-iOS.tw`
- `com.apple.developer.icloud-services` = `CloudKit`
- `aps-environment` = `development`, so silent CloudKit pushes drive import

The watch **widget** extension's entitlements are unchanged.

### Board at any move

The board is derived from the SGF, not from the cached dictionaries:

```
GameRecord.sgf
  → SgfHeaderScan (extended)      // mainline moves + setup stones
  → GoGame replay                 // captures, permissive
  → GoBoard.gtpVertices(of:)
  → WidgetBoardView
```

This works for every game, including one imported from an SGF where the phone
cached only the final position. The whole chain is Foundation-only, so it is
legal on the watch and testable on the iOS simulator.

Replay is **permissive**: it applies each move and removes captures without
enforcing ko or superko. A recorded game may legitimately contain a position
the configured ruleset would forbid, and rejecting a move mid-replay would
corrupt every later index.

### Review data at that move

Winrate, score lead, best move, and comment come from the record's existing
per-index dictionaries (`winRates`, `scoreLeads`, `bestMoves`, `comments`).
Indices the phone never analyzed show **no numbers** — hidden, not zeroed, so
the watch never invents a value.

Splitting the two sources this way also buys a test: for every index the phone
*did* cache, the pure-Swift replay must reproduce `blackStones`/`whiteStones`
exactly.

### Memory

Every fetch is property-bounded, following the widget-picker pattern, so the
watch never faults in `ownershipWhiteness`, `ownershipScales`, or `thumbnail`.
CloudKit still mirrors those blobs to the watch's **disk**; that is unavoidable
without a schema change, and the `@Model` schema is frozen.

## Code layout

The watch target has no test bundle. Following the visionOS precedent, all
logic lands in the shared package and the views stay thin.

### `KataGoAnalysisKit`

`SgfHeaderScan` gains move coordinates, `AB`/`AW` setup stones, and passes. Its
existing `moveColors` becomes a computed property over the new move array, so
the Safari extension's use of it is unchanged.

### `GoRulesKit`

New `SgfReplay`: scan in, board position at index N out. Checkpoints roughly
every 25 moves so scrubbing backwards in a 300-move game does not replay from
zero on watch hardware.

### `KataGoGameStore`

- The `SharedModelContainer` watchOS branch and the shared-ladder refactor.
- A bounded, newest-first library fetch materializing only `uuid`, `name`,
  `width`, `height`, `lastModificationDate`, `sgf`, capped at the 100 most
  recently modified games.
- **`WatchBoardFrame`** — the seam that makes this tractable. One value type
  carrying board size, black and white vertices, last move, move index and
  count, side to move, optional winrate / score lead / best move / comment, a
  candidate list, and a source discriminator (live-with-staleness vs stored).
  `WatchLiveModel` builds one from a `WatchSnapshot`; the browse model builds
  one from a `GameRecord` plus `SgfReplay`. Both board pages become pure
  functions of a frame, so neither page knows which world it is in and the
  builders are unit-testable from the iOS test target.

### Watch target (views only)

- `WatchRootView` becomes a `NavigationStack` with the library as its root.
- `WatchLibraryPage` (new): pinned live row, game rows, empty and
  sync-degraded states.
- `WatchBrowseModel` (new): `@Observable`; selected game, scrub index, replay,
  frame.
- `WatchBoardPage` / `WatchMovesPage`: refactored to render a `WatchBoardFrame`.
- `WatchLiveModel`: unchanged apart from vending a frame.

### Unchanged

The phone side — `WatchSessionRelay`, `WatchCommandHandler`, `WatchHostGate`,
`WatchSnapshotBuilder` — gains nothing. No new wire messages, which follows
directly from "watch-only, phone untouched". The watch complication keeps
reading its two `UserDefaults` keys.

### Project

The watch target gains `GoRulesKit` as a package product dependency, registered
in the pbxproj via the xcodeproj Ruby gem.

## Behaviour

### Launch

If a snapshot exists — including the one WCSession replays from the previous
session — the stack pushes straight to the live board, preserving today's
zero-tap glance exactly. With no snapshot, the watch lands on the library.

Once the user swipes back to the library, a one-shot latch stops the push from
recurring for the rest of that app session. The latch resets on the next cold
launch, so the glance case is restored every time the app starts fresh.

### Library

| Condition | UI |
|---|---|
| Games present | List, newest first |
| Empty, iCloud healthy | "No games yet" + games sync from your iPhone |
| Empty, iCloud unavailable or degraded rung | `EmptyLibraryState` messaging |
| Store open failed (in-memory rung) | "Storage unavailable", retryable |

A game row shows name, board size, move count, and a relative modification
date. **No board thumbnail** — rows stay cheap, and a board legible at watch
row height would not identify a game any better than its name does. Move count
comes from the SGF scan, computed lazily per visible row and memoized, so
opening the library does not scan a hundred games up front.

The pinned live row appears only while a snapshot exists, resolving its name
from the store via `hostGameID`.

**Collapse rule**: tapping a game row whose uuid matches `hostGameID` routes to
the live mirror, not the offline browser. There is never a stale second view of
the game being played.

Games arriving from CloudKit refresh the list live via
`NSPersistentStoreRemoteChange` with a coalesced trigger — the pattern already
running the Mac's iCloud list.

### Browsing a game

- **Board page**: stones, last-move marker, a `74 / 201` counter, Crown
  scrubbing `0…moveCount`. The Crown here is a plain local index — no debounce,
  no confirm, instant — because there is nothing to confirm. The shared-cursor
  state machine stays exclusive to the live view.
- Winrate bar and score text appear only where the record cached them.
- **Review page**: cached best move, then the stored comment, else "No analysis
  saved for this move."

### Failure handling

- An SGF that fails to scan shows "Can't read this game", not an empty board.
- A game deleted underneath the browser pops back to the library.
- The store never crashes the app; the ladder always yields a container.

## Testing

**`swift test`** (never runs under `xcodebuild test` — must be run separately):

- `SgfHeaderScan` move extraction: passes, `tt`, setup stones, handicap,
  `SZ[w:h]`, variations reduced to mainline.
- `SgfReplay`: captures, snapback, ko recapture, and that replaying from a
  checkpoint equals replaying from zero at every index.

**iOS test target (`KataGo AnytimeTests`)**:

- Differential test: for real records, every cached `blackStones[i]` /
  `whiteStones[i]` equals the replayed position at `i`.
- `WatchBoardFrame` builders from both sources.
- Bounded library fetch.
- Empty-state policy.
- Auto-push latch.

**Build gate**: all five schemes.

**On-wrist QA**: the only real gate for CloudKit-on-watch and WCSession
behaviour.

## Risks

**Provisioning is the most likely to bite.** Adding iCloud to the
`chinchangyang.KataGo-iOS.tw.watchkitapp` App ID needs a local device build with
`-allowProvisioningUpdates` to register the capability, or the next Xcode Cloud
archive fails at export — precisely how the first watch archive failed.

**CloudKit volume.** The frozen schema means ownership and thumbnail blobs
mirror onto the watch's disk regardless. Bounded fetches keep them out of
memory, which is the part that matters, but first sync on a large library will
be slow, and watchOS suspends aggressively enough that it may take several
sessions to complete. There is no fix that does not touch the schema.

**No CI story.** Neither CloudKit-on-watch nor WCSession can be exercised in CI;
a green unit suite and five green schemes cannot catch this class of bug. This
is the same gap that let the build-296 crash through.

**`@Sendable` closures.** Any new ObjC callback closure formed in a `@MainActor`
type — WCSession or CloudKit — must be marked `@Sendable`, or Swift 6 wraps it
in a main-queue assertion that traps when the framework invokes it on its own
queue.
