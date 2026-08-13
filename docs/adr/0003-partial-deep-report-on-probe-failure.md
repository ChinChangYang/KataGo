# 0003 — A failed probe drops its own report section, not the whole report

Date: 2026-08-12
Status: Accepted

## Context

`DeepReportGenerator.runProbes` runs its stages — snapshot, alternative
parity probe, pass probe, tenuki probes — inside **one** `do`/`catch`, so a
throw anywhere aborts every stage after it. `ReportCollector.sawError`
compounds this: the flag is raised by the first `? ` reply line and stays
raised for the whole probe session, so a single engine error line condemns
every subsequent `checkEngineError()`, including stages whose own commands
answered cleanly.

What prompted this: a tester reported that the broadcast's "Playing vs.
Passing" slide had silently disappeared during replay. Nothing was shown and
nothing was logged — the report simply had one fewer slide, and neither the
viewer nor the developer could tell a dropped probe from a position where the
comparison does not apply.

That opacity, not a specific proven fault, is what this ADR responds to. At
the time of writing the exact trigger is **unconfirmed**: the live-mode
broadcast was exercised in the simulator and produced all three slides on
every cycle, so the coupling described above is a demonstrated *hazard*
rather than a diagnosed cause. It is being removed because a subsystem whose
failure mode is "an entire section vanishes with no trace" cannot be
diagnosed at all — which is precisely the position this investigation
started from.

The stages are not equally load-bearing. The snapshot supplies the candidate
list every other section is built on; alternative parity, pass and tenuki
each own exactly one section and nothing depends on them.

## Decision

The probe pipeline moves from ALL-OR-NOTHING to **per-stage partial**
semantics.

1. Only the **snapshot** stage is fatal. No candidates means there is no
   report at all, so its throw still fails the whole generation.
2. **Alternative-parity, pass and tenuki failures are caught, logged, and
   their section is simply absent.** Every later stage still runs, and the
   report lands with whatever sections succeeded.
3. `sawError` is **cleared at the start of each probe**, so a stage judges
   only its own command window and cannot inherit an earlier stage's error
   line.
4. **Cancellation always propagates** — a `CancellationError` is re-thrown
   unchanged from every stage and is never swallowed by the per-stage catch.
   Pause, skip and probe-session teardown are all built on it; absorbing it
   would leave the engine hijacked.
5. The **pass stage is reordered above the alternative parity probe**, so the
   newest and least-proven probe cannot starve the oldest feature.

## Alternatives rejected

- **Fail loudly on any stage** — the status quo: one engine hiccup destroys a
  whole report whose other sections were already complete.
- **Show a fallback sentence on the affected slide** ("pass comparison
  unavailable") — puts engine plumbing on screen, in front of a TV audience.

## Consequences

- A reader of a report can no longer assume every section was attempted
  successfully. A missing pass section is indistinguishable **on screen**
  from "no pass comparison applies to this position".
- That opacity was accepted deliberately — a TV audience should not see
  engine plumbing — and is mitigated by logging each dropped stage through
  `os.Logger`, where a developer can find it, rather than by surfacing it.
- A report is now a best-effort document: partial by design, complete in the
  common case, and never empty unless the snapshot itself failed.
- Cancellation semantics are unchanged and stay exact, so the pause/skip
  paths and the broadcast's teardown keep working as before.

## Amendment, 2026-08-13 (see docs/adr/0006)

The "unconfirmed trigger" recorded above was subsequently diagnosed, and it was
not an error path at all: the probes waited a **fixed wall-clock window** and a
cold search on a 19×19 Apple TV board routinely expanded no root child inside
it, so KataGo printed nothing and the section was simply never built. The
hazard this ADR removed was real but was not what the tester was hitting.

The partial-section semantics decided here are unchanged and still correct.
What changes is their *meaning*: probes now end on evidence within a bounded
patience pool, so **"silent within budget" is no longer an expected outcome**.
A missing section now indicates a genuine engine failure rather than a slow
one — which is what makes the log line above worth reading.
