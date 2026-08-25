# 0008 — The board never waits for the engine

Date: 2026-08-23
Status: Accepted

Supersedes the launch-screen wording of ADR 0007. Its caption rules survive
unchanged — the "Compiling Core ML model…" string is still reported only from a
genuine cache miss, still counted rather than flagged, and still makes no claim
about recurrence — but the surface it is reported *on* is no longer a screen
that replaces the board. It is now the second line of an inline engine status,
and `EngineLaunchStatus.compileCaption` is its single source
(`Bridge/EngineLaunchStatus.swift`, read by
`EngineStatusText.decide(availability:isCompiling:note:)`,
`Services/EngineStatus.swift:138`). ADR 0007's macOS consequence also survives
verbatim: the Mac helper is a subprocess with no status channel back to the app,
so macOS still shows "Loading engine…" and nothing more.

## Context

Tester feedback: *"Load KataGo backend/model in the background. The app can show
stones and board when a model isn't loaded."*

The engine cannot read a single byte of GTP until it has loaded **both** neural
nets. `GTPEngine` is constructed with the main and human-SL model files
(`cpp/command/gtp.cpp:2056-2067`), `setOrResetBoardSize` runs at `:2068`, and
only then does the command loop start reading standard input
(`while(getline(cin,line))`, `:2130`). On a cold launch that is a multi-minute
Core ML compile; on a warm launch it is still seconds.

Every engine-hosting platform answered that wait by replacing the board with a
screen. At the change's base commit `f4a21bfc2` the gates were: iOS
`ContentView.isInitialized` (a full-screen `LoadingView` until the handshake
returned); macOS `BoardReadiness.isEngineReady` (`MacBoardHostView.swift:61`,
flipped from `MainWindowController`, and gating the inspector's Chart / Moves /
Comments tabs as well); visionOS `VisionGameShell.phase` (`.booting` showed
`EngineLoadingView` instead of the goban); tvOS `TVRootView.isReady` — which
gated the *whole* `TabView`, so the library itself did not exist until the
engine did.

The deeper reason those gates were unavoidable: **stones came from the engine.**
`GameSession.maybeCollectBoard` parsed `showboard` ASCII into
`Stones.blackPoints`/`whitePoints`, so nothing could be drawn before the engine
answered — even though the game record's SGF already holds the whole position,
and the watch has rendered it engine-free through `GoRulesKit.SgfReplay` since
ADR 2026-08-04. Opening a game was a `loadsgf` of a temp file whose `printsgf`
echo was then read back, and navigation walked the engine backwards with `undo`.

The one guard that pointed the other way confirms the diagnosis rather than
contradicting it: `clearPendingOutput()` (`Bridge/KataGoEngineIO.swift:49`,
called from `GameSession` at `:199`) exists because a stale engine output buffer
could paint an **empty board** on re-entry. It is a guard about the engine being
the only source of stones. Once the record owns the display there is no such
flash to guard against, and the call survives only to give the handshake a clean
channel.

## Decision

**The board never waits for the engine. Engine availability is a state the
board displays, never a screen that replaces it.**

1. **Display is record-owned, forever.** The board always shows the *record
   position*: the position at the game's current index, replayed from the
   record's SGF by `GoRulesKit.SgfReplay` (`SgfReplay.swift:28`).
   `RecordPositionProjector` (`Session/RecordPosition.swift:123`) is the **only**
   writer of `Stones.blackPoints/whitePoints/moveOrder/*Captured` and
   `BoardSize.width/height`; `showboard` ASCII never populates a stone again.
   `maybeCollectBoard` is now `maybeCollectSync`
   (`Session/GameSession.swift:527`) and does exactly one thing: consume the
   `= MoveNum` acknowledgement and the `Next player` line. Replay stays tolerant
   — exactly KataGo's `play` legality (`BoardHistory::isLegalTolerant`,
   `cpp/game/boardhistory.cpp:887`): only occupied points, off-board points and
   single-stone suicide are refused; ko/superko are ignored and multi-stone
   suicide is allowed, either colour may move. Rules-strict legality for *new*
   moves is stage 2.

2. **One SGF parser for display, feed and navigation.** The replay is built from
   the C++ `CompactSgf` move list plus `SgfHelper.placements()`
   (`Bridge/SgfHelper.swift:179`) through the single constructor
   `RecordReplayBuilder.replay(from:)` (`Session/RecordReplayBuilder.swift:23`)
   and `SgfReplay.init(width:height:setupBlack:setupWhite:setupEmpty:moves:)`
   (`SgfReplay.swift:142`). `SgfHeaderScan` remains the bridge-free targets'
   parser (watch, widget); a differential test pins both constructions equal on
   every fixture. Retiring the `loadsgf`→`printsgf` echo removed the only
   normalisation raw imported SGF ever got, and two parsers sharing one index
   space would desync.

3. **The engine is fed move by move, never `loadsgf`.** Opening or switching a
   game emits `rectangular_boardsize W H` (from the SGF's `SZ`, never `Config`)
   → `clear_board` → the rules bundle → `komi` → `set_free_handicap` or
   `set_position` for AB/AW → one `play` per recorded move up to the displayed
   index → `showboard` as the sync acknowledgement
   (`EngineFeed.openingCommands`, `Session/EngineFeed.swift:34`). Forward
   navigation keeps playing (`forwardCommands`, `:107`), backward keeps
   `undo`ing (`undoCount`, `:124`). A move the replay refused is never sent, so
   engine and display skip the same indices, and undo counts subtract refusals.
   One formatter, `playArguments` (`:87`), serves both the opening feed and
   navigation so a move cannot be spelled two ways. Colours are lower case
   everywhere (`play b Q16`, `set_position b D16 w Q4`) — `tryParsePlayer`
   lower-cases its argument, so this is the engine's own spelling.
   `set_free_handicap` (`cpp/command/gtp.cpp:3221`) is used when every setup
   stone is Black, because it leaves White to move and applies the handicap
   bonus exactly as `loadsgf` did; it demands an empty board, which is why
   `clear_board` precedes it. Everything else uses `set_position` (`:2992`).
   `loadsgf`, `temp.sgf` and `maybeLoadSgf` are retired from `GameSession`; the
   two Safari extension appexes keep their own `loadsgf` flow, which this change
   does not touch. No C++ engine change was needed.

4. **"In sync" and "record changed" are two different events.** *In sync* means
   the engine acknowledged the record position (`showboard` `= MoveNum` ack,
   `showBoardCount == 0`, `Stones.isReady == true`, `Model/KataGoModel.swift:163`).
   Only in-sync positions collect analysis, accept stone taps, step auto-play,
   continue a tvOS replay and persist per-index analysis
   (`Analysis.collectedForKey`, `:241`). *Record position changed* drives
   immediately and engine-free: haptics and sound (via
   `Stones.positionGeneration`, `:168`, which `StoneView:240` triggers on), the
   per-index `blackStones`/`whiteStones` cache the widget reads
   (`RecordStoneCache.write`, `Session/RecordStoneCache.swift:41`, which
   refuses a key naming a different record), the widget reload latch,
   opening-book sync, and the macOS draft's `noteChanged`. One
   driver per host: `View.recordPositionSync(...)` on iOS/tvOS,
   `trackRecordPosition()` (`withObservationTracking`) on macOS, an explicit
   call on visionOS.

5. **Defaults are "not ready".** `GameSession` starts *Launching* with the
   command gate shut, and `Stones.isReady` starts `false` (it was `true`). Only
   a completed handshake flips them. Otherwise `BoardView.onAppear` would
   `showboard` into a pre-loop buffer and the tap gate would open with no
   engine, where a tap runs the destructive `clearData(after:)`.

6. **The command gate.** `MessageList.isAcceptingCommands`
   (`Model/KataGoModel.swift:583`) defaults to `false`; `appendAndSend` (`:618`)
   returns whether the command went out and logs
   `> (dropped — engine unavailable) …` when it did not. Lifecycle commands —
   `version`, `stop`, `quit` — bypass the gate through
   `GameSession.sendLifecycleCommand` (`Session/GameSession.swift:257`), because
   they are how the engine is torn down and must never be swallowed by the state
   they are trying to change. `sendShowBoardCommand` counts only showboards
   actually sent: an incremented-but-unsent counter would pin `showBoardCount > 0`
   forever and the board would never report in sync again.
   `maybeCollectSync`, `maybeResetPendingStatesOnError` and `maybeCollectAnalysis`
   (`:583`) are all gated on the same flag, so a dying engine's trailing output
   cannot claim sync or file analysis against a board it does not hold.

7. **Availability is a five-state value with one vocabulary.**
   `EngineAvailability` (`Services/EngineStatus.swift:20`) is *Absent* ("No model
   chosen — Choose"), *Launching* ("Loading engine…", plus ADR 0007's compile
   caption when a compile is genuinely running), *Ready* (nothing at all),
   *Failed* (a reason plus Retry / Choose model) and *Held*. Every string comes
   from the pure `EngineStatusText` (`:119`), including `tvLine`, which returns
   fixed short strings and never the raw failure reason. `EngineStatusView`
   (`Rendering/EngineStatusView.swift:18`) renders it in three styles —
   `.inline` (iOS/macOS), `.ornament` (visionOS), `.tvLine` (tvOS) — and is
   `EmptyView` when the engine is ready. It is read as an *optional*
   `@Environment(EngineStatus.self)`, where `nil` means ready.

8. **Held is a status, not a screen.** A board larger than the engine's launched
   Max Board Size renders normally and the line says "Board larger than Max Board
   Size N". `EngineHeldRule.decide` (`Services/EngineStatus.swift:204`) is the
   one rule, shared by all four hosts (`AppEngineController.applyHeldStatus`
   `KataGo iOS/App/AppEngineController.swift:384`;
   `MainWindowController.applyHeldStatus` `:1095`;
   `VisionEngineController.applyHeldStatus` `:311`;
   `TVEngineController.applyHeldStatus` `:389`). It only ever moves
   `.ready ↔ .held` and is idempotent. The EFFECT is shared too, and lives where
   the session's other lifecycle edges do:
   `GameSession.holdEngineSession(maxBoardLength:)`
   (`Session/GameSession.swift:363`) sends `stop` as a lifecycle command
   **first**, then drops any half-read `showboard` block
   (`abortInFlightBoardCollection`), shuts the gate, runs `resetForFreshEngine`,
   and writes the status last; `releaseEngineHold(gameRecord:feeds:)` (`:382`)
   reopens the gate and re-states the whole position through
   `resyncEngineAfterHandshake` — with `feeds: false` for tvOS's
   `noteBoardMounted`, whose next breath is a `loadGame` that states it anyway.
   The hosts decide and delegate; they no longer each spell the effect out.
   Three of the four hand-written copies skipped the abort, and that strands
   `maybeCollectSync` mid-block: the next engine's `= MoveNum` line is eaten as
   board text, `showBoardCount` never returns to 0, and analysis and taps stay
   dead until a relaunch. Shutting the gate is
   load-bearing: `forwardMoves`/`backwardMoves` do not check board size, so
   scrubbing an oversized record would otherwise push `play` after `play` at an
   engine that was never told this board exists. This replaced iOS `GobanView`'s
   "Too large board size" `ContentUnavailableView`, visionOS `.boardTooLarge`
   (deleted from `VisionGameShell.Phase`; the card at `VisionRootView.swift:1109`
   now draws *over* the board) and the tvOS `boardFits` fallback screens. No
   platform has a board-too-large screen left. visionOS `.unsupportedBoard` —
   geometry outside 2…37 — stays a true gate (`unsupportedPhase`,
   `VisionRootView.swift:713`).

9. **The handshake is bounded, cancellation-aware and the sole reader.**
   `GameSession.handshake` (`Session/GameSession.swift:141`) shuts the gate,
   resets for a fresh engine, clears the pending output, sends `version` as a
   lifecycle command and then loops over `getMessageLine(timeoutSeconds:)`
   (`Bridge/KataGoEngineIO.swift:32`, with a default that falls back to the
   unbounded read) in half-second slices against a deadline, breaking on
   abandonment, on transport EOF, on `Task` cancellation, or on a `= `/`? `
   prefixed reply. A `? ` reply opens the gate — it proves the GTP loop is
   running and reading — but does not clear the crash sentinel, because it is not
   a successful model load. This is behaviour-preserving: before the gate existed,
   a `? ` version reply fell through the `= ` check and the host sent normally
   anyway. When an EOF and a cancellation land in the same slice, the EOF's
   reason wins: "The engine stopped." is what this handshake actually learned,
   and "did not answer in time" would replace it with a statement about
   patience. The budget is `defaultHandshakeTimeout = 660` (`:96`), the Core ML
   loader's own 600 s + 60 s launch fallback. **Every restart gets the same 660 s**
   on every platform (`AppEngineController.restartHandshakeTimeout:428`,
   `VisionEngineController:378`, `TVEngineController:459`): the Core ML cache key
   carries `boardXLen`/`boardYLen`, so a Max Board Size change misses the cache by
   construction and pays a full conversion plus compile.

10. **Restart is one discipline, shared.** `EngineRestartRules`
    (`Services/EngineRestartRules.swift:17`) owns `untilSettled` (`:33`, a
    deadline-checked, cancellation-observing poll — a `CheckedContinuation` never
    observes cancellation, so the previous wrapper was decoration),
    `canRestart(from:)` (`:62`, which allows `.failed` so Retry works),
    `shouldBeginRelaunch(isRelaunchInFlight:)` (`:86`, macOS's stand-in for a
    `Phase`) and `shouldArmReadLoop(generation:)` (`:103`, which arms a read loop
    a failed boot never armed, and resumes rather than re-keys one that already
    exists).
    `stopRequested` is raised **before** the `quit` so a death during the drain
    window is not reported to the user as a crash; `stop`/`quit` are sent only
    when the engine thread is actually running, because a `quit` written into the
    process-global input buffer with nothing draining it would be the first line
    the *replacement* engine reads. A thread that returns is classified by
    `EngineExitDisposition.decide(fatalError:stopWasRequested:)`
    (`Services/EngineStatus.swift:237` — the disposition lives with the rest of
    the status vocabulary, not in `EngineRestartRules`) and handed to
    `GameSession.noteEngineExit` (`Session/GameSession.swift:304`) **before**
    any stop flag moves.

11. **Latest selection wins.** A feed offered while the gate is shut is dropped,
    logged, and recorded as a debt on `GobanState.engineSyncGate`
    (`Model/GobanState.swift:37`, the `ReadinessGate` reused verbatim). The
    handshake's tail pays it by feeding the **live** record at the **live**
    cursor (`resyncEngineAfterHandshake`, `:1448`), which is also the right
    answer when the user switched games mid-launch.
    `GameSession.sendInitialCommands` — the fixed bundle of config commands
    every host used to send after its handshake — is DELETED, together with the
    `initialize` convenience that paired it with the handshake. Stating a
    default 19×19 board before anything had decided Held is the exact sequence
    that aborts a helper on its first evaluation, and
    `EngineFeed.openingCommands` says everything that bundle said.
    `EngineFeedInitialCommandsTests` still pins the superset claim: it carries
    the deleted bundle transcribed as its reference list, which is what stops a
    command being dropped from the feed unnoticed.

12. **`loadGame` honours the saved index everywhere** (`:1255`). iOS launch used
    to open at the tip only because the `loadsgf` echo reset the cursor. tvOS
    Play keeps `currentIndex = tip` as a deliberate product rule (there is no
    overwrite dialog on tvOS); visionOS dropped its pre-set-to-tip, which was an
    engine recipe.

13. **Picker policy, per build.** `RecoveryDecision.decide`
    (`Services/EngineLifecycle.swift:59`) checks DEBUG first: a debug build
    always mounts the board in *Absent* and presents the model picker as a
    **sheet** over it. Release never shows Absent — a persisted title
    auto-restores, no title launches the built-in net, a persisted title whose
    file is gone launches the built-in net with the note
    "⟨title⟩ was removed — using the built-in network", and a surviving crash
    sentinel mounts the board in *Failed* with Choose model and relaunches
    nothing. The picker is now reachable with a live engine: its own `onOpenURL`
    is deleted (`GameSplitView` owns imports), the Core ML routing probe and
    Clear Cache are disabled unless availability is Absent or Failed, and Play on
    the running model restarts it.
    *Superseded 2026-08-24 (`d54cc3e17`): neither is blocked by a running engine
    any more — the engine is unloaded around the work and relaunched after, and
    only a mid-launch engine still makes them wait.*

14. **Stage 2 is the seam this leaves.** Post-move order is now
    `play` → `printsgf` → `showboard`, so the record — and therefore the stone —
    updates before the in-sync acknowledgement. When a Swift SGF writer replaces
    `printsgf`, that ordering becomes moot and play itself becomes engine-free.

## Alternatives rejected

- **Stand in for the engine, then hand over.** Draw a temporary board from the
  record, and swap to the engine's `showboard` once it lands. Two sources of
  truth for one board, with a visible handover moment and a permanent question
  about which one is right after a refusal. Record-owned-forever has one answer.
- **`loadsgf` with a patched tolerant loader.** `CompactSgf::playMovesTolerant`
  *throws* on the first illegal move rather than skipping it, so the C++ side
  degrades to an empty position from that index onward. Making it skip means a
  C++ engine change, and it would still be one bulk command whose failure mode is
  "the whole file, or nothing". Move-by-move feeding skips exactly the indices the
  display skipped, which is the property the whole design rests on.
- **The C++ `SgfHelper` as the replay.** It has no `position(at:)` — it answers
  move lists and frames, not board states at an index — so the display would have
  had to reconstruct positions anyway, in a second place.
- **`SgfHeaderScan` as the app's parser.** It is the right parser for
  bridge-free targets and stays there, but running it *and* the C++ `CompactSgf`
  over one index space is two parsers that must agree forever. The C++ list is
  what navigation, move numbers and comments already use.
- **Observing `? illegal move` as control flow.** Letting the engine's refusal
  drive the display would make every refusal a round trip, and the refusal
  arrives asynchronously against a board the user has already scrubbed past. The
  replay predicts the same refusals locally; a DEBUG-only divergence log
  (`logEngineRecordDivergence`, `Session/GameSession.swift:555`) reports a
  mismatch and never mutates anything.
- **Numeric `MoveNum` verification.** `Search::makeMove` calls
  `setPlayerAndClearHistory` on a colour repeat (`cpp/search/search.cpp:322-327`),
  so a `B;B` record resets the engine's `BoardHistory` and its `MoveNum` cannot be
  compared to the record's index. Prefix acknowledgement only.
- **An `@Entry` environment default for `EngineStatus`.** A `@MainActor` default
  value in an environment key is a Swift 6 error. The status is read as an
  optional `@Environment(EngineStatus.self)`, where `nil` means "no host injected
  one, treat as ready" — which is exactly what a macOS or preview tree wants.
- **Extracting one shared in-process engine controller now.** iOS, visionOS and
  tvOS each run the quit → run-loop-exit → thread-exit → respawn → handshake
  dance. `AppEngineController` is a deliberate *port* of `VisionEngineController`,
  not an extraction: unifying three controllers while also moving four platforms
  off their loading screens would have made every regression ambiguous. What was
  genuinely shareable *was* hoisted — `EngineHeldRule`, `EngineRestartRules`,
  `EngineExitDisposition`, `EngineStatusText` — and the remaining duplication is
  lifecycle wiring, which is the follow-up.

## Consequences

- **Refusal parity is predicted, not observed.** The Swift tolerant replay and
  the C++ `isLegalTolerant` are argued equal and pinned by differential tests
  over every fixture, but no production run has confirmed it. The mitigation is
  the DEBUG-only divergence log, which prints one line and changes nothing —
  deliberately no self-heal.
- **The move-number markers are re-derived, and a `B;B` record moves them.**
  The digits `showboard` used to print now come from `SgfReplay.Position`'s
  `lastThreeMoves` (`SgfReplay.swift:51`), which mirrors `Board::printBoard`:
  the last three ACCEPTED move points, oldest first, a point that appears twice
  keeping its oldest digit, and passes and refused moves marking nothing. The
  window is kept over the history `Search::makeMove` maintains — and that
  history is CLEARED whenever the mover is not the side the engine expected
  (`setPlayerAndClearHistory`, `cpp/search/search.cpp`), so a colour repeat
  starts a fresh window containing only the repeating move. The upshot: the
  markers are identical to the old showboard-derived ones on every ordinary
  record, and differ only where a record plays the same colour twice in a row.
  Argued and tested, not observed against a live engine.

- **A mixed AB/AW record with `PL[W]` at index 0 analyses for Black.**
  `set_position` leaves Black to move and the feed does not pass a colour. Known
  gap; stage 2 can state it explicitly. `SgfReplay.toMove` ignores `PL[]` for the
  same reason — the engine is fed setup plus moves, never a player override.
- **A setup group with zero liberties is skipped, with a log line.**
  `Board::setStonesFailIfNoLibs` would refuse the whole placement, so
  `EngineFeed.setupCommand` (`Session/EngineFeed.swift:140`) sends nothing rather
  than sending something the engine will reject.
- **Any all-Black setup takes the handicap path.** A single-stone problem SGF
  (`AB[dd]` alone) therefore comes up with White to move and a handicap komi
  bonus. That is what `loadsgf` did too; it is now visible because it is the app's
  own command rather than a side effect.
- **A corrupt record self-heals on the first `printsgf`, and the indices shift.**
  Because the app no longer normalises imported SGF through a `loadsgf` echo, a
  malformed record is displayed as parsed until the next played move rewrites it
  from the engine — at which point stored per-index analysis may no longer line
  up with the new index space.
- **An unreadable record gets a line, and is never fed.**
  `GobanState.isRecordUnreadable` (`Model/GobanState.swift:45`) drives
  `UnreadableRecordView` ("Can't read this game",
  `Rendering/EngineStatusView.swift:167`). Its accessibility id is
  `Board.unreadableRecord`, deliberately outside the `EngineStatus.` prefix, so
  it can coexist with a ready engine without failing an in-sync wait.
- **The phone skips refused moves; the watch still refuses the whole record.**
  `WatchBrowseModel.isReadable` (`KataGo Anytime Watch/WatchBrowseModel.swift:69`)
  is still `anomalyIndex == nil`, so an anomalous record the phone renders and
  analyses shows as unreadable on the wrist. Recorded, not changed.
- **Analysis clears on every record change until the next info line.** The
  projector clears `Analysis` on a key change while not in sync, so scrubbing
  blanks the win rate for one round trip. There is also a 0 % window between
  `.ready` and the first `info` line, which pre-dates this change.
- **Haptics now fire on scrub steps and on nil-key publishes**, because they are
  triggered by `Stones.positionGeneration` rather than by the engine's
  acknowledgement. That is the point — the feel of the board no longer waits —
  but it is more haptics than before.
- **macOS still shows no compile caption.** ADR 0007's consequence stands: the
  Mac engine is a subprocess and the helper is the same loader minus the
  `EngineLaunchStatus` reporting, so `MacBoardHostView` deliberately injects
  `EngineStatus` and **not** `EngineLaunchStatus`
  (`KataGo Anytime Mac/MacBoardHostView.swift:77`). Wiring it needs a status
  channel in `KataGoEngineIPC` and is still out of scope.
- **macOS gives up the board's right-click menu while the status carries a
  button.** `MacBoardInteractionLayer` is z-stacked over `BoardView`, so it
  stands aside when `engineStatus.actions` is non-empty
  (`MacBoardHostView.swift:101`) — otherwise the Retry button would be visible
  and unclickable. An ordinary "Loading engine…" carries no actions, so the
  overlay stays live through a normal launch.
- **A tvOS screen with a nil selection does not blank its board.** The review and
  play screens park `navigationContext.selectedGameRecord` at nil as
  write-protection while still showing the game, so tvOS keys its record-position
  driver on the screen's own `game`, and the controller remembers the mounted
  board itself (`TVEngineController.noteBoardMounted`, `:345` /
  `noteBoardDismissed`, `:364`). Every other platform's nil key publishes an
  empty board. A future tvOS screen that draws a board and forgets to register it
  would get no Held decision and no post-restart re-feed.
- **A Held board cannot be navigated on tvOS.** `TVReviewScreen.stepBy`
  (`KataGo Anytime TV/TVReviewScreen.swift:944`) still
  guards on `stones.isReady`, which a held engine never grants, so a held tvOS
  board draws at its saved index and freezes. visionOS deliberately dropped that
  term from *its* navigation in the same change, so the two in-process hosts now
  disagree: "the board never waits" is true of the display on both, and of the
  timeline only on visionOS.
- **A `? ` first reply opens the command gate.** Behaviour-preserving (see
  decision 9), but it means a misbehaving engine that answers `?` to `version` is
  treated as alive for command purposes while its crash sentinel stays armed.
- **Release with no persisted model launches the built-in net.** *Absent* is a
  DEBUG-only state. A release user never sees "No model chosen".
- **iOS now reopens a game where you left it.** Launch goes through `loadGame`
  like every other open, so the saved `currentIndex` is honoured; it used to
  land on the tip purely because the `loadsgf` echo reset the cursor. tvOS Play
  still jumps to the tip on purpose; visionOS dropped the pre-set-to-tip it had
  inherited from the same recipe.
- **Opening a game costs N `play` round-trips and N transcript lines.** Cheaper
  than the N `undo`s a fresh load used to walk back, and it is what makes
  refusal-skipping possible at all — but the Developer Mode transcript now grows
  by roughly one line per recorded move each time a game is opened. A launch
  that comes up *Held* is the opposite extreme: it asks the engine nothing, so
  no GTP traffic appears at all, and the status line is the only explanation.
- **An expected engine exit parks availability in *Launching*.** On the app-quit
  path that is momentarily untrue — nothing is launching, the app is going away
  — but no surface shows it, and leaving *Ready* standing over a shut command
  gate would be the worse lie.
- **A very late thread exit can abort the next Retry's handshake.** If an engine
  thread returns after its teardown wait already gave up (240 s), the exit lands
  while a subsequent restart is mid-handshake and abandons it. Same shape on
  iOS, visionOS and tvOS; the way out is another Retry.
- **`UnreadableRecordView` still renders on tvOS**, as a small `.caption` pill
  over the board that can wrap to two lines. It is the one thing left in
  `BoardView`'s overlay there (the engine half is compiled out), and it predates
  this change — but wrapping text on a 10-foot UI is against the tvOS rule, and
  moving it into the side panel would mean a tvOS string outside
  `EngineStatusText`. Flagged, not fixed.
- **The macOS model dropdown is disabled while Held.** Its validation is
  `menuItem.isEnabled && session.engineStatus.isReady`, and *Held* is not
  *Ready* — so the toolbar cannot switch nets on a board the running engine
  cannot hold. The Models window's Play still can (it carries no readiness
  check, deliberately: it is also how a failed engine is replaced), and that is
  the way out of a Held launch on macOS.

- **A second macOS relaunch is rejected, not queued.**
  `MainWindowController.relaunch(model:)` is reachable from three places that
  can fire while one is already tearing down — the status line's Retry, the
  Models window's Play, the toolbar dropdown — and two overlapping calls would
  run two teardown/spawn pairs against one session (two `run()` loops on one
  transport, `engineProcess` replaced underneath the teardown still waiting on
  it). An `isRelaunching` flag, decided by
  `EngineRestartRules.shouldBeginRelaunch`, drops the second call for the
  duration of the first. The in-process controllers answer the same question
  with their `Phase`; macOS has none, which is why it needs the flag.

- **Max Board Size means something slightly different per platform.** iOS,
  visionOS and tvOS restart the engine in the background with the board visible;
  macOS applies it at spawn time only, deliberately — a relaunch there would
  tear down an engine the user is mid-analysis on with no warning
  (`KataGo Anytime Mac/ModelRowView.swift:427-439`). Until the next load, a Mac
  board over the launched cap is reported as *Held*.
- **Every launch now loads a record, on every platform**, including launches that
  never reach a board (the macOS Models window, an iOS picker-only session).
  That is inherent — the board has to show *something* — and it re-dates nothing
  by itself: the reviewer confirmed no `lastModificationDate` write on the launch
  path, and the worry that "every launch re-dates the auto-selected game" is
  retired.
- **Two pre-existing CloudKit-churn writes were fixed while proving that.**
  `GameRecord.updateToLatestVersion()` (`Model/GameRecord+SGF.swift:311`) wrote
  `width`/`height` unconditionally on every open, and `loadGame` wrote all seven
  `config.*` rule properties unconditionally. SwiftData dirties a model on a
  write even to the value it already holds, and a dirtied model is saved and
  exported — so every launch and every game switch pushed an identical record to
  iCloud. Both are now guarded. No stored value changed, only whether the write
  happens.
- **The UI-test sentinel changed.** "Wait for the `Forward to End` button to
  exist" is gone; suites now call `PortraitUITestCase.waitForBoardInSync`
  (`KataGo iOSUITests/PortraitUITestCase.swift:143`), which waits for the hidden
  `Board.sync` element to read `inSync` (`Rendering/BoardView.swift:223-224`)
  **and** for every `EngineStatus.*` element to vanish. The old existence-based
  sentinels no longer prove anything, because the board now exists before the
  engine does. `Board.sync` also adds one unlabelled node to every board's
  VoiceOver rotor.
- **A restart is now slow to report a dead engine.** Every platform waits the
  full 660 s before calling a silent-but-alive engine failed (it was 120 s on
  visionOS and tvOS). A handshake that ends in EOF still reports immediately.
- **The teardown polls wake the main actor.** Up to ~2400 wakeups on a worst-case
  thread teardown (50 ms and 100 ms intervals against 10 s and 240 s caps),
  during a restart only. That is the price of a wait that observes cancellation;
  the continuation version cost nothing and could hang forever.
- **A restart that gives up leaves the read loop parked until the next one.**
  Deliberate: an unparked reader would consume the next handshake's `version`
  reply. The status line says the engine failed and Retry is one tap away, but a
  user who dismisses the failure has a permanently silent engine.
- **Developer-Mode commands typed while the engine is unavailable are dropped**,
  with a transcript line, never queued or replayed.
- **`GameSession.initialize` and `sendInitialCommands` are gone.** Every host
  calls `handshake` and lets the feed configure the engine, so the pair had no
  production caller left; the tests that were their last three call sites now
  target `handshake` (`GameSessionInitializeClearTests`) and a transcribed
  reference list (`EngineFeedInitialCommandsTests`).
- **Neither macOS nor visionOS nor tvOS has automated coverage of its host
  wiring.** There is no Mac UI-test target and no Vision or TV test bundle, so
  the boot / restart / Held choreography on those three is pinned only by the
  pure rules the iOS bundle can reach (`EngineHeldRule`, `EngineRestartRules`,
  `EngineStatusText`, `EngineExitDisposition`, `VisionEngineChrome`,
  `TVAutoPlayPolicy`) plus manual verification. Device QA is the gate.
- **Stage 2's seam is `printsgf`.** Replacing it with a Swift SGF writer is what
  makes *playing* a move engine-free; until then a played move still round-trips
  through the engine to update the record.
