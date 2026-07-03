# KataGo Anytime Watch — Design Spec

**Date:** 2026-07-04
**Status:** Approved (design review via 14-question grill, all decisions user-confirmed)
**Exploration:** Sonnet-agent workflow `wf_547bc5f5-295` (4 surveys, 3 candidate designs, 3 adversarial critiques, grill synthesis)

## Context

KataGo Anytime runs on iOS, macOS, visionOS, and (in progress) tvOS. The user wants an Apple Watch companion: when a host device activates analysis mode, the watch shows the board, the best candidate moves, and the score lead; the wearer can navigate positions and play one of the best moves.

**Decisive platform fact:** WatchConnectivity pairs Apple Watch ↔ iPhone *only*. No API path exists from watchOS to iPad, Mac, or Apple TV (no Multipeer, no Bonjour peer discovery, no pairing). Reaching non-iPhone hosts requires a cloud relay (CloudKit push: seconds-to-minute latency, no SLA) — a different system, not a bigger version of this one.

**Decision: iPhone-only host for v1.** The watch mirrors an analysis session on its paired iPhone over WatchConnectivity, with sub-2-second freshness while both devices are awake. Mac/TV/iPad hosting is out of scope; a future cloud relay would be a separate project with its own design (its critique-identified flaw — play commands unbound to the position they were computed against — must be solved there, not inherited here).

## Releases

### v0 — Read-only live mirror (~1 week)

- **Live mirror:** board, top candidate moves, root winrate + score lead, streamed from the paired iPhone while analysis runs. Target freshness < 2 s when both apps are active; visible staleness state otherwise.
- **Navigation = local peek:** Digital Crown scrubs a watch-local ring buffer of the last ~50 positions (one detent = one move, redundant ‹ › chevrons). Zero host mutation. A "N moves behind live" pill shows when scrubbed back; snap back to live via the pill or scrubbing to the end.
- **Disconnected/stale:** the last snapshot is cached and shown with a prominent staleness badge ("stale — 4 min ago"). Never a blank screen (also App Review-friendly).
- **Complication:** one Smart Stack widget/complication showing the live score lead (e.g. "B+4.5", colored by leader), fed from the same snapshot stream. Best-effort refresh within WidgetKit budgets.
- **Follower only:** the watch never starts/stops analysis on the host.
- **Board rendering:** dot-only at every size including 19×19 (~8.4 pt/cell at 45 mm) — stones as filled circles, last move as a ring outline, top-3 candidates as rank-colored dots. No text on the grid, no zoom/pan, no tap-on-board, ever. Move detail lives in the Moves page, not on the board.

### v1.1 — Write path (separately scoped follow-up)

- **Prerequisite:** fix the sticky-maxVisits bug first (every analysis re-arm resets maxVisits to unbounded at 3 call sites) — watch-driven navigation multiplies exposure.
- **Shared cursor:** Crown scrubbing upgrades from local peek to driving the host board (`GobanState.go(to:)` replaying undo/play), debounced.
- **Play a candidate:** tap-to-play from the top-3 candidate carousel, under a **hard-block gate**:
  - Play is enabled only when the host reports: analysis session live, human's turn, plain unlocked live-mainline state (not editing, no active branch), no pending command.
  - Any violation or position change before the command lands → visible rejection on the watch, never silent. (Matches the app's existing validate-then-reject philosophy; `kata-check-move` validates against the *current* board only, so the gate carries the bound move number.)
  - When the side to move is AI-controlled, the carousel is replaced by an "AI is playing" state — no Play affordance, no genmove race.

## Architecture

### Targets & packages

| Piece | Where | Notes |
|---|---|---|
| `WatchSnapshot` payload + peek buffer | `KataGoGameStore` package (new files) | Already pure-Swift, engine-free, bridge-free (what the widget links). Add watchOS to `platforms:` in Package.swift. |
| Watch board view | Watch app, extending the `WidgetBoardView` pattern | Grid + stones from vertex strings, plus candidate dots + last-move ring. No engine, no KataGoUICore. |
| `WatchSessionRelay` (host side) | iOS app target (`KataGo iOS/`) | WCSession wrapper + snapshot builder. iOS-only; other platforms untouched. |
| Watch app "KataGo Anytime Watch" | New watchOS 26+ app target, bundled with the iOS app | Added via the `xcodeproj` Ruby gem (no synchronized groups) — the tvOS target is the template. New scheme. |
| Complication | New watch WidgetKit extension target | Reads the latest snapshot via the watch-local App Group (App Groups do not span devices; this one is watch-internal). |

The watch never links `KataGoUICore` (it pulls `CKataGoBridge`/the C++ engine). No SwiftData/CloudKit involvement — the frozen `@Model` schema is untouched.

### Data flow (v0)

1. `GameSession` already parses `kata-analyze` into `@Observable` state: `analysis` (per-point `AnalysisInfo`: visits/winrate/scoreLead/pv), `rootWinrate`, `rootScore`, `stones`, `board`, `player`; analysis mode is `GobanState.analysisStatus` (.run/.pause/.clear).
2. `WatchSessionRelay` observes that state (candidates via `Analysis.candidateMoves(width:height:limit:)`, PV from `analysis.info[point].pv`) and builds a `WatchSnapshot`:
   `{v, gameID, moveNumber, toMove, boardW/H, blackStones, whiteStones, lastMove, analysisStatus, rootWinrateBlack, rootScoreLeadBlack, candidates[≤10]{vertex, winrate, scoreLead, visits, pv≤6}, hostTimestamp}` — ~2 KB for 19×19 + 10 candidates.
3. Transport: `updateApplicationContext` (latest-wins, no reachability needed) coalesced to ≥ 500 ms between sends (matching `config.analysisInterval`), plus an immediate send on position/status change. `sendMessage` is reserved for v1.1 commands (reachable-only, reply handlers).
4. Watch app decodes, renders, appends distinct move numbers to the peek ring buffer, persists the latest snapshot for the stale view, and pokes `WidgetCenter` for the complication.

Winrate/scoreLead perspective: `AnalysisLineParser` already flips to Black's perspective when next color is black — the snapshot carries Black-perspective values and the watch renders "B+/W+" from sign, same as the host UI.

### Watch UI (v0)

Vertical TabView, two pages:
- **Page 1 — Board:** board ≈ 70% of height; thin bottom strip = two-tone winrate bar + large monospace score lead. Crown scrubs the peek buffer here. Stale badge overlays when applicable.
- **Page 2 — Moves:** top-3 candidate cards (coordinate + winrate Δ + score-lead Δ + color chip matching its board dot). Read-only in v0; tap-to-play arrives in v1.1.

Haptics via `WKInterfaceDevice.play` on live-move arrival and (v1.1) play confirmation/rejection.

### Failure modes

| Situation | Behavior |
|---|---|
| Phone unreachable / locked / analysis off | Cached last snapshot + staleness badge; complication shows last value with stale styling |
| Analysis paused (.pause/.clear) | Board keeps mirroring host position changes; candidates/winrate section shows "analysis off" |
| Watch app cold-launch, no session ever | Friendly empty state ("Start analysis on your iPhone") |
| v1.1: Play rejected (gate/position moved) | Visible rejection with reason; never silent |

## Testing & verification

- Unit tests (existing iOS-sim test target): `WatchSnapshot` encode/decode + size bound, snapshot builder from synthetic analysis state, peek-buffer semantics, staleness computation, v1.1 gate state machine.
- Real-hardware pair-testing (user has a physical Apple Watch): WCSession timing/reachability, Crown feel/debounce, 19×19 legibility, complication refresh. There is no usable Simulator story for WCSession.
- End-to-end check: run analysis on iPhone → watch shows live board/candidates/score < 2 s; lock phone → stale badge appears; reopen → recovers.

## Out of scope

- Mac / Apple TV / iPad as hosts (future cloud-relay project).
- Ownership overlay, PV playback on the board, trend chart page (v1.1+ candidates).
- Remote start/stop of analysis from the watch.
- Zoom/pan board inspection; tap-on-board input.
- Multi-host conflict handling (moot: the watch follows exactly its paired iPhone).

## Open items for the implementation plan

- Exact bundle IDs / target naming (`…tw.watchkitapp` family) and scheme name.
- Complication families for v1 (accessoryInline / accessoryCircular / accessoryRectangular) and refresh strategy under WidgetKit budgets.
- Whether the peek buffer stores full snapshots (~100 KB for 50) or board-diffs (memory is comfortable either way; prefer simple full snapshots first).
- pbxproj wiring details per the xcodeproj-gem recipe used for tvOS.
