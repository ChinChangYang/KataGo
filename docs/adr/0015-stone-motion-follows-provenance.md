# 0015 — Stone motion on the 2D board follows provenance, not the diff

Date: 2026-08-31
Status: Accepted

Extends ADR 0008's record-owned board to the flat goban's motion, and carries
the volumetric board's `StoneAnimationPlanner` (shipped for visionOS) into the
shared layer. Nothing about who owns the board changes: the record still writes
every stone, the engine is still told about it afterwards, and no animation is
ever allowed to decide what is on the board.

## Context

Stones appeared. On the volumetric board a played stone flies in and an undone
one lifts off, so the eye knows which stone changed and which side just moved;
on iPhone, iPad, Mac and Apple TV the whole position swapped between two frames,
and a capture of nine stones was indistinguishable from a nine-stone jump.

The obvious implementation — animate whatever the diff between two positions
says — cannot work, and the volumetric board already learned why
(`StoneAnimationPlanner`'s header):

- A play that captures one stone is shape-identical to an undo that restores
  one: 1 addition, 1 removal. No diff-time rule can tell them apart.
- On the editing path the record's `sgf` and `currentIndex` are rewritten at the
  `printsgf` reply, which lands AFTER the stones have already been published, so
  the index is stale by exactly one move at the moment the diff arrives.
- Batch changes — a 10-move jump, a jump to the end, a game switch, a board
  reload, an import — are diffs like any other. A rule that animates "the one
  addition" fires on the one-stone jump and on nothing else, which is worse than
  never firing.

Provenance answers all three. The command sites know what they are about to do
before they do it, and they are few: five of them enqueue an intent, and every
other way the board can change enqueues nothing and is therefore instant by
construction.

The second problem is sound. `GobanState` clicked at COMMIT time — the moment
the `play` command went out — which is right when the stone appears in the same
frame and wrong the moment the stone takes 150 ms to settle: the click lands a
whole settle before the stone touches the board, and the capture rattle lands
before the stone that caused it. The volumetric board solved this by moving the
cue to the scene; the flat board now does the same.

## Decision

**A stone animates only when a command site accounted for it, and it sounds when
it lands.**

1. **Intents at the chokepoints, not at the hosts.** `GobanState` carries the
   queue (`stonePlanner`), and the five sites that enqueue are the five that
   land a stone: `playPendingHumanMove` and `playAIMove` (`.place`),
   `playMainlineStep`'s two callers by way of those two, `forwardMoves(limit: 1)`
   (`.place`), `undoIndex` (`.remove` of the tip), and `autoPlayStep`
   (`.place`). `undoIndex` in particular is where the intent belongs because it
   is the one step every back-one path shares — the iOS toolbar, the tvOS play
   screen, `VisionRootView`, and `backwardMoves(limit: 1)` all go through it, so
   four hosts get the behaviour without four copies of the derivation.

2. **The queue lives on `GobanState`, as a value.** Not on a rendering object:
   the navigation methods that enqueue (`undoIndex`, `forwardMoves`,
   `autoPlayStep`) are nonisolated and could not touch a main-actor scene model.
   It is `@ObservationIgnored` and never read during a `body`.

3. **Only the accounted stone animates.** The layer resolves each published
   position's stone diff against the queue. A diff matching no intent is a batch:
   it mounts instantly, and it invalidates the whole queue. Every race therefore
   degrades to a missed animation, never to a wrong one.

4. **Scrubs and jumps clear.** `forwardMoves`/`backwardMoves` with any limit but
   1 drop the queue after their walk, and `go(to:)` drops it after delegating —
   so a one-step chart scrub or moves-list tap is instant even though the helper
   it called enqueued. Navigation is not a move, however short the hop.

5. **A game switch arms a silent remount.** `loadGame` drops the queue AND arms
   `stoneMotionInitialSyncArmed`, which turns the remount batch silent as well as
   instant. Loading a game is not a move. A jump's reset deliberately DISARMS
   that flag: a same-position reload can leave it armed with an empty diff, and
   the jump the user then presses must click once for its batch.

6. **Captures ride the landing.** `GoRulesKit` now reports which points a move
   cleared (`GoBoard.play` returns them, `SgfReplay.Position.capturedByLastMove`
   carries them with their colour), the projector publishes them on
   `Stones.capturedPoints`, and the captured stones' removal animation starts
   when the capturing stone finishes settling. The counters could never do this:
   they are running totals and name no points.

7. **Sound moves to the landing.** A satisfied `.place` clicks after the settle;
   a satisfied `.remove` is silent — a stone leaving the board is not a stone
   hitting it; a batch diff clicks once, immediately, unless it is the armed
   game-switch remount. The capture rattle waits for the landing when a stone is
   settling and fires at once otherwise. This is `StoneAnimationPlanner`'s
   existing `soundCue`/`captureCue` contract, unchanged, now read by both boards.

8. **A pass clicks at the command site.** It moves no stone, so no diff will ever
   come; an intent queued for it would sit in the queue until some unrelated
   diff happened to satisfy it. Every site that can play a pass tests for the
   vertex `"pass"` FIRST, because `BoardPoint(move: "pass", …)` returns the
   off-board pass sentinel rather than nil.

9. **Reduce Motion cross-fades.** One rule, in one place
   (`MotionPreference.scale(_:reduceMotion:)`), read by the 2D views through
   SwiftUI's `\.accessibilityReduceMotion` and handed to
   `VisionBoardSceneModel` by `VisionBoardRealityView`: nothing travels and
   nothing scales; only opacity animates, over the same durations.

10. **The motion layer is injected, so static renderers are inert.** `BoardView`
    owns the `StoneMotionState` and passes it to `StoneView` through a
    parameter that defaults to nil. `ReportBoardView`, the game-list thumbnail,
    the GIF renderer and every future `StoneView` consumer get no state and
    therefore no motion, without a single opt-out flag.

11. **The Canvas stays.** The arriving stone is ONE transient SwiftUI view drawn
    over its Canvas twin at 1.15x shrinking to 1.0x — never below 1x, so the
    twin is covered for the whole settle. Departing stones are transient copies
    at points the Canvas no longer draws at all. The dense-board render cost the
    Canvas was introduced to fix is untouched: at most eleven extra views, for a
    sixth of a second.

## Alternatives rejected

- **Classify the diff.** The reason this ADR exists. A capture and an undo are
  the same diff, and the record index that would break the tie is one move stale
  exactly when the diff lands.
- **Animate through SwiftUI transitions on the Canvas.** A `Canvas` is one view;
  its contents have no identity for SwiftUI to interpolate. The dead
  `.transition(.opacity)` that sat on it since the Canvas landed is deleted here
  — the projector writes stones inside `withAnimation(.none)`, so it had never
  run.
- **Put the planner on the rendering object, as visionOS does.** visionOS can:
  its command sites are all in one main-actor root view. `GobanState`'s are not.
- **Keep the commit-time click and animate anyway.** The click would arrive a
  settle before the stone, on every move — the exact defect the volumetric
  board's landing click was introduced to fix.
- **Have the projector drive the animation.** It is the one writer of the stones
  and would be a tempting place to hang this. But it is a pure projection with
  no view, no audio and no accessibility environment, and giving it those would
  make the record's own replay depend on what is on screen.

## Consequences

- **A backward jump now clicks once; it used to be silent.** `backwardMoves`
  played no sound at all, and its batch diff now takes the shared
  "batch clicks once" rule. Accepted: it is the same feedback a forward jump
  has always given, and the asymmetry was never deliberate.
- **Stepping over a REFUSED move no longer clicks.** `forwardMoves` used to
  click whenever the cursor moved; the layer clicks when the board changes, and
  a refused move changes nothing. More honest, and the only audible difference
  on a record with anomalies.
- **visionOS enqueues into a queue nothing there drains.** Its scene model keeps
  its own planner (its diffs come from the entity graph, not from `Stones`), so
  `GobanState`'s queue simply accumulates and is capped by
  `StoneAnimationPlanner.capacity`. Harmless, and noted at the property. The
  commit-time click that moved to the landing was already silent there —
  `gobanState.soundEffect` has no writer on visionOS — so nothing that platform
  hears changes.
- **There is no `retract` trigger on the 2D side.** The volumetric board needs
  one because it enqueues before the engine has ruled on legality. Here
  `playPendingHumanMove` runs only after `kata-check-move` came back legal, and
  `playAIMove` only for a reply that is actually being played, so no site can
  enqueue an intent whose command is then refused. `StoneAnimationPlanner.retract`
  stays for visionOS.
- **One frame of the arriving stone is drawn by the Canvas alone.** The layer is
  fed from a `positionGeneration` observer, which runs after the body that drew
  the new position — so the stone appears at 1x for one frame and then settles
  from 1.15x. Accepted at 16 ms; the alternative is driving the animation from
  the projector, rejected above.
- **Under Reduce Motion an arriving stone simply appears.** Its opacity ramp is
  masked by the Canvas twin the record already drew. That IS the accessible
  outcome — the setting asks for no motion, not for different motion — and the
  cross-fade is genuinely visible where nothing sits underneath it: the stones
  leaving the board.
- **tvOS self-play opts out.** The attract loop is engine-paced and unattended,
  and a settle per move fights the broadcast's own choreography, so
  `TVSelfPlayScreen` sets `stoneMotionEnabled = false` and `TVPlayScreen` /
  `TVReviewScreen` re-assert it, next to the other spectator flags they already
  trade. With motion off every diff is a batch, which is the click-per-move the
  screen had before.
- **`GoBoard.play` returns a value it did not before.** `@discardableResult`, so
  no caller changed; and nothing was added to `GoBoard` itself, because its
  synthesized `Equatable` is what `SgfReplay.Position` equality and the
  differential tests rest on — a per-move annotation stored there would make two
  identical positions compare unequal.
- **`Stones.capturedPoints` is deliberately outside `Stones.==`.** Two boards
  showing the same stones are the same position however they got there, and
  folding a per-move annotation into that identity would make an idempotent
  re-projection compare unequal.
