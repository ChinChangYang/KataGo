# Rank Is Strength — Fixed-Visit Human Play

**Date:** 2026-06-26
**Status:** Approved (design)
**Branch:** ios-dev
**Follows:** `2026-06-26-human-like-ai-redesign-design.md` (the #1209 rank ladder)

## Problem

The Human-like AI redesign adopted PR #1209's calibrated KGS-rank ladder, where
each rank's `humanSLChosenMovePiklLambda` (λ) was tuned at a **fixed 400-visit**
search budget so consecutive ranks sit ~1 KGS stone apart.

The app, however, drives engine moves on a **time budget**, not visits:
`getRequestAnalysisCommands` (GobanState) emits `kata-set-param maxTime
max(thinkingTime, 0.5)` before `kata-search_analyze_cancellable`, and never sets
`maxVisits` (it is commented out in `default_gtp.cfg`, i.e. effectively
unbounded). At the 0.5s quick-toggle default a phone reaches only tens-to-~150
visits — far below 400 — and #1209's own config warns λ needs "at least hundreds
and ideally thousands of visits" to suppress blunders.

Two consequences:

1. **The rank promise is unreliable.** A side labelled `9d` is only ~9d near the
   calibration budget. At short thinking times it plays softer/blunderier; at long
   times, stronger. Rank differentiation still exists (the human-SL policy is
   rank-conditioned and works at any visit count), but the calibrated 1-stone
   spacing — which is λ's job — only holds near 400 visits.
2. **Two overloaded strength knobs.** "Time per move" silently rescales the
   strength that the rank is supposed to define. The two controls fight.

There is **no literal config conflict** (the app never sets `maxVisits`, and
#1209's `maxVisits = 400` was deliberately not imported). This is a
calibration-fidelity / UX problem.

## Decision

Adopt **"rank is the strength"**: a human-profile side plays at a **fixed visit
budget (400)**, so `9d` plays at the calibrated 9d regardless of device or
thinking time. "Time per move" applies **only** to the full-strength `AI`
profile.

`blackMaxTime`/`whiteMaxTime` keep their second job — the `> 0` / `= 0` flag for
"engine plays this side" vs "a human plays it" — because that drives the player
label, the `effectiveHumanProfile → "AI"` analysis routing, auto-play, and the
board player-label tap. Only the *magnitude* stops mattering for human profiles.

## Goals

1. A human-profile engine move searches a fixed 400 visits (the #1209 calibration
   point), independent of "Time per move".
2. `AI`-profile moves keep today's time-budgeted behavior.
3. Continuous analysis stays full-strength (unbounded visits) — only the move the
   engine *plays* is budget-capped.
4. The config UI stops exposing an irrelevant time magnitude for human profiles.

## Non-goals

- No SwiftData schema change (`blackMaxTime`/`whiteMaxTime` reused as the
  engine-on/off flag; see project memory: never modify SwiftData models).
- No user-facing "visits" control or per-rank budget tuning (YAGNI; 400 is fixed).
- No change to the `AI` profile's behavior, to analysis bias routing, or to the
  power-saving analysis pause.

## Design

### Engine layer (shared `KataGoUICore`)

All move/analysis commands already funnel through
`GobanState.getRequestAnalysisCommands`, which has exactly two exits — the
**gen-move** branch (engine's turn, `maxTime > 0`) and the **continuous-analysis**
branch. Both seams live there.

**1. New budget helper** in `GtpCommandBuilder`:

```
searchBudgetCommands(effectiveProfile: String, maxTime: Float) -> [String]
```

- `effectiveProfile == "AI"` →
  `["kata-set-param maxVisits <unboundedMaxVisits>", "kata-set-param maxTime \(max(maxTime, 0.5))"]`
- otherwise (human rank/pro) →
  `["kata-set-param maxVisits 400", "kata-set-param maxTime 60"]`

Constants: `humanSLPlayMaxVisits = 400` (the #1209 calibration point),
`unboundedMaxVisits = 1_000_000_000`, `humanSLPlaySafetyMaxTime: Float = 60`
(a backstop so a slow device/large net cannot hang; on normal devices the 400
visits bind first).

**2. `genMoveAnalyzeCommands` becomes budget-aware.** It gains an
`effectiveProfile` parameter and prepends `searchBudgetCommands(...)` before the
existing `kata-search_analyze_cancellable …` line (replacing the lone
`kata-set-param maxTime …`). `getRequestAnalysisCommands` already knows the side
(lines 83–86) and passes `config.effectiveHumanProfileForBlack` /
`effectiveHumanProfileForWhite`.

**3. Reset invariant.** Every exit of `getRequestAnalysisCommands` sets
`maxVisits` explicitly, so a prior human move's `maxVisits = 400` never leaks:
- AI gen-move → `unboundedMaxVisits` (via the helper).
- human gen-move → `400` (via the helper).
- continuous-analysis branch → prepend
  `kata-set-param maxVisits <unboundedMaxVisits>` before the `fastAnalyzeCommand`.

The implementation plan must grep for any other site that issues a bare
`kata-analyze` / `analyzeCommand` after a move and apply the same reset (the
dominant path is `getRequestAnalysisCommands`).

This seam is shared, so the change applies to **iOS, visionOS, and macOS**
(the macOS subprocess engine drives the same `GameSession`/`GobanState`).

### UI layer (per-side control becomes conditional on the profile)

For each side, the control shown next to the "Human profile" picker depends on
the selected profile:

- profile `== "AI"` → the existing **"Time per move"** stepper (0–60s; `0` = a
  human plays the side).
- profile is a human rank/pro → an **"Engine plays this side"** toggle: on/off
  maps to `maxTime` `0.5 ↔ 0` (reusing `Config.toggleAIThinkingTime` and the
  existing `blackMaxTime/whiteMaxTime` storage). The irrelevant magnitude is not
  shown.

Panes: iOS `ConfigView` (Black + White blocks) and macOS
`ConfigEditorViewController` + `InspectorInfoViewController`. The board
player-label tap (Human↔Engine, `0 ↔ 0.5`) is unchanged and stays consistent
with the new toggle.

### Consequence (intended)

A human-profile move searches a fixed 400 visits → calibrated rank strength on
every device, at a fixed ~1–5s per move (no longer user-tunable for human
sides). Full-strength `AI` play and analysis are unchanged.

## Testing (TDD)

- `GtpCommandBuilderTests`:
  - `searchBudgetCommands("AI", t)` → `maxVisits 1000000000` + `maxTime max(t,0.5)`.
  - `searchBudgetCommands("9d"/"Pro 1800", t)` → `maxVisits 400` + `maxTime 60`
    (magnitude `t` ignored).
  - `genMoveAnalyzeCommands(effectiveProfile:…)` emits the budget pair before
    `kata-search_analyze_cancellable`; update existing expectations
    (they currently assert the bare `kata-set-param maxTime …`).
- `GobanState`/builder: the continuous-analysis exit resets `maxVisits` to
  unbounded (assert the emitted command list begins with the reset).
- UI conditional is build-verified across the 3 panes; the existing
  `PlayerNameLabelUITests` still exercises the `AI`-profile stepper path.

## Verification

- iOS unit suite green; 3-platform build (iOS/visionOS/macOS).
- Manual: set a side to `9d` + Engine-on; confirm a move searches ~400 visits
  (visits-per-second overlay / move latency) regardless of the toggle; switch the
  side to `AI` and confirm the time stepper returns and bounds the move; confirm
  the continuous-analysis overlay is not capped at 400 after a human move.

## Risks

- **Move latency.** 400 visits is a fixed ~1–5s/move; slower than a 0.5s toggle.
  This is the deliberate cost of fidelity (the safety cap bounds the worst case).
- **Slow-device degradation.** If 400 visits exceeds the 60s backstop on a very
  slow device/large net, the move caps early (< 400 visits) and the rank softens
  there — an acceptable backstop, documented.
- **Calibration is still approximate** (400 visits, but the app's rules/komi and
  net may differ from #1209's Japanese-rules tuning). Rank spacing is "close",
  not exact — unchanged from the prior spec's accepted caveat.
