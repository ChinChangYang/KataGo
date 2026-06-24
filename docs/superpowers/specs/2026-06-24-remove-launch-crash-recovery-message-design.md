# Remove the "Last launch couldn't finish loading" message

**Date:** 2026-06-24
**Status:** Approved (pending spec review)
**Scope:** iOS / visionOS / macOS app targets + shared `KataGoUICore` package + iOS unit tests

## Summary

The app shows a recovery message after it detects that a previous launch did not
finish loading a neural network:

- **iOS/visionOS:** a banner in the model picker — *"Last launch could not finish
  loading **X**. Your device may not have enough free memory…"* — plus an orange
  ⚠️ marker next to that model.
- **macOS:** an `NSAlert` recommending the built-in network.

This message is removed. The underlying **crash-detection mechanism and the
safety "stop and let the user choose" behavior are kept** — only the user-facing
UI (banner, ⚠️ marker, macOS alert) goes away.

## Why

The detection relies on a `pendingLoadModelTitle` sentinel that is armed before a
model load and cleared once the engine sends its first GTP response. The sentinel
is left behind not only by genuine out-of-memory crashes but also by perfectly
benign events — force-quitting during load, the OS suspending/terminating a
backgrounded app, Xcode stopping the process. These **false positives** make the
message noise. Showing nothing is the desired behavior.

Safety is **not** sacrificed: when a load genuinely OOM-crashes, the app must not
silently launch a model. So the detection stays and continues to force a manual
choice (iOS) or a safe built-in fallback (macOS); it simply no longer explains
itself with a banner or alert.

## Behavior

### Before
An orphaned sentinel at launch →
- iOS/visionOS: model picker with a ⚠️ banner; user picks a model.
- macOS: an alert recommending the built-in net; both buttons launch the built-in net.

### After
An orphaned sentinel at launch →
- **iOS/visionOS:** **stop on the model picker** (`selectedModel` stays `nil`, the
  user must pick) with **no banner and no ⚠️ marker**. The previously selected
  model is **never** auto-restored after an incomplete load.
- **macOS** (which has no launch picker): **silently launch the built-in net** —
  the designated safe, lightweight fallback, never the heavy model that just
  died — with **no alert**. This is the Mac analog of "stop and let the user
  choose," and matches what the alert's buttons already did, minus the alert.

### Unchanged
- **Normal launch (sentinel empty):** release auto-restores the last-good model;
  DEBUG and fresh-install show the picker (iOS) / launch the built-in net (macOS).
- **Last-good selection recording:** `selectedModelTitle` is still written only
  after the engine's first GTP response (`EngineLifecycle.markFirstResponse`).

### Accepted consequence
The sentinel cannot distinguish a true OOM from a benign force-quit. Therefore
**false alarms also stop on the picker** (iOS) or **fall back to the built-in
net** (macOS) — silently now. This trades the convenience of auto-restore for
safety, which is the intended choice.

### Edge cases (all recoverable, no crash loops)
- **First-ever launch where the only model tried crashed** (`selectedModelTitle`
  empty): iOS shows the normal picker; macOS launches the built-in net. Unchanged.
- **DEBUG builds:** still `.showPicker` (iOS) / built-in (macOS). Unchanged.
- **A genuinely OOMing model with a prior good model:** iOS stops on the picker
  (no auto-restore of the bad model); macOS launches the built-in net. The bad
  model is never auto-retried; the user can re-select it explicitly (and it will
  crash again — an explicit user action, still recoverable via the picker).
- **Sentinel left set after showing the picker:** when the user next picks a
  model, `onChange(of: selectedModel)` re-arms `pendingLoadModelTitle` to the new
  title (overwriting the stale one); a successful load then clears it. On macOS,
  launching the built-in net likewise re-arms then clears the sentinel. No leak.

## Mechanism change

`RecoveryAction.showPickerWithBanner` collapses into the existing `.showPicker`
case — both render the picker identically once the banner is gone. The decision
keeps its `pendingLoadModelTitle` parameter so the sentinel still forces the
picker:

```swift
// RecoveryDecision.decide(pendingLoadModelTitle:selectedModelTitle:isDebug:)
//   sentinel non-empty  -> .showPicker   (incomplete prior load: force picker, no auto-restore)
//   isDebug             -> .showPicker
//   selectedTitle set   -> .autoRestore(title:)
//   else                -> .showPicker
```

`RecoveryAction` becomes `.autoRestore(title:)` | `.showPicker`.

A non-user-facing diagnostic log line is **kept** on the detected-crash branch
(iOS + macOS) — it aids debugging real OOMs (e.g. the b40c768 net) and is never
shown to the user.

## Changes by file

### Shared — `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Services/EngineLifecycle.swift`
- Remove the `.showPickerWithBanner` case from `RecoveryAction`.
- In `RecoveryDecision.decide`, change the `!pendingLoadModelTitle.isEmpty` branch
  to return `.showPicker` (was `.showPickerWithBanner`). Signature **unchanged**.
- Update the now-stale doc comment on `RecoveryAction` (it describes the banner).
- `EngineLifecycle` class (`markFirstResponse`/`reset`/`lastLoadedModelTitle`) is
  **unchanged** — it still commits the last-good selection on first response.

### iOS — `ios/KataGo iOS/KataGo iOS/App/ModelRunnerView.swift`
- Keep `@AppStorage("ModelRunnerView.pendingLoadModelTitle")`, the sentinel arm
  (`pendingLoadModelTitle = newValue.title` + `synchronize()`) and clear
  (`pendingLoadModelTitle = ""`), and `engineLifecycle.reset()`.
- Drop the `crashedModelTitle: $pendingLoadModelTitle` argument to `ModelPickerView`.
- Replace the `switch` arms: remove `case .showPickerWithBanner`; the surviving
  `.showPicker` case logs the diagnostic when `!pendingLoadModelTitle.isEmpty`,
  then `break`. `.autoRestore` is unchanged.
- Keep `recoveryLogger` + `import OSLog` (still used by the diagnostic log).

### iOS — `ios/KataGo iOS/KataGo iOS/Models/ModelPickerView.swift`
- Remove the `@Binding var crashedModelTitle` property.
- Remove the `recoveryBanner(crashedTitle:)` view and its call in `body`.
- Remove the orange ⚠️ marker (`exclamationmark.triangle.fill`) next to the
  crashed model.
- Remove the "Model Picker — Recovery Banner" `#Preview`; fix the remaining
  preview(s) to drop the `crashedModelTitle` argument/state.

### macOS — `ios/KataGo iOS/KataGo Anytime Mac/MainWindowController.swift`
- Keep the sentinel arm/clear (`startEngineAndSession` arming;
  `handleLastLoadedModelChange` clear) and `engineLifecycle.reset()`.
- In `decideRecovery`, remove the `case .showPickerWithBanner`. The detected-crash
  state now resolves to `.showPicker` → built-in launch. Log the diagnostic when
  `!pending.isEmpty` (keep the `pending` local for the log).
- Delete `presentRecoveryAlert(pending:)` and `recoverWithBuiltIn()` — the
  `.showPicker` path (`setActiveModel(builtIn)` + `startEngineAndSession`) already
  launches the built-in net and re-arms/clears the sentinel.
- Update the stale comment blocks that describe the alert / banner.
- Keep `recoveryLogger` (still used by the diagnostic log).

### macOS — `ios/KataGo iOS/KataGo Anytime Mac/MacModelSelection.swift`
- **Unchanged** — `pendingLoadModelTitle` is still used by the detection. (Optional:
  light doc-comment tidy; not required.)

### Tests — `ios/KataGo iOS/KataGo iOSTests/EngineLifecycleTests.swift`
- The three tests that assert `.showPickerWithBanner` now assert `.showPicker`:
  `pendingLoadTriggersBanner`, `pendingLoadTriggersBannerEvenInDebug`,
  `pendingLoadBeatsSelectedTitle` (rename to reflect "forces picker" semantics).
- The four `decide` tests with an empty sentinel and the two `EngineLifecycle`
  tests are unchanged.

## TDD plan

1. **RED:** edit the three banner tests in `EngineLifecycleTests.swift` to expect
   `.showPicker`. Run the iOS suite → these three fail (source still returns
   `.showPickerWithBanner`).
2. **GREEN:** in `EngineLifecycle.swift`, point the sentinel branch at
   `.showPicker` and remove the `.showPickerWithBanner` case; update the two
   `switch` statements (`ModelRunnerView`, `MainWindowController`) so the code
   compiles. Run the suite → green.
3. **Remove UI:** delete the banner, ⚠️ marker, recovery preview (iOS) and the
   `presentRecoveryAlert`/`recoverWithBuiltIn` methods + alert wiring (macOS);
   drop the `crashedModelTitle` plumbing. Add the diagnostic log on the crash
   branch (iOS + macOS).
4. **Verify** (see below).

## Verification

- Full iOS unit test suite green (`xcodebuild test`, scheme `KataGo Anytime`,
  iPhone 17 simulator).
- All three platform builds succeed: iOS (`KataGo Anytime`), visionOS
  (`KataGo Anytime`), macOS (`KataGo Anytime Mac`) — this change touches the
  shared package and both app targets.
- Spot-check: no remaining references to `showPickerWithBanner`,
  `crashedModelTitle`, `recoveryBanner`, `presentRecoveryAlert`, or
  `recoverWithBuiltIn` outside of comments/history.

## Out of scope

- Replacing the sentinel with real crash-report/signal-handler detection.
- Any change to how `selectedModelTitle` / the last-good model is recorded.
- Migration/back-compat (the app is unreleased).
