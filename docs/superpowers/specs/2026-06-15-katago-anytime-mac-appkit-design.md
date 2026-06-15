# KataGo Anytime for Mac — Native AppKit Redesign

**Status:** Design approved (brainstorming) — pending implementation plan
**Date:** 2026-06-15
**Author:** Chin-Chang Yang (with Claude Code)

## 1. Motivation

KataGo Anytime is a single SwiftUI codebase targeting iOS, macOS, and visionOS. On
Mac the SwiftUI view layer looks and behaves awkwardly: a single `Window` (no menu
bar commands, **no keyboard shortcuts**), a sidebar that defaults to hidden,
`.buttonStyle(.glass)` that clashes with Aqua, cramped toolbar spacing, a
non-functional haptics toggle, phone-sized sheets, no right-click context menus,
and fragile `NavigationSplitView` behavior.

The fix is **not** to keep patching the cross-platform SwiftUI app. We will build a
**new, native macOS app using AppKit** for the application chrome, sitting on top of
the existing engine, data, and rendering code — which is already platform-agnostic.

## 2. Goals, Non-Goals, Success Criteria

### Goals
- A native macOS app that achieves **full feature parity** with the iOS app
  (every user-facing feature; see §8).
- Native Mac chrome: real menu bar + keyboard shortcuts, `NSToolbar`,
  `NSSplitViewController` panes (resizable/collapsible), right-click context menus,
  standard Settings window, proper window behavior.
- **No duplication** of engine/parsing/data/service logic — both apps share one
  core module.
- **Do not change existing iOS/visionOS behavior.** The only permitted change to the
  existing app is the mechanical *extraction* of shared code into the new module.

### Non-Goals
- No multi-window / per-game windows / tabs (single main window — see §7, decision D4).
- No rewrite of the board/analysis/chart **rendering** (reused via `NSHostingView` —
  see §3, decision D2).
- No changes to the SwiftData schema or CloudKit container (frozen).
- No new analysis/engine capabilities beyond what iOS already has.

### Success Criteria
- The Mac app builds and runs every feature on the §8 parity checklist.
- The iOS/visionOS app builds and behaves identically before and after the Phase-0
  extraction (verified by build + smoke test).
- The app feels native: keyboard-drivable, menu-complete, Aqua-consistent, with
  resizable panes and context menus.
- Zero build warnings across all targets (house standard).

## 3. Architecture

### 3.1 Module structure

```
KataGoInterface (existing framework)      ← C++ ↔ Swift bridge (unchanged)
        ▲
KataGoUICore (NEW local Swift package)    ← shared logic + reusable SwiftUI rendering
        ▲                      ▲
KataGo Anytime (iOS/visionOS)   KataGo Anytime for Mac (NEW AppKit target)
   SwiftUI App (existing)           AppKit App (new)
```

- **`KataGoInterface`** — the existing framework wrapping the C++ engine
  (`KataGoHelper`, `SgfHelper`, CoreML cache bridge). **Unchanged.**
- **`KataGoUICore`** — a **single new local Swift package** in the existing
  `KataGo Anytime.xcodeproj`. Holds everything that is not iOS-specific chrome.
  Organized into clean internal groups so a future split stays cheap:
  - `Engine/` — engine launch/config helpers built on `KataGoHelper`.
  - `Session/` — `GameSession` controller: the GTP message loop lifted out of
    `ContentView.messaging()`, plus pure parsers (`AnalysisLineParser`,
    `BoardTextParser`, `SgfHelper` usage, `MoveNumbers`, `SgfTruncation`).
  - `Model/` — `@Observable` state (`Stones`, `Turn`, `Analysis`, `Winrate`,
    `Score`, `GobanState`, `NavigationContext`) and SwiftData models
    (`GameRecord`, `Config`).
  - `Services/` — `Commentator`, `AudioModel`, `Downloader`, `BookLookup`,
    `NeuralNetworkModel`, `HumanSLModel`, `BinFileHasher`, `EngineLifecycle`,
    `CoreMLCacheReadiness`.
  - `Rendering/` — the reusable SwiftUI views (board/`GobanView`, stones, move
    numbers, analysis overlay, ownership heatmap, win-rate bar, `LinePlotView`).
    These are embedded on Mac via `NSHostingView`.
  - **Boundary hygiene:** `Engine/Session/Model/Services` must not import the
    `Rendering` views; enforced by review + `public` API discipline.

Decision **D1**: single combined package named **`KataGoUICore`** (not split
Core/UI). Rationale: simplest dependency graph and setup; logic/UI fusion is an
acceptable cost at this app's size; testability-of-pure-logic is the only real
reason to split and is YAGNI here.

### 3.2 Hybrid rendering (decision D2)

The Mac app is **native AppKit for all chrome** but **reuses the existing SwiftUI
rendering** by embedding views in `NSHostingView`/`NSHostingController`. We do **not**
re-implement the board/overlay/chart in Core Graphics. Rationale: the rendering is
visually tuned and works well; the awkwardness is in the chrome, not the canvas.

### 3.3 Observation bridge

AppKit views do not automatically observe `@Observable`. Pattern:
- AppKit controllers **own** the `@Observable` state objects and the `GameSession`.
- `GameSession` updates state from GTP responses (on the main actor).
- Hosted SwiftUI subviews auto-refresh from `@Observable` as today.
- A small **observation bridge** (`withObservationTracking` re-arming, or Combine
  publishers) pushes the same state changes into **native** UI: toolbar item
  enabled-state, inspector labels, menu-item state (`validateMenuItem` /
  `NSMenuItem` state), window title.

### 3.4 Code-sharing strategy & constraints

- Both apps depend on `KataGoUICore`; the iOS app's existing files are **moved** into
  the package (not copied). After extraction the iOS app imports `KataGoUICore`.
- **SwiftData schema is frozen** (CloudKit corruption risk): do not add/remove/rename
  `@Model` fields on `GameRecord`/`Config`; work around via `@AppStorage`/computed
  props/orphan fields. Both apps use the **same CloudKit container**
  (`iCloud.chinchangyang.KataGo-iOS.tw`) so sync continues to work.
- **Single engine process** (one `KataGoHelper.runGtp`, one NN in memory). Memory is
  tight (~1.2 GB with two nets; the b40 net can OOM on constrained devices — not a
  concern on Mac but informs the single-engine model).
- Engine defaults on macOS: **MLX/GPU**, 16 search threads (already set in
  `KataGoHelper`/`BackendChoice`).
- Deployment target: **macOS 26+** (matches the existing project).

## 4. Main Window (three-pane)

A single `NSWindowController` hosting an `NSSplitViewController` with three panes;
sidebar and inspector are independently collapsible; dividers are user-resizable.

- **Toolbar (`NSToolbar`):** sidebar toggle · New · Import · **active-model selector**
  (popup; switch among ready models; "Manage Models…") · move navigation
  `⏮ ◀ ▶ ⏭` · **Analyze** toggle · board/book view (👁) · inspector toggle. Every
  item also has a menu command + shortcut (§5).
- **① Library pane:** search field; date-grouped game list with thumbnails
  (small/large); selection drives the rest of the window. Right-click →
  Clone / Rename / Share / Delete. New/Import in toolbar + File menu.
- **② Board pane (center):** `NSHostingView(GobanView)` — win-rate bar at the left
  edge, analysis overlay (colored move circles with win%/score), captures + visits/s
  across the top, coordinates around the edge. Mouse interactions per §5.
- **③ Inspector pane (right):** segmented tabs **Chart · Comments · Moves · Info**
  (collapsible, ⌃⌘I):
  - **Chart** — interactive score/win-rate line plot (`LinePlotView`); click to jump.
  - **Comments** — per-move notes editor + AI comment generation (tone, temperature,
    Apple-Intelligence toggle) via `Commentator`.
  - **Moves** — NEW move list/tree; click to navigate; shows per-move win%/score.
  - **Info** — game summary + the common per-game settings inline (board/komi/rules,
    AI opponents, analysis params) with an **"Edit…"** sheet for the full config set.

Decision **D3**: three-pane layout (library · board · inspector).
Decision **D4**: single main window; selecting a game in the sidebar loads it and the
single engine analyzes the current game. No secondary windows/tabs.

## 5. Interaction Model

### 5.1 Menu bar
- **KataGo Anytime** — About · **Settings… ⌘,** · Hide ⌘H · Quit ⌘Q
- **File** — New Game **⌘N** · Import SGF… **⌘O** · Export SGF… **⇧⌘E** · Share… ·
  Close Window ⌘W
- **Edit** — Undo / Redo move **⌘Z / ⇧⌘Z** · Copy SGF **⌘C** · Paste SGF ·
  Rename Game **⏎** · Delete Game ⌫
- **Game** — Pass · Play Best Move · Generate AI Move **⌘G** · Clone Game **⌘D** ·
  Branch from Here **⌘B** · Commit / Discard Branch · Lock Editing
- **Navigate** — First **⌥⌘←** · Back 10 · Back **←** · Forward **→** ·
  Forward 10 · Last **⌥⌘→**
- **Analysis** — Toggle Analysis **⌘↩** · Pause · Clear · Generate Comment ·
  Toggle Ownership · Opening Book view
- **View** — Toggle Sidebar **⌃⌘S** · Toggle Inspector **⌃⌘I** ·
  Chart/Comments/Moves/Info **⌘1–4** · Coordinates · Move Numbers ▸ · Win-rate Bar ·
  Vertical Flip · Stone Style ▸ · Enter Full Screen
- **Window** / **Help** — standard (Minimize ⌘M, Zoom; Help, Acknowledgments)

Menu item enabled-state and checkmarks reflect live state via `validateMenuItem` and
the observation bridge.

### 5.2 Board mouse interactions
- **Left-click** empty point → play, preserving the existing pending-move /
  overwrite-confirmation / illegal-move (with reason + play-anyway) logic.
- **Arrow keys ← / →** → step backward/forward one move when the board has focus.
- **Right-click** point/stone → context menu: *Play here · Branch from here ·
  Copy coordinate*.
- **Hover-to-preview** (NEW, mouse-only): hovering an empty point shows a ghost stone;
  hovering an analyzed move surfaces its win%/score — a live "what-if" without
  committing. Included in v1.

## 6. Settings & Model/Backend Management

- **Settings window (⌘,):** standard tabbed prefs — **General · Board · Analysis ·
  Sound & Feedback** — holding the `@AppStorage` display/behavior defaults
  (coordinates, move-number style, stone style, ownership, win-rate bar, analysis
  style/info, show charts/comments, sound, visits/s). The View menu mirrors the live
  toggles. **Haptics toggle dropped on Mac** (silent no-op today). **Audio session**
  configured for desktop output.
- **Models window:** manage all networks — download/delete with progress, Active/Ready
  status — plus per-model backend config: **CoreML/NE vs MLX/GPU** (Mac default
  MLX/GPU), max board size (9/13/19/37), autotuning Fast/Full, "re-tune on next load."
  Opened from the toolbar model dropdown ("Manage Models…") and the Window menu.
  Quick-switching among ready models happens directly in the toolbar dropdown.
- **Engine launch & status:** loading/switching a model shows inline status
  ("Loading… / Compiling for 19×19…" — the latter only on the CoreML/NE path).
- **Crash recovery:** today's crash-loop sentinel (`pendingLoadModelTitle`) becomes a
  **launch alert** on Mac — "Loading *<model>* may have crashed last time → Load again
  · Choose another · Open library."
- **First run:** opens to the library and loads the bundled built-in net so the app is
  usable immediately; heavier nets are opt-in via the Models window.

Decision **D5**: model management is a **dedicated window**, not a Settings tab.

## 7. Mac-native Enhancements (beyond iOS parity)
Menu bar + keyboard shortcuts · resizable/collapsible `NSSplitView` panes ·
right-click context menus (library + board) · hover-to-preview on the board ·
the **Moves** list tab · dedicated **Models** and **Settings** windows ·
Aqua-consistent controls (drop `.glass`) · proper toolbar spacing ·
desktop audio routing.

## 8. Feature-Parity Checklist

Every item below must work in the Mac app. Grouped by area with its home in the new
app. (Derived from the full iOS feature inventory.)

### Library & game management → Library pane + File/Edit menus + context menu
- [ ] Game list with date sections, thumbnails (large/small toggle), first-comment preview
- [ ] Search/filter by name
- [ ] New Game (default 19×19, komi 7.5)
- [ ] Clone game (independent copy)
- [ ] Import SGF — file picker (multi-select), drag-and-drop, deep-link URL open
- [ ] Export / Share SGF (sharing service; game name as filename)
- [ ] Rename game; Delete game (with confirmation)
- [ ] Thumbnail auto-generation on board change (macOS `NSImage`/PNG path)
- [ ] SwiftData persistence; CloudKit sync (same container)

### Board rendering & display → reused SwiftUI board + View menu / Settings
- [ ] Board sizes 2×2 … 37×37 (limited by model); wood texture; star points; grid
- [ ] Stone styles (classic shader, flat); captured-stone counters; visits/s readout
- [ ] Move numbers: none / last-3 / last / all / marker ring
- [ ] Coordinates toggle; pass-area toggle; vertical-flip toggle

### Move input & game flow → board + Game menu + AudioModel
- [ ] Click to play; pending-move preview; overwrite confirmation on divergence
- [ ] Illegal-move detection with reason + play-anyway
- [ ] AI move generation (genmove) with overwrite confirmation
- [ ] Move/capture sound effects (3 variants each) + toggle

### Branching / editing → Game menu + context menu + branch border
- [ ] Create branch from any point; play in branch; branch border highlight
- [ ] Lock/unlock editing; commit branch (replace main); discard branch
- [ ] Branch navigation; commit/discard confirmations

### Analysis → reused overlay + Analysis menu + Inspector
- [ ] Live `kata-analyze` overlay: move circles, win%, score lead, visits
- [ ] Visits-weighted color coding; best-move highlight; hidden-move threshold
- [ ] Ownership heatmap toggle; analysis style (classic/modern); analysis info level
- [ ] Analyze toggle (run/pause/clear); analysis-for-whom; wide-root-noise;
      max moves; interval
- [ ] Win-rate bar (with score-lead overlay) + toggle

### Opening book (9×9) → board/book toggle + reused book rendering
- [ ] Book lookup; move-badness coloring; book win%/score/visits; book view cycle;
      persistence; load/unload on board-size change

### Charts & comments → Inspector
- [ ] Score line chart, interactive (click to jump), current-position marker, autoscale
- [ ] Per-move comment editing; AI comment generation; tone (5 options); temperature;
      Apple-Intelligence toggle; fallback to natural comment

### Navigation → Navigate menu + arrows + toolbar + chart + Moves tab
- [ ] First / back-10 / back / forward / forward-10 / last
- [ ] Move list (NEW) with click-to-navigate

### Per-game configuration → Inspector "Info" + Edit sheet
- [ ] Rules: board size, ko, scoring, tax, multi-stone suicide, button, white handicap
      bonus, komi
- [ ] Analysis: for-whom, hidden visit ratio, wide-root-noise, max moves, interval
- [ ] AI: white advantage (playout doubling), Black/White AI profiles (human-SL),
      per-color time-per-move
- [ ] Comments: Apple-Intelligence toggle, tone, temperature
- [ ] SGF: raw text edit with rule extraction

### Global settings → Settings window (⌘,)
- [ ] All `@AppStorage` display/behavior toggles (board, analysis, sound, visits/s);
      View-menu mirroring; haptics dropped on Mac

### Models / backend → toolbar dropdown + Models window
- [ ] Built-in + downloadable nets (Official b18/b40, FD3, Lionffen b6c64/b24c64,
      9×9 finetuned, Rect15)
- [ ] Download (progress, cancel), delete, file sizes, ready/active state
- [ ] Backend per model (CoreML/NE vs MLX/GPU), max board size, autotuning Fast/Full,
      re-tune toggle
- [ ] Crash recovery (launch alert); engine launch/compile status

### Integrations → kept on macOS
- [ ] App Intents / Siri Shortcuts (Get Game Info, Get Latest Game, Game entity query)
- [ ] Developer mode (raw SGF editor)

## 9. Build Phasing

One spec; the build proceeds in verifiable slices. Each phase ends with a building,
reviewable app and zero new warnings.

- **Phase 0 — Extract `KataGoUICore`.** Move shared code from the iOS app into the new
  package; iOS/visionOS app imports it and **builds + behaves identically** (verify by
  build on all platforms + smoke test). The one risky refactor; do first.
- **Phase 1 — Skeleton.** New AppKit target; NSApp/AppDelegate, main menu,
  `NSWindowController` + `NSSplitViewController` (3 panes), `NSToolbar`; wire
  `GameSession` + built-in model; board via `NSHostingView`; basic move nav. *(Running
  vertical slice.)*
- **Phase 2 — Library.** `NSTableView` library (search, thumbnails, sections), CRUD,
  SGF import / drag-drop / URL open, context menus, SwiftData wiring.
- **Phase 3 — Analysis & board input.** Live overlay, win-rate bar, ownership,
  visits/s, Analyze toggle; click-to-play (+pending/overwrite/illegal); right-click +
  hover-preview; sounds.
- **Phase 4 — Inspector.** Chart, Comments (+`Commentator`), Moves list, Info (+config
  Edit sheet).
- **Phase 5 — Models & Settings.** Models window (download/backend/tuning), Settings
  window, engine status, crash-recovery alert.
- **Phase 6 — Branching, opening book, App Intents, full-screen, accessibility,
  final parity sweep.** Then **retire the SwiftUI macOS build** (existing target
  builds iOS/visionOS only).

## 10. Constraints & Decisions (summary)
- **D1** Shared module = single `KataGoUICore` package.
- **D2** Hybrid rendering — AppKit chrome, reused SwiftUI rendering via `NSHostingView`.
- **D3** Three-pane main window (library · board · inspector).
- **D4** Single main window; switch games in the sidebar; one engine.
- **D5** Model management in a dedicated window.
- Frozen SwiftData schema; shared CloudKit container.
- macOS 26+; MLX/GPU + 16 threads default.
- Haptics dropped on Mac; audio session configured for desktop.

## 11. Risks & Open Questions
- **Phase-0 extraction risk:** moving many files into a package can disturb the iOS
  build (target membership, resource bundles, `@Model` container registration). Mitigate
  by doing it first, in small steps, verifying the iOS app each step.
- **`NSHostingView` ↔ AppKit focus/first-responder interplay** for board input and
  keyboard navigation needs care (who owns key events: the hosting view or the window).
- **SwiftData in a Swift package** with CloudKit: confirm the model container and
  entitlements resolve identically from the package for both targets.
- **Observation bridge** ergonomics (`withObservationTracking` re-arm vs Combine) —
  pick one consistent pattern in Phase 1.
- **App Intents** registration from an AppKit target (vs the SwiftUI `App`) — confirm
  the provider is discovered.

## 12. Out of Scope
Multi-window/tabs; rewriting rendering in Core Graphics; engine/analysis feature
additions; SwiftData schema changes; visionOS/iOS UI changes beyond the Phase-0
extraction.
