# 0001 — Default ruleset is the Tromp-Taylor preset (komi 7.5), centralized in the model's default constants

Date: 2026-08-11
Status: Accepted

## Context

The app's default game was born inconsistent, three different ways:

- A freshly constructed `Config` had komi 7.0 and the label "Chinese" (`rule = 0`), but
  its rule-knob defaults (white handicap bonus **0**) matched no preset, so the Ruleset
  picker showed **Custom**.
- The default SGF carried `RU[koSIMPLEscoreAREAtaxNONEsui0whbN]` (whb **N** — exactly
  Chinese) with `KM[7]`, so after a game load the picker showed **Chinese with komi
  7.0**, inconsistent with Chinese's suggested komi 7.5.
- macOS ⌘N and the tvOS New Game form each carried their own Chinese/7.5 defaults, and
  visionOS hardcoded komi 7.0 — per-surface drift.

Preset matching is komi-blind by design (a preset's identity is its six rule
components); the komi conventionally paired with a preset is a separate *suggested
komi* (6.5 territory, 7.0 button, 7.5 otherwise).

A standing project rule says "never modify SwiftData models" because the CloudKit
schema is frozen.

## Decision

1. The default game is the **Tromp-Taylor** preset — components POSITIONAL ko, AREA
   scoring, no tax, multi-stone suicide legal, no button, whb 0 — with its suggested
   komi **7.5**, on every surface that creates a game without user input: `Config()`
   defaults, the default SGF (named token `RU[tromp-taylor]`, `KM[7.5]`), macOS ⌘N,
   the tvOS New Game form, visionOS, photo import, and the Messages extension.
2. The change is made **in the SwiftData model's default-value constants**
   (`defaultKomi`, `defaultRule`, `defaultKoRule`, `defaultMultiStoneSuicideLegal`)
   rather than by overriding defaults at each creation site. This is deliberately
   carved out of the "never modify SwiftData models" rule: changing a default *value*
   is schema-neutral — no attribute is added, removed, renamed, or retyped; the
   append-only `Config.rules` array is untouched; existing records keep their stored
   values.
3. Existing games are **not migrated** — they keep their stored rules and komi
   (TestFlight-only tester data, standing no-migration policy).

## Consequences

- The Ruleset picker shows "Tromp-Taylor" for a brand-new game, never "Custom", and
  the default komi 7.5 is consistent with the displayed ruleset.
- Per-surface literals (visionOS, photo import, Messages) derive from or are
  test-locked to the single model default, so the default cannot silently drift
  per-platform again.
- Tromp-Taylor was chosen over Chinese-with-7.5 because it is upstream KataGo's own
  canonical ruleset (`default_gtp.cfg` already ships `rules = tromp-taylor`) and the
  cleanest logical rules; Chinese remains one tap away in the picker.
- Creation-site-only overriding was rejected because scattering defaults across
  surfaces is exactly the pattern that produced the original drift.
- **Handicap games under the default ruleset lose the N-point white handicap
  bonus**: the previous Chinese default was whb N, Tromp-Taylor is whb 0, so a
  default-rules N-stone handicap game (tvOS "Play KataGo", Messages) scores N
  points better for Black than before (handicap komi stays 0.5). This follows
  the Tromp-Taylor convention; picking Chinese restores the bonus.
