# 0011 — Live ownership is held across a position change, candidate moves are not

Date: 2026-08-25
Status: Accepted

Amends exactly one consequence of ADR 0008, and nothing else. The board is still
record-owned, analysis is still collected only while in sync, and per-index
analysis is still refused unless the numbers and the index agree.

## Context

Since `4d3a9c660` (first shipped in build 335; build 334 was the last good one)
every played move, undo and scrub step blanked the *ownership overlay*: the
shading vanished, the board sat bare for a round trip, and the new shading faded
in from nothing.

The rule that did it was written for a narrower case — clear when the position
changes while the engine is not *in sync*. But the board is marked out of sync
BEFORE the record changes, so it fired on every step of navigation, and it ran
outside any animation.

The win-rate bar and the score never blanked with it. They are separate
observables the clear never touched, written only when the engine actually
produced a number, so they have held across a position change for as long as they
have existed. ADR 0008's consequence bullet reported the symptom as scrubbing
"blanks the win rate", which is true only of the win-rate numbers the candidate
circles carry — the bar was never affected. Naming the wrong thing is part of why
this stood for a build: the overlay that actually blanked went unnamed.

The overlay is a full-board picture and a square's identity is its intersection,
so a map replaced by another map is a per-square value change. A map replaced by
NOTHING is a deletion followed by an insertion, and no animation on the arrival
can make the deletion look like anything else. On the volumetric board the
emptiness costs more: a quad is destroyed whenever its intersection leaves the
map, so an empty map tears down and rebuilds every quad on the board.

## Decision

**Live ownership is held across a position change; live candidates are not.**

1. The *ownership overlay* survives a position change — near or far, no distance
   threshold — and is replaced square by square when the engine answers.
2. The *candidate overlay* is cleared on exactly the schedule it always was. The
   asymmetry IS the decision: a territory map one stone out of date is
   approximately right, which is the whole job of a territory map; a candidate
   ranking after a move ranks the wrong player's options, and can put a circle on
   the stone that was just played. Absent beats wrong.
3. A *hold expiry* ends the hold outright in three cases: the board stops being
   the same game (a switch, a new game, a size change); *engine availability*
   leaves a working state (*Absent*, *Failed*, *Held*); or the board moves while
   the engine is not being talked to.
4. Availability and the command gate, never sync. The board leaves sync on every
   step by design, so expiring on sync is the regression spelled differently. A
   relaunch that does not move the board keeps its map — most restarts change
   neither the position nor the engine's opinion of it — but a board scrubbed
   behind a shut gate drops it, because nothing there can ever correct it.
5. A held map is never written down. Per-index analysis is persisted only while
   the collection stamp names the displayed position, and the narrow clear drops
   that stamp along with the candidates.
6. One rule, in the shared layer. visionOS gets the blink fix and nothing more —
   a map that is never emptied stops the quad teardown — and no per-frame
   RealityKit interpolation; the 90 Hz compositor owns that budget.

## Alternatives rejected

- **Hold both overlays.** The symmetric answer and the wrong one: a stale
  ownership map is off by one stone's influence, a stale candidate overlay is an
  argument made for the other player.
- **Expire the hold when the engine falls out of sync.** That is the rule being
  fixed. Sync churn is the normal condition of a board being navigated.
- **Clear both, but animate the clear.** Fading to a bare board still claims the
  app knows nothing about this position. It knows something — the map from one
  stone ago.
- **Treat *Launching* as a resting state, so any relaunch clears.** Closes the
  scrub-during-a-restart case without a second expiry rule, but blinks the board
  on every backend change, thread-count change and Retry — the reported symptom
  arriving through a different door.

## Consequences

- A scrubbed board can show a territory map for a position it is no longer on,
  and nothing says so. Accepted: it is the contract the win rate and the score
  have always had.
- ADR 0008's consequence bullet is corrected here. Scrubbing never blanked the
  win-rate bar or the score; what blanked was the two overlays, one of which
  carries win-rate numbers of its own.
- A board can be one position ahead of its overlay in a screenshot. Anyone
  reading a bug report has to allow for it.
- While a restart is in flight, standing still keeps the map and navigating drops
  it. Two behaviours from one situation — but the alternative is either a blink
  on every backend change or a wrong map for the length of a Core ML compile.
- A report whose ownership grid does not fit the board on screen is now dropped
  whole, rather than writing its emptiness onto the board. It is a report for a
  board the app has already left, so none of it is trusted — including its
  collection stamp, which would otherwise move to the live position while the
  held map still describes the previous one.
- On the volumetric board, the intersections the candidate markers just vacated
  briefly gain an ownership quad, until the next report re-establishes which
  intersections the candidates cover. Accepted: far smaller than the full-board
  teardown it replaces.
