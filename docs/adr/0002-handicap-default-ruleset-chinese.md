# 0002 — Handicap games with untouched rules default to the Chinese preset

Date: 2026-08-11
Status: Accepted

## Context

ADR 0001 made Tromp-Taylor (whb 0) the app-wide default ruleset and recorded a
consequence: a default-rules N-stone handicap game lost the N-point white
handicap bonus the previous Chinese default (whb N) provided, shifting the
game N points toward Black relative to the shipped "Play KataGo" balance.
The tester asked for handicap defaults to be special-cased.

Exactly two surfaces create handicap games: the tvOS "Play KataGo" New Game
form and the iMessage extension's setup card. Every other creation path is
handicap-free, and imported/pasted SGFs carry their own `RU[]`.

Constraints that shaped the choice:

- The default must remain a *named preset* — feedback #2's whole point was
  that a fresh game must never read "Custom", and preset matching is
  komi-blind but not whb-blind, so "Tromp-Taylor + whb N" would display as
  Custom.
- An explicit user choice must never be silently overridden.

## Decision

When a new game's rules are **untouched** (no preset picked, no knob edited)
and the handicap is set to 2 or more, the default ruleset becomes **Chinese**
— whose white-handicap-bonus component compensates White one point per free
stone — and reverts to Tromp-Taylor if the handicap returns to 0 while still
untouched. An explicit preset pick or knob edit pins the rules; handicap
changes then never touch them. "Untouched" is judged by value where no edit
history exists (the Messages card): rules identical to the current default
count as untouched, so an edit that exactly restores the default un-pins —
deliberate, since indistinguishable states carry no user intent. The tvOS
form tracks the pick explicitly and pins permanently.

Komi handling is unchanged per surface: the tvOS form keeps forcing 0.5 for
handicap games; the Messages card keeps the ruleset's own komi (Chinese and
Tromp-Taylor both suggest 7.5), which restores the pre-ADR-0001 balance
exactly.

The policy lives in one function per rules domain — Chinese for handicap ≥ 2,
Tromp-Taylor otherwise — used by both surfaces, and the flip is visible: the
ruleset picker shows "Chinese" the moment the handicap makes it the default.

## Alternatives rejected

- **Tromp-Taylor + whb N override** — keeps the TT label story but the
  components no longer match any preset, so the picker shows "Custom":
  recreates the original defect.
- **Komi bump (0.5 + N or 7.5 + N)** — nonstandard compensation; breaks the
  "handicap komi is 0.5" convention on tvOS and would double-count if the
  user later picks Chinese.
- **Hidden engine-side whb override at creation** — the labeled rules would
  no longer describe the actual scoring; incoherent and undebuggable.

## Consequences

- A default handicap game scores exactly as it did under the pre-ADR-0001
  Chinese default, on both surfaces.
- The ruleset picker visibly changes with the handicap until the user touches
  the rules — surprising once, then self-explanatory; both surfaces carry a
  footnote saying so.
- Even default games are untouched by this decision: Tromp-Taylor 7.5
  everywhere (ADR 0001).
- A user who explicitly picks Tromp-Taylor for a handicap game gets whb 0 —
  their choice, honored.
