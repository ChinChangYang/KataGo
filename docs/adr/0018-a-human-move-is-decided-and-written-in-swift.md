# 0018 — A human move is decided and written in Swift

Date: 2026-09-01
Status: Accepted

Completes ADR 0008. That decision made the board record-owned and left one
seam open, named in its §14: play still round-tripped the engine — a tap sent
`kata-check-move`, the legal reply sent `play`, and the record learned about
the stone only from the `printsgf` echo. This ADR closes the seam. Nothing
about who owns the board changes; what changes is who decides a move and who
writes it.

## Context

Tester: *"When a model is not loaded, a stone should be able to be played on
the board, but it cannot."*

Under ADR 0008 the board mounted on the first frame and navigated engine-free,
but a stone tap was gated on *in sync* (`Stones.isReady`), which only a live
engine's `showboard` acknowledgement ever set. With no model chosen, with a
model still compiling, after a crash, or with a board the engine cannot take
(*Held*), three independent blocks held: the command gate dropped
`kata-check-move`, the turn was parked `.unknown` so no host could name a
colour, and the tap gate itself read `isReady == false`. The spec had said so —
"Stage 2 (separate): engine-free play via a Swift SGF writer" — and ADR 0010
had accepted the consequence: a human-vs-AI game with no engine got no reply.

Everything a move needs was already in the process, unused for this:

- `GoRulesKit.GoBoard.play` is an exact port of the C++ board, throws
  `simpleKoBanned` and `suicideIllegal`, and carries the real ko point after a
  capture; `GoGame` already enforced positional/situational superko for the
  Messages extension.
- `RecordPosition.toMove` was computed on every projection and read by nothing.
- `Config.koRule` / `multiStoneSuicideLegal` are bridge-free and are adopted
  from the record's `RU[]` on every load.
- The post-handshake resync re-feeds the *live* record from `clear_board`
  unconditionally on every host, so an engine that arrives late already catches
  up with whatever the record holds.

## Decision

**A human move is decided in Swift against the record position, written to the
record in Swift, and only then told to the engine — if one is listening.**

1. **One legality path, KataGo's.** `MoveLegalityContext.check`
   (`GoRulesKit/MoveLegality.swift`) answers `kata-check-move`'s reasons in
   `PlayUtils::checkMoveLegality`'s order — out of bounds → occupied → ko →
   suicide → superko — under the record's rules, with the ko-hash history
   `SgfReplay.legalityContext(at:)` derives from the same replay the board was
   drawn from. The engine is never asked whether a move is legal, live or not:
   two rule sources over one index space is the desync ADR 0008 rejected, and
   the differential tests already pin the Swift board against the C++ one.
   Strictness is full: simple / positional / situational per the record's
   `koRule`, multi-stone suicide only where the rules allow it.

2. **Replay stays tolerant; new moves are strict.** `SgfReplay.apply` still
   clears the ko point before every recorded move and allows multi-stone
   suicide — that is engine-feed parity and does not move. The strict check is
   a sidecar over the same accepted moves, so a move it admits is one the
   tolerant replay will accept when it reads the record back.

3. **"Play Anyway" keeps its meaning, minus one case.** Ko, superko and a
   multi-stone suicide can still be overridden — the engine's tolerant `play`
   accepts all three, so the record and the engine stay agreed. A lone stone's
   suicide is refused outright: the tolerant replay would refuse it at that
   index, and an overridable move that then vanishes from the board is worse
   than a refusal.

4. **The side to move is the record's.** `GobanState.recordSideToMove` is
   written by the projector with every position. It is what a move plays as
   and what the ghost stone wears. `Turn.nextColorForPlayCommand` stays
   engine-sourced — its edge is what re-arms analysis and the AI reply — and is
   never read to play a stone. A local play toggles it only when an engine has
   resolved it; parked `.unknown` it stays parked for the resync's `showboard`.

5. **The write is `SgfAppend`.** It cuts the main line after the current index
   — paren- and bracket-aware, following the first variation at every fork as
   `CompactSgf` does, counting only nodes that carry `B[]`/`W[]` — appends the
   move, and closes the tree. Editing mode writes the record (with
   `clearData(after:)` for the per-index side data, as before); a locked game
   writes the branch; a locked game's own next move still takes the mainline
   shortcut and writes nothing.

6. **`printsgf` stays, as the live engine's echo.** With the gate open the
   engine gets `play` → `printsgf` → `showboard` after the record write. The
   echo re-states the record in the engine's spelling — the normalisation every
   played game has always received, and the `RE[]` tvOS reads off a finished
   one — and the ack is still what *in sync* means. With the gate shut all
   three are dropped and the debt is noted; the handshake's resync feeds the
   live record, the new move included.

7. **One gate for every host.** `GobanState.canPlayHumanMove`: the record
   position is on screen, no move waits on "Play Anyway", auto-play is not
   driving, a *live* engine is in sync (one move in flight at a time, exactly
   as before — the echo would overwrite a second write), and the record's side
   to move is not a side the engine plays. With the gate shut — *Absent*,
   *Launching*, *Failed*, *Held* — nothing is waited for. *Held* plays like the
   others: a human record edit is not something the engine has to be able to
   take, and it is told nothing, as for navigation.

8. **The AI reply takes the same road.** `playAIMove` writes the record through
   the same `commitMove`, so the engine's stone is on screen the moment the
   projector runs rather than a `printsgf` round trip later.

## Alternatives rejected

- **Two paths: local only when the engine is down.** Keeps `kata-check-move`
  for the live case. The two sources would disagree exactly where it matters
  (a ko the Swift kernel and the engine score differently) and the check-move
  reply handler was the one untested piece of the play path.
- **Retire `printsgf` from play entirely.** Cleaner on paper; in practice tvOS
  reads the result tag the engine's post-pass echo embeds, and the echo is the
  only normalisation an imported record ever gets. The double projection it
  causes (Swift text, then engine text) is a same-position republish the motion
  layer already treats as an empty diff.
- **Rebuild the SGF from the parse instead of cutting the text.** Loses every
  per-node property before the cut and every mid-line setup node; the walker
  preserves both.
- **Honour `PL[]` while here.** The replay ignores it on purpose (the engine is
  fed setup stones and moves, never a player override); honouring it here
  would put the display and the feed on different turns.
- **Simple ko only, engine-free.** Cheaper, and wrong for every area-scoring
  preset the app ships.

## Consequences

- A stone can be played on every host with no engine loaded, while a model
  compiles, after a crash, and on a *Held* board. A human-vs-AI game accepts the
  human's move with no engine; the AI answers when one arrives, through the
  existing resync and turn edge.
- The tvOS play and review screens gain an illegal-move confirmation they never
  had (the old engine reply latched the flag with no UI), and their navigation
  no longer waits for *in sync*, as the volumetric board's already did not.
- `kata-check-move` leaves the app entirely; `pendingMoveTurn` now means "a move
  is waiting on Play Anyway", and the five-second stale timeout that guarded a
  reply that never came is gone with the reply.
- A record with variations keeps them up to the cut and loses them after it;
  before, the first engine echo dropped them all.
- macOS's context-menu "Play here" → Overwrite path played the last
  left-clicked vertex, or nothing; it now plays the resolved one.
- The Messages extension, the widgets and the watch are untouched: they were
  already engine-free, and `GoRulesKit`'s replay kept its contract.
