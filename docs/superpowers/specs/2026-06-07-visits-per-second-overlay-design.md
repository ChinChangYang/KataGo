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
- **Placement:** top-right, beside the captured-stone counts, in the strip *above*
  the board — so it never blocks play. (Revised from the original bottom-left, which
  sat over the board.)
- **Label / setting name:** display reads `<rate> visits/s`; the setting is
  "Show visits/s".
- **Stability:** the number is the **average rate over the analysis session** for the
  current position (cumulative visits ÷ elapsed time since the session started), which
  converges and stays stable, rather than a per-report instantaneous delta that jitters.

## User-visible behavior

- New toggle in **Global Settings**, alongside "Sound effect" and "Haptic feedback".
- When ON: a small monospaced text in the top-right of the captured-stones strip
  (above the board) shows the session-average rate (SI-formatted, e.g. `1.2k visits/s`).
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
3. **Compute the session average in the model.** Feed `(rootVisits, timestamp)` into
   the `Analysis` model (monotonic clock). It anchors a *session* at the first sample
   of each continuous search and reports
   `visitsPerSecond = (rootVisits − sessionStartVisits) / (now − sessionStartTime)`.
   Averaging from the session start keeps the number stable as the search runs.
   - On a search reset (new move/position → cumulative visits drop), it starts a new
     session and clears the rate until visits accumulate again.
   - Guards against zero/negative elapsed time (retains the last value).

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

- In `StoneView`, the two capture counts keep their original fixed positions
  (`getCapturedStoneStartX`, black left-of-center, white right-of-center). The visits/s
  text is drawn in the empty gap *between* them — centered at the board center with its
  frame width set to exactly that gap (`2·spread − capturedStonesWidth`). This way it
  shares the captured-stones row without overlapping either count, and enabling or
  disabling it never shifts the counts. Styled to match the counts (monospaced,
  `.secondary`).
- `StoneView` stays decoupled from `Analysis`: it takes an optional `speedText: String?`
  parameter. `BoardView` owns the gating (`showVisitsPerSecond` ON **and**
  `analysisStatus == .run` **and** `visitsPerSecond > 0`) and passes the formatted
  string (or nil to hide). The thumbnail/preview call sites omit it (default nil).

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
