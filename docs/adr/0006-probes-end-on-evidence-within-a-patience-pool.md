# 0006 — Probe stages end on evidence, within a per-cycle patience pool

Date: 2026-08-13
Status: Accepted

## Context

`DeepReportGenerator`'s probe stages waited a **fixed wall-clock window** and
then read whatever had arrived: `send(kata-analyze …)` → `sleeper(budget)` →
`stop` → `sleeper(stopGrace)` → `collector.latestLine(for:)`. The budgets
(`ReportConstants`, unchanged since 2026-07-03) are snapshot 2.0 s, pass 1.0 s,
tenuki 1.0 s, grace 0.2 s, and they carry **no board-size term**.

A tester reported that the tvOS broadcast omits the Alternative and
"Playing vs. Passing" cards: **never** present at 19×19, sometimes present at
9×9. The asymmetry is the tell — this is a timing failure, not a logic one.

The mechanism is exact, and every link is in the engine's own source. The pass,
alternative-parity and tenuki probes analyze a **cold** tree (`kata-analyze`
with an explicit colour clears it). If no root child has been expanded when the
callback fires, KataGo prints **nothing at all** — not even `rootInfo`, which is
appended to the same `ostringstream` and printed only at the end:

```cpp
cpp/search/searchresults.cpp:1013-1014   if(numChildren <= 0) return;
cpp/command/gtp.cpp:827                  if(buf.size() <= 0) return;
```

So `latestLine` is nil, `model.passComparison` stays nil, and
`BroadcastScript` simply does not build the card — invisibly, by ADR 0003's
design. Symmetrically, a snapshot that expands exactly **one** child yields
`candidates.count == 1` and there is no Alternative card.

Sizing, from the one committed on-device tvOS measurement (12.7 inf/s ≈ 79 ms
per prediction on CPU+GPU — and taken with the engine *quit*, i.e. a best
case): a cold probe's first **searched** move needs two *dependent* NN evals,
~160 ms uncontended, which contention and thermals push to ~0.5–0.8 s. Against
a 1.0 s floor that is not a margin, it is a coin flip — and 19×19 costs ~4.5×
more per eval than 9×9, which is precisely the reported asymmetry.

Two facts constrain the fix:

- **`minmoves` cannot help.** `getAnalysisData` returns at
  `searchresults.cpp:1014` on `numChildren <= 0`, 115 lines *before*
  `minMovesToTryToGet` is read. And a zero-visit entry carries the ROOT's
  `lead` verbatim, an FPU-shifted winrate and a one-move PV
  (`searchresults.cpp:917-937`) — asking for it would fabricate a card.
- **`filterZeroVisitMoves` is a no-op.** `gtp.cpp:746` takes
  `vector<AnalysisData> buf` **by value**, so it filters a copy. Prior-only
  entries really are printed. "A line arrived" is therefore not evidence.

`ReportBudgets` is shared with the iOS/macOS Deep Analysis Report, documented
as a "~5 s quick report" — an interactive sheet with a human watching a spinner.

## Decision

Probe stages terminate on **evidence**, bounded by a **per-cycle pool**.

1. **Floor first, then patience.** Each stage's existing budget elapses
   unchanged; only past it does the stage keep waiting, and only while it is
   still starved. Whenever today's code already worked this is provably inert —
   same commands, same sleeper-call sequence, same timings.
2. **Evidence is graded**, not boolean: `none` (nothing searched) / `thin`
   (searched, but fewer moves than this stage asked for) / `sufficient`. The
   count comes from `rankedEntries` filtered on `visits > 0`, so it can never
   disagree with what `buildCandidates` will keep.
3. **A line in which nothing was searched is discarded**, even when it is all
   that ever arrived. Publishing it would put the position's own numbers on a
   card describing a different move.
4. **Thin evidence gets a separate, much shorter allowance**, measured from
   when it first appeared rather than from the start of the wait — a position
   with one sensible move must not spend the whole cap waiting for a second
   that will never come. Only the snapshot distinguishes thin from sufficient
   (the Alternative card needs two ranked moves); every other stage needs one.
5. **Two bounds, not one.** A per-stage cap (2.0 s) stops one starved stage
   draining everything, and a per-**cycle** pool (6.0 s, `.broadcast` only)
   bounds the whole pipeline. The worst case is therefore *floors + pool* —
   about 9.2 s + 6 s ≈ **15 s** — one number, rather than a ceiling multiplied
   by the number of stages.
6. **`.standard` keeps a pool of zero**, so iOS and macOS are byte-for-byte
   unchanged and the "~5 s quick report" promise stands. `scaled(by:)` does not
   multiply the pool: it is an allowance for a starved engine, not a depth
   control, and an 8× refine press must not wait a minute.
7. **Patience is not a pacing knob.** Every Auto-Play Speed gets the same pool.
   Deriving it from the pacing profile would recreate the deleted
   `maxSlideCount` bug, in which a speed control silently decided how much
   analysis the viewer was shown.
8. **The poll counts are logged** (`report.deep`), per stage, with the evidence
   grade and the pool remaining. The constants above are extrapolated from a
   microbenchmark taken with the engine quit; the logs are how they get
   corrected from a real Apple TV instead of guessed at a second time.

## Alternatives rejected

- **`kata-analyze … minmoves 1`** — dead code in the failure case (see above),
  and it would fabricate a card if it did fire.
- **Simply raise the fixed budgets.** Pays the full cost on every cycle,
  including the overwhelming majority that are already healthy, and still has a
  cliff — just a later one.
- **Switch the cold probes to `kata-search_analyze`**, whose terminal callback
  (`gtp.cpp:1149-1152`) and hard two-playout floor (`search.cpp:541-544`) make
  emission an engine-side *guarantee*. Genuinely stronger, and held in reserve:
  it runs under `genmoveParams` rather than `analysisParams`, which would put
  the visit-parity contract (CONTEXT.md) in question — the Alternative's
  numbers would come from a differently-parameterised search than the Best
  Move's. Escalate to it if the logs show stages still hitting the pool.
- **Per-stage ceilings with no pool.** Five stages × one ceiling is a
  worst-case nobody can state in a sentence, and the answering move in live
  self-play waits for the whole pipeline.

## Consequences

- A starved cycle now takes up to ~6 s longer, spent while the current slide is
  still typing (6 s minimum per slide), so it is hidden rather than felt. A
  *healthy* cycle is unchanged to the byte.
- Live self-play's answering move can be delayed by up to the pool: the early
  gen-move fires only once generation has settled, so a starved pipeline
  postpones it. Bounded, and bounded by a number that is written down.
- ADR 0003 still holds — a stage that genuinely fails still drops only its own
  section — but "silent within budget" is no longer an expected outcome. A
  missing section now means a real engine failure, not a slow one.
- The report can still fail outright when the snapshot returns only prior-only
  entries: that is deliberate (a report built on the root's own numbers is
  worse than no report) and the existing silence retry still applies first.
- **Residual, pre-existing and knowingly left alone:** the evidence rule judges
  a whole *reply*, not each entry in it. A snapshot that searched one move and
  also printed a prior-only second entry counts as thin, is accepted after the
  thin allowance, and `buildCandidates` will still rank that prior-only entry
  second — so the Alternative card can carry the root's own numbers. That was
  equally true before this change (nothing ever filtered zero-visit entries out
  of `rankedEntries`), it needs a change to the shared iOS/macOS report to fix,
  and it is out of scope here. Filtering `rankedEntries` on `visits > 0` is the
  fix when it is worth making.
- A skip pressed while the cursor is HOLDING for a card that has not landed is
  consumed rather than banked. Patience makes that hold seconds long, so it is
  a press a viewer really makes, and a banked one would blank the awaited card
  before a character was typed — deleting the card this all exists to restore.
- The constants are QA-tunable and expected to be tuned. They are sized from a
  single uncontended microbenchmark; nothing in the simulator can validate
  them, because it has neither the thermal ceiling nor the ~2.1 GB per-process
  budget. **Device QA is pending**, and it is what closes this out.
