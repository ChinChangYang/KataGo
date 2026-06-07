# Design: visits/s overlay toggle

**Date:** 2026-06-07
**Status:** Approved

## Goal

Add a Global Settings toggle that, when enabled, shows a small live search-speed
readout in the **bottom-left corner** of the Go board, e.g. `1.2k visits/s`.

## Decisions

- **Metric source:** visits/s, derived entirely in Swift. No C++/engine changes.
  - The user originally framed this as "nnEvals/s". True nnEvals/s is *not* present
    in the live `kata-analyze` output stream (the engine's `NNEvaluator::numRowsProcessed()`
    counter is only printed by `kata-benchmark`). Surfacing it live would require a
    C++ change to `gtp.cpp`. We chose the Swift-only path, so the displayed quantity
    is genuinely *visits/s* and is labeled as such for honesty.
- **Corner:** bottom-left.
- **Label / setting name:** display reads `<rate> visits/s`; the setting is
  "Show visits/s".

## User-visible behavior

- New toggle in **Global Settings**, alongside "Sound effect" and "Haptic feedback".
- When ON: a small monospaced text in the board's bottom-left corner shows the live
  rate (SI-formatted, e.g. `1.2k visits/s`).
- The overlay hides when analysis is not running or no valid rate has been computed yet.
- When OFF: nothing is shown.

## How the number is computed (no C++ changes)

1. **Request root totals.** Append `rootInfo true` to the `kata-analyze` command in
   `ConfigModel.getKataAnalyzeCommand`. The engine then emits one
   `rootInfo visits N` segment per report, where `N` is the *total* root search
   visits — the correct basis for a rate. (Summing per-move `info` blocks would
   undercount; using `maxVisits` would track only the top move.)
2. **Parse robustly.** In `ContentView.messaging()`, extract the count with a
   targeted regex `rootInfo visits (\d+)` run against the whole message. A plain
   `split(separator: "info")` (already used for per-move blocks) would split the
   word "rootInfo" itself, so rootInfo is parsed separately via regex.
3. **Compute the rate in the model.** Feed `(rootVisits, timestamp)` into the
   `Analysis` model. It computes `visitsPerSecond = Δvisits / Δtime` using a
   monotonic clock.
   - On a search reset (new move → visits count drops), it rebaselines and skips
     that sample rather than emitting a negative/garbage value.
   - Guards against zero/negative elapsed time.

## Wiring (mirrors the existing soundEffect / hapticFeedback pattern)

- `GobanState`: add `var showVisitsPerSecond: Bool = false`.
- `GameSplitView`: add `@AppStorage("GlobalSettings.showVisitsPerSecond")` plus the
  matching `.onAppear` (read into `gobanState`) and `.onChange` (write back) sync,
  exactly like the existing two global settings.
- `GlobalSettingsView` (ConfigView.swift): add
  `ConfigBoolItem(title: "Show visits/s", value: $showVisitsPerSecond)` with the
  same local-`@State` ↔ `gobanState` sync used by the existing items.
- `Analysis` (KataGoModel.swift):
  - `var visitsPerSecond: Double = 0`
  - private sampling state (last visits, last timestamp)
  - `update(rootVisits:at:)` method implementing the rate math above
  - a formatted display string, reusing the existing SI-unit formatter (e.g. `1.2k`).

## Rendering

- A small view added to `BoardView`'s `ZStack`, positioned in the bottom-left using
  the `Dimensions` struct (same technique as the coordinate labels / winrate bar:
  `gobanStartX/Y`, `gobanWidth/Height`, `squareLength`).
- Visible only when `gobanState.showVisitsPerSecond` is ON **and** analysis is active
  with a valid (> 0) rate.
- Folded inline into `BoardView` if it stays a few lines; extracted to a small
  `SpeedOverlayView` only if that reads more cleanly.

## Testing

- Unit-test the rate math in `Analysis`:
  - normal delta produces expected rate,
  - reset/rebaseline (visits drop) yields no negative value,
  - zero/negative elapsed-time guard.
- The UI wiring follows an already-working, established pattern, so no new UI tests
  beyond a build check across iOS/macOS/visionOS.

## Out of scope

- No C++/engine changes.
- No true nnEvals/s (would require a `gtp.cpp` change to emit the
  `numRowsProcessed()` counter in `rootInfo`). Noted as possible future work if the
  exact NN-eval rate is ever wanted.
