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

## Broadcast

- **Broadcast** — the commentated slide show that narrates one position on Apple TV: deterministic fact sentences typed out in lockstep with an acted-out board, and spoken aloud when narration is on. Distinct from the *Deep Analysis Report*, which is the same underlying study data presented as a static sheet.
- **Live mode** — the broadcast driving a game forward; each cycle ends by asking the engine for a move.
- **Replay mode** — the broadcast walking a recorded game; each cycle ends by playing the game's next recorded move instead of asking for one.
- **Cycle** — one move's worth of broadcast: generate the study data for the current position, present its slides, then advance the game by one move.
- **Slide** — one titled unit of a cycle, carrying an ordered list of fact sentences. Four kinds: *Best Move*, *Alternative*, *Playing vs Passing*, *Comment*.
- **Playing vs Passing slide** — the slide contrasting playing the best move with passing: what passing costs, where the opponent would punish, and which areas change hands. Present whenever the position's study data includes a pass comparison.
- **Comment slide** — a slide whose facts are the human-written note attached to that move, rather than engine-derived sentences.
- **Beat** — one acted-out moment of a slide's board choreography, paired with the sentence it illustrates.
- **Pass beat** — the beat in which the side to move *passes*. Distinct from a tenuki beat: passing forfeits the move, it does not relocate it.
- **Tenuki beat** — the beat in which a player ignores the move under discussion and *plays elsewhere*.
- **Auto-Play Speed** — the viewer's pacing choice for a replay broadcast (Slow / Normal / Fast). A pacing profile — how fast sentences reveal and how long a slide dwells — not a per-move delay, and not a choice about which analysis is shown.

## Rules & presets

- **Ruleset preset** — a named ruleset (Chinese, Japanese, Korean, AGA, BGA, AGA Button, New Zealand, Tromp-Taylor, Stone Scoring, Ancient Territory, Chinese OGS/KGS) defined *entirely* by its six rule components. Komi is **not** part of a preset's identity.
- **Rule components** — the six knobs that define a ruleset: ko rule, scoring rule, tax rule, multi-stone-suicide legality, button, white handicap bonus.
- **Preset match** — the mapping from current rule components to the preset label the picker displays. Komi-blind by design: only the six components participate.
- **Custom** — the picker state shown when the current components match no preset. Not a preset itself.
- **Suggested komi** — the komi conventionally paired with a preset's components (6.5 for territory scoring, 7.0 with a button, 7.5 otherwise). Applying a preset applies its suggested komi.
- **Default game** — the game a platform creates without the user choosing anything (first launch, quick New Game, fallback after deleting the last game). An even default game uses the Tromp-Taylor preset with its suggested komi 7.5, identically on every platform and peripheral surface (photo import, Messages).
- **Handicap default** — the ruleset a new game with handicap stones receives when the user has not chosen one: the Chinese preset, whose white handicap bonus compensates White one point per free stone (Tromp-Taylor compensates nothing). The default follows the handicap only while *untouched*; an explicit ruleset choice always wins and never flips back.
- **Untouched rules** — rules the user has neither picked from the preset list nor edited knob-by-knob. Only untouched rules retarget themselves when the handicap changes. Rules identical to the default count as untouched: indistinguishable states are treated the same.
