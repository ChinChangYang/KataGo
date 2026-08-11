# CONTEXT

Ubiquitous language for KataGo Anytime. Glossary only — no implementation details.

## Deep Analysis Report

- **Deep Analysis Report** — the on-demand, per-position study sheet (iOS/visionOS ⋯ menu, macOS Game menu). Distinct from *live analysis*, the continuous overlay on the board.
- **Best Move** — the report's top candidate: the move the engine's open search ranked first for the side to move.
- **Alternative** — the report's second candidate slot. Exactly one Alternative is shown; it can originate from the engine's rank #2, from the game's next recorded move (the *smart default*), or from a *user pick*.
- **Smart default** — the Alternative chosen automatically when the report opens: the game's next recorded move when reviewing mid-game (if legal and not the Best Move), else engine rank #2.
- **User pick** — an Alternative the user nominated from the in-report board picker.
- **Snapshot probe** — the unconstrained analysis pass over the report's position; its ranked candidate list is the report's baseline.
- **Forced-candidate probe** — an analysis pass constrained so that all root search effort goes to one nominated vertex, used to evaluate a move the open search would starve.
- **Tenuki follow-up** — the probe answering "what happens next if this candidate is played": play the candidate, analyze the reply position, undo.
- **Refine** — re-running the report's probes at a doubled budget (capped), preserving the user's pick.
- **Visits** — the number of search playouts backing a candidate's evaluation; the report's proxy for how trustworthy a candidate's numbers are.
- **Visit parity** — the report's contract that the Alternative is always evaluated by its own forced-candidate probe, regardless of origin (engine rank, smart default, or user pick), so its visits are in the same ballpark as the Best Move's and its numbers are equally trustworthy.

## Rules & presets

- **Ruleset preset** — a named ruleset (Chinese, Japanese, Korean, AGA, BGA, AGA Button, New Zealand, Tromp-Taylor, Stone Scoring, Ancient Territory, Chinese OGS/KGS) defined *entirely* by its six rule components. Komi is **not** part of a preset's identity.
- **Rule components** — the six knobs that define a ruleset: ko rule, scoring rule, tax rule, multi-stone-suicide legality, button, white handicap bonus.
- **Preset match** — the mapping from current rule components to the preset label the picker displays. Komi-blind by design: only the six components participate.
- **Custom** — the picker state shown when the current components match no preset. Not a preset itself.
- **Suggested komi** — the komi conventionally paired with a preset's components (6.5 for territory scoring, 7.0 with a button, 7.5 otherwise). Applying a preset applies its suggested komi.
- **Default game** — the game a platform creates without the user choosing anything (first launch, quick New Game, fallback after deleting the last game). The default game uses the Tromp-Taylor preset with its suggested komi 7.5, identically on every platform and peripheral surface (photo import, Messages).
