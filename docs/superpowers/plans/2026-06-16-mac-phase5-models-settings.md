# Mac Phase 5 — Models & Settings

**Date:** 2026-06-16
**Branch:** `ios-dev` (not pushed)
**Spec:** `docs/superpowers/specs/2026-06-15-katago-anytime-mac-appkit-design.md` §6 / §9 Phase 5
**Predecessors:** Phases 0–4 (`mac-phase0-complete`..`mac-phase4-inspector`)

Today the Mac engine launches the hardcoded built-in net on MLX/GPU; there is NO model switching,
backend config, Settings window, engine-status UI, or crash recovery. Phase 5 adds all of it,
**native AppKit** (consistent with the redesign).

## Locked decisions (this phase)
- **D-P5-1 — Model switching = INSTANT in-process reload, after a feasibility SPIKE.** Implement
  engine teardown + relaunch in-process so a model/backend change reloads immediately. **S0 spike**
  verifies the C++/MLX engine can be re-init'd in one process first; if it proves unsafe (Metal/MLX
  global state, deadlock, leak), FALL BACK to "applies on next launch" and inform the user.
- **D-P5-2 — Backend config = FULL parity.** Expose CoreML/NE vs MLX/GPU toggle (+ compiled board
  size for the CoreML path), Max Board Size (9/13/19/37), autotuning Fast/Full, re-tune-on-next-load.
- **D-P5-3 — Crash recovery = FULL.** Persist last-good model + auto-restore on launch; NSAlert on a
  crash-loop sentinel (Use Built-in / Dismiss). Changes today's always-built-in launch.
- **D-P5-4 — Models window + Settings window + backend config = native AppKit** (NSTableView /
  NSTabViewController), reusing `ConfigEditingSupport` rows; do NOT host the iOS-target SwiftUI
  `ModelPickerView`/`ConfigView` (they're iOS-locked / NavigationStack-y).

## Reuse (shared, public — host/wire, don't rebuild)
- `NeuralNetworkModel` + `allCases` catalog (9 nets) + `builtInModel` + `downloadedURL` (Documents/<fileName>).
- `Downloader` (`@MainActor @Observable`, URLSession progress/cancel, `onDownloadComplete` pre-hash seam).
- `BackendSettings`/`BackendChoice`/`BoardSizeChoice` (per-model backend, same UserDefaults keys as iOS).
- `EngineLifecycle` + `RecoveryDecision`/`RecoveryAction`; `EngineLaunchStatus` + `registerEngineLaunchStatusUpdater`.
- `KataGoHelper.runGtp(modelPath:mlxDeviceToUse:maxBoardSizeForNNBuffer:requireExactNNLen:tunerFull:reTune:)`
  full backend-override signature (iOS `ModelRunnerView` lines ~100-113).
- `GameSession.initialize` handshake → `markFirstResponse`; `BinFileHasher` (already registered on Mac).
- `MacGlobalPreferenceSync` (14 `GlobalSettings.*` keys ↔ GobanState, Phase 3) — Settings window writes
  `gobanState.*`, sync persists.
- `ConfigEditingSupport` rows (`popupRow`/`checkboxRow`/`numericRow`/`sectionHeader`) from Phase 4.
- `CoreMLCacheReadiness` (+ projection — T10 publicizes/platform-corrects it for Mac CoreML readiness).

## Sequence

### S0 — SPIKE: in-process engine teardown + relaunch (DO FIRST, gates D-P5-1)
- Verify the katago thread can be stopped (`session.stopRequested` + `quit` + thread end) and `runGtp`
  re-entered on a fresh thread within the same process WITHOUT crash/deadlock/leak (MLX/Metal device
  re-init is the risk). Minimal harness: after launch, stop, relaunch with the same model, confirm a
  second `GTP ready` + board renders + analysis goes live again (data diagnostic like Phase 3).
- **If safe:** proceed with instant-reload (T3 et al.). **If unsafe:** switch D-P5-1 to next-launch-only
  (model selection records the choice + status "loads on next launch"; drop T3's relaunch, keep teardown
  only at quit), update this plan, and tell the user.

### T1 — Persisted Mac model-selection + crash-sentinel store
- New `@MainActor MacModelSelection` (Mac target) owning the SAME UserDefaults keys iOS uses:
  `ModelRunnerView.selectedModelTitle` (last-good) + `ModelRunnerView.pendingLoadModelTitle` (sentinel).
  Resolve active `NeuralNetworkModel` by title; expose `currentModel` + `setActiveModel(_:)`. Single writer
  (no overlap with `MacGlobalPreferenceSync`'s keys).

### T2 — Parameterize the Mac engine launch to honor `BackendSettings` [dep T1]
- `startKataGoThread` takes `(modelPath, mlxDeviceToUse, maxBoardSizeForNNBuffer, requireExactNNLen,
  tunerFull, reTune)` (mirror `ModelRunnerView` 100-113). `startEngineAndSession` builds `BackendSettings(model:)`
  from the resolved active model, passes the overrides, clears `reTune=false` one-shot after an MLX/GPU launch.
  `modelPath = builtIn ? Bundle default_model.bin.gz : downloadedURL.path()`.

### T3 — Engine teardown + relaunch orchestration [dep T2, S0-safe]
- `stopEngineAndSession()` (set `stopRequested`, send `quit`, end/abandon the thread, `boardReadiness.isEngineReady=false`,
  reset `engineLifecycle` + re-arm observers) + `relaunch(model:)` = stop + start with the new active model.
  HIGHEST-risk; verify the analysis/auto-play observers + readiness gate reset correctly. (Skipped/trimmed if S0 unsafe.)

### T4 — `EngineLaunchStatus` + crash-sentinel through the handshake [dep T1]
- In `AppDelegate` construct `EngineLaunchStatus` + `registerEngineLaunchStatusUpdater{...}` (as `KataGo_iOSApp`),
  hand to `MainWindowController`. ARM `pendingLoadModelTitle=title` + `synchronize()` BEFORE the thread starts;
  observe `engineLifecycle.lastLoadedModelTitle` → on change write `selectedModelTitle` + clear the sentinel
  (mirror `ModelRunnerView` 115-119).

### T5 — Crash-recovery decision + launch alert (NSAlert) [dep T2,T3,T4]
- At launch call `RecoveryDecision.decide(pending, selected, isDebug)` once. `.autoRestore(title)` → set active +
  launch (RELEASE); `.showPickerWithBanner` → NSAlert ("Last launch couldn't finish loading <title>" + memory
  note) with **Use Built-in Network** (active=builtIn, relaunch) / **Dismiss** (clear sentinel); `.showPicker` →
  open Models window / built-in default. Reuse the recovery logger pattern.

### T6 — Toolbar active-model dropdown (`NSMenuToolbarItem`) [dep T3,T7]
- New `.activeModel` toolbar item: menu of downloaded/`.visible` nets (checkmark active, action → set active +
  relaunch via T3), separator, **Manage Models…** → opens the Models window (T7). Disable non-downloaded entries
  + during a launch-in-progress; refresh checkmarks on selection/download changes.

### T7 — Models window — native AppKit (NSTableView) [dep T1,T3,T8]
- New `NSWindowController`+`NSViewController` with an `NSTableView` of `allCases` (`.visible`): title+description,
  size, status (Active / Ready badge from `CoreMLCacheReadiness` / Downloaded). Per-row: download (one `Downloader`
  per model → `NSProgressIndicator`, cancel; lifecycle-managed, cancel on close), delete (`FileManager.removeItem`
  + confirm NSAlert, only `!builtIn && downloaded`), select-as-active (→ relaunch). Hosts/links the T8 backend pane.

### T8 — Per-model Backend config UI — FULL [dep T1]
- Native section/sheet via reused `ConfigEditingSupport` rows: Backend (popup `BackendChoice.allCases`),
  Max Board Size (popup `BoardSizeChoice`, MLX) / Compiled Board Size (CoreML, shown when backend==.coremlNE),
  Autotuning Fast/Full, Re-tune-on-next-load (checkbox). `onChange` → `BackendSettings(model:)` setters (same
  UserDefaults keys). Either relaunch (T3) on change or label "applies on next launch". Respect the `reTune`
  one-shot (T2).

### T9 — Engine launch/status caption in the board pane [dep T4]
- Replace the bare `ProgressView` in `MacBoardHostView` with a status view reading `EngineLaunchStatus.phase`
  ("Loading… / Compiling Core ML model — first launch only / Finishing…") + active-model title + `KataGo <version>`.
  Since MLX/GPU (Mac default) emits NO phase, add a generic "Loading…" fallback for the MLX load/tune path.

### T10 — `CoreMLCacheReadiness` projection: public + platform-correct
- Promote `makeProjectionResolver`/`makeProjectionDigestFor` to public; parameterize `useFP16`/`maxBatchSize`
  (Mac CoreML uses `maxBatchSize=8` vs iOS 1) so the projected digest matches the actual cache key (or T7's
  Ready badge lies). DEFAULT ARGS = iOS values so iOS readiness is unaffected (shared code — re-verify iOS).

### T11 — Settings window (⌘,) — tabbed prefs over `GlobalSettings.*`
- Native tabbed `NSWindow` (NSTabViewController), tabs **General · Board · Analysis · Sound & Feedback** mirroring
  iOS `GlobalSettingsView` sections (General = app-level prefs with no iOS analogue: e.g. show-charts/comments,
  visits/s; or fold sensibly). Reused rows: popups for the 4 Int pickers (stoneStyle/moveNumberStyle/analysisStyle/
  analysisInformation), checkboxes for toggles. Controls read/write `session.gobanState.*` (NOT UserDefaults —
  `MacGlobalPreferenceSync` persists; single writer) and observe external changes (View-menu toggles). Wire the
  dead `showSettings:` selector (responder chain). **Haptics dropped on Mac.**

### T12 — Register new files + 3-platform build verification [dep all]
- Register every new Mac `.swift` (Models WC/VC, Settings WC/VC, MacModelSelection, backend view, status view)
  in `project.pbxproj` for the **Mac target only** via the `xcodeproj` gem. Cold build iOS/macOS/visionOS +
  iOS tests (T2/T10 touch shared code).

## Open questions (resolve at runtime / during impl)
1. **S0:** can `runGtp` be re-entered in-process on Mac (MLX/Metal re-init)? Gates D-P5-1.
2. MLX/GPU load emits no `EngineLaunchStatus` phase → generic "Loading…" only, or add an MLX-side status producer? (T9)
3. Is the CoreML "Ready" badge meaningful on Mac given MLX/GPU default? (T7/T10) — relevant now that backend is full-parity.
4. First-run with empty sentinels: silently launch built-in (today) vs open Models window? (T5) — default: launch built-in.
5. Does the 824MB Official 40-block net run on Mac under MLX/GPU? (OOMs on iOS; "no repro on Mac" per memory) — list it; flag if it fails.
6. Disk-space precheck before large downloads? (iOS doesn't) — default: no precheck, show size in the row.

## Execution model
Subagent-driven; **S0 spike first** (I run/verify it). Fresh implementer per task; adversarial review on the
risky ones (T3 teardown/relaunch re-entrancy, T5 recovery state machine, T10 shared-code projection). Build green
on 3 platforms + iOS tests when shared code changes; commit per task; tag `mac-phase5-models-settings` at the end.
Manual/visual tests DEFERRED → append to [[project_mac_deferred_manual_testing]]. Update [[project_mac_appkit_redesign]].
