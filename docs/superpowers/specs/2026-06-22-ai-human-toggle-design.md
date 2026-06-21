# Tappable AI/Human Toggle — Design

**Date:** 2026-06-22
**Status:** Approved

## Problem

A side (black/white) plays as AI when its per-move thinking time is
positive (`Config.blackMaxTime` / `Config.whiteMaxTime` > 0) and as a
human when it is `0`. Today the *only* way to switch a side between AI
and human is to dig into **More ▸ Configurations ▸ Game Settings ▸ AI**
and nudge a "Time per move" stepper. That is slow and hidden for what is
the single most common in-game action: "let the computer take this side"
/ "let me play this side."

Meanwhile the board already shows, beside each color's captured-stone
count, a per-side label that reads `Human` or the AI profile (`AI` by
default) — but it is inert text. Users have no reason to suspect it can
be changed there.

## Goal

Make the per-color `Human`/`AI` label beside the captured-stone counts a
**tappable toggle**. Tapping it flips that side:

- `Human` → `AI` sets that side's thinking time to **0.5s**.
- `AI` → `Human` sets that side's thinking time to **0**.

Each color toggles independently. The toggle must be discoverable (look
like a control, not static text) yet fit the narrow strip above the
board.

## Non-goals / decisions

- **Always 0.5s on enable.** Toggling a side to AI always sets `0.5s`,
  even if a different value (e.g. `3s`) was previously set via the Config
  form. No "remember last custom time" — simplest, predictable. The
  Config form remains the place to set a non-default time.
- **App startup unchanged.** `defaultBlackMaxTime` / `defaultWhiteMaxTime`
  stay `0.0`; new games still start **Human vs Human**. "Default thinking
  time 0.5s" refers only to the value applied when this toggle enables a
  side, not to the app's per-game defaults. (Defaulting both to 0.5 would
  silently enable AI — and analysis/move-gen — for both colors at game
  start.)
- **All three platforms.** `StoneView`/`BoardView` are shared (macOS hosts
  them via `NSHostingController`), so the toggle appears on iOS, visionOS,
  and macOS from one code path. Automated verification targets iOS;
  macOS click-routing gets a manual spot-check (consistent with the
  deferred-Mac-QA checklist).
- **Affordance: tinted capsule button** (user choice) — the name word is
  wrapped in a rounded, tinted background so it reads as a button; tint
  hints state (accent when AI, neutral when Human).

## Background (current behavior)

- **State source of truth.** `Config.blackMaxTime` / `whiteMaxTime`
  (`Float` seconds), backed by frozen optional SwiftData fields
  `optionalBlackMaxTime` / `optionalWhiteMaxTime`, surfaced via computed
  accessors (`ConfigModel.swift`). `> 0` ⟺ that color is AI — the same
  test gates `shouldGenMove`, the analysis power-saving predicate, and the
  player label.
- **Label.** `Config.playerLabel(for:)` returns `humanProfileForBlack`/
  `humanProfileForWhite` (default `"AI"`) when that side has `maxTime > 0`,
  else `Config.humanPlayerLabel` (`"Human"`), and `""` for `.unknown`.
- **Render.** `StoneView.drawCapturedStones` (`StoneView.swift:65-101`)
  lays out, per color, an `HStack` of `[ name • ×count ]` framed to a
  fixed `capturedStonesWidth` (120) × `capturedStonesHeight` (20),
  absolutely `.position`-ed in the strip just above the board. The name
  `Text` carries accessibility id `blackPlayerName` / `whitePlayerName`;
  the count is `.fixedSize()` so the adaptive (`minimumScaleFactor(0.2)`)
  name can never squeeze it.
- **Two call sites.** `BoardView` (`BoardView.swift:56-63`, the live
  board) passes `blackPlayerName: config.playerLabel(for: .black)` /
  `whitePlayerName: ...`. The game-list thumbnail
  (`GameSplitView.swift:386-389`) mounts `StoneView` **without** names and
  often with `isDrawingCapturedStones: false` — it must stay
  non-interactive.
- **Mid-game enable path.** `ConfigEngineSync.setBlackMaxTime` /
  `setWhiteMaxTime(_:config:gobanState:player:messageList:)`
  (`ConfigEngineSync.swift:203-222`) write the config **and** call
  `rearmAnalysis`, so enabling a color mid-game (0 → >0) issues the
  gen-move immediately when it is that color's turn; disabling (>0 → 0) is
  a harmless no-op re-arm. This is the exact path to reuse.

## Components

### 1. `StoneView` — optional toggle closure + capsule button

Add one optional parameter (additive, defaulted — existing call sites and
previews unchanged):

```swift
var onToggleAI: ((PlayerColor) -> Void)? = nil
```

`drawCapturedStones` gains the player's `PlayerColor` (so it can call back
with the right color) and renders the name two ways:

- **`onToggleAI == nil`** (thumbnail / previews): today's plain `Text`,
  unchanged.
- **`onToggleAI != nil`** (live board): the name is wrapped in a `Button`
  whose action is `onToggleAI(playerColor)`, styled as a tinted capsule
  (`.padding` + `Capsule().fill(tint)`), where
  `isAI = (name != Config.humanPlayerLabel)` drives the tint (accent when
  AI, a neutral/`.secondary` fill when Human). It keeps
  `.accessibilityIdentifier(nameAccessibilityID)` and
  `lineLimit(1)` / `minimumScaleFactor(0.2)` so a long human-SL profile
  still scales to fit. Only the name word is the tap target — the stone
  icon and `×count` remain inert.

The capsule lives inside the existing 120×20 frame. The added horizontal
padding eats a few points of the adaptive name's width; `minimumScaleFactor`
already absorbs that. The board-wide `.onTapGesture` in `BoardView` is
unaffected — the strip sits above the playing grid and the `Button`
consumes its own taps.

### 2. `BoardView` — wire the action

Pass the closure when mounting `StoneView`:

```swift
StoneView(
    ...,
    blackPlayerName: config.playerLabel(for: .black),
    whitePlayerName: config.playerLabel(for: .white),
    onToggleAI: { toggleAI(for: $0) }
)
```

New private method:

```swift
private func toggleAI(for color: PlayerColor) {
    switch color {
    case .black:
        ConfigEngineSync.setBlackMaxTime(config.blackMaxTime > 0 ? 0 : 0.5,
            config: config, gobanState: gobanState, player: player, messageList: messageList)
    case .white:
        ConfigEngineSync.setWhiteMaxTime(config.whiteMaxTime > 0 ? 0 : 0.5,
            config: config, gobanState: gobanState, player: player, messageList: messageList)
    case .unknown:
        break
    }
}
```

`config`, `gobanState`, `player`, and `messageList` are all already in
`BoardView`'s scope/environment. Writing the config updates the label via
Observation (same mechanism the Config form relies on); `rearmAnalysis`
makes an enabled side-to-move play immediately.

## Data flow

Tap capsule → `BoardView.toggleAI(color)` → `ConfigEngineSync.set*MaxTime`
→ writes `config.*MaxTime` (0 ⇄ 0.5) and re-arms analysis →
`config.playerLabel(for:)` recomputes → the capsule's text + tint update;
if it is now that color's turn, the engine generates a move via the
existing `getRequestAnalysisCommands` gen-move path.

## Edge cases

- **Thumbnail / previews**: no `onToggleAI` → inert text, exactly as
  today.
- **Toggling the side-to-move to AI auto-plays** a move. This is identical
  to the existing Config-form path (set `maxTime > 0` mid-game) — not new
  behavior, not in scope to change. (In UI tests, toggle the side *not* to
  move to avoid the uncommitted-branch state that hides the "More"
  button.)
- **Accessibility element type changes**: the label becomes a `Button`, so
  it is queried as `app.buttons["blackPlayerName"]` rather than
  `app.staticTexts[...]`. Its accessibility `label` is still the displayed
  string (`Human`/`AI`). The existing `PlayerNameLabelUITests` must be
  updated accordingly (app is unreleased; the test is ours).
- **macOS/visionOS** inherit the toggle through the shared `BoardView`;
  macOS click-routing into the hosted SwiftUI `Button` gets a manual
  spot-check.
- **Toggling while the AI is thinking**: re-arm handles re-issuing; same
  semantics as the Config form.

## Testing

- **UI test (iOS Simulator, `FullTestPlan`).** Update
  `PlayerNameLabelUITests` to query `app.buttons["blackPlayerName"]` /
  `["whitePlayerName"]` (and update its header doc + the `waitForLabel`
  helper's element type). Add a case
  `testTappingWhiteLabelTogglesAIAndHuman`: from the all-human baseline,
  **tap the White capsule** (side not to move) → assert
  `whitePlayerName` flips `Human` → `AI`; tap again → back to `Human`;
  `blackPlayerName` stays `Human` throughout. Attach a board screenshot.
  Keep the existing restore-to-baseline idempotency convention.
- **Builds.** iOS, visionOS, macOS (`KataGo Anytime` and `KataGo Anytime
  Mac` schemes).
- **Computer-use (iOS Simulator).** Launch the app to the board, tap a
  capsule, confirm the label flips Human⇄AI; toggle the side-to-move to
  AI and confirm the engine plays a move.

## Files touched

- `KataGoUICore/Sources/KataGoUICore/Rendering/StoneView.swift` — add
  `onToggleAI` param + capsule `Button` branch in `drawCapturedStones`.
- `KataGoUICore/Sources/KataGoUICore/Rendering/BoardView.swift` — pass
  `onToggleAI` and add `toggleAI(for:)`.
- `KataGo iOSUITests/PlayerNameLabelUITests.swift` — query buttons; add
  the toggle test.

No SwiftData schema changes, no new `Config` defaults, no C++ changes.
