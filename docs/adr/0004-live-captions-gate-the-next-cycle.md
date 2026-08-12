# 0004 — Live broadcast captions run on a drain that gates the next cycle

Date: 2026-08-12
Status: Accepted

Supersedes the reasoning recorded in `BroadcastController.playedPassSlide`'s
doc comment, which argued for the opposite and is now a pointer here.

## Context

The broadcast has two captions that report what *happened*, as opposed to the
analysis slides that weigh what *could*: the **played-pass slide** ("White
passes.") and the **game-over slide** ("Both players passed. The game is
over."). Replay earns both. Live self-play earned neither.

The reason is structural. Replay plays its move synchronously inside the
cycle, so the cycle can straddle the call and see the pass happen. Live mode's
pass arrives asynchronously, with an engine reply, and by the time anything
observes it two things have already happened in one synchronous block:
`gobanState.passCount` was raised and the turn toggled. Consequently:

- The first pass routed the next beat through `startCycle`'s endgame-formality
  branch, which answers immediately and never opens a cycle task — there was
  no in-cycle moment in which to type a caption.
- The closing pass arrived at `TVSelfPlayScreen`'s turn observer with
  `isGameOver` already true, and that observer was gated on `!isGameOver`, so
  the controller was never poked and its terminal caption was unreachable
  code in live mode.

The obvious repairs were both rejected in an earlier round, for a reason that
still holds: a caption typed from a bare detached task would type over the
next cycle's slides, and moving the formality branch inside the cycle task
opens a window — between `phase = .awaitingMove` and the continuation
clearing `cycleTask` — in which a landing turn change is dropped by the
`cycleTask == nil` gate, **stalling the live loop with no visible cause**.

## Decision

Live captions run on a dedicated **caption drain**, and the next cycle waits
for it.

1. `advance(game:)` becomes the single entry to "the position moved on".
   Both the screen's turn observer and a cycle's own chain funnel through it,
   so a pass landing mid-slideshow — which the early gen-move makes the
   *normal* live path — is captioned like any other.
2. A pass is detected as a **rise in `gobanState.passCount` across an
   advance**, with the baseline taken at construction. A seeded continuation
   enters with the SGF's trailing passes already counted, so a zero baseline
   would caption a pass nobody just played.
3. Captions are appended to a queue drained by one `captionTask`. Queueing
   preserves the order they were earned, which is what makes a closing double
   pass narrate as "White passes." → "Both players passed. The game is over."
4. **`noteTurnChanged` defers while the drain is live** — recording the turn
   change rather than acting on it — and the drain replays it on the way out.
   This is what makes the hazard above unreachable: the signal is never
   dropped, so the loop cannot stall.
5. The **answering move is requested first**. `advance` queues the caption and
   then calls `startCycle`, whose formality branch asks the engine
   immediately; only the *slides* of the following cycle wait. The board stays
   truthful — the stone appears when the engine replies.
6. `pause`, `cancelAll` and `cancelAllAndDrain` all reach the drain, on the
   same terms as the cycle task. A paused broadcast that is still narrating
   is a bug.
7. A caption **covered by live self-play's game-over card holds only for its
   narration** (CONTEXT: *caption hold*). The card is a full-screen dimming
   overlay carrying the result; once it is up there is nothing left on the
   board to absorb. Checked inside the hold loop, not at entry, because the
   card usually goes up *during* the previous caption — the answer to a pass
   is most often the pass that ends the game. Two closing captions at the 6 s
   minimum-slide floor run ~12 s against an 8 s interstitial, and would have
   been cut off mid-sentence.

## Alternatives rejected

- **Move the formality branch inside the cycle task**, so a caption is just
  another in-cycle slide. Cheapest-looking, and it re-opens the dropped-turn
  window whose failure mode is a silently stalled live loop.
- **Type the caption to completion before requesting the answer.** Never
  truncated, but nothing is asked of the engine for a slide's duration, and
  the pause is visible as a dead board.
- **Request the answer and let an early reply cut the caption off.** Snappy,
  and it truncates narration mid-word exactly when the game is most eventful.
- **Extend the 8 s interstitial to fit two dwelling captions.** Costs every
  viewer ~4 extra seconds per game in the attract loop — including the
  majority with narration off, for whom the closing captions are invisible.
- **Put the terminal sentence into the game-over card instead.** The card
  carries the *result*, which arrives asynchronously in `RE[…]` and has a
  draw-aware fallback; coupling narration to it is a larger change than the
  gap being closed.

## Consequences

- Cycle start is no longer driven by turn changes alone: a caption can hold it
  back. Anything added to the loop must go through `advance`, not
  `startCycle`, or it will bypass pass detection.
- The live closing captions are **speech-first in practice**: the game-over
  card is already up and dimming the screen, so with narration off they flash
  past. That is deliberate — the card says strictly more than the caption
  (it carries the result), and the gap being closed was audible.
- `TVSelfPlayScreen`'s turn observer must stay ungated on `isGameOver`. Re-
  adding that gate makes the terminal caption unreachable again, silently.
- Replay is unchanged: it keeps earning its played-pass slide inside the
  cycle, its captions keep their dwell (there is no card over them), and
  `advance` skips live pass detection whenever a replay move source is set.
