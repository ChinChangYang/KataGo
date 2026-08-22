# The board never waits for the engine

Date: 2026-08-22
Status: Approved (design)

## Context

Tester feedback: *"Load KataGo backend/model in the background. The app can
show stones and board when a model isn't loaded."*

Today every engine-hosting platform replaces the board with a loading screen
until the KataGo engine has loaded **both** neural nets (`gtp.cpp:2068` loads
main + human-SL before the command loop at `:2130` reads anything). On a cold
launch that is a multi-minute Core ML compile; on a warm launch it is still
seconds. The board itself is populated only from the engine's `showboard`
ASCII (`GameSession.maybeCollectBoard`), so nothing can be drawn before the
engine answers — even though the game record (SGF) already holds the whole
position, and the watch already renders it engine-free through
`GoRulesKit.SgfReplay`.

Gates per platform: iOS `ContentView.isInitialized` (`ContentView.swift:31-125`,
flipped at `:182`); macOS `BoardReadiness.isEngineReady`
(`MacBoardHostView.swift:61`, flipped at `MainWindowController.swift:1182` /
`:1248`); visionOS `VisionGameShell.phase` (`VisionRootView.swift:53-60`);
tvOS `TVRootView.isReady` (`TVRootView.swift:123-333` — the *whole* TabView).

## Design

### Rule

The board never waits for the engine, on iOS, macOS, visionOS and tvOS.
Engine availability is a *state* shown inline where analysis would appear —
never a screen that replaces the board — through first launch, every restart
(model/backend/Max Board Size/crash), failure, and "no model chosen" (iOS). A
deleted chosen net falls back to the built-in net and the status says so.

### Display — record-owned, forever

The board always shows the **record position**: the position at the game's
current index, replayed from the record's SGF by `GoRulesKit.SgfReplay`
(whole game, every index). `showboard` ASCII never populates stones again.
Replay stays tolerant — exactly KataGo's `play` legality
(`boardhistory.cpp:887-915`: only occupied, off-board and single-stone
suicide are refused; ko/superko ignored, multi-stone suicide allowed, either
colour may move). Rules-strict legality for *new* moves is **stage 2**.

### Feed — move by move, never `loadsgf`

Open/switch: `boardsize` / `clear_board` / rules bundle / `komi` →
`set_free_handicap` or `set_position` for AB/AW → one `play` per recorded
move up to the displayed index → `showboard` as the sync ack. Forward
navigation keeps playing, backward keeps `undo`ing. A move the replay refused
is never sent, so engine and display skip it identically; undo counts
subtract refusals. `loadsgf` / `temp.sgf` / `maybeLoadSgf` retired from
`GameSession` (the Safari appexes keep their own `loadsgf`). No C++ engine
change.

### In sync

The engine has acknowledged the record position (`showboard` `= MoveNum`
ack, `showBoardCount == 0`, `stones.isReady == true`). Only in-sync
positions collect analysis, accept stone taps (stage 1), step auto-play,
continue tvOS replay, persist per-index analysis. **Record position
changed** drives immediately and engine-free: haptics/sound, the per-index
stone cache (`blackStones`/`whiteStones`) the widget reads, widget reload,
book sync, macOS draft `noteChanged`. Latest selection wins during a launch.
Analysis already on re-arms itself via the turn change
(`BoardView.onChange(of: player.nextColorForPlayCommand)`) — pinned with a
test.

### Status line

- *Absent* — "No model chosen — Choose".
- *Launching* — "Loading engine…" + "Compiling Core ML model…" only from a
  genuine compile, per ADR 0007.
- *Ready* — nothing.
- *Failed* — reason + Retry / Choose model.
- *Held* — board larger than the engine's Max Board Size (see decisions).

macOS keeps "Loading engine…" without the compile caption (no helper→app
channel; deferred as in ADR 0007).

### Scope

**Stage 1 (this plan).** View + navigation + game switching engine-free;
record-owned display; move-by-move feed; inline status; all four
engine-hosting platforms (iOS, macOS, visionOS, tvOS); iOS board tree mounts
with no model selected.

**Stage 2 (separate).** Engine-free play via a Swift SGF writer.

**Out of scope.** watchOS is unaffected — it already renders engine-free and
is only rebuilt to confirm it still compiles. The Safari extensions keep
their own `loadsgf`-based, engine-free-of-this-change flow.

Deliverables include ADR 0008 and a new "Engine" section in `CONTEXT.md`.

## Decisions made while designing (visible for approval)

1. **Defaults are "not ready".** `GameSession` starts *Launching* / not
   accepting commands; `Stones.isReady` starts `false` (today `true`,
   `KataGoModel.swift:145`). Only a completed handshake flips them.
   Otherwise `BoardView.onAppear` would `showboard` into the pre-loop buffer
   and the tap gate would open with no engine (a tap then runs
   `clearData(after:)` — destructive).
2. **Lifecycle commands bypass the gate.** `version`, `stop`, `quit` go
   through `engine.sendCommand` directly; everything else through
   `MessageList.appendAndSend`, which drops (and logs
   `> (dropped — engine unavailable) …`) while not accepting.
   `sendShowBoardCommand` counts only showboards actually sent.
3. **One SGF parser for display, feed and navigation.** The replay is built
   from the C++ `SgfHelper`/`SgfOperations` move list + placements (the
   engine's own `CompactSgf`, which navigation, move numbers and comments
   already use), via a new
   `SgfReplay.init(width:height:setupBlack:setupWhite:moves:)`.
   `SgfHeaderScan` stays for bridge-free targets (watch). A differential
   test pins both constructions equal on every fixture. (Reason: retiring
   the `loadsgf`→`printsgf` echo removes the only normalisation of raw
   imported SGF; two parsers on one index space would desync.)
4. **Side to move** = opposite of the last *accepted* move (engine parity
   after a refusal); at index 0: White after `set_free_handicap` (all-Black
   setup, White to move), else Black. `player.nextColorForPlayCommand` stays
   engine-sourced from the `showboard` `Next player` line so the turn edge
   remains asynchronous and real.
5. **Post-move order becomes `play` → `printsgf` → `showboard`** (today
   `play` → `showboard` → `printsgf`), so the record — and therefore the
   stone — updates before the in-sync ack. Stage 2's record write makes this
   moot.
6. **No numeric `MoveNum` verification.** `B;B` resets the engine's
   `BoardHistory` (`search.cpp:323-327`), so `MoveNum` cannot be compared to
   the index. Prefix ack only (as today); DEBUG-only ASCII divergence log,
   never a mutation.
7. **Board larger than Max Board Size is a *Held* status, not a screen.**
   The record position still renders; analysis/taps are off; the line says
   "Board larger than Max Board Size N — Settings". Replaces iOS
   `GobanView`'s `ContentUnavailableView`, visionOS `.boardTooLarge`, tvOS
   `boardFits` fallbacks. visionOS `.unsupportedBoard` (outside 2…37
   geometry) stays a true gate.
8. **Open-at-tip rules.** `loadGame` honours the saved `currentIndex`
   everywhere (iOS launch now goes through `loadGame` — today iOS launch
   opens at the tip only because the `loadsgf` echo reset the index; game
   *switch* already honoured the saved index). tvOS Play keeps
   `currentIndex = tip` as a product rule (no overwrite dialog on tvOS;
   comment rewritten). visionOS drops its pre-set-to-tip (it was an engine
   recipe; visionOS renders the overwrite dialog).
9. **Picker policy.** DEBUG: the board mounts in *Absent* and the
   model-picker *sheet* auto-presents (today's DEBUG rule, now as a sheet;
   the nine UI suites keep tapping `ModelDetailView.downloadPlayButton`).
   Release: a persisted title auto-restores; no title → launch the built-in
   net (Absent is never shown on Release); a persisted title whose file is
   gone → built-in + note "⟨title⟩ was removed — using the built-in
   network"; a surviving crash sentinel → *Failed* "The last launch did not
   finish loading ⟨title⟩" + Choose model.
10. **Picker reachable with a live engine** (new on iOS): the picker's own
    `onOpenURL` is deleted (`GameSplitView` owns imports); the Core ML
    routing probe and "Clear Cache" are disabled unless availability is
    *Absent*/*Failed*; Play on the running model restarts it; the backend
    sheet's "takes effect on the next load" stays true.
11. **Watch keeps refusing anomalous records**
    (`isReadable = anomalyIndex == nil`); the phone skips refused moves.
    Recorded as an ADR consequence, not changed here.
12. **iOS engine controller is a port, not an extraction.**
    `AppEngineController` (iOS target) ports `VisionEngineController`'s
    quit → run-loop-exit → thread-exit → respawn → handshake discipline.
    Unifying the three in-process controllers is a follow-up, not this
    change.
13. **Game Settings board-size editor** is disabled unless in sync
    (stage 1); the feed takes width/height from the SGF `SZ`, never from
    `Config`.

## Glossary

Added to `CONTEXT.md` as a new "Engine" section:

- **Record position** — the board at the game's current index, replayed
  from the game record. The only thing the board ever shows.
- **Engine position** — the position the engine has been fed. Never
  displayed; it exists so analysis has something to analyse.
- **Feed** — telling the engine the record's moves one at a time. A move
  the engine would refuse is skipped, exactly as the replay skipped it.
- **In sync** — the engine has acknowledged the record position. Analysis
  is collected, and stones may be played, only while in sync.
- **Engine availability** — *Absent* (no model chosen), *Launching* (model
  loading, possibly compiling), *Ready*, *Failed* (with a reason and an
  action), *Held* (the engine cannot take this board's size). A state the
  board displays; never a screen that replaces it.

The existing **Compile** entry is reworded to point at the new vocabulary:
"…the only reason the launch screen has anything to say beyond 'Loading'."
becomes "…the only reason the engine status has anything to say beyond
'Loading'."

## Preserved / Changed

User-visible behaviour, by platform. Derived from the plan's per-platform
commits (C1–C4 shared session work, C5 iOS, C6 macOS, C7 visionOS, C8 tvOS)
and its Open risks.

### iOS

| | Behaviour |
|---|---|
| Preserved | The last game and its stones are what a returning user sees; forward/back/end navigation; Developer Mode command entry; live analysis on in-sync positions; the "Lock" affordance persists across the flow; the model picker's DEBUG auto-present habit (now a sheet, not a full-screen block). |
| Changed | The board (and the rest of `GameSplitView`) mounts immediately, including with no model chosen — no more full-screen `ContentView.isInitialized` block or `LoadingView`. Engine state shows as an inline line/overlay (Absent / Launching / compiling / Failed / Held) instead of a screen swap. Navigation, stone rendering and move numbers work while the engine is still loading; only analysis, stone taps and the board-size editor wait for in-sync. A board larger than Max Board Size renders with a *Held* line instead of `GobanView`'s `ContentUnavailableView`. Settings → "Change model" is reachable, and Play restarts the engine, even while a model is already running (previously the picker's own deep-link handling and cache tools were reachable in more states than intended). A deleted chosen net falls back to the built-in net with a note; a crash mid-load on the previous launch shows Failed with Choose model. Developer Mode commands typed while the engine is not accepting are dropped (logged), not queued. |

### macOS

| | Behaviour |
|---|---|
| Preserved | Board layout and the inspector's tabs; a widget deep link opens the target game. |
| Changed | The board and inspector mount whenever a game is selected, not gated on `BoardReadiness.isEngineReady` — no more `EngineLaunchStatusView` block. A cold-launch deep link opens the game engine-free and feeds it once the `katago-engine` subprocess handshakes. Killing the subprocess now surfaces a Failed status with Retry (previously an readiness gate with no equivalent recovery path); relaunching resumes analysis. The compile caption is still absent on macOS (no helper→app channel), so "Loading engine…" carries no further detail. |

### visionOS

| | Behaviour |
|---|---|
| Preserved | The `.unsupportedBoard` gate (outside 2…37 geometry) stays a true full gate; the model-choosing ornament UI; L1/R1/L2/R2 navigation. |
| Changed | The board is visible during boot (`.booting` now shows the status ornament over an already-rendered board rather than withholding the board) and during every restart (Max Board Size change, model activation) instead of being hidden by `VisionGameShell.phase`. `.boardTooLarge` becomes a *Held* status line with the board still rendered, replacing its earlier text-only screen. Command-issuing ornaments disable while not ready, but board navigation keeps working through a restart. A failed restart now offers Retry (previously the failure path had no in-place recovery). |

### tvOS

| | Behaviour |
|---|---|
| Preserved | Replay's move-by-move pacing once running; New Game's board-size flow. |
| Changed | The library `TabView` is unconditional and mounts before the engine is ready — `TVRootView.isReady` now only arms the background read loop, and the root `TVLoadingView` is retired. `TVReviewScreen`/`TVPlayScreen`'s `boardFits` fallback screens become a rendered board with a one-line `EngineStatusView(.tvLine)` *Held* status. Side panels (analysis/winrate row) show the one-line status instead of being blocked outright when not ready. Starting a new game no longer waits on the engine phase — Start Game is engine-free and the feed runs once the engine is Ready. Replay now explicitly holds (rather than advancing on stale state) while the engine is unavailable. Settings' status strings are drawn from the same `EngineStatusText` vocabulary used elsewhere, so Failed reasons read consistently with the other platforms. |

### watchOS and Safari extensions

Unaffected. The watch already renders engine-free via `GoRulesKit.SgfReplay`
and is rebuilt only to confirm it still compiles against the shared package
changes. The Safari extension appexes keep their own `loadsgf`-based flow,
untouched by this plan.

## Open risks

- Refusal parity between the new `GoRulesKit` tolerant replay and the C++
  engine's `play` legality is predicted, not yet observed in production;
  mitigated by differential tests and a DEBUG-only divergence log (no
  self-heal).
- `set_position` starts with Black to move; a mixed AB/AW problem SGF with
  `PL[W]` at index 0 will analyse the wrong side. Documented as a known gap;
  stage 2 may pass the colour explicitly.
- The `MessageList` gate drops Developer-Mode commands typed while the
  engine is launching (logged, but not queued or replayed).
- macOS AppKit observer wiring is covered only by manual verification and
  the headless harnesses, not by an automated UI test suite.
- Feed speed for long games is bounded by N `play` round-trips (cheaper than
  today's N `undo` replays for a fresh load), but any UI test touching board
  sync must use the new `waitForBoardInSync` helper — the old
  existence-based sentinels no longer apply.
