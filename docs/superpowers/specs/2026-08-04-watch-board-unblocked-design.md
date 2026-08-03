# KataGo Anytime Watch — Nothing Drawn On The Wood

Date: 2026-08-04
Status: Approved (design)

## Problem

The previous change (`a0fe3523`) maximized the watch board to fill its page.
Once the board took the whole page, every readout that used to sit beside it
had nowhere to go, so it was overlaid onto the board instead — on the theory
that the bottom-left corner is "the least information-dense part of a Go
position" (`WatchFrameBoard.swift:119-121`).

That theory is wrong. Reported from the device: on a 9x9 the red `wifi.slash`
staleness glyph and the `W+21.8` score capsule cover the bottom-left corner
outright, hiding stones on a board where the corner is as contested as anywhere
else. On a 2x2 through 7x7 it is proportionally worse.

Everything currently drawn on the wood:

| Overlay | Where | Lifetime |
|---------|-------|----------|
| Score capsule + `wifi.slash` | `WatchFrameBoard.swift:122-148`, bottom-leading | Permanent whenever analysis exists |
| Position pill `3/50` / `→ 5/50` | `WatchBoardPage.swift:86-106`, top | Whenever scrubbed off live |
| Stored move counter `3/50` | `WatchStoredGameView.swift:95-104`, top | 2 s after each Crown detent |
| Rejection banner | `WatchRootView.swift:69-76`, bottom | Transient, self-clearing |

## Goal

Nothing persistent is drawn on the wood. The board page is the board and its
win-rate gutter, and nothing else, on every board size from 2x2 to 37x37 and in
every connection state.

The single exception is the self-clearing rejection banner, kept deliberately
(Decision 4). No readout — score, win rate, staleness, or position — is drawn
over the board in any state.

## Scope

**In scope.** The watch target's board page and its two second pages (`Top
Moves` for the live mirror, `Review` for a stored game), plus the pure helpers
they need in `KataGoGameStore`.

**Out of scope.** The board renderer itself (`WidgetBoardView`), the win-rate
gutter, the best-move blending, and every other platform. This changes where
readouts live, not what the board draws.

## Decisions

Settled during design; everything below rests on these.

1. **The score leaves the board page entirely** and lives on the second page.
   It is not relocated to a margin, not shrunk, and not made transient.
2. **Staleness is reported by the nav title**, which changes from `Live` to
   `Offline`. This is existing chrome above the board, so it costs no board
   area, and it says the state in words rather than as a glyph.
3. **The position pill folds into the nav title too**, so the no-overlay rule
   has no exceptions to remember. This trades away tap-to-return-to-live;
   returning is done by spinning the Crown forward.
4. **The rejection banner stays.** It is the one deliberate exception: a
   transient, self-clearing report that a move the user just made was refused.
   Moving it to a page the user is not looking at would silently swallow that.

### Rejected alternatives

- **Score inside a widened win-rate bar**, as iOS does
  (`WinrateBarView.swift:43-48` draws the score in the bar as a gray monospaced
  integer). This costs no board area — the board is height-limited, so the
  ~47 pt of horizontal margin visible either side of the wood at 46 mm is
  already dead space — and it would have matched the iOS design this board was
  told to follow. Rejected in favor of the second page, which removes the
  readout from the board page altogether rather than relocating it within.
- **A reserved row beneath the board.** Guarantees no overlap on any board
  shape including wide rectangles, but shrinks the board about 10% on every
  watch size, directly against the "maximize to screen" goal that motivated the
  previous change.
- **A column in the trailing margin.** Keeps the full `W+21.8` text and keeps
  it beside the board, but the margin narrows on smaller watches and vanishes
  entirely on a wide board such as 13x9, where the board becomes width-limited.
  It cannot be stated as a single rule.
- **Tinting the win-rate bar red when stale.** Free and peripheral, but the
  bar's entire job is encoding win rate by color; recoloring it overloads one
  channel with two meanings.

## Design

### `WatchBoardTitle` (new, in `KataGoGameStore`)

A pure function mapping watch state to the board page's title. It lives in the
package for the same reason `WatchNavigationPolicy`, `WatchBoardLayout` and
`WatchBoardFrame` do: the watch target has no test bundle, so logic placed
there cannot be tested at all.

```swift
public enum WatchBoardTitle {
    public static func live(stale: Bool,
                            pendingTarget: Int?,
                            hostMoveIndex: Int?,
                            hostMoveCount: Int?,
                            sharedCursorAvailable: Bool,
                            movesBehindLive: Int) -> String

    public static func stored(name: String,
                              index: Int,
                              count: Int,
                              showsCounter: Bool) -> String
}
```

Live precedence, highest first:

| State | Title |
|-------|-------|
| `stale` | `Offline` |
| `pendingTarget != nil` | `→ 5/50` |
| Cursor mode, `hostMoveIndex < hostMoveCount` | `3/50` |
| Ring mode, `movesBehindLive > 0` | `3 behind` |
| Otherwise | `Live` |

Staleness outranks a pending scrub deliberately. `WatchLiveModel.scrub` gates
on `sharedCursorAvailable`, which is `!isStale && isReachable`
(`WatchLiveModel.swift:48`), so a pending target can only survive into a stale
state, never be created in one — and once the phone is unreachable that scrub
will never be confirmed. Showing `→ 5/50` there would be a promise the watch
cannot keep.

Stored precedence: `3/50` while `showsCounter`, else the game's name.

`Offline` will be rendered in red if watchOS honors styling on a nav title. It
may not; the word carries the meaning either way, so nothing depends on it.

### `WatchFrameBoard` — deletions

Reduces to board plus gutter bar. Removed: `statusCluster`, `isStale`,
`staleAccessibilityLabel`, `suppressesScore`. Both call sites lose the
corresponding arguments. The doc comment's claim about the bottom-left corner
goes with it.

`suppressesScore` existed only to stop the score capsule from stacking with the
bottom-anchored rejection banner. With the score gone, the conflict it worked
around cannot occur.

### `WatchBoardPage` / `WatchStoredGameView` — deletions

`statusPill` and `counterPill` are deleted along with the `.overlay(alignment:
.top)` that hosted them. `WatchStoredGameView` keeps `showsCounter` and its
`.task(id: crownIndex)` debounce — that two-second window now decides whether
the title shows the counter or the game name — and keeps the
`.animation(.easeInOut(duration: 0.2), value: showsCounter)` so the title
change is not abrupt.

`WatchBoardPage` keeps `staleAccessibilityLabel`'s wording, moved to the status
section below; the property itself is deleted.

### Second page — shared status section

One `@ViewBuilder` in the watch target, used by both `Top Moves` and `Review`,
for the reason `WatchFrameBoard` is already shared: the live mirror and the
offline browser must not drift apart.

| Row | Value | Shown when |
|-----|-------|------------|
| `Black` | `62%` | `winrateBlack != nil` |
| `Score` | `W+21.8` | `scoreLeadBlack != nil` |
| `Last update 3 minutes ago` | — | Live page, stale only |

`Score` reuses `WatchBoardFrame.scoreText` (`WatchBoardFrame.swift:173`), which
already renders from whichever side leads. Win rate is Black-perspective, to
agree with the gutter bar and with the bar's existing accessibility label.

The staleness row reuses the relative-time wording from the deleted
`staleAccessibilityLabel`, so what VoiceOver reads is preserved rather than
reduced to the one-word title.

### `Review`'s "no analysis" condition

`WatchStoredGameView.swift:128` prints "No analysis saved for this move"
whenever `bestMove` and `comment` are both nil. Adding win rate and score above
it creates a contradiction: a record can cache a win rate and a score at an
index while caching neither a best move nor a comment, and the page would then
print a score and a denial that anything was saved. The condition is extended
to require all four fields nil.

## Testing

Automated, in `KataGo iOSTests` (the package's own bundle is not run under
`xcodebuild test`):

- `WatchBoardTitle.live` — one case per precedence row, plus stale-beats-
  pending, plus cursor mode at the live head returning `Live`, plus ring mode
  at the live head returning `Live`.
- `WatchBoardTitle.stored` — counter shown and hidden.
- Win-rate percent formatting — rounding boundaries (0, 0.005, 0.5, 0.999, 1).

Manual, on the simulator:

- The nav title tracks the selected page in a `.verticalPage` TabView — that
  the TabView-level title shows on the board page while `WatchMovesPage`'s own
  title (`WatchMovesPage.swift:41`) shows on page two is inferred from the
  reported screenshot, not from documented API, and is the one behavior here
  that must be confirmed by eye.
- The board is unobstructed on a 9x9 in every state: live, scrubbed, stale.

## Risks

- **Losing tap-to-return-to-live** is a real regression, accepted in Decision 3.
  The Crown still reaches the live head, and in cursor mode the title reports
  the distance.
- **Title churn while scrubbing.** In cursor mode the title changes on every
  Crown detent. This is the pill's existing behavior relocated, and watchOS does
  not animate title changes, but it is worth a look during simulator QA.
- **A stale, off-live watch reports only `Offline`.** The position is dropped
  from the title in that state, and nothing else reports it — the status
  section carries how stale the data is, not where in the game the user has
  scrubbed to. Accepted: a watch that has lost the phone cannot act on the
  position anyway, and the title's one job in that state is to explain why the
  board has stopped moving.
