# Remove the "Last launch couldn't finish loading" message — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the user-facing crash-recovery message (iOS banner + ⚠️ marker, macOS alert) while keeping the crash-detection sentinel and the safety stop (iOS forces the model picker; macOS falls back to the built-in net).

**Architecture:** `RecoveryAction.showPickerWithBanner` collapses into the existing `.showPicker`; the `RecoveryDecision.decide` sentinel branch now returns `.showPicker` (signature unchanged). The two call sites (`ModelRunnerView` on iOS, `MainWindowController` on macOS) drop the banner/alert outcome and instead render the picker / launch the built-in net, each emitting a non-user-facing diagnostic log. All banner/marker/alert UI is deleted.

**Tech Stack:** Swift, SwiftUI (iOS/visionOS), AppKit (macOS), Swift Testing, Xcode 26, `xcodebuild`. Shared logic lives in the `KataGoUICore` SwiftPM package.

## Global Constraints

- Working directory for all build/test commands: `ios/KataGo iOS` (relative to repo root `/Users/chinchangyang/Code/KataGo-ios-dev`).
- iOS/visionOS app target & scheme: `KataGo Anytime`. macOS app target & scheme: `KataGo Anytime Mac`. iOS unit-test target: `KataGo AnytimeTests`.
- The crash-detection sentinel (`ModelRunnerView.pendingLoadModelTitle`) and its arm/clear lifecycle MUST be preserved — only its *outcome* and the user-facing UI change.
- `selectedModelTitle` recording (`EngineLifecycle.markFirstResponse` on first GTP response) MUST be unchanged.
- Keep the existing non-user-facing `recoveryLogger` diagnostic logs (do NOT remove `import OSLog` / the logger).
- The app is unreleased: no migration / back-compat code.
- `RecoveryDecision.decide(pendingLoadModelTitle:selectedModelTitle:isDebug:)` keeps its exact signature.
- Final state must build on all three platforms (iOS, visionOS, macOS) and the full iOS test suite must pass.

---

## File Structure

| File | Change |
|------|--------|
| `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Services/EngineLifecycle.swift` | Remove `.showPickerWithBanner` from `RecoveryAction`; sentinel branch returns `.showPicker`. |
| `ios/KataGo iOS/KataGo iOSTests/EngineLifecycleTests.swift` | Replace the 3 banner tests with one discriminating `.showPicker` sentinel test. |
| `ios/KataGo iOS/KataGo iOS/App/ModelRunnerView.swift` | Drop `crashedModelTitle:` arg + `.showPickerWithBanner` case (fold into `.showPicker` + log). Keep sentinel arm/clear. |
| `ios/KataGo iOS/KataGo iOS/Models/ModelPickerView.swift` | Remove `crashedModelTitle` binding, banner view, ⚠️ marker, recovery preview. |
| `ios/KataGo iOS/KataGo Anytime Mac/MainWindowController.swift` | Drop `.showPickerWithBanner` case (crash → `.showPicker` + log); delete `presentRecoveryAlert` + `recoverWithBuiltIn`; update stale comments. Keep sentinel arm/clear. |
| `ios/KataGo iOS/KataGo Anytime Mac/MacModelSelection.swift` | Unchanged (sentinel still used). |

**Task ordering note:** Task 1 removes `.showPickerWithBanner` from the shared `RecoveryAction` enum, which breaks the macOS target's `switch` until Task 2 fixes it. Task 1 is verified by the iOS test suite + iOS/visionOS builds (neither depends on the macOS target); the macOS build goes green again at the end of Task 2. **Land Tasks 1 and 2 together** (execute Task 2 immediately after Task 1) so the repo is not left with a red macOS build.

---

## Task 1: Collapse the decision + remove the iOS/visionOS message

**Files:**
- Test: `ios/KataGo iOS/KataGo iOSTests/EngineLifecycleTests.swift:35-60`
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Services/EngineLifecycle.swift:30-49`
- Modify: `ios/KataGo iOS/KataGo iOS/App/ModelRunnerView.swift:35-94`
- Modify: `ios/KataGo iOS/KataGo iOS/Models/ModelPickerView.swift:184-336`

**Interfaces:**
- Produces: `enum RecoveryAction: Equatable { case autoRestore(title: String); case showPicker }` (the `.showPickerWithBanner` case is removed). `RecoveryDecision.decide(pendingLoadModelTitle: String, selectedModelTitle: String, isDebug: Bool) -> RecoveryAction` — signature unchanged; a non-empty `pendingLoadModelTitle` now returns `.showPicker`.
- Consumes: nothing from other tasks.

- [ ] **Step 1: Write the failing tests (RED)**

In `ios/KataGo iOS/KataGo iOSTests/EngineLifecycleTests.swift`, replace the three tests at lines 35-60 (`pendingLoadTriggersBanner`, `pendingLoadTriggersBannerEvenInDebug`, `pendingLoadBeatsSelectedTitle`) with a single discriminating test:

```swift
    @Test func pendingLoadForcesPicker() {
        // A surviving sentinel (an incomplete prior load) forces the picker
        // even when a last-good model exists — it must NOT auto-restore. This
        // input has a non-empty selectedModelTitle and isDebug == false, so
        // the ONLY branch that yields `.showPicker` is the sentinel branch;
        // remove that branch and this returns `.autoRestore`. (A debug variant
        // would not discriminate: debug yields `.showPicker` on its own.)
        let action = RecoveryDecision.decide(
            pendingLoadModelTitle: "Official KataGo Network",
            selectedModelTitle: "Built-in KataGo Network",
            isDebug: false
        )
        #expect(action == .showPicker)
    }
```

Rationale: the three original banner tests reduce, post-collapse, to "the sentinel branch forces the picker." Two of them asserted that against `.autoRestore` (redundant with each other); the debug one no longer discriminates (debug alone yields `.showPicker`). One discriminating test replaces all three. The remaining branches stay covered by the untouched tests below.

Leave the other tests (`markFirstResponseSetsTitle`, `resetClearsTitle`, `noPendingAutoRestoresInRelease`, `noPendingSuppressesAutoRestoreInDebug`, `emptyStateShowsPicker`, `emptyStateShowsPickerInDebug`) untouched — they cover the autoRestore (release), debug-suppression, and empty-state branches.

- [ ] **Step 2: Run the tests to verify they fail**

Run (from repo root):
```bash
cd "ios/KataGo iOS" && xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/EngineLifecycleTests"
```
Expected: `pendingLoadForcesPicker` FAILS (source still returns `.showPickerWithBanner`, which `≠ .showPicker`). All other EngineLifecycleTests pass.

- [ ] **Step 3: Update `RecoveryAction` + `RecoveryDecision` (GREEN — shared logic)**

In `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Services/EngineLifecycle.swift`, replace the `RecoveryAction` enum (lines 29-37) with:

```swift
/// What `ModelRunnerView` should do at launch based on persisted state.
public enum RecoveryAction: Equatable {
    case autoRestore(title: String)
    case showPicker
}
```

Then in `RecoveryDecision.decide`, replace the sentinel branch (lines 47-49):

```swift
        if !pendingLoadModelTitle.isEmpty {
            return .showPickerWithBanner
        }
```

with:

```swift
        if !pendingLoadModelTitle.isEmpty {
            // An incomplete prior load: the sentinel survived process death.
            // Force the picker rather than auto-restoring, so the user
            // re-chooses a model after a possible OOM. No banner is shown.
            return .showPicker
        }
```

- [ ] **Step 4: Update the iOS launch switch + drop the banner argument (`ModelRunnerView.swift`)**

In `ios/KataGo iOS/KataGo iOS/App/ModelRunnerView.swift`, replace the `ModelPickerView(...)` call (lines 35-39):

```swift
                ModelPickerView(
                    selectedModel: $selectedModel,
                    crashedModelTitle: $pendingLoadModelTitle
                )
```

with:

```swift
                ModelPickerView(
                    selectedModel: $selectedModel
                )
```

Then replace the `switch` body (lines 58-69):

```swift
            case .showPickerWithBanner:
                recoveryLogger.error(
                    "Recovered from apparent crash loading model: \(pendingLoadModelTitle, privacy: .public)"
                )
                // Leave pendingLoadModelTitle set: the picker reads it to
                // render the banner, and user action (Dismiss, or selecting
                // a new model) is what clears it.
            case .autoRestore(let title):
                selectedModel = NeuralNetworkModel.allCases.first { $0.title == title }
            case .showPicker:
                break
            }
```

with:

```swift
            case .autoRestore(let title):
                selectedModel = NeuralNetworkModel.allCases.first { $0.title == title }
            case .showPicker:
                // An incomplete prior load (orphaned sentinel) lands here too:
                // we force the picker rather than auto-restoring, so the user
                // re-chooses after a possible OOM. No banner is shown; the
                // stale sentinel is overwritten when the user next picks a model.
                if !pendingLoadModelTitle.isEmpty {
                    recoveryLogger.error(
                        "Previous launch did not finish loading model: \(pendingLoadModelTitle, privacy: .public). Showing model picker."
                    )
                }
            }
```

Keep `@AppStorage("ModelRunnerView.pendingLoadModelTitle")` (line 24), the sentinel arm (lines 92-94: `engineLifecycle.reset()` / `pendingLoadModelTitle = newValue.title` / `UserDefaults.standard.synchronize()`), the clear (line 118: `pendingLoadModelTitle = ""`), and `recoveryLogger` + `import OSLog`.

Then update the now-stale arming comment (lines 86-91): change the sentence "the next launch will show the picker with a recovery banner instead of restarting the same crash" to "the next launch will show the picker (no banner) instead of restarting the same crash."

- [ ] **Step 5: Remove the banner, marker, and binding (`ModelPickerView.swift`)**

In `ios/KataGo iOS/KataGo iOS/Models/ModelPickerView.swift`:

(a) Remove the `crashedModelTitle` binding (lines 184-188):

```swift
    /// Title of the model whose load did not finish during the previous
    /// launch. Empty string means no crash to display. Writing an empty
    /// string (via the banner's Dismiss button) clears the crash-loop
    /// sentinel that `ModelRunnerView` persists.
    @Binding var crashedModelTitle: String
```

(b) Remove the banner call in `body` (lines 206-208):

```swift
                if !crashedModelTitle.isEmpty {
                    recoveryBanner(crashedTitle: crashedModelTitle)
                }

```

(c) Remove the ⚠️ marker (lines 225-229):

```swift
                                    if model.title == crashedModelTitle {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(.orange)
                                            .accessibilityLabel("Did not finish loading last time")
                                    }
```

(d) Remove the `recoveryBanner(crashedTitle:)` helper entirely (lines 268-302):

```swift
    @ViewBuilder
    private func recoveryBanner(crashedTitle: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text("Last launch could not finish loading **\(crashedTitle)**.")
                        .font(.headline)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }

                Text("Your device may not have enough free memory for this network. The built-in network is recommended.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack {
                    Button {
                        if let builtIn = NeuralNetworkModel.builtInModel {
                            selectedModel = builtIn
                        }
                    } label: {
                        Text("Use Built-in Network")
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Dismiss") {
                        crashedModelTitle = ""
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 4)
        }
    }
```

(e) Replace the first preview (lines 305-320) to drop `crashedModelTitle`:

```swift
#Preview("Model Picker") {
    // A simple wrapper view to host the binding required by ModelPickerView
    struct PreviewHost: View {
        @State private var selectedModel: NeuralNetworkModel? = nil
        @State private var readiness = CoreMLCacheReadiness()
        var body: some View {
            ModelPickerView(
                selectedModel: $selectedModel
            )
            .environment(readiness)
        }
    }
    return PreviewHost()
}
```

(f) Remove the entire "Recovery Banner" preview (lines 322-336):

```swift
#Preview("Model Picker — Recovery Banner") {
    struct PreviewHost: View {
        @State private var selectedModel: NeuralNetworkModel? = nil
        @State private var crashedModelTitle = "Official KataGo Network"
        @State private var readiness = CoreMLCacheReadiness()
        var body: some View {
            ModelPickerView(
                selectedModel: $selectedModel,
                crashedModelTitle: $crashedModelTitle
            )
            .environment(readiness)
        }
    }
    return PreviewHost()
}
```

- [ ] **Step 6: Run the iOS tests to verify they pass (GREEN)**

Run (from repo root):
```bash
cd "ios/KataGo iOS" && xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/EngineLifecycleTests"
```
Expected: all EngineLifecycleTests PASS.

- [ ] **Step 7: Verify the iOS and visionOS builds**

Run (from repo root):
```bash
cd "ios/KataGo iOS" && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug
cd "ios/KataGo iOS" && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug
```
Expected: both `** BUILD SUCCEEDED **`. (The macOS target is expected to be red until Task 2 — do not build it here.)

- [ ] **Step 8: Run the full iOS suite once**

Run (from repo root):
```bash
cd "ios/KataGo iOS" && xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17'
```
Expected: `** TEST SUCCEEDED **` (no regressions from the UI removal).

- [ ] **Step 9: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Services/EngineLifecycle.swift" "ios/KataGo iOS/KataGo iOSTests/EngineLifecycleTests.swift" "ios/KataGo iOS/KataGo iOS/App/ModelRunnerView.swift" "ios/KataGo iOS/KataGo iOS/Models/ModelPickerView.swift"
git commit -m "feat: drop the launch crash-recovery banner (iOS); keep the picker stop

RecoveryAction.showPickerWithBanner collapses into .showPicker. An
incomplete prior load still forces the model picker (no auto-restore),
but with no banner or warning marker. The sentinel + a non-user-facing
diagnostic log are kept.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WoQvc49FJf5btyZsHLawb3"
```

---

## Task 2: Remove the macOS alert + fix the macOS switch

**Files:**
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/MainWindowController.swift:290-296, 962-1073`

**Interfaces:**
- Consumes: `RecoveryAction` from Task 1 (`.autoRestore(title:)` | `.showPicker`); `RecoveryDecision.decide(pendingLoadModelTitle:selectedModelTitle:isDebug:)`.
- Produces: nothing for later tasks.

- [ ] **Step 1: Replace the `.showPickerWithBanner` switch case in `decideRecovery`**

In `ios/KataGo iOS/KataGo Anytime Mac/MainWindowController.swift`, in `decideRecovery()`, replace the `switch` cases (lines 1004-1025):

```swift
        case .autoRestore:
            // `modelSelection.currentModel` already resolves the active model
            // from `selectedModelTitle`, so a normal launch restores it.
            startEngineAndSession()

        case .showPicker:
            // Fresh install / DEBUG: macOS has no launch picker, so default to
            // the built-in net.
            if let builtIn = NeuralNetworkModel.builtInModel {
                modelSelection.setActiveModel(builtIn)
            }
            startEngineAndSession()

        case .showPickerWithBanner:
            // A prior load apparently crashed before the engine ever responded.
            // Do NOT launch yet — present the recovery alert once the window is
            // on screen; its completion launches the built-in net.
            recoveryLogger.error(
                "Recovered from apparent crash loading model: \(pending, privacy: .public)"
            )
            presentRecoveryAlert(pending: pending)
        }
```

with:

```swift
        case .autoRestore:
            // `modelSelection.currentModel` already resolves the active model
            // from `selectedModelTitle`, so a normal launch restores it.
            startEngineAndSession()

        case .showPicker:
            // Fresh install / DEBUG, OR an incomplete prior load (the sentinel
            // survived process death). macOS has no launch picker, so fall back
            // to the safe built-in net — never auto-relaunch the model that may
            // have OOM'd. No alert is shown. Launching the built-in net re-arms
            // and then clears the sentinel via the normal lifecycle.
            if !pending.isEmpty {
                recoveryLogger.error(
                    "Previous launch did not finish loading model: \(pending, privacy: .public). Falling back to the built-in network."
                )
            }
            if let builtIn = NeuralNetworkModel.builtInModel {
                modelSelection.setActiveModel(builtIn)
            }
            startEngineAndSession()
        }
```

Keep the `let pending = modelSelection.pendingLoadModelTitle` / `let selected = modelSelection.selectedModelTitle` reads (lines 996-997) — `pending` is still used by the log.

- [ ] **Step 2: Delete `presentRecoveryAlert` and `recoverWithBuiltIn`**

Delete the two methods (lines 1028-1073), from the doc comment above `presentRecoveryAlert` through the end of `recoverWithBuiltIn`:

```swift
    /// Presents the crash-recovery NSAlert as a SHEET on the window, then (in the
    /// completion) clears the sentinel and launches the BUILT-IN net regardless of
    /// which button was chosen — on Mac we never retry the crashing model. Mirrors
    /// the spec's locked decision. The window is on screen by the time `init`
    /// returns and `showWindow` runs, but we defer to the next run-loop turn so
    /// the sheet attaches to a presented window; if there's still no window we
    /// fall back to a windowless built-in launch.
    private func presentRecoveryAlert(pending: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let window = self.window else {
                // No window to host the sheet — clear the sentinel and launch the
                // built-in net so the app isn't left engine-less.
                self.recoverWithBuiltIn()
                return
            }

            let alert = NSAlert()
            alert.messageText = "Loading “\(pending)” may not have finished last time."
            alert.informativeText =
                "The app restarted before that network finished loading, which can "
                + "happen if it ran out of memory. To be safe, the built-in network "
                + "will be used instead. You can switch networks again from the "
                + "Models window."
            // First-added button is the default (rightmost / return-key).
            alert.addButton(withTitle: "Use Built-in Network")
            alert.addButton(withTitle: "Choose Later")

            alert.beginSheetModal(for: window) { [weak self] _ in
                // BOTH responses fall back to the built-in net — never retry the
                // model that apparently crashed.
                self?.recoverWithBuiltIn()
            }
        }
    }

    /// Clears the crash sentinel, makes the built-in net the active model, and
    /// launches it. Used by both recovery-alert buttons and the no-window path.
    private func recoverWithBuiltIn() {
        recoveryLogger.notice("Crash recovery: falling back to the built-in network.")
        modelSelection.pendingLoadModelTitle = ""
        if let builtIn = NeuralNetworkModel.builtInModel {
            modelSelection.setActiveModel(builtIn)
        }
        startEngineAndSession()
    }
```

- [ ] **Step 3: Update the stale `decideRecovery` doc comment**

Replace the comment block above `decideRecovery` (lines 962-982). Replace the bullet list at lines 975-982:

```swift
    //   • `.autoRestore` / `.showPicker` -> launch immediately.
    //   • `.showPickerWithBanner` (a prior load crashed) -> DEFER launch until
    //     the user dismisses the NSAlert sheet; both alert buttons fall back to
    //     the built-in net for safety (never retry the crashing model on Mac).

    /// Runs the launch-time recovery decision exactly once and either launches
    /// the engine immediately or defers to the recovery alert. Guarded by
    /// `hasDecidedRecovery` so scene/relaunch transitions can't re-run it.
```

with:

```swift
    //   • `.autoRestore` -> launch the last-good model immediately.
    //   • `.showPicker` (fresh install / DEBUG, OR an incomplete prior load) ->
    //     launch the safe built-in net; never auto-relaunch a model that may
    //     have OOM'd. No alert is shown.

    /// Runs the launch-time recovery decision exactly once and launches the
    /// engine. Guarded by `hasDecidedRecovery` so scene/relaunch transitions
    /// can't re-run it.
```

- [ ] **Step 4: Update the stale `init` comment near `decideRecovery()`**

Replace the comment at lines 290-295:

```swift
        // Run the launch-time crash-recovery decision ONCE, BEFORE arming the
        // sentinel / launching the engine — it must read the PREVIOUS run's
        // sentinel (`pendingLoadModelTitle`), which `startEngineAndSession()`
        // will overwrite (arm) for THIS run. For the non-banner outcomes this
        // launches the engine immediately; for the banner outcome it defers the
        // launch until the user dismisses the NSAlert sheet (see `decideRecovery`).
        decideRecovery()
```

with:

```swift
        // Run the launch-time crash-recovery decision ONCE, BEFORE arming the
        // sentinel / launching the engine — it must read the PREVIOUS run's
        // sentinel (`pendingLoadModelTitle`), which `startEngineAndSession()`
        // will overwrite (arm) for THIS run. Every outcome launches the engine
        // immediately (last-good model, or the built-in net after an incomplete
        // prior load); see `decideRecovery`.
        decideRecovery()
```

- [ ] **Step 5: Update the stale arming comment in `startEngineAndSession`**

Replace the sentence in the arming comment (lines 592-599) that reads "the NEXT launch's `decideRecovery()` shows the recovery alert instead of restarting the same crash" with "the NEXT launch's `decideRecovery()` falls back to the built-in net instead of restarting the same crash." Keep the code at lines 600-602 (`engineLifecycle.reset()` / `modelSelection.pendingLoadModelTitle = model.title` / `UserDefaults.standard.synchronize()`) unchanged.

- [ ] **Step 6: Verify the macOS build**

Run (from repo root):
```bash
cd "ios/KataGo iOS" && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS' -configuration Debug
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Confirm no stale references remain**

Run (from repo root):
```bash
cd "ios/KataGo iOS" && grep -rn "showPickerWithBanner\|crashedModelTitle\|recoveryBanner\|presentRecoveryAlert\|recoverWithBuiltIn" --include='*.swift' .
```
Expected: no matches (all gone, including comments).

- [ ] **Step 8: Commit**

```bash
git add "ios/KataGo iOS/KataGo Anytime Mac/MainWindowController.swift"
git commit -m "feat: drop the launch crash-recovery alert (macOS); fall back to built-in

The macOS launch-recovery path no longer shows an NSAlert. An incomplete
prior load now silently launches the safe built-in net (with a
non-user-facing diagnostic log), mirroring the iOS picker-stop. Deletes
presentRecoveryAlert + recoverWithBuiltIn; the sentinel arm/clear stays.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WoQvc49FJf5btyZsHLawb3"
```

---

## Final Verification (after both tasks)

- [ ] Full iOS suite: `cd "ios/KataGo iOS" && xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17'` → `** TEST SUCCEEDED **`.
- [ ] iOS build → `** BUILD SUCCEEDED **`.
- [ ] visionOS build → `** BUILD SUCCEEDED **`.
- [ ] macOS build → `** BUILD SUCCEEDED **`.
- [ ] `grep` (Task 2 / Step 7) returns no matches.

## Self-Review (completed by plan author)

- **Spec coverage:** iOS banner removal (Task 1, Steps 4-5) ✓; ⚠️ marker (Task 1, Step 5c) ✓; macOS alert removal (Task 2, Steps 1-2) ✓; enum collapse + decision (Task 1, Step 3) ✓; sentinel/arm/clear preserved (Global Constraints + explicit "keep" notes) ✓; diagnostic log kept (Task 1 Step 4, Task 2 Step 1) ✓; tests updated (Task 1, Step 1) ✓; 3-platform verification (per-task + Final) ✓; MacModelSelection unchanged (File Structure) ✓.
- **Placeholder scan:** no TBD/TODO; every code step shows complete code.
- **Type consistency:** `RecoveryAction` = `.autoRestore(title:)` | `.showPicker` used consistently across Tasks 1-2; `decide(...)` signature identical everywhere; method names (`presentRecoveryAlert`, `recoverWithBuiltIn`) match the source being deleted.
