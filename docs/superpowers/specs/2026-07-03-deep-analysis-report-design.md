# Deep Analysis Report — Design

- **Date:** 2026-07-03
- **Status:** Implemented (see docs/superpowers/plans/2026-07-03-deep-analysis-report.md)
- **Platforms:** iOS, visionOS, macOS. tvOS excluded (no FoundationModels; feature never presented there).

## 1. Summary

An on-demand, per-position study report for KataGo Anytime. The user triggers "Deep Report"
from the More menu (iOS/visionOS) or a Game menu item (macOS). A sheet opens instantly with a
skeleton layout; engine probes fill the sections progressively over ~5 seconds; a Foundation
Models narrative streams in last. The report is **data-first**: every number and coordinate is
engine truth rendered natively (mini-boards, delta heatmaps, tables); the LLM only narrates
deterministic facts handed to it.

Report contents, top to bottom:

1. **Header** — game name, move number, side to move, visits/s, "quick estimate" badge when
   probe visits are low.
2. **Position summary** — current win rate, score lead, total visits (from `rootInfo`).
3. **Candidates** (top 2 by visits) — per candidate: mini-board with a PV / Δ-ownership
   toggle, win-rate/score deltas, and a **tenuki callout** ("if ignored, X follows up with …")
   from a play→analyze→undo probe.
4. **AI move vs. pass** — ownership-delta heatmap and value deltas between the best candidate
   and the pass scenario: which areas are firm vs. contested.
5. **Streamed narrative** — Foundation Models prose in the game's configured tone; hidden when
   Apple Intelligence is unavailable or the game's `useLLM` toggle is off.
6. **Footer actions** — Copy summary to comment, Regenerate.

## 2. Goals and non-goals

**Goals (v1):**

- Per-candidate ownership change vs. the current position.
- Tenuki insight: the AI's follow-up at N+3 if the opponent ignores the candidate at N+1.
- AI-move-vs-pass comparison (win rate, score lead, ownership delta).
- Principal variation per candidate, shown as numbered ghost stones.
- Streaming, progressively rendered report; ~5 s end-to-end on a modern iPhone.
- Ephemeral reports with a copy-to-comment escape hatch.

**Non-goals (v1):**

- Persisting structured reports (regeneration is cheap; schema is frozen).
- Markdown/AttributedString rendering (native SwiftUI layout carries the formatting).
- Any tvOS surface.
- Live-updating reports that track board navigation (a report is a snapshot of one position;
  the modal sheet makes that honest).

## 3. Decisions (brainstorm outcomes)

| Question | Decision |
|---|---|
| Core value | Data-first; LLM narrates deterministic facts only |
| Probe depth | Tenuki probes included in v1 (play→analyze→undo) |
| Time budget | ~5 s quick: 2 candidates, time-budgeted probes (not fixed visits) |
| UI surface | Modal sheet on all platforms; one shared SwiftUI view |
| Persistence | Ephemeral + copy-to-comment (narrative or templated summary) |
| Architecture | Swift-side orchestrator over the existing single GTP stream |

Rejected alternatives: a C++ composite GTP command (atomic but permanent upstream-merge
friction in `gtp.cpp`, and fights progressive rendering); the JSON analysis-engine mode
(request IDs + arbitrary positions would dissolve the correlation/mutation problems, but needs
a second engine instance — impossible on iOS at ~1.2 GB steady — or a costly mode switch).

## 4. Load-bearing constraints (discovered in exploration)

- **PV is config-gated:** the engine always emits `pv`, but the shipped `default_gtp.cfg` sets
  `analysisPVLen = 1`, a const read once at startup that `kata-set-param` cannot change.
  v1 changes the cfg to `analysisPVLen = 15` (app-wide effect; parser fixture-tested).
- **`movesOwnership` exists but would corrupt the current parser:** `AnalysisLineParser`'s
  `/ownership (...)/` regex would match the `movesOwnership` block first. The parser fix and
  its regression test land before the feature ever requests the option.
- **Analyze-family player argument = free hypothetical probes:** analyzing the unchanged board
  with the opponent to move is the pass scenario; after playing a candidate, analyzing with the
  same color to move is the tenuki scenario. Only the candidate `play` mutates state.
- **Single GTP stream, no request IDs:** `GameSession.messaging()` is the only reader; any
  command cancels an in-flight analyze; `kata-set-param maxVisits` is sticky (3 existing
  re-arm sites reset it; the report re-arm becomes the 4th).
- **Probes use `kata-analyze` only** (never the search-analyze family), so the
  cancelled-search stray-`play` gotcha is designed out rather than guarded.
- **SwiftData schema is frozen (CloudKit):** no new stored fields; report types are plain
  structs; persistence only via the existing `comments` dictionary.
- **No runtime `SystemLanguageModel.availability` check exists in the app today** — the report
  adds one (net-new).
- **No Markdown/AttributedString rendering exists** — deliberately kept out; native layout.
- **Engine perspective contract:** engine emits White-perspective (`reportAnalysisWinratesAs =
  WHITE`); Swift flips to side-to-move. Pass/tenuki probes flip the side to move, so all report
  values are normalized to the reported position's side-to-move at collection time.
- **iOS runs the engine in-process (~1.2 GB steady with two nets):** no second engine; probes
  and the LLM never run concurrently (Neural Engine contention).

## 5. Architecture

New code lives in the `KataGoUICore` package (no pbxproj surgery) except two entry-point edits
in existing app-target files.

- **`DeepReportGenerator`** — orchestrates the probe sequence over the existing
  `KataGoEngineIO` transport, per `GameSession` (multi-window Mac safe).
- **`ReportCollector`** — receives parsed analysis lines while report mode is active, so probe
  data never clobbers the live `Analysis` object (board overlay, chart).
- **`AnalysisLineParser` extensions** — `pv`, `movesOwnership`, `rootInfo` winrate/scoreLead,
  raw-float ownership retention; root-ownership regex collision fixed first.
- **Report types** — `DeepReport`, `PositionSummary`, `CandidateReport`, `TenukiFollowUp`,
  `PassComparison`; `DeepReportModel` (@Observable) drives progressive UI.
- **`DeepReportView`** — shared SwiftUI sheet content; **`ReportBoardView`** — static vector
  mini-board (modeled on the widget board renderer) with stone, Δ-ownership, and numbered-PV
  overlay layers.
- **Narration** — `LanguageModelSession.streamResponse` over a deterministic fact list, behind
  `#if canImport(FoundationModels)` + runtime availability + the game's `useLLM` toggle.

## 6. User flow and gating

Trigger → sheet opens instantly (skeleton) → probes fill sections → narrative streams →
engine restored and live analysis re-armed → sheet stays open for reading. Dismiss or Cancel
mid-generation aborts and restores.

The action is **disabled** when: no game selected; engine not ready; an AI move is being
generated (its cancellable search would interleave); the game is in scoring/finished state.

## 7. Probe pipeline

All budgets are wall-clock, so faster devices get proportionally more visits. Sequence, fully
serialized in `DeepReportGenerator`:

1. **Enter report mode.** Set `GobanState.reportGenerationActive` — board taps and navigation
   ignored; `GameSession` routes analysis lines to the `ReportCollector`. Stop live analysis
   via the established force-`waitingForAnalysis` pattern. Ensure `maxVisits` unbounded.
2. **Snapshot probe (~2 s).** `kata-analyze interval 50 maxmoves 8 ownership true
   movesOwnership true rootInfo true`; `stop` at budget; keep the last report line. Yields
   candidates with PVs, raw root ownership, per-candidate ownership. Zero mutation.
3. **Pass probe (~1 s).** `kata-analyze <opponent> …` (player argument, unchanged board =
   pass scenario); last line yields the opponent's best punishment, root values, ownership.
4. **Tenuki probes (~1 s × 2).** For each top candidate `c` (skip pass candidates):
   `play <P> <c>` → `kata-analyze <P> …` (same color = opponent tenuki) → `stop` → `undo`.
   Last line yields the N+3 follow-up. The generator tracks an outstanding-plays counter
   (never exceeds 1) so abort always knows how many `undo`s restore the position. Probe plays
   bypass `GobanState` entirely — raw engine commands; record/branch bookkeeping untouched.
5. **Restore.** `showboard` to verify sync; exit report mode; re-arm live analysis through the
   existing re-arm path (which resets `maxVisits`).
6. **Narrate.** Only after probes finish: format all facts deterministically, then stream the
   narrative. Instructions forbid invented numbers/coordinates and require treating
   within-noise deltas as "about even" (initial constants: win-rate deltas < 2 percentage
   points, score deltas < 1.0 points, whenever the probe's visits < 100). Temperature from
   `Config.temperature`, tone from the game's `CommentTone`.

**Abort/failure paths** (Cancel, sheet dismissed, engine `?` line, no analysis data after a
stage's fixed budget, app backgrounding): one restore function — `stop`, `undo` × outstanding
plays, `showboard`, exit report mode, re-arm. Safe to call from any state.

## 8. Data model and parser

Parser changes (shared path; regression-tested against current fixtures):

- `pv` per info block (vertex list, terminated by next keyword). Depends on the cfg change.
- `movesOwnership` per info block; root-ownership extraction re-anchored so the two never
  collide (collision regression test lands first).
- `rootInfo` winrate/scoreLead parsed (today only `visits` is) — position summary and probe
  values come from `rootInfo`, better than the max-visits-candidate proxy.
- Raw float ownership retained in new fields; the digitized `OwnershipUnit` path is untouched
  (the 1/5-step digitization would swallow small deltas).

Report types are plain structs; `PassComparison` includes a deterministic contested-points
extraction (top 8 points by |Δ|, grouped into named board regions such as "upper right") so
the LLM receives named facts, never grids.

## 9. UI and LLM layer

- Presentation: `.sheet` + `NavigationStack` (iOS/visionOS); `NSHostingController` +
  `presentAsSheet` (macOS), env-object injection per the `InspectorTabs` wrapper pattern.
- Mini-boards: `ReportBoardView`, static vector rendering; segmented toggle per candidate
  between PV (numbered ghost stones) and Δ-ownership (direction-encoded black/white alpha
  squares matching the live ownership idiom — user choice in round 2, superseding the
  original blue/orange pair). Round 2 also rebuilt the boards on the app's real components
  (`BoardLineView` wood/coordinates + `StoneView` styles + `MoveNumberView`).
- Numbers: existing formatter helpers; delta arrows with sign; per-probe visit counts; "quick
  estimate" badge under ~100 visits.
- Progressive rendering: skeleton (`redacted`) sections fill as the collector publishes;
  narrative streams token-wise. Toolbar: progress + Cancel during generation; Copy-to-comment
  + Regenerate when complete.
- LLM output is a plain streamed `String`; formatting comes from native layout, not the model.
- Gating: `#if canImport(FoundationModels)` + `SystemLanguageModel.availability == .available`
  + the game's `useLLM` toggle. `useLLM` on but model unavailable → one-line hint; the data
  report is complete without the narrative.
- Copy to comment: appends the narrative (or a templated fact summary when LLM is off) to
  `gameRecord.comments[currentIndex]` via the existing comment persistence path.

## 10. Platform integration

- **iOS/visionOS:** "Deep Report" item in `PlusMenuView` (icon `doc.text.magnifyingglass`),
  sheet trigger as local `@State` (Configurations-sheet pattern).
- **macOS:** Game-menu item (no shortcut in v1) → `MainWindowController` action →
  `NSHostingController(rootView:)` → `presentAsSheet`. Per-window session/engine makes
  multi-window naturally safe.
- **Files:** all new logic in `KataGoUICore`; only the two entry points touch app targets
  (existing files — no pbxproj registration needed).
- **Config:** `Resources/default_gtp.cfg`: `analysisPVLen = 15`.
- **tvOS:** package still compiles (FoundationModels code behind `canImport`); the view is
  never presented.

## 11. Edge cases

- **Branch active:** works; probes read the engine's current position and bypass `GobanState`
  bookkeeping (`branchSgf`/`branchIndex` untouched). Header shows the branch move number.
- **Pass among candidates:** no tenuki probe (pass-then-pass is game end); row still shows
  values and ownership.
- **Endgame/scoring, AI-to-move, engine restarting:** action disabled.
- **Board sizes:** grids are width×height-dynamic, matching existing ownership handling.
- **Memory/NE contention:** probes and LLM serialized; `movesOwnership` only in the one-shot
  snapshot probe (`maxmoves 8`), never the continuous live stream.

## 12. Testing

- **Parser:** fixtures for `pv` presence, `movesOwnership`/root-ownership collision (lands
  before the feature), `rootInfo` winrate/scoreLead, raw-float retention; existing fixtures
  unchanged.
- **Generator:** scripted fake `KataGoEngineIO` transport drives happy path, cancel during
  each step, engine error mid-tenuki (outstanding-`undo` restore), watchdog timeout, and the
  `maxVisits` re-arm.
- **Perspective normalization:** dedicated tests for all three probe types × both colors to
  move — the highest-risk correctness detail.
- **UI:** RenderPreview snapshots: skeleton, partial, complete, LLM-unavailable, small board.
- **Manual QA:** device latency vs. the 5 s budget; Mac sheet; cancellation mid-generation
  with `showboard` board-state verification; a branch-position report.
- **Gate:** local iOS Simulator test suite (CI runs no tests).

## 13. Deferred (v2 candidates)

- Depth picker (quick/standard/deep probe budgets).
- Persistent/structured report storage and report sharing.
- Non-modal macOS report window with staleness indicator.
- Tapping a report candidate to play it on the live board.

## 14. Round 3 — UI polish (2026-07-03 user + external-reviewer feedback)

Presentation-layer only; probes, budgets, and data flow unchanged.

- **Title:** sheet titled "Deep Analysis Report" everywhere. On macOS the AppKit-presented
  sheet's window title must be set explicitly (SwiftUI `navigationTitle` never reaches it —
  it showed "Untitled"). Game name stays as the content heading.
- **Candidate labels:** first candidate = "Best Move <vertex>", others = "Alternative
  <vertex>". The best move drops its "(+0%)" delta; alternatives keep the delta (now clearly
  vs. the best move). Narrator facts use the same labels.
- **Stats:** one inline pattern everywhere ("37% win rate · -1.3 points · 1,054 visits");
  the header's label-above-value grid is removed. Visit counts get thousands separators.
- **Boards:** fill the sheet's content width (≥80% of sheet width; the old 360 pt cap is
  removed), still square, coordinates on.
- **Tenuki sentence:** names both sides — "If <opponent> ignores <candidate>, <side> follows
  up with <vertex> (…)".
- **Marked moves:** Δ-ownership boards draw the candidate's stone with the app's red
  current-move dot; the Playing-vs-Passing board draws the best move the same way (playing
  move only — the punishment reply stays text).
- **Low-visit treatment:** shared orange badge "Quick estimate — only N visits"
  (exclamation icon); a low-visit candidate's stats + board render slightly dimmed while its
  heading and badge stay full-opacity.
- **Toolbar:** macOS uses text buttons ("Regenerate", "Copy to Comment", "Done"/"Cancel")
  with tooltips, per Mac sheet convention; iOS/visionOS keep the icon buttons.

Round 4 (2026-07-04 follow-up, presentation only): the position stats line above "Best
Move" is removed (header keeps game name / move / visits-per-second); a `Divider()` sits
above every "Best Move"/"Alternative" heading and above "Playing vs. Passing"; the pass
sentence names the punishing color ("White would punish at K14", not "the opponent"), UI
and narrator facts alike; on iOS/visionOS a `ToolbarSpacer(.fixed)` separates
Copy-to-Comment from Done so they are not grouped into one trailing capsule.
