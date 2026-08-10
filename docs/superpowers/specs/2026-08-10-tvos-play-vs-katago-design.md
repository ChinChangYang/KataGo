# Play a Game Against KataGo on Apple TV

**Date:** 2026-08-10
**Status:** Approved

Companion spec: `2026-08-10-tvos-narrated-autoplay-controller-design.md`
(items 1–4 of the same feedback round). That spec ships first; this one
reuses its last-move ghost anchor.

## Problem

Tester feedback (2026-08-10 TV round, item 5 of 5): the user wants to play a
game with KataGo on Apple TV, customizing board size, rules, KataGo rank
(human SL), and handicap when starting a new game.

Today tvOS is watch-only:

- `TVLibraryView` only browses iCloud-synced `GameRecord`s; its empty states
  tell the user to create games on other devices. The synced store is
  deliberately never written on tvOS (`autoCreatesGameOnEmptyLibrary =
  false`; review forces `isEditing = false` + `forcesBranchOnPlay = true` —
  the build-291 corruption guard against overwriting synced SGFs).
- `TVSelfPlayScreen` plays engine-vs-engine into a disposable in-memory
  record (`TVSampleGameStore`), with human moves possible only while paused.
- The human-SL net is deliberately absent: `KataGoHelper.runGtpImpl`
  hardcodes `skipHumanNet = true` under `#if os(tvOS)` and strips every
  `humanSL*` cfg line (launching with those params and no human model aborts
  in `Setup::loadParams`). The net was skipped as the single biggest memory
  lever (~half the NN footprint); the Apple TV 4K (A12) ~2.1 GB budget was
  Phase-0-validated without it. `b18c384nbt-humanv0.bin.gz` is not in the TV
  target's Copy Bundle Resources.
- Handicap stones exist nowhere in the engine-backed apps: `Config` (frozen
  @Model) has no handicap field, `GameRecord.makeSgf` hardcodes `HA[0]`.
  Placement logic exists only in GoRulesKit (`GoGame.handicapPoints`, the
  iMessage `HA[n]AB[...]` codec); the engine and all SGF readers already
  honor AB setup stones.

Meanwhile the whole human-vs-AI machine is shared code already compiled into
the TV app: the #1209 rank ladder (`HumanSLModel`), per-rank visit budgets
(`GtpCommandBuilder`), ruleset presets (`NewGameRuleset` +
`ConfigEngineSync`), and the turn-observer gen-move loop (shared
`BoardView`'s `.onChange(of: player.nextColorForPlayCommand)` →
`maybeSendAsymmetricHumanAnalysisCommands` / `shouldGenMove`, keyed off
per-side `maxTime`: 0 = human, >0 = engine).

## Goal

From the TV library, start a customized game against KataGo at a certified
human-SL rank, play it with the game controller, and have the game sync to
the user's other devices.

## Decisions (from brainstorming)

1. **Bundle the human net** in the TV target. Shipping is gated on an
   on-device dual-net memory validation; the designed fallback if it fails
   is conditional loading via engine restart.
2. **Games persist to the synced CloudKit store** — a new record created on
   tvOS, the visionOS New Game pattern. Review of all other records stays
   locked; the read-only policy is narrowed, not removed.
3. **Handicap = classic stones**: 2–9 on star points via `HA[n]AB[...]` SGF,
   komi auto-set to 0.5, stones always to Black, White moves first.
4. **A dedicated `TVPlayScreen`** runs the standard turn-observer loop;
   `TVReviewScreen` and `TVSelfPlayScreen` invariants are untouched.
5. **Resume**: unfinished human-vs-AI records open in `TVPlayScreen` from
   the library — including games started on iPhone/iPad/Mac.

## Design

### Entry and the New Game form

`TVLibraryView` gains a "Play KataGo" lead card beside the "KataGo vs
KataGo" card, pushing a new `TVNewGameScreen` form:

- **Board size** — 9/13/19 quick picks plus custom width/height steppers
  2…cap, where cap is `engine.maxBoardLength` (the LAUNCHED NN buffer,
  never live settings). Sizes above the cap are disabled with a hint to
  Settings ▸ Max Board Size (the visionOS New Game pattern).
- **Ruleset** — the 11 `NewGameRuleset` presets (no Custom row; granular
  knobs stay an iOS/macOS feature). Komi is the preset's default.
- **KataGo rank** — `HumanSLModel.allProfiles`: AI, 9d…1d, 1k…25k, Pro
  years. Rank profiles use the certified #1209 ladder as-is.
- **Handicap** — 0 or 2–9. Choosing a handicap sets komi to 0.5. The picker
  is disabled when `GoGame.handicapPoints` defines no points for the chosen
  size (small or rectangular boards).
- **Your color** — Black/White, default Black. Handicap stones always go to
  Black regardless of who plays Black (picking White + handicap gives
  KataGo's Black the stones — legitimate give-handicap play).

Form UI obeys the house tvOS rules: no bare `.onTapGesture` (Select via the
focus engine / `TVSelectPressCatcher` path), `.bordered` pill floor, no new
focusable elements that steal `onMoveCommand` from adjacent controls.

### Record creation

A new shared SGF builder — `GameRecord.makeSgf(width:height:komi:
ruleString:handicap:)` or equivalent — emits `HA[n]` + `AB[...]` (points
from GoRulesKit's `GoGame.handicapPoints`) and White-to-play (`PL[W]`) when
handicap > 0. The engine loads such SGFs natively (`loadsgf`/`finalStones`
already honor AB; differential tests cover handicap 2/3). `Config` and
`GameRecord` schemas are untouched — handicap lives entirely in the SGF.

Creation runs the visionOS `startNewGame` recipe: `GameRecord.
createGameRecord(sgf:...)` with a **fresh** `Config` (never clone — the
seeded-continuation factory documents that trap): the KataGo side gets the
chosen rank profile (`ConfigEngineSync.setBlack/WhiteHumanProfile`
semantics) and `maxTime` = the standard 0.5 s AI default; the user's side
gets `maxTime = 0`. Insert into `SharedModelContainer.shared`'s main
context, save, set the one-shot `gobanState.unlockEditingOnReload = true`,
then the same gated `switchGame` path as boot (the `boardFits` gate runs
BEFORE any load — `NNEvaluator::evaluate` aborts the process on an
oversized board, so the gate is mandatory).

`autoCreatesGameOnEmptyLibrary` stays `false`.

### Human net on tvOS

- **Bridge:** `KataGoHelper.runGtpImpl` drops the `#if os(tvOS)` hardcode
  and honors the existing `includeHumanNet` parameter (the tvOS app passes
  true; the iOS Safari appex keeps false). `strippedHumanSLConfig` already
  keys off `skipHumanNet`, so cfg stripping stays in lockstep with the net
  automatically — the `Setup::loadParams` abort trap cannot re-open.
- **Bundling:** add `b18c384nbt-humanv0.bin.gz` (~100 MB) to the TV
  target's Copy Bundle Resources (pbxproj edit via the xcodeproj Ruby gem).
  `ci_scripts/ci_post_clone.sh` already downloads it; verify, don't assume.
- **Memory (the ship risk):** primary design loads both nets at every
  launch. Reference point: two b18-class nets are ~1.2 GB on iPad against
  tvOS's ~2.1 GB, but tvOS runs a different shape (single CoreML server
  thread `[100]`, batch 2, `.cpuAndGPU`). **Shipping is gated on on-device
  validation**: a full ranked game plus a review broadcast with dual nets
  resident, judged by vmmap "Physical footprint (peak)" with headroom.
  Fallback design if it fails: `TVEngineController.restartEngine` grows an
  include-human-net parameter and the app restarts the engine with the
  human net only around ranked play — the proven Max-Board-Size restart
  pattern (quit → park read loop → thread-exit wait → respawn →
  handshake; never two engines at once).
- **First launch:** the second net doubles CoreML convert/compile on a
  cache miss; the existing `TVLoadingView` engine-launch status surfaces
  it. `mlxNnMaxBatchSize` stays put (it is part of the compiled-model cache
  key).
- **Sticky params:** rank gen-moves arm `maxVisits 400/40`; every analyze
  request must flow through the `continuousAnalyzeCommands` /
  `fastContinuousAnalyzeCommands` bundles that embed the re-arm. The shared
  `GobanState.getRequestAnalysisCommands` site already does; the plan adds
  a checklist test that the tvOS broadcast/review probe paths re-arm too.
- With the net loaded, the `humanSL*` `kata-set-param` lines that today
  fail harmlessly as GTP `?` errors on tvOS start applying. For the "AI"
  profile this mirrors defaults (no behavior change); for rank profiles it
  is the feature.

### TVPlayScreen

A new screen owning a playable game, deliberately NOT sharing state
machinery with review (locked spectator) or self-play (broadcast protocol):

- **State:** `suppressesGenMove = false`, `forcesBranchOnPlay = false`,
  editing unlocked via the one-shot `unlockEditingOnReload`,
  `navigationContext.selectedGameRecord` set. Exit restores engine state
  through the same seams the other screens use (`restoreAnalysisForExit`
  pattern).
- **Move loop:** entirely existing shared machinery — `BoardView`'s
  `.onChange(of: player.nextColorForPlayCommand)` hook drives the
  asymmetric human-SL command bundles and gen-move for the side whose
  `maxTime > 0`. No new engine protocol.
- **Input:** the proven review stack — focusable board leaf, `isAiming`
  plain state, `GhostCursorModel` with the last-move anchor from the
  companion spec, `TVSelectPressCatcher` Select →
  `sendCheckMoveCommand` (legality + turn-order + single-flight guards
  included). D-pad aims; Select plays.
- **Controller mapping** (visionOS-aligned): Select/A = play at cursor,
  X = undo one move, L1 = undo (hold repeats), Y = pass, Menu = exit
  aiming / back. L2/R2 stay unbound on this screen (timeline navigation
  belongs to review). Undo semantics match visionOS: a single undo hands the turn to
  the engine, which replies — take-back is undo twice (hold). The legend
  (`TVControllerLegend`) gains the play-screen rows.
- **Panel:** reuses the review components (`TVPlayerRow` chips showing
  rank vs Human, winrate headline, score chart, info row) plus Pass and
  Undo buttons. Analysis overlays default OFF for a ranked game (play
  honestly); a panel toggle enables them (best-moves list only when on).
- **Game end:** two passes stop the gen-move loop (existing
  `passCount < 2` guard); a result overlay reuses the self-play
  result-text path (`RE[]` when present, anticipated score fallback). The
  record persists; no resign (parity with the other platforms).
- **Board-too-large:** the screen gates on `boardFits` against
  `engine.maxBoardLength` before loading, with the existing
  `tooLargeView`-style pointer to Settings, same as review.

### Resume

A pure KataGoUICore classifier — `isPlayable(record)`: the config encodes
human-vs-AI (exactly one side with `maxTime == 0`) AND the game is
unfinished (no `RE[]`, last two moves not both passes). Library cards for
playable records open `TVPlayScreen` (labeled Continue) instead of the
locked review; everything else reviews as today. Because the rule is
config-based, a human-vs-AI game started on iPhone can be continued on the
TV — the same deliberate-write narrowing as creation, applied to one more
record.

## Testing

- **Unit (KataGoUICore, `swift test` + iOS-host):** handicap SGF builder
  (points match `GoGame.handicapPoints`, HA/AB/PL and komi correctness,
  rejects sizes without star points); engine `loadsgf` round-trip via the
  existing differential-test pattern; `isPlayable` classification; form
  validation (size caps, handicap availability, color/handicap
  interaction); rank command bundles include the maxVisits re-arm on the
  tvOS paths.
- **Device gates (blocking):** dual-net memory validation on Apple TV 4K
  (A12) — full 19×19 ranked game plus review broadcast, vmmap physical
  footprint peak with headroom. If it fails, implement the conditional
  restart fallback before shipping.
- **Manual QA (Apple TV):** full ranked game at 19×19 and a handicap-5
  game (opening position correct, White moves first, komi 0.5); resume
  after app relaunch; continue an iPhone-started human-vs-AI game; sync
  round-trip visible on iPhone; first-launch double compile UX; thermal
  behavior during a long game; Siri-Remote-only play.

## Open items

- Dual-net memory on the A12 is the ship risk; the fallback is designed
  but only built if validation fails.
- `GoGame.handicapPoints` coverage for non-standard sizes decides where
  the handicap picker is enabled; verify its exact domain during
  implementation.
- Single-step undo-vs-AI (engine replies until you undo twice) is accepted
  as visionOS parity.
