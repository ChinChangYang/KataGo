# The board never waits for the engine — implementation record

Date: 2026-08-23
Status: Implemented (stage 1). Device QA pending on macOS, visionOS and tvOS.

**Spec:** `docs/superpowers/specs/2026-08-22-board-never-waits-for-the-engine.md`
(design + the 13 numbered decisions).
**Decision record:** `docs/adr/0008-the-board-never-waits-for-the-engine.md`.
**Vocabulary:** `CONTEXT.md` § Engine.

This is a record of what was built, not a plan to build it. Branch
`board-never-waits`, off `ios-dev` at `f4a21bfc2`. Ten commits, C0–C9, each
reviewed and each with its build/test gate green before the next began. The
per-commit briefs, reports and review diffs live in
`.superpowers/sdd/address-the-following-feedback-moonlit-pike/`.

## The commit sequence

**C0 — `87d57af87` `docs(engine): the board never waits for the engine — spec and glossary`.**
Wrote the spec from the grilled design: the rule, record-owned display, the
move-by-move feed, the in-sync/record-changed split, the status line, the scope
split between stage 1 and stage 2 (engine-free *play* via a Swift SGF writer),
the 13 decisions, a Preserved/Changed table per platform, and the open risks.
Added the `## Engine` section to `CONTEXT.md` — Record position, Engine
position, Feed, In sync, Engine availability — and reworded the existing
**Compile** entry away from "the launch screen".

**C1 — `afa6074a3` `feat(gorules): SgfReplay yields the whole record position`.**
Gave `GoRulesKit.SgfReplay` everything the board needs: capture counts, the
last-three-move digits (mirroring `Board::printBoard` over the `moveHistory`
that `Search::makeMove` clears on a colour repeat), `refusedIndices` with
`anomalyIndex` as its minimum, `acceptedMoveCount(upTo:)`,
`trailingPassCount(at:)`, engine-parity `toMove`, and a value initialiser taking
setup stones plus a move list. Added `SgfHelper.placements()` over the C++
`Sgf::getPlacements` so the replay can be built from the engine's own parse, and
made `KataGoUICore` depend on `GoRulesKit` (a one-way edge — GoRulesKit stays
bridge-free for the watch and the Messages extension). 20 new package tests; the
iOS differential suite gained four raw-import fixtures and a C++-side
construction comparison.

**C2 — `4d3a9c660` `refactor(session): the board shows the record position, never showboard`.**
Introduced `RecordPosition`, `RecordPositionKey`, `RecordPositionProjector`
(the only writer of the board's stones), `RecordStoneCache` (one writer
replacing three copies, assigning only on real change to stop CloudKit churn)
and the `recordPositionSync` driver. `maybeCollectBoard` became
`maybeCollectSync` — the `= MoveNum` ack and the `Next player` line, nothing
else — plus a DEBUG-only divergence log that never mutates. `Stones.isReady`
flipped to default `false` and gained `positionGeneration`, which now drives
haptics. All four hosts wired. Two fix rounds: a Swift 6 isolation slip in a
nested test struct, then a redundant per-move C++ parse and a missing
width/height guard that let an unparseable record shrink the board.

**C3 — `45ef59861` `feat(session): feed the engine move by move; loadsgf retired`.**
Added `EngineFeed` (opening bundle, forward `play`s, `undo` counts, setup
command), `GtpCommandBuilder.setupStonesCommand`
(`set_free_handicap` for all-Black setup, else `set_position`) and
`RecordReplayBuilder`. Rewrote `loadGame` with no tip reset, no `maybeLoadSgf`
and no undo loop; made navigation and auto-play refusal-aware; added
`GobanState.handleTurnChange` (shared by `BoardView` and visionOS) and the
`Board.sync` accessibility element with
`PortraitUITestCase.waitForBoardInSync` replacing nine "Forward to End"
sentinels. `loadsgf` / `temp.sgf` are gone from the app; the Safari appexes keep
theirs. Two fix rounds: colour casing unified to lower case and two tests
corrected; then a real skew bug — two different predicates for "was this index
sent" — collapsed into one, and `autoPlayStep` pinned to a single index space.
Two pre-existing CloudKit-churn writes (`updateToLatestVersion`, `loadGame`'s
seven `config.*` rule assignments) were found and guarded here.

**C4 — `caa46e91e` `feat(session): engine availability is a state, commands wait for the handshake`.**
`EngineStatus.swift`: `EngineAvailability`, the observable `EngineStatus`, the
pure `EngineStatusText` (ADR 0007's caption hoisted to
`EngineLaunchStatus.compileCaption` so no surface can spell it differently) and
`EngineExitDisposition`. `MessageList.isAcceptingCommands` flipped to `false` —
57 fixture sites across 27 test files moved to `.accepting()` factories.
`GameSession` gained `sendLifecycleCommand`, a bounded `handshake`,
`beginEngineSession`/`endEngineSession`, and a timed
`getMessageLine(timeoutSeconds:)` on both transports. `EngineStatusView` and
`UnreadableRecordView` written. One fix round: an expected teardown was being
reported as a failure (ordering bug — `stopRequested` was raised before the
classifier read it), and the 120 s restart bound was not real because a
`CheckedContinuation` never observes cancellation.

**C5 — `27d2d12fa` `feat(ios): the board never waits for the engine`.**
`AppEngineController` (a port of `VisionEngineController`, per decision 12) took
over the iOS engine lifecycle; `ModelRunnerView` stopped being a switch and
became the board plus a picker *sheet*; `ContentView` lost `isInitialized` and
`LoadingView.swift` was deleted. `RecoveryDecision` grew four outcomes with
DEBUG checked before the sentinel; Settings gained "Change model" and lost the
quit-to-picker dialog; `GobanView`'s "Too large board size" screen became the
inline *Held* line, which also shuts the command gate. Two fix rounds: nine UI
failures root-caused to stale test proxies (a "Lock" button that was never a
sound proxy for "the board is up", a *Launching* state too brief to observe on a
warm cache, and a GIF seed losing the recency race — moved into `App.init()`);
then three review Importants — a restart getting 120 s where a boot gets 660 s,
two teardown waits that could not be bounded, and a Held board whose previous
search was never stopped.

**C6 — `9ecd95e99` `feat(mac): the board and inspector never wait for the helper`.**
Deleted `BoardReadiness` and `EngineLaunchStatusView`; the board and all three
inspector tabs now mount whenever a game is selected. `seedInitialGame()` runs
in `MainWindowController.init`, before the recovery decision, so the board is up
even if the engine never starts. Added the availability observer,
`applyHeldStatus()` and `resyncEngineToRecord()`, and hoisted the shared
`EngineHeldRule`. `MacBoardInteractionLayer` stands aside while the status line
carries a button — otherwise Retry would have shipped visible and unclickable.
One fix round: a snapshot that went stale by construction, a Mac test that
re-implemented the loop it was testing, and — the important one — a handshake
that told a Held engine `rectangular_boardsize 37 37`, fixed by dropping
`sendInitialCommands` on macOS in favour of the feed (pinned by
`EngineFeedInitialCommandsTests`).

**C7 — `b58063ccf` `feat(vision): the goban stays up through boot and every restart`.**
`VisionGameShell.phase` stopped gating the volume; `VisionEngineChrome` became
the pure rule for what is shown and what may send. `.boardTooLarge` was deleted
in favour of Held drawn over the goban, and `.unsupportedBoard` stayed the one
true gate. Boot order became mount → ready → handshake → Held → resync; a
crashed engine now reports Failed with Retry; navigation dropped its
`stones.isReady` term so L1/R1 keep stepping through a restart. The shared seam
`resyncEngineAfterHandshake(player:)` gained the turn-park macOS had been doing
locally, and the iOS `EngineHeldRule` duplicate was folded in. One fix round: a
Critical — Retry after a failed *boot* brought up an engine nobody was reading —
plus the restart budget (a Max Board Size change misses the Core ML cache by
construction) and the hoisting of `EngineRestartRules` so the lifecycle could be
tested at all.

**C8 — `14b1e6f69` `feat(tv): the library mounts before the engine`.**
The tvOS `TabView` became unconditional and `TVRootView.isReady` and
`TVLoadingView` were deleted; `TVEngineController` adopted the visionOS shape
(shared restart rules, 660 s budget, exit classification, Held). Because tvOS
parks its selection at nil on purpose, the controller remembers the mounted
board itself (`noteBoardMounted`/`noteBoardDismissed`). The review and play
screens' `boardFits` fallback screens became a rendered board with a one-line
`EngineStatusView(.tvLine)`; the "to play" row stopped defaulting to White.
`EngineLoadingView` was deleted — no platform has a loading screen left. Two fix
rounds: `TVSelfPlayScreen` was registering no board (so an oversized self-play
seed was reachable and silent), and one `TVAutoPlayPolicy.tick` caller was
missed by the deliberately non-defaulted new argument.

**C9 — this commit.** ADR 0008; the `CLAUDE.md` Key Swift Files, Communication
Pattern, GTP Commands and visionOS entries; `README.md` (iOS launch, the Engine
settings section, macOS, visionOS, tvOS); the `verify` skill's launch recipe;
`CONTEXT.md`'s Held wording; the stale comments in `GameSplitView`,
`DeepLinkRouter`, `EngineCoreMLBridge`, `GameSession.initialize`, the
`GoRulesKit` product comment in `Package.swift`, and the tvOS auto-play QA
recipe; and this record.

## Verification that was run

Per commit, by the controller (implementers never ran `xcodebuild` — the
DerivedData lock produces spurious `TEST FAILED`, and two concurrent
invocations are never allowed):

- All five schemes build one at a time, judged by grepping
  `BUILD SUCCEEDED`/`BUILD FAILED` rather than by the exit code: `KataGo Anytime`,
  `KataGo Anytime Mac` (compile-checked with `CODE_SIGNING_ALLOWED=NO` — the
  login keychain currently has no valid codesigning identity),
  `KataGo Anytime Vision`, `KataGo Anytime TV`, `KataGo Anytime Watch`.
- `cd "ios/KataGo iOS/KataGoUICore" && swift test --filter GoRulesKitTests` —
  52 tests before C1, **72** from C1 onward, green at every commit. SwiftPM
  tests never run under `xcodebuild`, so this is a separate command.
- The iOS unit bundle on `iPhone 17`, green at every commit and at every fix
  round: 1671 after C2, 1718 after C3, 1778 after C4, 1805 after C5, 1819 after
  C6, 1832 after C7, and **1832** after C8 — which removed four tests that had
  become verbatim duplicates of the shared-rule suites and added four.
- `KataGo Anytime MacTests` from C6 on: 99 → **100**.
- The full UI plan (`-testPlan FullTestPlan`) at C5, the commit that rewrote the
  iOS root: 1795 unit + 34 UI green after fix round 1, and 1805 unit + 34 UI
  green after fix round 2. UI smoke suites at C3 (`GlobalSettingsMenuUITests`)
  and C4 (`BoardAccessibilityUITests`).
- `SwiftExplicitPrecompiledModules` trashed after commits that changed a
  default argument or moved a static, per the stale-default-args rule.
- Every diff scanned for CJK; every commit English-only.

Still outstanding, and recorded as such in ADR 0008: device QA on macOS,
visionOS and tvOS. None of those three targets is in any test bundle, so their
boot / restart / Held choreography is pinned only by the pure rules the iOS
bundle can reach (`EngineHeldRule`, `EngineRestartRules`, `EngineStatusText`,
`EngineExitDisposition`, `VisionEngineChrome`, `TVAutoPlayPolicy`) plus the
manual recipes in the C6, C7 and C8 reports. The iOS engine-parity check — the
DEBUG divergence log staying silent across `SampleGames`, and `showboard` ASCII
compared with the rendered board at several indices — is also a device/simulator
exercise rather than a test.
