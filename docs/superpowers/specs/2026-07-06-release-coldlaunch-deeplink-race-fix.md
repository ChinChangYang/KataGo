# Release cold-launch widget deep-link race fix (iOS/visionOS)

## Problem

Tapping a widget configured to game A, with the app terminated, opened the
most-recently-modified game B instead — **only in Release builds**, on the
auto-restore path (model picker bypassed). Reported on device; the prior fix
(311862ba, `DeepLinkRouter`) had been verified in the Debug simulator only.

### Reproduced (2026-07-06, iPhone 17 / iOS 26.5 simulator, Release build)

Store had "Baseline" (older) and "New Game" (most recent). With the
auto-restore sentinel armed, `xcrun simctl terminate` +
`xcrun simctl openurl booted "katago-anytime://open-game?id=<Baseline uuid>"`
cold-launched the app on **"New Game"** — deep link dropped. A warm re-tap of
the *same* URL was also swallowed (see corollary below).

## Root cause

Two windows exist for the cold-launch `open-game` URL; 311862ba closed only
the first:

1. URL delivered **before** `ContentView.initializationTask` reads
   `DeepLinkRouter.pendingGameID` → handled (the Debug-simulator case: the
   model picker keeps `initializationTask` from running until a human taps,
   so the URL always wins — `RecoveryDecision.decide` returns `.showPicker`
   whenever `isDebug` is true, which is why Debug could never reproduce this).
2. URL delivered **after** that synchronous read (Release auto-restore mounts
   `LoadingView` on the first frames, so the read races the asynchronous URL
   delivery and wins on device) → the id lands in `pendingGameID` during the
   multi-second `session.initialize` model-load await and **strands**:
   `GameSplitView`'s `.onChange(of: pendingGameID)` mounts seconds later and
   never fires for a pre-mount change. Selection stays on
   `gameRecords.first` (most-recent).

**Corollary:** the stranded non-nil id also swallows later *warm* taps of the
same widget — writing an equal UUID fires no `.onChange` — until a different
game's link changes the value.

The widget side is provably clean: `SavedGameSnapshot.resolveSnapshot`
carries `configuredGameID` onto every branch and `SavedGameWidgetView` builds
`.widgetURL` from `configuredGameID ?? gameID`, so a configured widget's tap
URL is always game A regardless of display fallbacks.

## Fix — resolve after the handshake + drain at mount

Invariant: a pending deep link survives until something can apply it.

1. **`GameSession`**: split `initialize` into a public
   `handshake(selectedModelTitle:engineLifecycle:)` (version/first-response
   exchange only) plus a now-public `sendInitialCommands(config:)`;
   `initialize` remains as the convenience composing both (macOS/tvOS hosts
   and existing tests unchanged).
2. **`ContentView.initializationTask`**: handshake first, then resolve
   `GameRecord.resolveInitialSelection(pendingGameID:container:)` — the
   blocking version read spans the model load, so the URL has been delivered
   by resolve time. One game still seeds engine config, selection, book
   check, and SGF load.
3. **`GameSplitView`**: the pending-id `.onChange` becomes
   `.onChange(..., initial: true)` routed through a single
   `applyPendingDeepLink()` seam (pattern from 941edaaf) — drains an id set
   before mount (guarantee for arbitrarily late delivery) and clears it after
   applying (un-strands same-widget re-taps).

## Testable units

`GameSessionHandshakeSplitTests` (in `GameSessionInitializeClearTests.swift`):
handshake sends no config commands until `sendInitialCommands`; `initialize`
still sends them; a pending id set while the gated version read is in flight
(`GatedVersionEngine`) is visible after `handshake` and resolves to the
configured game.

## Verification

- iOS unit suite green.
- Release-simulator E2E: the reproduction above now opens "Baseline" on cold
  launch; warm re-tap of the same URL and a different game's URL both switch.
- All-platform builds green (iOS, macOS, tvOS, watchOS).
- On-device Release widget repro re-run by the user.

## Files

- `KataGoUICore/Sources/KataGoUICore/Session/GameSession.swift`
- `KataGo iOS/App/ContentView.swift`
- `KataGo iOS/Game/GameSplitView.swift`
- `KataGo iOSTests/GameSessionInitializeClearTests.swift`
