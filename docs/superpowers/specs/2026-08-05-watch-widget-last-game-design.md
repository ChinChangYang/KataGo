# Apple Watch widget: the last game's last position

Feedback: *"Redesign widgets. Show name and comments of the last position in the last game."*

Today the watch ships one complication, `ScoreLeadWidget`, that renders a single
number (`B+4.5`) from two App-Group scalars the watch app mirrors while it runs.
This replaces it with a tile that names the game and shows the commentary at the
position that game is parked on.

## Decisions

| Question | Answer |
|---|---|
| Which game is "the last game"? | Whichever is newer: the game the iPhone last mirrored, or the newest game in the watch's library |
| Which position? | Where the game is **parked** (`currentIndex`), not the end of the mainline |
| Widget lineup | **Replace** the single existing complication; keep all three families |
| Freshness | iPhone pushes complication updates to wake the watch app; the design is correct without them |
| Tap target | Deep-link into that game (live mirror if it is the host game, else the saved board) |
| Merge model | Two mirrors, one merged record |
| Deferred comment persistence | **Fix** `CommentView` to flush, rather than document the lag |
| Scope | All five slices, staged |

## Non-goals

- No board thumbnail on the tile. A board beside the text leaves roughly 90 pt of
  text width, which destroys the comment this feature exists to show. The board
  lives behind the tap.
- No `accessoryCorner` family. It is smaller than circular, single-line, and
  system-styled — not a better third slot.
- No configuration intent. The tile always shows the last game; there is nothing
  to pick.
- No change to how the phone or Mac decides `lastModificationDate`.

## Platform constraints that shape everything

These are constraints, not preferences. Without them written down, several wrong
designs look plausible.

1. **The App Group is watch-local.** `group.chinchangyang.KataGo-iOS.tw` is
   entitled on both the iPhone and the watch, which reads as one shared
   container but is not — containers are per-device. Nothing the iPhone writes
   there is visible to the watch widget. The phone→watch path is WatchConnectivity
   only, and **all** App-Group writers must live in the watch app process.
2. **The watch's SwiftData store deliberately has no App Group.**
   `SharedModelContainer.swift:118-124` states the reason: "the watch's only
   second process is the complication, which reads UserDefaults rather than the
   store." An appex that touched `SharedModelContainer.shared` on watchOS would
   take the CloudKit-only branch and open a *second, permanently empty* store.
   **Hard invariant: the watch complication appex contains zero SwiftData/CoreData.**
3. **The watch target has no test bundle.** `KataGo iOSTests` is the only bundle
   covering watch logic; it runs on the iOS Simulator against the iOS host app.
   Anything in the package behind `#if os(watchOS)` is therefore **not compiled**
   by the test target and silently uncovered. Every new pure function must be
   platform-unconditional.
4. **Complication ≠ Smart Stack.** `WCSession.isComplicationEnabled` reflects
   placement on an active watch *face*. A Smart-Stack-only placement leaves it
   false and `remainingComplicationUserInfoTransfers` at 0, so the phone push
   never fires. Correctness must not depend on the push.

## Architecture

### The shared value type

`WatchWidgetSnapshot` lives in **`KataGoAnalysisKit`** — Foundation-only, already
a dependency of `KataGoGameStore` and `@_exported` from it (`AnalysisKitReexport.swift`),
so app-side code needs no import change while the widget links only the light
product.

```swift
public struct WatchWidgetSnapshot: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case live, library }

    public var gameID: String            // NON-optional: a record without one cannot exist
    public var name: String
    public var comment: String?          // nil = no comment at this position
    public var parkedIndex: Int
    public var mainlineMoveCount: Int
    public var scoreLeadBlack: Double?
    public var isBranch: Bool
    public var capturedAt: Date          // watch clock; see "the content key"
    public var source: Source
}
```

Field names are deliberate. `parkedIndex` / `mainlineMoveCount` rather than
`moveCount`, because `GameEntity.moveCount` already holds `currentIndex` under a
misleading name and `WatchSnapshot.moveNumber` means a third thing (stones
placed; passes do not advance it).

Both records ride **one** App-Group key, `watchWidget.records`:

```swift
public struct WatchWidgetRecords: Codable, Equatable, Sendable {
    public var live: WatchWidgetSnapshot?
    public var library: WatchWidgetSnapshot?
}
```

One key, not two: the merge below is per-field, so a torn cross-process read
across two keys could combine one game's index with another game's comment.
Eviction also becomes a single atomic write.

### The content key

`capturedAt` cannot come from `hostTimestamp` or `lastModificationDate`:

- `GameRecord.lastModificationDate` is a plain `Date.now` written by whichever
  device edited (`GobanState.swift:651`, `GameSession.swift:450`,
  `GameRecord+SGF.swift:288`, `GameDraft.swift:118`/`:151`). Comparing it to a
  phone timestamp compares two arbitrary clocks.
- `hostTimestamp` is a 2 Hz heartbeat. `WatchSessionRelay` rebuilds every 500 ms
  and `candidates[].visits` moves on nearly every tick while analysis runs, so a
  phone idling on last Tuesday's game would outrank a Mac session finished
  minutes ago.
- Stamping at write time is worse: `activate()` replays a days-old persisted
  application context through the full `ingest` body (`WatchLiveModel.swift:66-70`),
  and any foreground visit would re-stamp a week-old `rows.first`.

So the merge key is **when the content I am showing last changed**, observed on
the watch, so one clock governs both records:

```swift
public var contentKey: String   // gameID | parkedIndex | name | comment | score rounded to 0.1
```

Rules, all enforced in one `writeLive` / `writeLibrary` chokepoint:

- If the incoming record's `contentKey` equals the stored record's, **keep the
  stored `capturedAt` and skip the write entirely** — no encode, no
  `UserDefaults.set`, no reload.
- Only a key change advances `capturedAt` to `Date()`.
- **Monotonic**: never lower a stored `capturedAt` for the same `gameID`. This is
  what defeats a late-delivered older payload (see "FIFO, not latest-wins").

This also solves, for free, the fact that **a comment edit never moves
`lastModificationDate`** — `CommentView.swift:86,99` writes `comments` and
nothing else, so a comment written on the iPad neither re-sorts the game to the
top of the watch's fetch nor advances any stored timestamp. The content key
advances on a comment change regardless. Bumping `lastModificationDate` in
`CommentView` is explicitly **not** the fix here: it would change library sort
order on every platform and the iOS widget picker's suggested entities. Track
that separately if ever wanted.

### The merge

`WatchWidgetSnapshot.merge(live:library:now:) -> WatchWidgetSnapshot?` is the
tested surface, not a `newer(_:_:)` picker.

1. Either side nil → the other (or nil).
2. **Same `gameID` → merge per field, never pick.** Take
   `name`/`parkedIndex`/`mainlineMoveCount`/`scoreLeadBlack`/`isBranch` from the
   record with the newer `capturedAt`. Resolve `comment` as `newer ?? older`
   **only when both records agree on `parkedIndex`**; when they disagree, use the
   winner's comment alone — a comment from a different index rendered against
   this index is confidently wrong.
   This case is the common one, not an edge: the phone is parked at move 158
   while the watch's CloudKit replica still has `currentIndex` 30, and `comments`
   is sparse for app-played games but dense for imported SGFs
   (`GameRecord+SGF.swift:265` populates it from every `C[]` node).
3. **Different games** → the newer `capturedAt`, except that a `.live` record
   older than **24 h** loses to any `.library` record.

### Writers

All three run in the watch app process (constraint 1). Pure logic lives in the
package; `WidgetCenter` stays in the watch target.

**W1 — live, from `WatchLiveModel.ingest`.** Refuses and leaves the stored record
untouched when:

- `hostGameID == nil`. This is a normal frame, not a malformed one:
  `WatchSnapshotBuilder` fills the host fields only `if let gameRecord`, and
  `WatchSessionRelay` passes an Optional `selectedGameRecord`, so a phone cold
  launch before selection lands pushes exactly this. Without the refusal the tile
  gets a nameless record with a fresh clock that outranks the library.
- The name is still unresolved after backfill.

**Backfill, watch-side.** Rather than trusting the phone's wire fields, the live
writer fills gaps from the library it already has: `name` from
`library.row(id: gameID)?.name` (an O(≤100) lookup), and `comment` from the
library record's `comments[parkedIndex]` when the wire carries none. This makes
the tile correct against **any** phone build, including a v1.2 phone that has no
`gameName`/`positionComment` at all — which matters because watch and phone
update independently on TestFlight and WCSession replays the persisted context
on every cold launch, so one stale frame would otherwise regenerate a blank
record indefinitely.

**Branch suppression.** `GobanState.getCurrentIndex` returns `branchIndex` while
a branch is active, but the saved record's `comments` are mainline-indexed. When
`isBranch`, the live record carries `comment == nil` and the tile hides the "of M"
readout (`mainlineMoveCount` describes a different line).

**W2 — library, after `WatchLibraryStore.refresh()`.**

`refresh()` stays pure. Its header states read-only is "structural, not a
convention", it avoids importing CloudKit so it "stays appex-safe", and
`KataGo iOSTests/WatchLibraryStoreTests.swift` calls it in-process — a
`UserDefaults` write inside it would scribble the real App Group on every test
run. Instead the mirror is a separate type invoked from the two moments that
already own "the library changed": the root launch task and the coalesced
remote-change path (via a new `onRefresh: (() -> Void)?` hook).

Per write:

- Skip a row whose `lastModified == nil` (there is no honest ordering for it, and
  the repo contains an 1846-dated sample record shaped exactly like one).
- Gate the whole thing on an `(id, lastModified)` change so it runs once per real
  library change, not once per refresh — CloudKit's initial sync fires a burst.
- One narrow bounded fetch: `propertiesToFetch = [\.uuid, \.currentIndex, \.comments, \.scoreLeads]`.
  `name` and `lastModified` come from the row you already have; `mainlineMoveCount`
  from the memoized `library.moveCount(for: row)` — **not** from the fetch, because
  it needs `sgf`, and reading a property absent from `propertiesToFetch` faults the
  entire row including the ownership dictionaries and the HEIC thumbnail
  (`WatchBrowseModel.swift` documents this trap).
- Look the comment up with `WatchStoredAnalysis.at(index:…)` — an exact lookup
  that trims and returns nil for blank. Do **not** copy `GameEntity.init`'s
  `keys.max()` fallback; that exists because the iOS widget draws a board and
  faults those dictionaries anyway, and it would label a comment with the wrong
  position.
- Never widen `refresh()`'s own `propertiesToFetch`. Pulling `comments` for 100
  rows undoes the footprint bound its doc comment exists to enforce.

**Eviction.** The library mirror is the only writer that sees both worlds, so it
owns removing a dead live record: if the stored live `gameID` is absent from
`rows`, **and** `rows` is non-empty, **and**
`SharedModelContainer.watchStoreMode == .cloudKit` (so a degraded or in-memory
open cannot mass-evict), clear `live` and reload. Without this, deleting the
mirrored game from the Mac while the iPhone app is closed leaves a dead gameID
with a newer clock on the tile forever, and the tap dead-ends on "Game not found".
Tested as pure `evictingStaleLive(live:libraryIDs:storeMode:)`.

**W3 — background wake.** `.backgroundTask(.watchConnectivity)` on the
`WindowGroup` plus a `nonisolated session(_:didReceiveUserInfo:)`. Touches
WCSession, App-Group `UserDefaults`, and `WidgetCenter` — **never** SwiftData.
Details in "Freshness".

### Reload gate

Today's gate is `guard scoreDelta >= 0.5, elapsed >= 30` (`WatchLiveModel.swift:205`).
Carried forward unchanged, a comment or name change would update the record and
**never render** until something unrelated moved the score by half a point. It is
re-keyed:

```swift
WatchWidgetReloadPolicy.shouldReload(previousKey:nextKey:elapsed:minInterval:)
```

The content key is the trigger; the 30 s interval is purely a floor, never a
required conjunct. A background-wake write bypasses the floor — reloading is the
entire point of the wake.

The same re-keying fixes **write amplification**: the two `defaults?.set` calls
at `WatchLiveModel.swift:200-202` run on *every* ingest, up to 2 Hz. The plan
replaces two scalars with a JSON encode plus a several-hundred-byte `cfprefsd`
transaction, so gating the *write* (not just the reload) on the content key is a
prerequisite, not an inheritance. Treat every write as best-effort — a locked,
off-wrist watch can defer it — and re-run both mirrors unconditionally on the
next `scenePhase == .active`.

### The provider

Single `TimelineEntry`. Policy is a bounded `.after(...)` in the shape of the
existing `WidgetReloadPolicy` (whose doc comment already says verbatim "Replaces
the previous `policy: .never`"), **not** `.never`: a tile showing a three-day-old
sentence with no self-healing path is worse than the number it replaces, because
a stale number reads as a number while a stale sentence reads as truth.

## Presentation

One `Widget`, `kind: "ScoreLeadWidget"` **kept unchanged**, with a comment
explaining why: renaming it orphans every placement testers have made *and*
flips `isComplicationEnabled` to false, silently killing the push path with no
error anywhere. The identifier is hoisted to a single `public static let` in the
shared leaf target so the app-side and widget-side constants cannot drift.

Three user-visible strings change in one edit:
`CFBundleDisplayName` ("KataGo Score"), `.configurationDisplayName` ("Score
Lead"), and `.description`, which is now factually wrong — the library mirror
makes the tile meaningful with the phone asleep.

All three families stay supported; narrowing `supportedFamilies` also drops
placements. But they are **not** three renditions of the same content:

**`accessoryRectangular`** — the family this redesign is for. Two named layouts
chosen by a pure function in the package (same pattern as `WatchBoardTitle`), so
`KataGo iOSTests` can pin the choice:

```
comment present                    comment absent (the DEFAULT)
┌──────────────────────────┐       ┌──────────────────────────┐
│ Ladder Fight 3     B+3.5 │       │ Ladder Fight 3     B+3.5 │
│ 12m ago · Move 42        │       │ Move 42 of 178           │
│ White's cut is the only  │       │ 12m ago                  │
│ move that keeps the …    │       └──────────────────────────┘
└──────────────────────────┘
```

Comment-absent is the **default** layout, not the exceptional one: comments are
sparse at most indices, which is why `WatchStoredGameView` already prints "No
analysis saved for this move". A layout that leaves a large empty region there
reads as a broken widget.

Row 1 is an `HStack` of name (`lineLimit(1)`, `.tail`) | `Spacer` | score
(`.monospacedDigit().layoutPriority(1)` so the **name** yields, not the number).
The comment body gets the remaining height with `.frame(maxHeight: .infinity, alignment: .topLeading)`
and **no `lineLimit`**, so it renders two lines on a small watch and three on a
large one rather than clipping a fixed stack.

> **Required before this is considered done:** probe the real content rect with a
> `GeometryReader` overlay on a **41 mm and a 46 mm** simulator, at default and
> AX1/AX3 text sizes, and record the numbers in a reference memory. Published
> point sizes for these families were not verifiable from this repo; the *shape*
> above (three rows, comment last, comment unclamped) is the design, the exact
> fit is a hypothesis. Widgets do not scroll — overflow is a clip.

**Always-On Display.** Read `\.isLuminanceReduced` and collapse to row 1 plus the
move line, dropping the comment body: a multi-line paragraph at reduced contrast
is unreadable and Apple's guidance is to reduce content. The existing tile needed
no such handling because a bare number needed none.

*Privacy note, stated rather than asked:* this tile puts a game name and a
sentence of commentary permanently on the watch face, legible to anyone glancing
at the wrist. That is the requested feature; it is recorded here because it is a
behavioural change from a score-only tile.

**Render modes.** Encode hierarchy with `.primary` / `.secondary` / `.semibold`
only, never hue — on tinted faces WidgetKit renders `.accented` and replaces
colors with the face's tint, so a "green when Black leads" score would flatten to
two indistinguishable shades. Use `.widgetAccentable()` for emphasis and check a
full-color **and** a tinted face. Build one root
(`VStack(alignment: .leading, spacing: 2) { … }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).containerBackground(.fill.tertiary, for: .widget)`)
with the empty state handled *inside* the `VStack` — today's file applies the
modifier separately in each branch of an if/else around a bare centered `Text`,
which is fine for a numeral and would centre a left-aligned name over a
paragraph.

**`accessoryInline`** — system-rendered: its font, the face's tint, its
truncation. `.font` / `.foregroundStyle` / `.lineLimit` are silently dropped (the
same styling loss the repo already recorded for watchOS navigation titles), and
the slot is shared with the date on several faces. Budget ~20 characters, durable
token **first**, name pre-truncated by the *writer*: `B+4.5 · Ladder Fig…`. No
comment.

**`accessoryCircular`** — an integer score (`B+22`), or the move number when no
score is stored. A signed one-decimal score does not fit above the legibility
floor in the usable inner square. This is a *different* readout, not a compact
rendition of name + comment.

**Degraded states**, three distinct strings, unit-tested in the pure layer:

| State | Tile |
|---|---|
| App Group unavailable (`UserDefaults(suiteName:)` returns nil) | "Storage unavailable" |
| No record yet | "Open KataGo Anytime on your Watch" |
| Record present, any age | Content, with the relative age carrying the signal |

There is no third "too stale to show" state: a real record is always rendered,
and its age is always visible. The age line is `Text(capturedAt, style: .relative)`,
which WidgetKit re-renders on its own without a timeline entry — which is why the
tile stays honest between reloads.

No em-dash or bare whitespace placeholder — that was defensible for a numeric
tile and is not for a text one.

**Legacy cutover.** Immediately after the update the new widget reads a key
nothing has written yet, and the watch app can go days unopened. On a missing or
undecodable `watchWidget.records`, fall back to `watchScoreLeadBlack` /
`watchScoreUpdatedAt` and render the score-only rendition for one release. Add a
one-shot `removeObject(forKey:)` for both legacy keys guarded by a
`didCleanLegacyComplicationKeys` flag; otherwise they survive in the App Group
forever.

## Freshness

**Phone side.** `WatchSnapshot` gains v1.3 optional `gameName`,
`positionComment`, `isBranch` — optional so a persisted v1.2 context still
decodes, exactly as v1.1 and v1.2 were added. `WatchSnapshotBuilder` applies the
shared `cappedComment(_:)` where the string **enters the wire**, not only in the
App-Group record: `WatchSnapshot`'s header pins the frame at "~2 KB typical, hard
test bound 16 KB" for a 2 Hz context and `WatchSnapshotTests` enforces it, while
Commentator output is a full paragraph.

The push is a policy object, `WatchWidgetPushPolicy.shouldPush(previousKey:nextKey:elapsed:minInterval:)`,
with a minimum interval of 5 minutes and the content key as trigger. Transport
**degrades rather than hard-gates**:

- `isComplicationEnabled && remainingComplicationUserInfoTransfers > 0` →
  `transferCurrentComplicationUserInfo`
- otherwise → a rate-limited `transferUserInfo`, still delivered on the next
  watch-app run

Sweep or cancel the previous `WCSessionUserInfoTransfer` before enqueuing the
next.

**FIFO, not latest-wins.** `transferCurrentComplicationUserInfo` queues; re-tagging
a new payload as current leaves the previously-current one in the outstanding
queue. A late-delivered old payload written unconditionally would move the tile
*backward* (move 88 → move 71). The monotonic `capturedAt` rule in `writeLive` is
what makes this safe, and on a background launch the application context is
replayed *as well*, racing with no ordering guarantee.

**Watch side.** Four changes, each independently a bug fix:

1. **`session(_:didReceiveUserInfo:)` is `nonisolated`**, extracts the Sendable
   `Data`, then hops — mirroring `didReceiveApplicationContext`
   (`WatchLiveModel.swift:228-232`). A plainly-declared method on this
   `@MainActor` type traps off-main; the file already documents that
   `EXC_BREAKPOINT` at lines 143-149.
2. **It must never touch `latest`.** `session(_:activationDidCompleteWith:)`
   replays the persisted context only under `guard self.latest == nil`
   (`WatchLiveModel.swift:223`). Setting `latest` from a reduced complication
   payload would permanently suppress the real mirror frame for the process, and
   `sharedCursorAvailable`, `canPlayNow`, `WatchBoardPage` and the launch route
   all bind to it. Enforce structurally: the complication payload sink is a
   separate small type where `self.latest` is not in scope.
3. **Claim the background task.** `.backgroundTask(.watchConnectivity)` on the
   `WindowGroup`; inside, await `WCSession.default.hasContentPending == false`
   and the pending write + reload, then return. Without it nothing holds the
   process alive across the `Task { @MainActor in … }` hop, so the wake can
   produce nothing — and `WKBackgroundTask.h` documents that failing to complete
   background tasks *terminates* the app (0xc51bad01/02/03).
4. **Activation splits, and the store goes lazy.** Registering the delegate at
   `.onAppear` is why background delivery works safely today; moving activation to
   `init()` is required for the wake, and forces two guards:
   - `ingest` plays `WKInterfaceDevice.play(.click)` on any position change while
     `peek.isLive` (`WatchLiveModel.swift:82-87`), which after this change would
     **buzz the wrist on invisible background deliveries**. Gate that haptic — and
     the `.success`/`.failure` ones in `handleReply` / `handleTransportFailure` —
     on `WKApplication.shared.applicationState == .active`. Silent in the simulator.
   - `App.init()` currently builds `WatchLibraryStore(container: SharedModelContainer.shared, …)`
     (`KataGoAnytimeWatchApp.swift:10-16`), which on watchOS opens an
     `NSPersistentCloudKitContainer` with mirroring setup and push registration.
     A wake whose whole job is UserDefaults + WidgetCenter must not pay that.
     Build the store lazily at first UI appearance. Likewise split `activate()`:
     delegate + `WCSession.activate()` + context replay from `init()`; the 5 s
     `isStale` clock task (`WatchLiveModel.swift:71-77`) from the live view's `.task`.

   Also: `WatchRootView`'s launch `.task` runs once per **scene lifetime** and
   `routeOnLaunch()` is one-shot. If the scene is created during a background
   wake, the 2 s grace burns then and the live auto-push never happens when the
   user later raises their wrist. Re-arm the routing decision on the
   background→active transition, guarded by `latchConsumed` so it cannot bounce
   the user off the library mid-session.

**Library freshness on a wake.** The library mirror is *not* invoked from the
wake handler — that path must not touch SwiftData. The `.library` record is
therefore "as of the last time the watch app ran". Stated, not accidental.

## Deep link

**The watch app cannot declare a URL scheme today.** It is
`GENERATE_INFOPLIST_FILE = YES` with four `INFOPLIST_KEY_*` overrides and no
`INFOPLIST_FILE`; `CFBundleURLTypes` is an array of dictionaries with no
`INFOPLIST_KEY_` equivalent. Follow the in-repo precedent (the widget target's
own): `GENERATE_INFOPLIST_FILE = NO` + a real `KataGo Anytime Watch/Info.plist` +
`INFOPLIST_FILE` in **both** configs, carrying the four existing values forward
as real keys — dropping `WKApplication` or `WKCompanionAppBundleIdentifier`
silently breaks pairing — plus `CFBundleURLTypes` for `katago-anytime`. Build and
inspect the resulting `Info.plist` inside the `.app`; do not assume Xcode merges
generated keys into a supplied plist. This also makes `xcrun simctl openurl`
usable, which is otherwise the only way to exercise the route short of a live
complication tap.

**Two coupled failures to fix.**

`routeOnLaunch()` guards only on `path.isEmpty` (`WatchRootView.swift:97-102`)
and the launch task calls it unconditionally after the 2 s grace. A widget tap
that cold-launches is precisely when the deep link must be latched, so
`routeOnLaunch` sees a snapshot, pushes `.live`, and the tap silently opens a
different game. And `.stored(id)` resolves through `library.row(id:)`, a linear
scan of `rows` filled only by `WatchLibraryPage.task` — behind a pushed
destination, capped at 100 rows — so a cold deep link dead-ends on "Game not
found". This coupling is newly load-bearing: `routeOnLaunch` previously only ever
pushed `.live`, which needs no rows.

The fix is one decision point:

- `WatchNavigationPolicy.deepLinkDisposition(pendingGameID:hostGameID:hasSnapshot:libraryHasRow:graceExpired:) -> .wait | .live | .stored(String) | .giveUp`,
  pure, in the package, covered by `WatchNavigationPolicyTests`.
- A single `applyPendingDeepLink()` seam that **always** clears the latch on any
  terminal disposition, invoked from three places (the pattern `VisionRootView`
  already uses): `.onChange(of: pendingGameID, initial: true)`, the end of the
  launch task after the grace loop, and `.onChange(of: model.latest?.hostGameID)`
  for `.wait` re-evaluation.
- `routeOnLaunch()` no-ops while the latch is set.
- Hoist `library.refresh()` + `startObservingRemoteChanges()` into
  `WatchRootView`'s launch task.
- Add `WatchLibraryStore.row(byID:)` — a bounded single-record fetch
  (`#Predicate { $0.uuid == id }`, `fetchLimit = 1`, `propertiesToFetch` including
  `sgf`, which `WatchStoredGameView` needs) so the tap never depends on refresh
  ordering or the 100-row window. Not `GameRecord.resolveDeepLinkTarget`, which
  fetches unbounded with no `propertiesToFetch`.

**Mechanics.**

- Build the URL inline in the widget (a few lines of `URLComponents`, with a
  comment naming `GameDeepLink` as the source of truth) rather than linking
  `GameDeepLink`, which reaches `SharedModelContainer.appGroupID`.
- Never force-unwrap in an appex. `GameDeepLink.url(for:)` takes a non-optional
  `UUID` and force-unwraps its `URLComponents`; the widget's own builder takes the
  record's `String` id and returns `URL?`, so an unbuildable URL yields *no*
  `widgetURL` rather than a crash or a placeholder — the shape
  `SavedGameWidgetView.swift:279` already uses. No `widgetURL` on `placeholder(in:)`.
- Store `GameDeepLink.gameID(from: url)?.uuidString` in the latch, never the raw
  query value — `WatchRoute.stored` ids are uppercase and `UUID(uuidString:)`
  accepts either case.
- A warm deep link **assigns** `path = [route]`, never appends: the app is often
  already at `[.live]`, and appending yields `[.live, .stored(id)]`, so back-swipe
  lands on the live mirror and `latchConsumed` never sets.
- Writing an *equal* id fires no `.onChange` — and this tile points at one game at
  a time, so same-id repeat taps are the normal interaction. The latch must handle
  that.
- `.onOpenURL` ignores anything `gameID(from:)` cannot parse; the same scheme also
  carries `import-sgf`.
- One `widgetURL` at the root of each family's rendition. `Link` is unsupported in
  watchOS accessory widgets, so there is exactly one tap target — and because the
  URL and the rendered content come from the same entry, a stale tile always opens
  the game it is showing.

## The `CommentView` flush fix

`CommentView` holds the live text in `@State` and writes it to the record only on
`.onDisappear` (`CommentView.swift:99`) or an index change (line 86).
`wandAndSparklesAction()` assigns the generated paragraph straight into that
`@State` (lines 124, 127) — it never reaches `gameRecord.comments` at generation
time. Every comment source in this design reads that dictionary, so the tile
would show blank or stale text for exactly the position the user just commented
on, then silently correct itself minutes later.

Fix: flush into `gameRecord.comments[currentIndex]` when generation completes,
and on a short typing debounce. Self-contained, with its own test, and it makes
the widget-visible state match what is on the phone screen. It also removes the
push-churn concern — a comment written once is one content-key change, not one
per streamed token.

This lands as its own slice, independent of everything else.

## Edge cases

| Case | Behaviour |
|---|---|
| Frame with `hostGameID == nil` | Live write refused; stored record survives |
| v1.2 phone (no `gameName`) | Watch backfills name/comment from the library; refuses only if still unresolved |
| Game deleted elsewhere | Library mirror evicts the live record (guarded on non-empty rows + `.cloudKit` mode) |
| Same game, divergent parked index | Per-field merge; comment taken only from the record whose index matches |
| Branch active on the phone | Live record carries no comment; "of M" hidden |
| `lastModified == nil` | Row not mirrored |
| Late-delivered older push | Rejected by the monotonic `capturedAt` rule |
| No comment at the position | Comment-absent layout (the default) |
| Empty library / degraded store | "Open KataGo Anytime on your Watch" |
| App Group unavailable | "Storage unavailable" — distinct from "no data" |
| CJK comment | Grapheme-count cap; SwiftUI does the visual truncation |

**On CJK specifically:** `GameRecord+SGF.swift:265` copies every SGF `C[]` node
verbatim, and imported Go SGFs routinely carry Chinese/Japanese/Korean
commentary. Cap on `Character` (grapheme) count — never bytes or unicode scalars
— and append an ellipsis only when truncation actually occurred. The wire cap
exists to bound the payload, not to fit the tile; fitting is SwiftUI's job. The
repo's English-only rule covers **committed source**, not rendered user content;
nobody should "fix" a CJK comment by filtering it.

## Testing

Everything below is platform-unconditional Foundation code in
`KataGoAnalysisKit`, tested from **`KataGo iOSTests`** (Swift Testing). No
`#if os(watchOS)` in any of it — that would make it invisible to the only test
bundle that covers watch logic.

- `merge(live:library:now:)`: both-nil, one-nil, same-game with matching index,
  same-game with divergent index, different games by recency, live past the 24 h
  expiry, and the cold-replay ordering.
- `contentKey` stability and the skip-write-on-equal-key rule.
- Monotonic `capturedAt`: a late older payload for the same gameID does not win.
- Nil-`gameID` refusal: the previously stored record survives.
- `cappedComment`: a multi-scalar grapheme straddling the boundary, a CJK string,
  and the ellipsis-only-when-truncated rule.
- `shouldReload` and `shouldPush`: key change triggers, interval floors.
- `evictingStaleLive(live:libraryIDs:storeMode:)`.
- `deepLinkDisposition` precedence, including `.wait` → `.live` re-evaluation and
  the same-id repeat tap.
- The rectangular layout-choice enum.
- `WatchSnapshot` v1.2 payload still decodes under v1.3.
- The existing 16 KB wire-size test extended with a worst-case comment.
- `WatchWidgetRecords` round-trip through an injected
  `UserDefaults(suiteName: "test.<uuid>")` — never the real App Group.
- `CommentView` flush on generation completion.

**Explicitly not unit-tested**, and verified by build-and-look or device QA
instead: the widget view (no test target can reach it), the WCSession delegate
paths, and the background wake.

**Field diagnosability.** The freshness path has three silent failure modes that
present identically as "the tile is old": the push never fired (Smart Stack
placement, or budget exhausted), the wake fired but the write was deferred
(locked, off-wrist watch), or the reload was gated out. The relative age the
layout already shows is the primary signal; encode the winning `source`
(live vs library) as a one-glyph distinction so a tester can report it.

**Manual QA script:**

1. Place the complication on a **watch face**, not only the Smart Stack.
2. With the phone app closed, confirm the tile shows the newest library game.
3. Open a game on the phone; confirm the tile follows within the reload floor.
4. Background the watch app, change the position on the phone, confirm the age
   resets **without** opening the watch app.
5. Tap the tile from each state; confirm live vs stored routing.
6. Check a full-color face, a tinted face, and the Always-On rendition.
7. Record the observed `isComplicationEnabled` / `remainingComplicationUserInfoTransfers`
   behaviour in a reference memory.

Paired-simulator WCSession QA is documented as fragile (OS resync reverts the
phone to an old bundle; auto-lock kills the pipe), so steps 4-7 are on-wrist.

## Slices

Each is separately buildable, separately testable, and leaves the app in a
shippable state.

0. **`CommentView` flush.** Independent of everything; own test.
1. **Shared leaf types.** `WatchWidgetSnapshot`, `WatchWidgetRecords`, content
   key, merge, cap, reload/push policies, eviction, layout-choice enum — plus
   every unit test above. No UI, no behaviour change.
2. **Library mirror + the three renditions.** Legacy scalars still written. This
   alone delivers the visible feature with **zero** WatchConnectivity changes and
   is fully verifiable on a paired simulator.
3. **Live record replaces the legacy scalars.** Content-keyed write, re-keyed
   reload gate, backfill, branch suppression, eviction, legacy fallback + one-shot
   key cleanup.
4. **Background wake + phone push.** Activation split, lazy store, haptic gating,
   launch-route re-arm, `.backgroundTask(.watchConnectivity)`,
   `didReceiveUserInfo`, `WatchSnapshot` v1.3, relay push with degradation.
   Needs on-wrist QA.
5. **Deep link.** Watch `Info.plist` + `CFBundleURLTypes`, `deepLinkDisposition`,
   `applyPendingDeepLink`, `row(byID:)`, refresh hoist, `widgetURL`.

Slices 4 and 5 are independently deferrable without leaving the feature broken.

## Project surgery

Linking `KataGoAnalysisKit` into `KataGoAnytimeWatchWidget` is **not** a one-line
change: the target has `dependencies = ()` and **no `packageProductDependencies`
key at all**, and its Frameworks phase carries only `Foundation.framework`. It
needs a new `XCSwiftPackageProductDependency` bound to the local `KataGoUICore`
package reference, a new `PBXBuildFile` with `productRef`, insertion of a brand-new
`packageProductDependencies` key, and a Frameworks `files` entry. The repo's
`reference_adding_swift_files_xcodeproj` recipe covers source files only. Do it in
the Xcode GUI or by hand-copying the `KataGoAnytimeWidget` objects with fresh
UUIDs, and verify by **build**.

Two more traps:

- New files under `KataGoAnytimeWatchWidget/` and `KataGo Anytime Watch/` need
  **folder-qualified** paths in the pbxproj — those groups use
  `sourceTree = SOURCE_ROOT` with path-prefixed children, so the bare-filename
  advice that works for `KataGo iOSTests/` is wrong for them.
- Rewriting `ScoreLeadWidget.swift`'s contents in place under a new type name
  avoids four pbxproj removals; only `KataGoAnytimeWatchWidgetBundle.swift` needs
  updating.

## Verification sweep

The iOS app target depends on and embeds the watch app, which depends on and
embeds the watch widget — so a watch-widget compile error breaks the
`KataGo Anytime` iOS build and every Xcode Cloud archive. tvOS matters because
`KataGoGameStore` compiles for tvOS, which has no WidgetKit (`WidgetBoardView.swift`
already wraps its import in `#if canImport(WidgetKit)`); keep `WidgetCenter` out
of the package entirely.

Run **one at a time** — concurrent DerivedData locks produce spurious
`TEST FAILED` — never delegated to a subagent, and grep for
`BUILD SUCCEEDED` / `BUILD FAILED` because a piped `xcodebuild` exit code lies:

1. `KataGo Anytime Watch` (watchOS Simulator)
2. `KataGo Anytime` (iOS Simulator — also compiles the watch widget)
3. `xcodebuild test -scheme "KataGo Anytime"`
4. `KataGo Anytime TV`
5. `KataGo Anytime Mac`
6. `KataGo Anytime Vision`
7. `swift test` in `KataGoUICore/`

No `ci_post_clone.sh` change is needed (no new bundled resources).

## Documentation to update

- `CLAUDE.md`'s watchOS paragraph describes the watch as "companion live mirror +
  remote play, plus a standalone read-only game library" and names the bridge-free
  products it links. It never mentions the widget target and will be wrong after
  this change: name the target, the product it links, and the App-Group key it
  reads.
- Add a memory topic file for this feature, cross-linked from
  `project_watchos_companion.md` and `project_watch_standalone_library.md` — both
  document the now-retired `watchScoreLeadBlack` / `watchScoreUpdatedAt` keys.

## Rejected alternatives

| Alternative | Why not |
|---|---|
| Widget opens its own App-Group CloudKit store | Reverses `SharedModelContainer.swift:118-124`; a second CloudKit mirror on the watch; jetsam risk in a wrist appex |
| Link `KataGoGameStore` into the widget | Drags SwiftData, CoreData, AppIntents and a wood `.imageset` into a complication; the repo already has a 30 MB jetsam scar on the iOS widget |
| Two App-Group keys | No atomicity across a cross-process read; a torn read could combine one game's index with another's comment |
| `newer(live:library:)` picker | Discards a real comment whenever the two records park on different indices — the common case |
| Rename the widget `kind` | Orphans every tester placement and flips `isComplicationEnabled` to false, silently killing the push path |
| `policy: .never` | No self-healing; a stale sentence reads as truth in a way a stale number does not |
| Bump `lastModificationDate` in `CommentView` | Changes library sort order on every platform and the iOS widget picker's suggested entities |
| Board thumbnail on the rectangular tile | Leaves ~90 pt of text width, destroying the comment the feature exists to show |
| `accessoryCorner` as a third family | Smaller than circular, single-line, system-styled, face-slot-limited |
