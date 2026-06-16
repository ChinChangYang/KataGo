# Mac Phase 4 — Inspector (Chart · Comments · Moves · Info)

**Date:** 2026-06-16
**Branch:** `ios-dev` (not pushed)
**Spec:** `docs/superpowers/specs/2026-06-15-katago-anytime-mac-appkit-design.md` §4③ / §9 Phase 4
**Predecessors:** Phases 0–3 (`mac-phase0-complete`..`mac-phase3-analysis-input`)

The Inspector pane is currently a `PlaceholderViewController`. Phase 4 replaces it with a tabbed
inspector: **Chart · Comments · Moves · Info**, collapsible (⌃⌘I, already wired) with ⌘1–4 tab
shortcuts.

## Locked decisions (this phase)
- **D-P4-1 — Config editing = NATIVE AppKit.** The Info tab and the full "Edit…" editor are built
  with native AppKit controls (`NSTextField`/`NSStepper`/`NSPopUpButton`/`NSSwitch`/form rows), NOT
  by reusing the SwiftUI `ConfigView`. Higher effort, most Mac-native.
- **D-P4-2 — AI commentary ships as-is.** Reuse `CommentView`/`Commentator` unchanged; on-device AI
  unavailable → silent template-comment fallback (existing `do/catch`). No availability gating, no
  shared-code change.
- **D-P4-3 — Moves tab = flat ordered list of the active line** (a true variation tree needs net-new
  C++/SGF parsing — out of scope). Show per-move win%/score columns **with blanks** where the sparse
  `winRates`/`scoreLeads` dictionaries aren't populated yet.
- **D-P4-4 — Port the auto-play stepping loop now** so the Chart self-fills and its wand button works.
- **D-P4-5 — Inspector container = AppKit.** Use `NSTabViewController` with `tabStyle =
  .segmentedControlOnTop` (native segmented tabs, lazy child-VC management) hosting 3 SwiftUI tabs via
  `NSHostingController` + 1 native AppKit Info tab. (Consistent with D-P4-1 and the whole redesign.)

## What is REUSE (host the shared SwiftUI view + inject the right @Environment)
- **Chart** = `LinePlotView(gameRecord:)` (public, zero platform conditionals). Needs env:
  `GobanState, BoardSize, MessageList, Turn, Stones` (NOT `Analysis`). Click-to-jump (`.chartXSelection`
  → `gobanState.go(to:…)`) and the wand auto-play button are internal.
- **Comments** = `CommentView(gameRecord:)`. Needs env: `GobanState, Analysis, Stones, BoardSize, Turn`
  (NOT `MessageList`) + a `FocusState<Bool>.Binding` supplied by a small SwiftUI wrapper that owns
  `@FocusState`. `Commentator` (+ `CommentTone`, `@Generable CommentText`) reused as-is.
- **Navigation / move enumeration** (all public): `GobanState.go(to:gameRecord:board:messageList:player:audioModel:stones:)`,
  `getSgf`/`getCurrentIndex`, `SgfHelper.getMove(at:)`/`moveSize`/`getComment(at:)`, `BoardSize.locationToMove`.
- **Per-move data on `GameRecord`** (frozen @Model — read only): `scoreLeads`/`winRates`/`bestMoves`/
  `comments`/`moves` (`[Int:…]?`), `concreteConfig: Config`. NO schema changes ([[feedback_never_modify_swiftdata_models]]).
- **Inspector plumbing already done:** split item (`MainSplitViewController` canCollapse/min220/max360),
  ⌃⌘I toggle (`AppDelegate` View menu), toolbar Inspector button — all operate on whatever VC fills the slot.
- **Hosting template:** `BoardViewController` → `NSHostingController` → `.environment(session.x)` +
  `BoardReadiness` gate + `navigationContext.selectedGameRecord` read — copy this for the SwiftUI tabs.

## Tasks (build order: T1 → T2 → T3 → T4 → T5 → T6 → T7)

### T1 — Inspector shell: `InspectorViewController` (NSTabViewController) + Chart/Comments tabs
- **Files:** new `KataGo Anytime Mac/InspectorViewController.swift`, new `KataGo Anytime Mac/CommentsTabView.swift`
  (small SwiftUI wrapper owning `@FocusState` and hosting `CommentView`); pbxproj registration (Mac target).
- **Approach:** `InspectorViewController: NSTabViewController`, `init(session:navigationContext:audioModel:readiness:)`
  mirroring `BoardViewController`. Set `tabStyle = .segmentedControlOnTop`. Add 4 `NSTabViewItem`s:
  - **Chart** → `NSHostingController(rootView: ChartTab)` where `ChartTab` gates on
    `readiness.isEngineReady && selectedGameRecord != nil` (else `ProgressView`) then
    `LinePlotView(gameRecord:)` with env `gobanState/board/player/messageList/stones`.
  - **Comments** → `NSHostingController(rootView: CommentsTabView(...))`; `CommentsTabView` owns
    `@FocusState commentIsFocused`, gates on readiness/selection, hosts `CommentView(gameRecord:).focused($commentIsFocused)`
    with env `gobanState/analysis/stones/board/player`.
  - **Moves** → placeholder child VC (filled by T3).
  - **Info** → placeholder child VC (filled by T5).
  Labels + SF Symbols (chart.xyaxis.line / text.bubble / list.number / info.circle). Use
  `navigationContext`/`readiness` observation so tabs refresh on game switch.
- **Risk:** each SwiftUI tab needs EXACTLY its env set (CommentView crashes without `Analysis` + the
  FocusState binding). New files → pbxproj via the `xcodeproj` gem (Mac target). `NSTabViewController`
  lazy-loads tabs — confirm env injection happens per hosted view.

### T2 — Swap `PlaceholderViewController` → `InspectorViewController`
- **Files:** `KataGo Anytime Mac/MainSplitViewController.swift`
- **Approach:** Replace the inspector `PlaceholderViewController(...)` with
  `InspectorViewController(session:navigationContext:audioModel:readiness:)` (same 4 args
  `BoardViewController` gets). Keep the `inspectorWithViewController` availability branch +
  canCollapse/thickness. No toggle/toolbar work.
- **Risk:** trivial; check `PlaceholderViewController` still referenced elsewhere before removing.

### T3 — Moves tab: new `MovesListView` (SwiftUI, flat active-line list w/ metrics+blanks)
- **Files:** new `KataGoUICore/Sources/KataGoUICore/Rendering/MovesListView.swift` (in package so iOS can
  reuse later); wire as the Inspector Moves child VC. pbxproj (package file is auto-included; the host
  wiring is in `InspectorViewController`).
- **Approach:** `MovesListView(gameRecord:)`, env `GobanState/BoardSize/MessageList/Turn/Stones`. Source
  the active line via `gobanState.getSgf` + `getCurrentIndex` (NOT raw `gameRecord.sgf`/`currentIndex` —
  correct under branching). For `i in 0..<SgfHelper(sgf:).moveSize`: row = {moveNumber `i+1`, player from
  `Move.player`, coordinate via `board.locationToMove`}, plus metrics from `winRates[i+1]`/`scoreLeads[i+1]`
  **flipped to the just-moved player's perspective** (white: `1-w` / `-score`, per `Commentator.formatWinRate/formatScore`).
  **Show blanks (“—”) when a key is absent** (D-P4-3). Highlight the current row off `getCurrentIndex`
  (Observable → auto-updates). Row tap → `gobanState.go(to: i+1, …, audioModel: nil, …)` guarded by
  `!isAutoPlaying` (exactly `LinePlotView`'s jump).
- **Risk:** off-by-one — dict key `i` = position AFTER `i` moves; `getMove(at:i)` is move `i+1`. List must
  tolerate sparse/missing metrics. Use a `List`/`Table` that scrolls; keep current row visible.

### T4 — Port the auto-play stepping loop (Chart precondition) — D-P4-4
- **Files:** `KataGo Anytime Mac/MainWindowController.swift` (extend `handleAnalysisLifecycleChange`)
- **Approach:** The Mac analysis observer currently mirrors only the iOS analyze re-arm/stop, not the
  auto-play branch (`GameSplitView.swift:495-525`). Port it: on the `waitingForAnalysis` true→false
  transition, when `gobanState.isAutoPlaying && !analysis.info.isEmpty && stones.isReady`, call
  `maybeUpdateAnalysisData(…)` (writes `scoreLeads`/`winRates` at currentIndex), then read the next move
  via `SgfHelper(sgf: gameRecord.sgf).getMove(at: currentIndex)`, `gobanState.play(…)`, toggle player,
  `sendShowBoardCommand`, `audioModel.playPlaySound(soundEffect:)`, set `isAutoPlayed=true`; when no next
  move, set `isAutoPlaying=false`/`isAutoPlayed=false`. Also ensure flipping `isAutoPlaying` true kicks the
  first analyze (iOS does this via `onChange(of: isAutoPlaying)` `GameSplitView.swift:115`) — add a Mac
  counterpart (observe `isAutoPlaying`, or trigger an analyze when it goes true) if the existing
  `waitingForAnalysis` transition doesn't already cover the first step.
- **Risk (HIGH):** runs from the `withObservationTracking` bridge and mutates SwiftData + drives GTP —
  must stay on `@MainActor` and not re-enter the observer badly (the documented one-shot/defer gotchas).
  Verify the loop self-sustains move-to-move and terminates at game end. Verify via the data diagnostic
  (scoreLeads filling) like Phase 3's analysis check.

### T5 — Info tab: NATIVE AppKit (summary + inline common settings) — D-P4-1
- **Files:** new `KataGo Anytime Mac/InspectorInfoViewController.swift` (native `NSViewController`);
  reads `GameRecord`/`Config` from the package; pbxproj (Mac target).
- **Approach:** Native AppKit form (e.g. `NSGridView`/stacked rows). **Summary:** `gameRecord.name`,
  `lastModificationDate`, `concreteConfig.board W×H / komi / rule`, + SGF-parsed PB/PW/RE/handicap (via
  `SgfHelper` — these aren't first-class `GameRecord` fields). **Inline common settings** bound live to
  `gameRecord.concreteConfig` (read/write existing props + computed accessors ONLY — NO new stored props):
  board W/H, komi, rule (ko/scoring/tax), AI opponents (per-color `humanSLProfile` + `maxTime`,
  `playoutDoublingAdvantage`), analysis params (`analysisForWhom`, `maxAnalysisMoves`, `analysisInterval`).
  **Preserve engine side-effects:** edits that iOS pushes via GTP (komi/rule/PDA/wide-root-noise/human-SL
  commands; board-size/rule changes defer `kata-set-rule` + `showboard` + `printsgf`) must replay at a
  commit point (on field commit / control action) via `session.messageList.appendAndSend`. Refresh on
  game switch (observe `navigationContext.selectedGameRecord`).
- **Risk (HIGH):** NEVER modify the `Config`/`GameRecord` @Model schema. Engine/SGF divergence if
  rule/board edits don't replay the GTP commands. Board-size change mid-game is fragile — mirror iOS's
  exact replay sequence. Largest native surface; budget care for the AppKit form + bindings.

### T6 — Full config "Edit…" — NATIVE AppKit sheet — D-P4-1
- **Files:** new `KataGo Anytime Mac/ConfigEditorViewController.swift` (+ presentation from the Info tab).
- **Approach:** Native AppKit form (sheet/`presentAsSheet`) covering the full per-game config set
  (the six iOS `ConfigView` sub-screens worth: Name/Rule/Analysis/AI/Comment/SGF) using native NS
  controls. Reuse the GTP-replay commit logic from T5. Open from the Info tab's "Edit…" button.
  Global display prefs (the `@AppStorage` set) do NOT belong here — those go in the Phase 5 Settings
  window; this editor is per-game `Config` only.
- **Risk:** large native surface; reuse T5's binding+replay helpers to avoid duplication. Keep the
  schema frozen. Ensure the deferred rule/SGF GTP replays fire on sheet dismissal (iOS does them in
  `RuleConfigView`/`SgfConfigView` `.onDisappear`).

### T7 — Tab shortcuts ⌘1–4 (+ expand if collapsed)
- **Files:** `KataGo Anytime Mac/AppDelegate.swift` (View menu items), `MainWindowController.swift`
  (or `InspectorViewController`) responder-chain action.
- **Approach:** Add View-menu items Chart ⌘1 / Comments ⌘2 / Moves ⌘3 / Info ⌘4 routed via the
  responder chain to an `@objc selectInspectorTab(_:)` that sets the `NSTabViewController`
  `selectedTabViewItemIndex`. If the inspector is collapsed, expand it first (uncollapse the inspector
  split item) then select. Prefer the menu route over pure SwiftUI `.keyboardShortcut` (more robust when
  the hosted content isn't first responder). `validateMenuItem` enables them when a game is selected.
- **Risk:** reaching the `NSTabViewController` from the menu action (thread the reference, or have
  `MainWindowController` hold a weak ref to the `InspectorViewController`).

## Open questions to resolve during implementation (runtime checks)
1. macOS pointer + `.chartXSelection` actually scrubs/jumps a move (Charts cross-platform but iOS-driven). → T1/Chart.
2. Auto-play loop self-sustains move-to-move on Mac and the first step kicks; no re-entrancy with the analysis observer. → T4.
3. SwiftData `GameRecord` writes from hosted inspector views (scoreLeads/comments/config edits) run on @MainActor with a valid context + persist/CloudKit-sync. → cross-cutting.
4. Native config edits replay the right GTP so engine + on-disk SGF stay in sync (esp. board-size/rule mid-game). → T5/T6.
5. ⌘1–4 fire via the menu route; expand-if-collapsed interaction. → T7.

## Execution model
Subagent-driven: fresh implementer per task; spec-conformance + adversarial review on the risky ones
(T4 auto-play re-entrancy, T5/T6 config GTP-replay + frozen schema). Build green on all 3 platforms +
iOS tests when shared code (MovesListView, any package touch) changes; commit per task; tag
`mac-phase4-inspector` at the end. Manual/visual tests are DEFERRED — append them to
[[project_mac_deferred_manual_testing]]. Update [[project_mac_appkit_redesign]] memory.
