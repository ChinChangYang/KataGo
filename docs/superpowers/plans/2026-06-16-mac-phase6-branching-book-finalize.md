# Mac Phase 6 — Branching, Book, App Intents, Parity & Retire SwiftUI macOS (FINAL)

**Date:** 2026-06-16
**Branch:** `ios-dev` (not pushed)
**Spec:** `docs/superpowers/specs/2026-06-15-katago-anytime-mac-appkit-design.md` §9 Phase 6
**Predecessors:** Phases 0–5 (`mac-phase0-complete`..`mac-phase5-models-settings`)

The final phase: branch exit dialogs, opening-book view, AI move generation, edit-mode toggle,
minimal accessibility, App Intents on Mac — then **retire the SwiftUI macOS build** so the new
native `KataGo Anytime Mac` target is the sole macOS product.

## Locked decisions
- **D-P6-1 — Wire AI move generation now** (full play-vs-AI parity; verify it doesn't conflict with the auto-play loop).
- **D-P6-2 — Retire the SwiftUI macOS build now** (drop `macosx` from the OLD target) + dead-code cleanup. Reversible 2-line pbxproj edit.
- **D-P6-3 — Wire App Intents on the Mac target** (add the 3 shared intent files to the Mac target + register the provider).
- **D-P6-4 — Minimal accessibility** (label the board interaction overlay + toolbar/menu groups; no per-intersection VoiceOver).
- **D-P6-5 — Branch exit dialogs + opening-book view + edit-mode toggle are IN.** "Branch from here" stays OUT (hypothetical, no shared logic; branching is implicit on off-mainline play).

## Reuse (already shared / already done — do NOT rebuild)
- **Branch business logic** (GobanState): `isBranchActive`, `branchSgf`/`branchIndex`, implicit ENTRY via `playPendingHumanMove`/`playAIMove`, branch-aware `getSgf`/`getCurrentIndex`/`forwardMoves`/`undoIndex`, `GameSession.maybeCollectSgf` branch-write arm, `commitBranch`/`deactivateBranch`. The **red on-board branch border** renders for free in `BoardView`.
- **Opening-book engine**: `BookLookup`, `BookAnalysisView` overlay, `BoardView.updateWinrateFromBook`, the `.book` guard in `maybeCollectAnalysis`, per-move advance — all shared + hosted. Mac already calls `bookLookup.loadIfNeeded()` + `loadGame` resets eyeStatus for non-9x9.
- **AI-play substrate**: `getKataGenMoveAnalyzeCommands`, `getRequestAnalysisCommands`/`shouldGenMove`, `maybeCollectPlay`/`postProcessAIMove`, the `aiMove` binding flow, and the **AI-overwrite + illegal-move NSAlert sheets already wired** (Phase 3 T4/T5, `installConfirmationObserver` pattern). The native **config editor with per-color AI time sliders already exists** (`ConfigEditorViewController`).
- **Already done (not gaps)**: Clone-Current-Position (sidebar context menu), full-screen (View menu), `isEditing` true→false reload observer, the toolbar/menu validation plumbing, `GobanStateBranchTests` (cover shared branch logic).
- **App Intents code** (`AppIntents/GameEntity.swift`, `GetGameInfo.swift`, `KataGoShortcuts.swift`) is platform-agnostic; needs only target membership + provider registration.

## Tasks (order: T1→T2→T3→T4→T5→T7→T6→T8→T9→T10→T11→T12)

### T1 — Branch exit affordance (Game-menu + toolbar item)
- **Files:** `AppDelegate.swift` (Game menu — create it; there's no Game menu yet), `MainWindowController.swift`.
- Add a **Game menu** with a "Deactivate Branch" item (and a toolbar item) → `@objc deactivateBranchAction(_:)` setting `gobanState.confirmingBranchDeactivation = true`. `validateMenuItem`/`validateToolbarItem`: enable only when `isBranchActive && !shouldGenMove`. (The red border already signals branch mode.)

### T2 — Three branch NSAlert sheets (chooser / replace / discard) [dep T1]
- **Files:** `MainWindowController.swift`.
- Extend `installConfirmationObserver`/`trackConfirmations`/`handleConfirmationChange` to also track `confirmingBranchDeactivation`/`Replace`/`Discard` (add `lastConfirmingBranch*` snapshots). On each false→true edge present an NSAlert **sheet** (`beginSheetModal`, never `runModal`):
  - **Chooser** ("Branch moves are temporary. Replace the original game with this branch, or discard it?"): **Replace** → set `confirmingBranchReplace=true` (next runloop, via `Task{@MainActor}` to avoid chaining sheets in one transaction); **Discard Branch** → `confirmingBranchDiscard=true`; Cancel.
  - **Replace** ("Replace the original game…? moves after this point will be permanently lost."): Replace (destructive) → `commitBranch(gameRecord:)` (or `deactivateBranch()` if no game); Cancel.
  - **Discard** ("Discard this branch? Your newly played stones will be lost."): Discard (destructive) → `deactivateBranch()`; Cancel.
  Clear each flag on dismissal (snapshot diff prevents re-fire). Mirrors `GameSplitView` 196-249.

### T3 — Reload-on-deactivation observer (fixes a real desync) [dep T2]
- **Files:** `MainWindowController.swift`.
- Add a `withObservationTracking` observer on `gobanState.branchSgf` (snapshot `lastBranchSgf`). On active→inactive (`old.isActiveSgf && !new.isActiveSgf`) call `gobanState.loadGame(gameRecord: selectedGameRecord, previous: nil, …)` to rebuild the engine board from the saved SGF (fires for BOTH commit + discard, since both end via `deactivateBranch`). Mirrors `GameSplitView.processChange(oldBranchStateSgf:)`. **Verify commit ordering** (loadGame must read the committed sgf, not race the commit).

### T4 — Eye / board↔book visibility toggle (3-state) — View-menu + toolbar item
- **Files:** `AppDelegate.swift` (View menu), `MainWindowController.swift`.
- `@objc toggleEyeStatus(_:)` reproducing `StatusToolbarItems.eyeAction`: `.opened → (.book if isBookCompatible && bookLookup.isLoaded else .closed)`; `.book → .closed`; `.closed → .opened`. Mutate `gobanState.eyeStatus`. View-menu item + toolbar item (👁). Refresh the toolbar item image/tint after the change (the overlay/win-rate bar already react via the hosted BoardView). `validateMenuItem` reflects state.

### T5 — Wire `syncBookState()` (replace the Phase 6 TODO stubs) [dep T4]
- **Files:** `MainWindowController.swift`.
- Port `GameSplitView.syncBookState()`: early-return if `bookLookup.justAdvanced` (de-dup + `clearJustAdvanced`); else, gated on `selectedGameRecord` + `concreteConfig.isBookCompatible` + `bookLookup.isLoaded`, reconstruct the move list from `getSgf`/`getCurrentIndex` via `SgfHelper` and call `bookLookup.syncFromMoves(...)`. Call it at the iOS sync points (book-loaded change, eye→.book, stones-ready). Replace the `// TODO(Phase 6): book sync` stub in `handleStonesReadyChange`.

### T7 — Lock / Edit-mode toggle
- **Files:** `AppDelegate.swift` (Game menu), `MainWindowController.swift`.
- Game-menu item (+ optional toolbar) → `@objc toggleEditing(_:)` flipping `gobanState.isEditing` (mirrors iOS Lock/Unlock). `validateMenuItem` checkmark from `isEditing`. The true→false reload observer already exists. Enables intentional edit-from-current-position (branch entry is still implicit on off-mainline play).

### T6 — Wire Mac AI move generation [dep D-P6-1]
- **Files:** `MainWindowController.swift` (+ promote the throwaway `aiMoveBox` to the real store if needed).
- In `handleAnalysisLifecycleChange`, when `gobanState.shouldGenMove(config:player:)` is TRUE on the re-arm edge, issue the **gen-move** analysis (via `requestAnalysis`/`maybeRequestAnalysis` → `getRequestAnalysisCommands` returns the `kata-search_analyze_cancellable` set) instead of plain `getKataAnalyzeCommand()` — mirroring iOS (which skips the plain re-arm while `shouldGenMove`). The engine's chosen move flows through `session.run(... aiMove: aiMoveBox.binding)` → `maybeCollectPlay`/`postProcessAIMove` → the already-wired AI-overwrite NSAlert / direct play. **RUNTIME-VERIFY** (highest risk): enabling a per-color `maxTime>0` (via the existing config editor) makes the engine generate + play, WITHOUT conflicting with the auto-play loop (both key off `analysisStatus`/`waitingForAnalysis`) — confirm no double-play/loop. Verify via a DEBUG smoke (set White maxTime>0, confirm a `play` arrives + the move appears).

### T8 — Minimal accessibility [D-P6-4]
- **Files:** `MacBoardInteractionLayer.swift`, `MainWindowController.swift` (toolbar items), menus.
- Give the board interaction overlay an accessibility label (e.g. "Go board, click to play"); ensure toolbar nav-group + the new eye/branch/edit items + analyze have accessibility labels/tooltips. No per-intersection elements.

### T9 — App Intents on the Mac target [D-P6-3]
- **Files:** `project.pbxproj` (add `AppIntents/GameEntity.swift`, `GetGameInfo.swift`, `KataGoShortcuts.swift` to the Mac target's Sources phase via the `xcodeproj` gem), `AppDelegate.swift` (call `KataGoShortcuts.updateAppShortcutParameters()` in `applicationDidFinishLaunching`, mirroring `KataGo_iOSApp.init`).
- Verify the intents compile/link in the Mac target (they import the shared `GameRecord.fetchGameRecords`/`comments`). Handle any `LoadingIcon`/asset reference (add to the Mac asset catalog or guard).

### T10 — Retire the SwiftUI macOS build [D-P6-2]
- **Files:** `project.pbxproj`.
- For the OLD "KataGo Anytime" app target's Debug+Release configs (E18F3E32 ~line 3371 / E18F3E33 ~3433), change `SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx xros xrsimulator"` → `"iphoneos iphonesimulator xros xrsimulator"` (remove `macosx`). DO NOT touch KataGoSwift / katago / the "KataGo Anytime Mac" target configs. Verify: the OLD scheme no longer offers a macOS destination; the Mac scheme still builds.

### T11 — Dead-code cleanup in the OLD SwiftUI app [dep T10]
- **Files:** `KataGo iOS/KataGo_iOSApp.swift` (the `Window(...)` macOS scene arm → keep only the `WindowGroup` body), `GameSplitView.swift` (the `#if os(macOS)` NSImage/PNG thumbnail path → keep the HEIC body), `PlusMenuView.swift` (minor branches). Simplify the now-unreachable `#if os(macOS)` branches in the OLD `KataGo iOS/` group ONLY (NOT the shared package, which the Mac app still uses on macOS). Be conservative — only remove genuinely-dead branches.

### T12 — Final parity sweep + 3-platform verification + tag [dep most]
- Cold build iOS/macOS/visionOS (0 warnings) + iOS FastTestPlan (247 tests). Runtime smoke: branch dialogs, eye/book toggle, edit mode, AI-play (T6 DEBUG smoke). Confirm `GobanStateBranchTests` still pass. Tag `mac-phase6-finalize`. Update [[project_mac_appkit_redesign]] (mark the WHOLE redesign DONE) + [[project_mac_deferred_manual_testing]].

## Open questions (runtime)
1. T6: does enabling per-color `maxTime>0` already arm gen-move on Mac (shared `onChange(nextColorForPlayCommand)` → `maybeRequestAnalysis`)? And does gen-move play coexist with the auto-play loop without double-play/looping? (highest risk)
2. T2/T3: `commitBranch` (trim + reassign currentIndex + `deactivateBranch`) → does the T3 reload observer fire strictly AFTER the commit (no race)?
3. T4: does the eye toolbar item image refresh without an explicit `validateVisibleItems()`?
4. T9: do the App Intents link cleanly in the Mac target (asset refs, no iOS-only API)?
5. T10: does re-opening the project in Xcode re-normalize pbxproj noisily after the edit? (keep the diff to the edited configs)

## Execution model
Subagent-driven; fresh implementer per task-group; adversarial review on the risky ones (T2/T3 branch
state machine + reload ordering, T6 AI-play vs auto-play interaction). Build green on 3 platforms +
iOS tests; commit per group; tag `mac-phase6-finalize`. Manual/visual tests DEFERRED → append to
[[project_mac_deferred_manual_testing]]. On completion, mark the native macOS redesign COMPLETE.
