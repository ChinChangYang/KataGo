# 0012 — Hypothetical boards are resolved positions, not stone overlays

Date: 2026-08-25
Status: Accepted

## Context

Every board the app draws for a *what if* — the Deep Analysis Report's
Variation view, the tvOS Broadcast playing a principal variation out one stone
per 0.9 s, a *beat* acting out "and then the opponent plays elsewhere" — was
built the same way: take the base position's stone lists and append a ghost
stone per vertex. `ReportBoardView.pvStones` alternated colors by array index
and appended; `BroadcastBoardFrame.merged` appended a beat's placed stones;
`markedMove` appended one more. None of the three consulted any rules.

So a variation move that captured left the captured stones on the board. Worse
than stale: `Stones` is two flat arrays and `StoneView.drawStones` paints all
black points and then all white points with no occlusion check, so a point that
ended up in both lists rendered **white** whichever move actually belonged
there. The board could show a stone of the wrong color, in a position no
sequence of legal moves could reach.

The app already had two correct board replays and used neither here. The GIF
export replays its SGF through the C++ engine with captures resolved
(`SgfHelper.gifFrames`); the record board replays through `GoRulesKit.SgfReplay`
in pure Swift (ADR 0008). The hypothetical boards had a third story: no replay
at all.

The three appends also could not be fixed independently. `merged` was called
once per color, seeded from that color's own base list, and a beat needs both:
`tenukiPhase` places the candidate stone and then a stone the engine chose on
the board that candidate had already cleared — so when the candidate captures, the
follow-up point holds an *enemy* stone in the base and becomes legal only once
the capture is applied. A per-color merge never sees that capture.

## Decision

**A board that draws a hypothetical is a resolved position.** The stones are
computed by playing the line out under rules, not by adding stones to a picture.

1. One resolver serves every hypothetical: the Deep Report's PV, the tvOS
   Broadcast's PV frames, a beat's placed stones, and `markedMove`. The rules
   kernel is `GoRulesKit.ForcePlay`; `KataGoUICore.VariationPosition` is the
   projection callers see, so GoRulesKit types stay off KataGoUICore's public
   surface — the contract `RecordPosition` already keeps.
2. **The rules are Swift, not the engine.** ADR 0008 says the board never waits
   for the engine, and a Broadcast frame re-derives its whole prefix on every
   render; that must be synchronous, and on tvOS the engine may be busy
   generating the next move. The GIF export's C++ precedent does not transfer —
   it is a one-shot batch job, not a per-frame renderer.
3. **Force-play: nothing is refused.** Every on-board empty point accepts a
   stone, and every liberty-less group is lifted — the opponent's, then the
   played stone's own. Ko, superko and turn order are never consulted. A point
   already holding this color is a no-op; a point holding the other color, or a
   token naming no intersection, is skipped and logged, and the line continues.
4. **Suicide is uniform.** Single- and multi-stone suicide are the same event:
   a group with no liberties comes off. This is deliberately more permissive
   than both `GoBoard.play` and the C++ GTP `play`, which reject the
   single-stone case (`Board::isIllegalSuicide` falls through for a lone stone
   even when multi-stone suicide is legal).
5. **The line resolves as ONE ordered chain**, both colors together. Order is
   load-bearing, not incidental — see the tenuki case above.
6. **Move numbers are the engine's own indices.** Gaps are truthful: a captured
   stone's number goes with it, a pass consumes an index and shows nothing.
   This needs no bookkeeping — `MoveNumberView` already draws a label only
   where a stone stands.
7. **Nothing real moves.** No prisoner count, no capture tally, no record. A
   variation is a picture of what would happen.

## Alternatives rejected

- **Replay in C++, like the GIF export.** Authoritative, and the obvious
  precedent — but it puts an engine round trip inside a render path that runs
  every frame, which is the coupling ADR 0008 removed.
- **Match GTP `play` exactly.** The instinctive reading of "play it like the
  engine would", and it still refuses three things. A renderer that refuses has
  to draw *something* anyway, so the refusals just move the problem.
- **Truncate the variation at the first move the rules dislike.** Honest, but
  it makes an unproven assumption load-bearing: nobody has verified that engine
  PV vertices are legal on their own base position (`Search::isLegalStrict`
  gates `genmove` output, not search-tree expansion). Truncating on a false
  positive silently shortens a good line.
- **Force an occupied point by lifting whatever stands there.** Never loses a
  stone the author meant to show — but it invents a capture the game never made.
  Unnecessary in any case: the move that clears a point always travels ahead of
  the move that needs it.
- **Resolve per color, keeping `merged`'s signature.** The smallest diff, and it
  cannot express the tenuki case at all.

## Consequences

- The Deep Report's Variation view, its Δ view's marked move, and every tvOS
  Broadcast board are fixed by one change on three platforms. visionOS and
  watchOS have no hypothetical boards and are untouched.
- `BroadcastBoardFrame.blackVertices(base:)`/`whiteVertices(base:)` are replaced
  by a single `stones(black:white:width:height:)`. Resolution needs both colors
  and the board size; the per-color pair could supply neither.
- A skipped move is invisible on screen — the variation simply renders one stone
  short. It is logged once per distinct symptom, because a renderer re-resolves
  on every body evaluation and an un-deduped log would drown the console.
- `lastMoveVertex`'s guarantee is weaker than it was: a placed stone that
  self-captures leaves no stone under the red dot, and the dot then draws
  nothing. That is the right answer, but the guarantee is gone.
- Force-play is public in GoRulesKit, so anything that needs to lay out a
  hypothetical position can reach it — and it is covered by `swift test`, which
  `xcodebuild` never runs for SwiftPM targets.
- `GoBoard` is not modified. Force-play composes its existing public API, so the
  record-replay path carries none of this risk.
- The differential test can only cover the legal subset, because the force-only
  cases have no C++ analogue on this path. Suicide, skips and ko recapture are
  pinned by hand-computed unit tests instead.
