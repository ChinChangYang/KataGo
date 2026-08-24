# 0010 — Resting engine states surface through the analysis control

Date: 2026-08-24
Status: Accepted

Narrows ADR 0008's status surface, and reverses commit `abb00e02b` ("the
engine pill is the control", merged one day earlier). ADR 0008's core rule
survives untouched — the board never waits for the engine, and no engine state
is ever a screen that replaces it — but the inline pill it introduced now
renders for exactly one state: the transient *Launching* wait (with ADR 0007's
compile caption). The resting states — *Absent*, *Failed*, *Held* — put
nothing over the board at all.

## Context

ADR 0008 made engine availability an inline pill over the top of the board.
For a transient launch that is honest chrome: it narrates a wait that ends.
But three of the five states are *resting* — Absent ("No model chosen"),
Failed (a reason and a way out), Held ("Board larger than Max Board Size N")
can each persist indefinitely, and for their whole duration the pill covered
part of the goban. Blocking the board is the one thing this app's UI treats as
a cardinal sin everywhere else.

The pill had also just been made tappable (`abb00e02b`): tap → model picker,
or a Retry/Choose-model menu. That made the covering element load-bearing —
the remedy lived on the obstruction.

Meanwhile the analysis sparkle — the one control whose promise a missing
engine actually breaks — sat *disabled* whenever the engine was not ready,
saying nothing about why.

## Decision

1. **Only Launching overlays the board.** `BoardView`'s status overlay (and
   the visionOS front status card) render solely for
   `availability == .launching`. The Ready-state note ("⟨net⟩ was removed —
   using the built-in network") and the visionOS "Board Too Large" card go
   with the resting pills. tvOS is excluded: its `tvLine` lives in the side
   panel, blocks nothing, and tvOS has no model picker.

2. **The analysis control wears the resting states.** One pure rule,
   `AnalysisControlModel`, decides the sparkle from (analysis preference,
   engine availability) on iOS, macOS, and visionOS:
   - *Badge grammar*: a bare red slash means "you turned analysis off"; a red
     slash with a small warning badge means "the engine cannot analyse". The
     badge is a shape, not a colour, so the distinction survives
     colour-blindness — and the accessibility label diverges the same way
     ("Analysis off" vs "Analysis stopped — engine unavailable. Opens model
     selection."), because VoiceOver cannot see the badge.
   - *Tap*: with a usable engine, cycle run → pause → off as always. With a
     resting-down engine, open the **remedy surface** — the model picker
     sheet (iOS), the Manage Models window (macOS; the bare-Space hotkey
     follows, and the branch lives in `toggleAnalysis` itself because Space
     bypasses menu validation), the Models ornament (visionOS).
   - *Enablement*: enabled in every resting state — a disabled control cannot
     open the remedy. Disabled only while Launching.

3. **The remedy surface explains what it fixes.** `EngineStatusHeaderView`
   (from `EngineStatusHeaderModel`, reusing `EngineStatusText`'s strings) sits
   above the model list: the state line, the failure reason verbatim, Retry
   exactly when the status's actions offer it (so the failed-last-launch
   no-retry policy holds for free), the Held hint with the raise-vs-switch
   logic the visionOS card used to own, and the built-in-fallback note.

4. **Gate, don't force.** The analysis *preference* (run/pause/off) belongs to
   the user; engine transitions never write it. The sparkle's appearance
   reports *activity* — preference AND a ready engine — so nothing has to be
   forced off to look off. This is what keeps the Held round trip resuming by
   itself (walk onto a 37×37 record, walk back, analysis returns), and keeps a
   deliberate "off" off across an engine failure and recovery. One addition:
   a model chosen from a *sparkle-initiated* open arms a `.clear` preference
   back to `.run`, because that tap said "I want analysis".

## Consequences

- The goban is never covered at rest. A user in a human-vs-AI game with no
  engine gets no reply and no banner — the badged sparkle is, deliberately,
  the sole signal (accepted trade-off).
- The pill is inert again; `EngineStatusView`'s Button/Menu paths and the
  `EngineStatus.chooseModel`/`.retry`/`.actions` identifiers are gone. The UI
  suite reaches the picker through the sparkle (`Toggle Analysis`, whose
  identifier is pinned while its label follows the state). The header's
  identifiers use the `EngineHeader.` prefix, never `EngineStatus.`, which
  `waitForBoardInSync` still sweeps as "not ready".
- macOS's board interaction layer no longer stands down on
  `engineStatus.actions` — with no tappable pill underneath, the old gate
  would have silently killed right-click and hover for the whole of every
  Failed rest.
- `EngineStatusAction` and `EngineStatus.actions` survive as the header's
  data source and the hosts' wiring seam, unchanged.
- A reader wondering why the pill-as-control lasted one day: the resting
  pills competed with the board they existed to serve, and tying the remedy
  to the obstruction meant the obstruction could never go. Moving the remedy
  to the sparkle freed the board.
