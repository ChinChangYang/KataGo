# Mac Phase 3 — Analysis & Board Input

**Date:** 2026-06-16
**Branch:** `ios-dev` (not pushed)
**Spec:** `docs/superpowers/specs/2026-06-15-katago-anytime-mac-appkit-design.md` §9 Phase 3
**Predecessors:** Phase 0 (`mac-phase0-complete`), Phase 1 (`mac-phase1-skeleton`), Phase 2 (`mac-phase2-library`)

The native macOS app hosts the **shared SwiftUI `BoardView`** (the real renderer, in package
`KataGoUICore`) via `NSHostingView`, and uses `GameSession` (the extracted `@Observable @MainActor`
engine session). Phase 3 makes analysis actually *run* on Mac and adds native board input.

## Locked decisions (this phase)

- **D-P3-1 — Branch from here: DEFERRED to Phase 6.** The right-click board menu ships with
  *Play here · Copy coordinate* only. "Branch from here" depends on the branch state machine +
  confirm/commit/discard dialogs (Phase 6) and is not wired now.
- **D-P3-2 — Hover-to-preview: full, with fallback.** Attempt ghost stone **plus** the hovered
  candidate move's win%/score readout. If a public per-vertex analysis lookup proves impractical
  to add cleanly, ship **ghost-stone-only** and note the gap.
- **D-P3-3 — Coordinate mapping = single shared source of truth.** Extract the point↔board-vertex
  math (currently inline in `BoardView`'s `.onTapGesture`) into a **public helper in
  `KataGoUICore`** so the SwiftUI tap, the right-click menu (T8), and hover (T9) all agree. Touching
  shared code ⇒ **re-verify iOS** (build all platforms + tests) after that extraction.

## What is already FREE via the reused `BoardView` (do NOT rebuild)

Confirmed by the understanding pass. These render/work with **zero Mac code** once analysis data flows:

- **Analysis overlay** (colored move circles + win%/score/visits) — `AnalysisView`, gated by
  `gobanState.shouldRequestAnalysis` (true when `analysisStatus != .clear`) && `eyeStatus == .opened`.
  Mac defaults are `.run`/`.opened`. Text variant chosen by `analysisInformation` (default 2 = All).
- **Ownership heatmap** *rendering* — gated by `gobanState.showOwnership` (default true). Data is
  `analysis.ownershipUnits` from `GameSession.maybeCollectAnalysis`. (The *toggle* still needs wiring.)
- **Win-rate bar** — `BoardView`, gated by `showWinrateBar` (default true) && `eyeStatus == .opened`.
  Driven by `rootWinrate.black` / `rootScore.black`.
- **Captures readout** — `StoneView`, always drawn from `stones.blackStonesCaptured` / `whiteStonesCaptured`.
- **Click-to-play happy path** — `BoardView.onTapGesture` → `gobanState.sendCheckMoveCommand`; reply
  parsed by `GameSession.maybeCollectCheckMove`, already driven by `MainWindowController` via `session.run()`.
- **Pending-move suppression + human-overwrite confirmation** — `BoardView`-local `@State`; renders inside
  `NSHostingView` with no Mac wiring.
- **Place/capture sound *code path*** — play sound fires from `GobanState` play paths, capture sound from
  `BoardView.onChange(of: stones.*StonesCaptured)`. Silent only because `gobanState.soundEffect` defaults
  false ⇒ un-muted by T6. `AVAudioSession` config is `#if !os(macOS)`, so `AudioModel` is Mac-safe.
- **Coordinates / pass area / move numbers / stone style / vertical flip / branch outline / book overlays** —
  all rendered + gated inside the hosted views at their defaults.
- **Arrow-key move navigation** — ALREADY DONE in Phase 2 (`AppDelegate` Navigate menu → implemented
  `@objc` actions on `MainWindowController`). Not re-scoped.

## Cross-cutting implementation notes

- **Observation bridge (used by T1, T4, T5, and menu/toolbar state):** `MainWindowController` is not a
  SwiftUI view, so reacting to `@Observable` `GobanState` changes uses a **self-rescheduling
  `withObservationTracking`** helper: read the tracked properties inside `apply`, and in `onChange` hop to
  `@MainActor` to react **then re-register** (a tracking closure fires once per change and must be
  re-armed or it stops observing). One small reusable helper, not N ad-hoc copies.
- **Toolbar/menu state refresh:** `NSToolbarItem` images and `NSMenuItem` checkmarks do **not** auto-update
  when `analysisStatus`/`showOwnership`/etc. change from non-UI paths. Where state can change off the UI
  (e.g. overwrite Cancel sets `.clear`), drive an explicit `toolbar.validateVisibleItems()` /
  rely on `validateMenuItem` being called on menu open, and refresh the Analyze item image via the
  observation bridge.
- **Per task:** leave the app building on all 3 platforms (0 new warnings), run iOS unit tests when shared
  code is touched, commit, then move on. Tag `mac-phase3-analysis-input` at the end.

## Tasks (build order: T1 → T2 → T6 → T3 → T7 → T4 → T5 → T8 → T9)

### T1 — Continuous `kata-analyze` re-arm + stop observer (highest leverage)
- **Files:** `KataGo Anytime Mac/MainWindowController.swift`
- **Goal:** Without this, the free overlays populate once then go stale — `GameSession` only *parses*
  analyze output and sets `waitingForAnalysis`; it never sends `kata-analyze`/`stop`. iOS does this in
  `GameSplitView` `.onChange`. Mac has no equivalent.
- **Approach:** Replicate iOS's two host-driven observers via the observation bridge:
  1. Observe `gobanState.waitingForAnalysis`: on `true→false` transition and the selected game's config
     `!shouldGenMove`, re-send `config.getKataAnalyzeCommand()` via `session.messageList.appendAndSend(command:)`,
     UNLESS `analysisStatus == .pause` (then send `"stop"`). (`GameSplitView.swift:483-493` verbatim.)
  2. Observe `gobanState.analysisStatus`: when it becomes `.clear`, send `"stop"`.
     (`GameSplitView.processAnalysisStatusChange:414-418`.)
  First analyze is kicked by the hosted `BoardView.onAppear` → `maybeRequestAnalysis`; the observer
  sustains it. **Runtime-verify** the first request actually fires on Mac; if not, add an explicit kick
  after `session.initialize()` in `initializeSession`.
- **Risk:** tracking-closure re-arm correctness; double-arming (mitigated by `waitingForAnalysis` gate);
  must mutate `MessageList` on `@MainActor`.
- **Verify:** Mac build green; runtime smoke — overlay circles + win-rate bar update continuously
  (snapshot harness or visual).

### T2 — `toggleAnalysis:` action behind the (currently dead) toolbar Analyze button
- **Depends:** T1 — **Files:** `KataGo Anytime Mac/MainWindowController.swift`
- **Approach:** Add `@objc func toggleAnalysis(_:)` mirroring iOS `StatusToolbarItems.sparkleAction`:
  `.pause → .clear`; `.run → gobanState.maybePauseAnalysis()`; `.clear → set .run`, call
  `session.analysis.resetVisitsPerSecondSession()` **then** `gobanState.maybeRequestAnalysis(...)` (order
  matters or visits/s denominator inflates). Toolbar item already targets `Selector("toggleAnalysis:")`
  via first responder. Reflect on/off in `validateToolbarItem` and by swapping the item image
  (e.g. `wand.and.stars` vs a slashed/tinted variant) driven by the observation bridge. Guard nil
  `selectedGameRecord`. The `.clear` `"stop"` is sent by T1's observer (no duplicate here).
- **Verify:** clicking the toolbar button cycles run→pause→clear and the overlay starts/stops.

### T6 — Mac `GlobalPreferenceSync` equivalent (14 `GlobalSettings.*` keys ↔ `GobanState`)
- **Files:** `KataGo Anytime Mac/MainWindowController.swift`; **new** `KataGo Anytime Mac/MacGlobalPreferenceSync.swift`
- **Goal:** Display flags currently sit at compiled defaults and never persist; `soundEffect` defaults
  false (silent). Shared `UserDefaults` keys so iOS/Mac prefs round-trip. Precondition for T3/T7 toggles.
- **Approach:** Small `@MainActor` class owned by `MainWindowController`, replicating
  `GameSplitView.GlobalPreferenceSync` (`:573-624`). On launch: seed `gobanState.<prop>` from
  `UserDefaults.standard` key `"GlobalSettings.<name>"`, **falling back to the same `Config.default*`
  constants** (NOT literals). Then observe `gobanState` writes back to `UserDefaults` (observation-bridge
  re-arm, or a combined snapshot+diff of all 14). Keys/types/defaults:
  `soundEffect:Bool=false`, `hapticFeedback:Bool=false`, `showVisitsPerSecond:Bool=false`,
  `showCoordinate:Bool=Config.defaultShowCoordinate`, `showPass:Bool=Config.defaultShowPass`,
  `verticalFlip:Bool=Config.compatibleVerticalFlip`, `showOwnership:Bool=Config.defaultShowOwnership`,
  `showWinrateBar:Bool=Config.defaultShowWinrateBar`, `showCharts:Bool=Config.defaultShowCharts`,
  `showComments:Bool=Config.defaultShowComments`, `stoneStyle:Int=0`, `moveNumberStyle:Int=0`,
  `analysisStyle:Int=0`, `analysisInformation:Int=Config.defaultAnalysisInformation`.
  Wire in `MainWindowController.init` before `BoardView` appears.
- **Risk:** must use `Config.default*` exactly (`showComments=false`, `analysisInformation=2` differ from
  the bool-true majority). **Register the new file in `project.pbxproj`** via the `xcodeproj` Ruby gem
  (app target `KataGo Anytime`) — no synchronized groups. Not SwiftData/`Config @Model` (those are frozen).

### T3 — Analysis menu (Toggle ⌘↩ · Pause · Clear · Toggle Ownership)
- **Depends:** T2 (and T6 for ownership persistence) — **Files:** `AppDelegate.swift`, `MainWindowController.swift`
- **Approach:** Insert an `Analysis` submenu via the established `makeSubmenu` pattern. Items target
  `MainWindowController` via responder chain: **Toggle Analysis** `keyEquivalent:"\r"` + `[.command]`
  → `toggleAnalysis(_:)` (T2); **Pause** → `pauseAnalysis(_:)` (`maybePauseAnalysis()`); **Clear** →
  `clearAnalysis(_:)` (set `.clear`; T1 sends `"stop"`); **Toggle Ownership** → `toggleOwnership(_:)`
  (flip `gobanState.showOwnership`, persisted by T6). Add `validateMenuItem` cases gated on
  `selectedGameRecord != nil`, with checkmarks reflecting `analysisStatus`/`showOwnership`.
- **Risk:** verify ⌘↩ doesn't intercept Return inside future hosted text fields (Phase 4); keep the
  `AnalysisStatus` state machine consistent (`maybePauseAnalysis` only transitions from `.run`).
  **Ownership toggle lives here, not in View menu (T7)** — avoid duplication.

### T7 — View-menu display toggles (Visits/sec · Win-Rate Bar · Coordinates · Pass)
- **Depends:** T6 — **Files:** `AppDelegate.swift`, `MainWindowController.swift`
- **Approach:** Extend `AppDelegate.viewMenu` with a separator + toggle items → new `@objc` actions on
  `MainWindowController` flipping `gobanState.showVisitsPerSecond` / `showWinrateBar` / `showCoordinate` /
  `showPass` (persisted by T6). Set `NSMenuItem.state` in `validateMenuItem` from the live `gobanState`
  value. (Ownership stays in the Analysis menu, T3.) `showVisitsPerSecond` gates `BoardView.speedText`
  (also needs `analysisStatus == .run`).
- **Risk:** avoid bare-letter shortcut collisions (prefer no/modified shortcuts); checkmark needs live read.

### T4 — Illegal-move "Play Anyway" confirmation (NSAlert)
- **Depends:** T1 — **Files:** `KataGo Anytime Mac/MainWindowController.swift`
- **Goal:** Preserve illegal-move-with-reason + play-anyway. State is free in the package; only the AppKit
  presentation is missing (the dialog lives in iOS `GameSplitView`, not `BoardView`).
- **Approach:** Observe `gobanState.confirmingIllegalMove` (observation bridge). On `true`, present an
  **NSAlert as a sheet** (`beginSheetModal(for:)` — never block the GTP run loop) with title from
  `gobanState.illegalMoveReason` (ko/superko/suicide/default; mirror `GameSplitView.illegalMoveReasonText`).
  **Play Anyway** (destructive) → `gobanState.playPendingHumanMove(gameRecord:analysis:board:stones:messageList:player:audioModel:)`;
  **Cancel** → `gobanState.clearPendingMove()`. Clear the flag on dismissal so the observer doesn't re-fire.
- **Risk:** modal reentrancy on `@MainActor`; verify `playPendingHumanMove` signature.

### T5 — AI-overwrite confirmation (NSAlert)
- **Depends:** T4 — **Files:** `KataGo Anytime Mac/MainWindowController.swift`
- **Approach:** Mirror T4 on `gobanState.confirmingAIOverwrite` (set by `GameSession.postProcessAIMove`).
  **Overwrite** → `gobanState.playAIMove(aiMove: aiMoveBox.value, ...)`; **Cancel** → clear flag + set
  `analysisStatus = .clear`. Promote the existing throwaway `AIMoveBox` to the real `aiMove` source.
  Note: the *human* board-tap overwrite is already free inside `BoardView`; this is only the AI path.
- **Risk:** Mac has no genmove trigger yet, but `maybeCollectPlay` runs in the shared loop (loaded SGFs /
  future genmove) — wire defensively. Reuses T4's plumbing.

### T8 — Right-click board context menu (*Play here · Copy coordinate*) — branch DEFERRED
- **Depends:** T6, D-P3-3 coordinate helper — **Files:** `BoardViewController.swift`, `MacBoardHostView.swift`,
  `MainWindowController.swift`, and (D-P3-3) the new shared coordinate helper in `KataGoUICore/Rendering/`.
- **Approach:** First extract the inline point↔vertex math from `BoardView.onTapGesture` into a public
  `KataGoUICore` helper (D-P3-3), then **re-verify iOS**. Add a Mac-only context menu over the board that
  converts the right-click point (NSHostingView space, flipped y) to a board vertex via the shared helper.
  Items: **Play here** → `gobanState.sendCheckMoveCommand(...)` (reuses the tap path incl. pending/overwrite
  guards); **Copy coordinate** → `NSPasteboard.general` write the coordinate string. **"Branch from here"
  is deferred** (D-P3-1).
- **Risk (HIGH):** right-click handling must NOT swallow left-click taps that the hosted `BoardView`
  needs (**runtime-verify** tap-vs-overlay event routing). Coordinate mapping depends on live frame +
  `verticalFlip`; the shared helper prevents drift.

### T9 — Hover-to-preview (ghost stone + hovered move win%/score) — full w/ ghost-only fallback
- **Depends:** T8 (shares the coordinate helper) — **Files:** `BoardViewController.swift`,
  `MacBoardHostView.swift`, shared helper.
- **Approach:** Net-new (package hover is cosmetic `.hoverEffect()`, compiled out on macOS). Prefer a
  SwiftUI overlay using `onContinuousHover` (macOS) layered in `MacBoardHostView` (stays in SwiftUI
  coordinate space — avoids flipped-y), else an `NSTrackingArea`. On hover: map cursor → vertex (shared
  helper), draw a translucent ghost stone in `player.nextColorForPlayCommand` at the hovered empty point;
  if `analysis` holds a candidate at that vertex, show its win%/score. **Must NOT send GTP** — display only.
  Suppress when a pending move exists / point occupied / not `analysisStatus == .run`.
  **Fallback (D-P3-2):** if a clean public per-vertex analysis lookup can't be added, ship ghost-only.
- **Risk (HIGHEST):** mouse-move reaching an overlay through `NSHostingView`; per-vertex analysis lookup
  may need a new public `Analysis` accessor. Do last.

## Open questions to resolve during implementation (runtime checks)
1. Does the FIRST `kata-analyze` actually fire on Mac (BoardView.onAppear timing vs engine ready)? → T1.
2. Do single left-clicks reliably reach `BoardView.onTapGesture` through `NSHostingView`, and still after
   T8/T9 overlays are layered? → T8/T9 event routing.
3. Does `Analysis` expose (or need) a by-vertex win%/score accessor for T9? → drives full vs ghost-only.
4. Is ⌘↩ safe vs future hosted editable text fields? → T3.
5. Toolbar image / menu checkmark refresh cadence on off-UI state changes. → cross-cutting bridge.

## Execution model
Subagent-driven: a fresh implementer per task, then a spec-conformance + code-quality review (adversarial
review on the risky ones — T1 observation correctness, T4/T5 modal reentrancy, T8/T9 event routing &
coordinate mapping). Build green on all 3 platforms + iOS tests when shared code changes, commit per task,
tag `mac-phase3-analysis-input` at the end. Update `project_mac_appkit_redesign` memory.
