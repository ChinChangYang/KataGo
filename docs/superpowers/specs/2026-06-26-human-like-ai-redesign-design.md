# Human-like AI Redesign

**Date:** 2026-06-26
**Status:** Approved (design)
**Branch:** ios-dev

## Problem

The Human-SL profile menu (`HumanSLModel.allProfiles`) exposes ~283 raw engine
strings verbatim:

- `AI`
- 29 × `rank_<rank>` (post-AlphaZero KGS-rank style)
- 29 × `preaz_<rank>` (pre-AlphaZero KGS-rank style)
- 224 × `proyear_<year>` (`proyear_1800` … `proyear_2023`)

Two problems:

1. **Duplication / confusion.** Every rank appears twice (`rank_9d` *and*
   `preaz_9d`) with no guidance on which to pick. The per-profile strength comes
   from a hand-rolled per-`level` formula in `HumanSLModel`, not from any
   calibrated measurement.
2. **Ugly menu items.** Entries read like internal identifiers
   (`proyear_2023`, `rank_5k`) rather than natural menu labels.

Meanwhile, upstream KataGo PR
[#1209](https://github.com/lightvector/KataGo/pull/1209) ("Add Human-SL KGS-rank
ladder") provides an **empirically calibrated** ladder: 29 configs
`gtp_human<rank>.cfg` (9d→20k), each tuned via the new `tunehuman` subcommand so
consecutive ranks are exactly 1 KGS stone apart. Each config uses
`humanSLProfile = preaz_<rank>` plus a tuned `humanSLChosenMovePiklLambda`.

## Goals

1. **Consolidate** each `rank_<rank>` / `preaz_<rank>` pair into a single unified
   `<rank>` menu entry, driven by PR #1209's calibrated configs.
2. **Rename** `proyear_<year>` to the natural label `Pro <year>`, with pro
   configs derived from the 9d config but `λ = 0.06` (empirically used by the old
   formula's `proyear` branch).
3. Keep the change focused on `HumanSLModel` and its consumers; the app continues
   to own visits / threads / time / rules.

## Non-goals

- Importing PR #1209's `maxVisits = 400`, `numSearchThreads`, `delayMove*`,
  `rules`, logging, or resign settings. Those are app-managed.
- Changing the SwiftData `Config` schema (frozen — see project memory). The
  stored `humanSLProfile` stays a free-form `String`; only the *values* change.
- Curating the pro-year list. Per the approved decision, **all 224 years are
  kept**, only relabeled.

## Design

### Profile keys (`HumanSLModel.allProfiles`)

The stored `Config.humanSLProfile` value becomes the clean **menu key** (key ==
display label). New set, in menu order:

```
["AI"]
+ ["9d","8d","7d","6d","5d","4d","3d","2d","1d","1k","2k", … ,"20k"]   // 29 ranks, 9d→20k
+ ["Pro 1800","Pro 1801", … ,"Pro 2023"]                              // 224 pros, oldest→newest
```

Total: 1 + 29 + 224 = **254** entries (down from ~283, and no more duplicate
ranks).

### Key → engine mapping

`HumanSLModel` translates the menu key into the actual engine values. The
`humanSLProfile` computed property (the value sent via
`kata-set-param humanSLProfile`) and the λ become key-driven:

| Menu key      | engine `humanSLProfile` | `humanSLChosenMovePiklLambda` |
|---------------|-------------------------|-------------------------------|
| `AI`          | `rank_9d`               | `0.06` (unchanged)¹           |
| `9d` … `20k`  | `preaz_<rank>`          | #1209 tuned table (below)     |
| `Pro <year>`  | `proyear_<year>`        | `0.06`                        |

¹ For `AI`, `humanSLChosenMoveProp = 0` and the explore probs are 0, so λ has no
effect. This redesign keeps the `AI` profile's emitted parameter **values**
unchanged (same λ 0.06 and same level-9 temperatures 0.67/0.16/26 it produces
today; only the float *formatting* is cleaner, e.g. `0.66999996` → `0.67`, a
<1e-7 difference). `AI` is also the sentinel used for "Human"-labelled sides via
`effectiveHumanProfileForBlack/White`, so preserving its values avoids any
analysis regression.

### #1209 tuned λ table (exact, from the committed config files)

```
9d  0.045     1d  0.50930    10k 0.59036
8d  0.08680   1k  0.48988    11k 0.56458
7d  0.12670   2k  0.46755    12k 0.54297
6d  0.19830   3k  0.49173    13k 0.58977
5d  0.28064   4k  0.47130    14k 0.61625
4d  0.37300   5k  0.50720    15k 0.61839
3d  0.45556   6k  0.48925    16k 0.67050
2d  0.51330   7k  0.53370    17k 0.74130
             8k  0.50640    18k 0.78210
             9k  0.53880    19k 0.89820
                            20k 1.22270
```

### Emitted commands (`HumanSLModel.commands`)

The command **shape is unchanged** — the same 11 `kata-set-param` lines the model
emits today. Only the *values* change. Base `default_gtp.cfg` already sets
`humanSLChosenMoveIgnorePass = true` and `humanSLCpuctExploration/Permanent =
0.50/2.0` (matching #1209), so **no new commands are required**.

For a **human profile** (any rank or pro), the constants below come straight from
#1209's `gtp_human*.cfg` and are now identical across all human profiles except
`humanSLProfile` and λ:

| param                              | human value         | old (formula) value        |
|------------------------------------|---------------------|----------------------------|
| `humanSLProfile`                   | `preaz_<rank>` / `proyear_<year>` | `rank_*`/`preaz_*`/`proyear_*` |
| `humanSLChosenMoveProp`            | `1.0`               | `1.0`                      |
| `humanSLRootExploreProbWeightless` | **`0.8`**           | `0.5`                      |
| `chosenMoveTemperatureEarly`       | **`0.70`**          | `min(0.85, 0.70-(level-8)*0.03)` |
| `chosenMoveTemperature`            | **`0.25`**          | `min(0.70, 0.25-(level-8)*0.09)` |
| `chosenMoveTemperatureHalflife`    | **`30`**            | `30-(level-8)*4`           |
| `chosenMoveTemperatureOnlyBelowProb` | **`1.0`**         | `pow(10,(level-8)*0.2)` clamped |
| `humanSLChosenMovePiklLambda`      | table / `0.06`      | `0.06+(level-9)²*0.03`     |
| `winLossUtilityFactor`             | **`1.0`** ⚠️        | `0.0`                      |
| `staticScoreUtilityFactor`         | `0.5`               | `0.5`                      |
| `dynamicScoreUtilityFactor`        | `0.5`               | `0.5`                      |

⚠️ **Biggest behavioral change:** `winLossUtilityFactor` goes `0.0 → 1.0`. Human
play changes from *pure imitation* to *play human-shaped moves but actually try to
win*, with moves KataGo dislikes suppressed via λ. This is exactly #1209's
calibrated recipe and the reason the λ ladder is meaningful.

For the **`AI` profile** (unchanged from today):

| param | value |
|-------|-------|
| `humanSLProfile` | `rank_9d` |
| `humanSLChosenMoveProp` | `0.0` |
| `humanSLRootExploreProbWeightless` | `0.0` |
| `chosenMoveTemperatureEarly / Temperature / Halflife / OnlyBelowProb` | `0.67 / 0.16 / 26 / 1.0` (today's level-9 values — `chosenMoveTemperature` *does* still affect AI's own move selection, so it is kept unchanged, **not** set to the human constants) |
| `humanSLChosenMovePiklLambda` | `0.06` (unchanged; no effect since prop 0) |
| `winLossUtilityFactor` | `1.0` |
| `staticScoreUtilityFactor` | `0.1` |
| `dynamicScoreUtilityFactor` | `0.3` |

### Pros derived from the 9d config

`Pro <year>` emits the **identical** human constant set as a rank, with only:

- `humanSLProfile = proyear_<year>`
- `humanSLChosenMovePiklLambda = 0.06`

This is the literal "derived from the 9d config but λ = 0.06" requirement
(the 9d config differs only by `humanSLProfile = preaz_9d`, λ = 0.045).

### Internal model shape

`HumanSLModel` is rewritten around the new key space:

- `allProfiles` → built from the new key lists above.
- A static λ lookup for ranks (`["9d": 0.045, …, "20k": 1.22270]`).
- `humanSLProfile` (engine value): `AI → rank_9d`; rank key → `preaz_<rank>`;
  `Pro <year>` → `proyear_<year>`.
- The `level` property and all per-`level` formula computed properties are
  **deleted** (no longer referenced once temperatures and λ are constants/table).
- `init?(profile:)` validates against `allProfiles`.

### Legacy stored-value normalization (flagged decision)

Project memory says "skip migration; app unreleased," but the developer has a
large iCloud-synced game library whose `Config.humanSLProfile` may hold old
engine strings. To avoid those games silently resetting to `AI`,
`HumanSLModel.init?(profile:)` (and the `profile` setter) will **normalize**
legacy inputs before validation:

- `rank_<r>` → `<r>`  (e.g. `rank_9d` → `9d`)
- `preaz_<r>` → `<r>` (e.g. `preaz_9d` → `9d`)  ← both legacy ranks collapse to the unified key
- `proyear_<y>` → `Pro <y>`
- `AI` → `AI`

This is input-validation, not a SwiftData schema migration. Unknown/garbage
inputs still fail validation (→ caller falls back to default, as today).

## Consumers / blast radius

Heart of the change is `KataGoUICore/.../Model/HumanSLModel.swift`. Consumers that
need no logic change because they pass keys through and re-emit via the model:

- `GtpCommandBuilder.symmetricHumanAnalysisCommands` → `HumanSLModel(profile:).commands`
- `GobanState` (analysis emission, gen-move), `GameSession` (analysis emission),
  `ConfigEngineSync` (black/white profile sync) — all route the stored key through
  `HumanSLModel`.
- `Config.effectiveHumanProfileForBlack/White` → returns `"AI"` sentinel or the
  stored key; both remain valid keys.

Display gets clean labels for free:

- `StoneView` player-name label renders the stored key (now `9d` / `Pro 2023` /
  `AI`).

Pickers iterate `allProfiles` and show the key as label — automatically clean:

- iOS `ConfigView.HumanStylePicker` (`Text(profile)`).
- macOS `ConfigEditorViewController` and `InspectorInfoViewController`
  (flat `options:` + `firstIndex(of:)`).

(Picker grouping/sectioning for the long pro list is out of scope; lists stay
flat with sensible ordering.)

## Testing (TDD)

Update and extend the affected suites:

- `HumanSLModelTests` (new or expanded): for representative keys
  (`AI`, `9d`, `5k`, `20k`, `Pro 1800`, `Pro 2023`) assert the emitted
  `commands` contain the correct `humanSLProfile`, λ, `winLossUtilityFactor 1.0`
  (humans) / `1.0` (AI), constant temperatures, and root-explore `0.8` (humans) /
  `0.0` (AI). Assert `allProfiles` membership/counts and legacy normalization
  (`rank_9d`/`preaz_9d` → `9d`, `proyear_2023` → `Pro 2023`).
- `GtpCommandBuilderTests`: replace `rank_5k`/`rank_9d` literals with new keys
  (`5k`, and `AI` → `rank_9d` engine value still emitted).
- `ConfigModelTests`: replace `rank_5k` / `proyear_2000` literals with new keys
  (`5k`, `Pro 2000`); effective-profile expectations updated accordingly.
- `PlayerLabelTests`: labels now read `9d` / `5k` etc.; update expectations.
- `PlayerNameLabelUITests` + `StoneView` preview strings: update sample profile
  strings to new keys.

## Verification

- iOS Simulator unit tests green (FastTestPlan + the affected suites).
- 3-platform build (iOS, visionOS, macOS) per CLAUDE.md.
- Manual spot-check: pick a rank and a `Pro <year>` for an AI side; confirm the
  GTP log shows `humanSLProfile preaz_<rank>` / `proyear_<year>`, the tuned λ, and
  `winLossUtilityFactor 1.0`; confirm the player label reads the clean key.

## Risks

- **Strength shift.** `winLossUtilityFactor 0→1` plus the calibrated λ ladder
  meaningfully changes how every human profile plays (stronger, less purely
  imitative). This is intended (it is the point of adopting #1209).
- **λ calibrated at 400 visits / Japanese rules.** The app runs time-based search
  and user-chosen rules, so the 1-stone-per-rank spacing is approximate in-app.
  Acceptable; documented here.
