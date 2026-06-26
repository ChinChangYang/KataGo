# Cold-launch widget deep-link fix (iOS/visionOS)

## Problem

Tapping the KataGo Anytime widget for a game that is **not** the most-recently-modified
game, while the app is **cold** (terminated, no network loaded), opens the *most-recent*
game instead of the configured one.

### Reproduced (2026-06-27, iPhone 17 / iOS 26.5 simulator)

Two games: `Target` (older, black stone top-left) and `New Game` (most-recent decoy,
black stone bottom-right). Widget configured to `Target`. Cold-launched via
`katago-anytime://open-game?id=<Target uuid>` (the exact URL a widget tap produces).
Result: the app opened **New Game** (title bar "New Game", board stone bottom-right) —
the deep link was dropped.

### Root cause

The `open-game` URL is delivered to whatever `.onOpenURL` is mounted at launch, which is
**not** `GameSplitView`'s handler (the only one that calls `selectGame(byID:)`):

- On a cold launch the app shows the model picker (`ModelPickerView`) or, in release
  auto-restore builds, `LoadingView` with **no** `.onOpenURL` at all.
- `ModelPickerView.onOpenURL` only handles SGF **file imports** (`importGameRecord`); a
  custom-scheme `open-game` URL fails that and is silently dropped.
- By the time `GameSplitView.onOpenURL` mounts, the URL is gone, and
  `ContentView.initializationTask()` has already pinned the selection to
  `gameRecords.first` (most-recent).

`GameRecord.resolveDeepLinkTarget` is correct; the URL just never reaches it on cold launch.

## Fix — root-level `DeepLinkRouter`

Capture the deep link at the one place mounted from the first frame.

1. **`DeepLinkRouter`** (`@Observable`, KataGoUICore): holds `var pendingGameID: UUID?`.
2. **Root `.onOpenURL`** on `modelRunnerRoot` in `KataGo_iOSApp.swift` (always mounted):
   an `open-game` URL sets `router.pendingGameID`; non-`open-game` (SGF) URLs fall through
   to the existing import handlers untouched.
3. **`ContentView.initializationTask()`**: compute the initial game **once** via a new
   testable `GameRecord.resolveInitialSelection(pendingGameID:container:)` and use it for
   the engine `config:`, the selection, the book-compat check, and the SGF load (clearing
   `pendingGameID` after). When no deep link is pending, behavior is unchanged
   (most-recent).
4. **`GameSplitView`**: drop the `open-game` branch from its `.onOpenURL` (keep SGF
   import) and add `.onChange(of: router.pendingGameID)` to apply deep links that arrive
   while the app is already warm. Consolidating to one capture point avoids SwiftUI
   delivering the URL to two handlers.

macOS is untouched (it already defers cold-launch deep links via its `ReadinessGate`).

## Testable unit

```swift
// GameRecord
@MainActor
public class func resolveInitialSelection(pendingGameID: UUID?, container: ModelContainer) -> GameRecord? {
    if let id = pendingGameID { return resolveDeepLinkTarget(id: id, container: container) }
    return (try? fetchGameRecords(container: container))?.first   // most-recent default
}
```

Unit tests (mirroring `GameDeepLinkResolveTests`): pending-older → opens older (the bug),
no-pending → most-recent, pending-missing → most-recent fallback, no-pending-empty → nil.
The View wiring (root `.onOpenURL` → `pendingGameID` → `initializationTask`) is verified by
re-running the actual widget tap in the simulator.

## Files

- new `KataGoUICore/Sources/KataGoGameStore/DeepLinkRouter.swift`
- `KataGoUICore/Sources/KataGoGameStore/GameRecord.swift` (+`resolveInitialSelection`)
- `KataGo iOS/App/KataGo_iOSApp.swift`, `KataGo iOS/App/ContentView.swift`, `KataGo iOS/Game/GameSplitView.swift`
- `KataGo iOSTests/GameDeepLinkTests.swift` (+tests)
