# Power-Saving Analysis Pause (iOS / visionOS)

**Date:** 2026-06-21
**Platforms:** iOS + visionOS (the `KataGo Anytime` app target). macOS is intentionally unchanged.
**Status:** Approved design, pending implementation plan.

## Problem

When a person plays against the AI (one side has a positive per-move thinking
time, the other is zero) and the user hides the analysis overlay with the "eye"
button, the engine keeps running continuous `kata-analyze` in the background. The
results are invisible, so the compute — and the battery/thermal cost — is wasted.

We want to pause that continuous analysis to save power in exactly this case,
without changing behavior for any other case.

## Scope

### In scope
- iOS and visionOS (they share the `KataGo Anytime` app target / `GameSplitView`).
- Pause when **all three** hold:
  1. The analysis overlay is hidden — `eyeStatus != .opened` (i.e. `.book` or `.closed`).
  2. The game is **mixed human-vs-AI** — exactly one of `blackMaxTime` / `whiteMaxTime` is `> 0`.
  3. It is the **human's turn** — the side to move has thinking time `0` and the opponent has `> 0`.

### Out of scope / unchanged
- **Both-human** games (both thinking times `0`): analysis runs as today, regardless of eye state.
- **Both-AI** games (both thinking times `> 0`): analysis runs as today, regardless of eye state.
- The **AI's own turn**: the engine must still run `genmove` to produce the AI's
  move, so that path is never suppressed — the game cannot stall.
- **macOS** (`KataGo Anytime Mac` / `MainWindowController`): unchanged. Desktop is
  typically plugged in; the predicate is a compile-time no-op there.
- **Rendering**: unchanged. Overlays are already gated on `eyeStatus == .opened`,
  so suppressing requests while hidden has no visible effect until the eye reopens.

## Behavior table

Only the bolded rows differ from current behavior.

| Black time | White time | Game | Eye | Behavior |
|---|---|---|---|---|
| 0 | 0 | both human | any | unchanged — analysis runs |
| >0 | >0 | both AI | any | unchanged — analysis runs |
| mixed | mixed | human vs AI | `.opened` | unchanged — analysis runs |
| mixed | mixed | human vs AI | `.book` / `.closed`, **human to move** | **engine analysis paused (`stop`)** |
| mixed | mixed | human vs AI | `.book` / `.closed`, AI to move | unchanged — AI still thinks & plays |

## Design

### Single predicate (shared `GobanState`)

A pure function captures the entire condition. It is the one source of truth and
is a compile-time no-op on macOS so the shared analysis path is untouched there.

```swift
/// Continuous analysis is hidden AND pointless to run: a human-vs-AI game,
/// the overlay is not visible (eye .book/.closed), and it's the human's turn.
/// The AI's own turn is never suppressed (it must genmove), and both-human /
/// both-AI games are unaffected. No-op on macOS.
public func isAnalysisHiddenForPowerSaving(config: Config,
                                           nextColorForPlayCommand: PlayerColor?) -> Bool {
    #if os(macOS)
    return false
    #else
    guard eyeStatus != .opened, let next = nextColorForPlayCommand else { return false }
    switch next {
    case .black: return config.blackMaxTime == 0 && config.whiteMaxTime > 0
    case .white: return config.whiteMaxTime == 0 && config.blackMaxTime > 0
    case .unknown: return false
    }
    #endif
}
```

### Touchpoints

1. **`GobanState.swift`** (shared) — add `isAnalysisHiddenForPowerSaving(config:nextColorForPlayCommand:)`.

2. **`GobanState.shouldRequestAnalysis(config:nextColorForPlayCommand:)`** (shared) —
   in the `nextColorForPlayCommand != nil` branch, add
   `&& !isAnalysisHiddenForPowerSaving(...)`. This suppresses the **initial** and
   **post-move** fast-analyze requests on the human's turn. As a side effect,
   `maybeRequestClearAnalysisData` (which keys off the same predicate) sets
   `requestingClearAnalysis = true`, clearing the now-hidden overlay data. No-op
   on macOS. The `nil` branch is left unchanged (no turn context → never suppress).

3. **`GameSplitView.processChange(oldWaitingForAnalysis:newWaitingForAnalysis:)`**
   (iOS/visionOS) — this is the **continuous re-issue** loop, which sends
   `kata-analyze` directly rather than through `shouldRequestAnalysis`. Extend its
   existing stop-vs-reissue branch (already inside `!shouldGenMove(...)`) so it
   sends `"stop"` when `analysisStatus == .pause` **or**
   `isAnalysisHiddenForPowerSaving(...)`. This mirrors the proven `.pause` path and
   stops the loop within one analysis cycle after the eye is hidden.

4. **`GameSplitView.processEyeStatusChange(oldEyeStatus:newEyeStatus:)`**
   (iOS/visionOS) — currently only handles `.book` (calls `syncBookState()`).
   Add resume: on a transition **into** `.opened` (from `.book`/`.closed`), if
   `analysisStatus == .run` and it is **not** the AI's turn
   (`!shouldGenMove(config:player:)`), call `maybeRequestAnalysis(...)` to restart
   the continuous analysis that power-saving stopped. The `!shouldGenMove` guard
   keeps us from double-issuing during an AI move and is a no-op for
   both-human/both-AI games where nothing was stopped. The `onChange(of:
   gobanState.eyeStatus)` call site is updated to pass both old and new values.

### Why these four points cover everything

- All analysis *requests* (initial board appear, config change, post-move, manual
  "start") funnel through `shouldRequestAnalysis` → touchpoint 2 covers them.
- The only path that re-issues `kata-analyze` *without* `shouldRequestAnalysis` is
  the `waitingForAnalysis` loop → touchpoint 3 covers it.
- After a `stop`, the loop goes idle and nothing re-triggers it, so an explicit
  resume on eye-reveal is required → touchpoint 4 covers it.

## Edge cases

- **Hitting "start analysis" (sparkle) with the eye hidden** in a mixed game on
  the human's turn: stays paused. Consistent with "don't analyze what's hidden";
  the user can reveal the overlay to resume.
- **Book mode (`.book`)**: book data comes from `bookLookup`, not the engine, and
  `BookAnalysisView` / the book winrate path don't depend on `kata-analyze`, so
  pausing the engine in book mode leaves the book display intact.
- **Game over (passCount ≥ 2)**: `shouldGenMove` is already false; the resume path
  will re-request fast-analyze on reveal, showing final analysis — acceptable.
- **macOS**: predicate returns `false`; `shouldRequestAnalysis` and the Mac
  re-issue loop in `MainWindowController` behave exactly as before.

## Testing

- **Unit test** the pure predicate across the full truth table:
  - both-human (0/0) → false for every eye state / turn.
  - both-AI (>0/>0) → false for every eye state / turn.
  - mixed, human to move, eye `.book` and `.closed` → true.
  - mixed, human to move, eye `.opened` → false.
  - mixed, AI to move, any eye state → false.
  - `nextColorForPlayCommand == nil` / `.unknown` → false.
  - (macOS no-op is compile-time; not unit-tested on the iOS test target.)
- **Build** iOS, visionOS, and macOS targets.
- **Run** the iOS test plan.
