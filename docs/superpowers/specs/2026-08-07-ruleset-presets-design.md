# Ruleset Presets in the Per-Game Rule Editors

**Date:** 2026-08-07
**Status:** Approved

## Problem

Tester feedback: users want to set up Chinese-like, Japanese-like, Tromp-Taylor,
OGS/KGS, AGA-like, New Zealand-like, or Stone-Scoring rules, but the UI never
shows how. The per-game rule editors expose only KataGo's six granular knobs
(Ko rule, Scoring rule, Tax rule, Multi-stone suicide, Has button, White
handicap bonus), so a user has to know the mapping table on
lightvector's rules page (https://lightvector.github.io/KataGo/rules.html) by
heart to reproduce a named ruleset.

The mapping infrastructure already exists in the shared package:
`NewGameRuleset` / `NewGameRules` (KataGoUICore) expand a named preset to its
concrete components by parsing `RU[<token>]` through the engine's own SGF
parser, and the macOS New Game dialog already uses it (preset picker fills the
granular rows; hand-editing a row flips the picker to "Custom"). The per-game
editors do not.

## Goal

Users can set up any of KataGo's named rulesets from the app UI without knowing
the knob mappings. The mapping is embedded functionally — a preset picker —
rather than as a reference table.

## Decisions (from brainstorming)

1. **UX shape:** Ruleset preset picker (the Mac New Game pattern), not a
   read-only mapping reference.
2. **Surfaces:** the iOS rules sheet (`RuleConfigView`) and the macOS per-game
   Config editor (`ConfigEditorViewController`). Apple TV stays read-only (its
   label gets more accurate as a side effect, see Persistence).
3. **Preset list:** all named rulesets the engine parses — 11 presets + Custom.
4. **Komi:** picking a preset also auto-sets komi to the ruleset's default;
   the user can hand-edit komi afterwards (komi is not part of preset
   matching).
5. **Apply mechanism:** per-knob `ConfigEngineSync` setters (six
   `kata-set-rule` commands + `komi`), never `kata-set-rules`, so the app's
   forced `friendlyPassOk false` policy holds and config/engine cannot desync.

## Design

### Shared model (KataGoUICore)

**Extend `NewGameRuleset`** with four cases:

| Case | Display name | SGF token |
|------|--------------|-----------|
| `chineseOGS` | Chinese (OGS/KGS) | `chinese-ogs` |
| `agaButton` | AGA Button | `aga-button` |
| `stoneScoring` | Stone Scoring | `stone-scoring` |
| `ancientTerritory` | Ancient Territory | `ancient-territory` |

All four tokens are accepted by `Rules::parseRules` (`cpp/game/rules.cpp`), so
`NewGameRules.expand()` needs no changes. Picker order
(`NewGameRuleset.pickerCases`): Chinese, Chinese (OGS/KGS), Japanese, Korean,
AGA, BGA, AGA Button, New Zealand, Tromp-Taylor, Stone Scoring, Ancient
Territory, Custom. The macOS New Game dialog renders `pickerCases`, so it picks
up the four new presets automatically — a desired consistency side effect.

`NewGameRules.suggestedKomi()` already agrees with `rules.cpp`'s per-preset
komi for all 11 presets (territory scoring → 6.5, button → 7.0, else 7.5),
including the new four.

**New `ConfigEngineSync.applyRuleset(preset, config, messageList)`**: expands
the preset via `NewGameRules.expand()` and calls the six existing per-knob
setters (`setKoRule`, `setScoringRule`, `setTaxRule`,
`setMultiStoneSuicideLegal`, `setHasButton`, `setWhiteHandicapBonusRule`) plus
`setKomi(NewGameRules.suggestedKomi(components))`. No-op for `.custom`.

**Persistence via the existing `Config.rule` Int** (no SwiftData schema
change — the field already exists and is synced):

- Append the five missing tokens to `Config.rules` (append-only so the six
  existing indices, and every synced record, stay valid):
  `tromp-taylor`, `chinese-ogs`, `stone-scoring`, `aga-button`,
  `ancient-territory`. Final array:
  `["chinese", "japanese", "korean", "aga", "bga", "new-zealand",
  "tromp-taylor", "chinese-ogs", "stone-scoring", "aga-button",
  "ancient-territory"]`.
- On preset pick → store that preset's index (mapped via SGF token ↔
  `Config.rules` entry; add a small `NewGameRuleset` ↔ `Config.rule` index
  mapping helper).
- On a hand-edit whose components no longer match any preset → store `-1`
  (Custom sentinel). `TVReviewScreen`'s existing `indices.contains` guard
  already renders out-of-range as "Custom", so TV labels get more accurate for
  free.
- Displayed picker value = `NewGameRules.match(currentComponents,
  preferring: preset(from: config.rule))`. The stored label is only a
  tie-breaker for engine-identical pairs (Japanese/Korean, AGA/BGA) so the
  user's chosen label survives relaunch; it is never trusted blindly, so a
  stale stored label cannot misrepresent the actual knobs.

### iOS rules sheet (`RuleConfigView`, `KataGo iOS/Config/ConfigView.swift`)

A `ConfigTextPicker` row titled **"Ruleset"** directly above "Ko rule" (board
size rows stay above it — board size is not part of a ruleset). Options: the
twelve `pickerCases` display names. "Custom" is selectable but a no-op on the
knobs, exactly like the Mac New Game dialog.

- `onAppear`: selection = `match(componentsFromConfig, preferring:
  storedPreset)`.
- Picking a named preset: `ConfigEngineSync.applyRuleset(...)`, store
  `config.rule`, refresh all six knob `@State`s plus `komiText`, set
  `isRuleChanged`.
- **Echo suppression** (no timing-sensitive flags): applying a preset
  programmatically updates the knob `@State`s, which fires their `.onChange`
  handlers. Each knob handler first checks whether the new value already
  equals the config's value — if so it is an echo of a programmatic set and
  skips the engine send. Then it recomputes the picker selection via
  `match(components, preferring: current)`: after a preset apply this returns
  the preset (no flip); after a genuine hand-edit it returns `.custom`, flips
  the picker, and stores the `-1` sentinel.

### macOS Config editor (`ConfigEditorViewController`)

A "Ruleset" `popupRow` above Ko in the Rules section, mirroring
`NewGameViewController`'s existing row. Preset pick → `applyRuleset` + store
`config.rule` + refresh the component popups/checkbox and the komi row.
Component-row handlers select the matching picker entry via
`match(preferring:)` and store the sentinel on mismatch. AppKit callbacks are
direct calls — no cascade/echo concern.

### Engine-sync semantics

`applyRuleset` sends exactly the six `kata-set-rule` commands plus `komi` —
byte-identical to what a game reload replays (`GameSession` /
`GobanState.loadGame` ruleCommandsBundle) — and never `kata-set-rules`.
`GtpCommandBuilder.rulesetCommand` remains test-only. Mid-game semantics are
unchanged from today's per-knob edits (`isRuleChanged` still drives the
existing on-disappear refresh).

## Testing

Unit tests extend `NewGameRulesetTests.swift` in the **KataGo iOSTests** target
(runs under the real xcodebuild iOS-Simulator gate):

- Expansion of the four new presets matches `rules.cpp`'s component values.
- `match()` round-trips all eleven named presets.
- `config.rule` index ↔ preset mapping, including the `-1` Custom sentinel and
  out-of-range values.
- A guard that the first six `Config.rules` entries keep their historical
  order (index stability for synced records).

UI behavior is verified manually via the `verify` skill flow (config sheet on
the iOS Simulator; Mac editor on a signed Debug build). No new UI tests.

## Out of scope

- Apple TV rule *editing* (stays read-only).
- visionOS/watchOS surfaces (no rule editors there).
- A reference table / link to lightvector's rules page in the UI.
- Changing `friendlyPassOk` policy or using `kata-set-rules` at runtime.

## Implementation notes (deltas discovered and shipped, 2026-08-07)

1. **White-handicap-bonus order fix (prerequisite).** Planning uncovered a live
   bug this feature sat on: `Config.whiteHandicapBonusRules` was
   `["0", "N-1", "N"]` while the enum raw values, the C++ `Rules::WHB_*`
   constants, and the bridge parser mean 0/N/N-1. `GobanState.switchGame`
   assigns the bridge enum and replays the array text, so an SGF-loaded
   `RU[chinese]` game (whb=N) sent `whiteHandicapBonus N-1`, oscillating
   N↔N-1 across save/load cycles; the Mac Config editor popup mislabeled the
   same way. The array is now `["0", "N", "N-1"]` (index == rawValue == C++
   constant) and `NewGameRules.whiteHandicapBonusLabels` aliases it. The
   meaning-flip for old picker-persisted records ships without migration
   (tester data disposable).
2. **TV label derivation.** `TVReviewScreen.ruleText` now reads
   `NewGameRuleset.preset(fromConfigRule:)?.displayName ?? "Custom"` — the
   old token prettifier would render the newly reachable tokens wrongly
   ("Chinese Ogs"). Display only; TV editing stays out of scope.
3. **Same-components pick persists the label only.** Refining Decision 4:
   when a picked preset's expansion already equals the current components
   (the picker's programmatic snap after a hand-edit, or a relabel between
   engine-identical presets such as Japanese → Korean), only `config.rule`
   is written — no GTP, no komi reset — and only when the index actually
   differs, so opening the sheet never dirties the synced record. On macOS,
   AppKit reports an explicit re-pick of the already-selected item (SwiftUI
   cannot), so a same-label re-pick there re-applies fully and restores the
   preset's default komi.
