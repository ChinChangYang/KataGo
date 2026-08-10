# Narrated Auto-Play and Controller Navigation on Apple TV

**Date:** 2026-08-10
**Status:** Approved

Companion spec: `2026-08-10-tvos-play-vs-katago-design.md` (the fifth feedback
item from the same round). This spec ships first.

## Problem

Tester feedback (2026-08-10 TV round, items 1–4 of 5):

1. Auto-play should speak the narration aloud.
2. With a game controller, board focus should start the cursor at the last
   move, not the board center.
3. The controller should step backward/forward through positions while the
   board is focused.
4. Auto-play shouldn't just play moves for a review game — it should mirror
   the narration UI/UX of a live game.

Current behavior:

- **Review auto-play is a silent flip-book.** `TVReviewScreen` owns a plain
  timer loop (`isAutoPlaying` + `autoPlayTask`): sleep
  `TVAutoPlaySpeed.interval` (3.0/1.5/0.7 s), consult the pure
  `TVAutoPlayPolicy.tick`, and on `.advance` call
  `gobanState.forwardMoves(limit: 1)`. The review layout does not change at
  all while replaying — the only visual difference is the play icon flipping
  to pause.
- **A live game is a commentated broadcast.** `TVSelfPlayScreen` runs
  `BroadcastController` (KataGoUICore/Report): per move, a
  `DeepReportGenerator` report → up to 3 slides ("Best Move X" /
  "Alternative Y" / "Playing vs. Passing") of deterministic `ReportNarrator`
  fact sentences → `TVBroadcastSlidePanel` typewriter at
  `BroadcastConstants.charactersPerSecond = 30` in lockstep with
  `TVBroadcastSlideBoard` choreography → one licensed gen-move
  (`broadcastGenMovePending`).
- **Nothing speaks.** Zero `AVSpeechSynthesizer`/`AVSpeechUtterance` usage
  anywhere in the repo. FoundationModels is compile-time unavailable on tvOS,
  so all tvOS narration text is the deterministic `ReportNarrator` facts.
- **Synced comments are invisible on tvOS.** iOS/macOS write per-move
  commentary into `GameRecord.comments[Int: String]` (hand-written or Deep
  Report "Copy to Comment"); no tvOS surface displays it.
- **The cursor reveals at center.** Both TV game screens call
  `ghost.activate(width:height:)` with no origin, and nothing on tvOS calls
  `GhostCursorModel.setAnchor` — the model's last-move `anchor` fallback
  (`origin ?? anchor ?? center`) exists and visionOS feeds it
  (`.onChange(of: lastMoveKey)` → `MoveNumbers.derive(...).lastPoint` →
  `setAnchor`), but tvOS lacks the caller.
- **Stepping is dead while aiming.** Both screens'
  `handleControllerEvent` begin with `guard !isAiming else { return }`, so
  L1/R1 (step ±1, hold-to-repeat via `TVControllerInput.bindRepeating`) and
  L2/R2 (jump start/end) — which work when the panel or timeline has focus —
  are deliberately inert while the ghost cursor is up.

## Goal

Review auto-play becomes the same commentated, spoken broadcast experience as
watching a live game, and a game controller can aim and navigate at the same
time, starting from the last move.

## Decisions (from brainstorming)

1. **Full broadcast mirror.** Review auto-play runs the real
   `BroadcastController` cycle per replayed move; the cycle ends by playing
   the next recorded move instead of a gen-move. The silent timer replay is
   replaced, not kept alongside.
2. **Speech covers both broadcasts** — review replay and live self-play — via
   a "Spoken narration" toggle in TV Settings (next to Sound Effects),
   **default ON**.
3. **Synced comments join the narration**: when the just-played move index
   has a `GameRecord.comments` entry, one extra "Comment" slide types and
   speaks it. Facts are never replaced by comments.
4. **`TVAutoPlaySpeed` maps to broadcast pacing** (slow = live parity,
   normal = faster text, fast = Best-Move slide only). Speech rate never
   changes; when speaking, speech is the pacing floor.
5. **Last-move anchor**: port the visionOS hook; the center fallback stays
   for pass/empty positions.
6. **Navigation while aiming** (review screen only): L1/R1 step, L2/R2 jump;
   X (auto-play) and Y (analysis) stay suppressed while aiming. Self-play's
   guard is untouched. Siri-Remote-only users are unchanged.

## Design

### Replay move source for BroadcastController

`BroadcastController` gains a move-source seam: the existing licensed
gen-move (`issueGenMove()` → `requestBroadcastGenMove`) or a replay closure
that advances one recorded move (the code `advanceOneMove()` runs today:
`forwardMoves(limit: 1)` with the audio click, then reanalyze is *not*
needed — the broadcast owns engine probes). Everything else — report
generation, `BroadcastScript.slides(from:)`, typewriter, choreography,
`skipSlide()`, pause — is reused unchanged.

`TVReviewScreen`:

- `startAutoPlay()` stops spinning a timer Task and instead creates/owns a
  `BroadcastController` in replay mode, presenting through the same
  `TVBroadcastSlideBoard`/`TVBroadcastSlidePanel` swap the self-play screen
  uses (hero and panel swap whenever `broadcast.currentSlide != nil`).
- `TVAutoPlayPolicy` remains the between-cycle gate: before each cycle,
  `tick(...)` decides advance / hold (stones not ready) / stop (branch
  active, thermal) / finish. `.finish(continuesLive: true)` keeps the
  `SelfPlaySeed` handoff and the 2 s handoff beat; the transition is now
  visually continuous since both sides run the same broadcast UX.
- All existing stop paths stay: any manual step, pick, Select, or focusing
  the board to aim tears the broadcast down (cancel speech, restore hero and
  panel, restore analysis state).
- The review engine-state protocol is untouched: `suppressesGenMove` stays
  `true` for the whole replay (replay mode never gen-moves, so no license is
  needed), the record stays locked, plays still force branches.

### Comment slide

After the recorded move plays, if `gameRecord.comments[newIndex]` is
non-empty, append one "Comment" slide whose facts are the comment text. The
slide shows over the live hero board (no slide-board choreography frames).
It is typed and spoken like any other slide. Comments are sparse — only
moves someone annotated on iOS/macOS — so most moves get only the fact
slides. Replay walks the mainline only, so the branch-has-no-comment-slot
limitation never applies.

### NarrationSpeaker

New in KataGoUICore:

- `protocol NarrationSpeaking` — `speak(_ text: String)` (enqueue),
  `cancelAll()`, an is-speaking/queue-empty signal. Enables fake-driven
  pacing tests.
- `AVSpeechNarrationSpeaker` — thin `AVSpeechSynthesizer` wrapper; one
  utterance per fact; system English voice, standard rate; cancellation via
  `stopSpeaking(at: .immediate)`.

`BroadcastController.present()` drives it: when the toggle is on, each
fact's utterance is enqueued as that fact's typewriter chunk begins, so
audio tracks the choreography anchors (`.fact(i)`). Slide advance requires
typewriter completion AND an empty speech queue, on top of the existing
`dwellSeconds`/`minimumSlideSeconds` floors. `skipSlide()`, `pause()`, and
teardown call `cancelAll()` first. Facts appended mid-typewriter (the late
tenuki fact) enqueue naturally; a slide replaced by `setAlternative`
cancels and re-enqueues.

Settings: `@AppStorage("TVSettings.spokenNarration")`, default `true`, a
toggle row in `TVSettingsScreen` next to Sound Effects. Audio uses the
session `AudioModel` already configures (`.playback`, `.mixWithOthers`).

### Speed mapping

`TVAutoPlaySpeed` keeps its key, picker, and three cases; its meaning
changes from a sleep interval to a broadcast pacing profile:

- **slow** — live-broadcast parity: all slides, stock `BroadcastConstants`.
- **normal** — all slides, faster reveal (~1.5× characters/second, reduced
  dwell).
- **fast** — Best-Move slide only (plus the Comment slide when present),
  fastest reveal.

Speech is never rate-shifted; with the toggle on, an unfinished utterance
holds the slide regardless of speed.

### Last-move anchor

Extract `LastMoveKey` (currently private to `VisionRootView`: an
`Equatable` of `getSgf(gameRecord:)` + `getCurrentIndex(gameRecord:)`) into
KataGoUICore next to `GhostCursorModel`. Both `TVReviewScreen` and
`TVSelfPlayScreen` add the visionOS hook verbatim:
`.onChange(of: lastMoveKey, initial: true)` →
`MoveNumbers.derive(sgf:currentIndex:).lastPoint` →
`ghost.setAnchor(lastPoint, width:height:)`. `lastPoint` is nil for a pass
or an empty board, preserving the center fallback. The derive walk is
O(moves) C++ SGF parsing — it runs once per position change, never per body
evaluation. visionOS switches to the shared `LastMoveKey`.

Intended interaction with stepping-while-aiming: `setAnchor` snaps a
visible ghost when the anchor changes, so stepping back/forward while
aiming makes the cursor follow the last move of each position.

### Stepping while aiming (review screen only)

`TVReviewScreen.handleControllerEvent` restructures its `guard !isAiming`:
while aiming, `.leftShoulder`/`.rightShoulder` run `stepBy(∓1)` and
`.leftTrigger`/`.rightTrigger` run the jump-to-start/end paths — the same
funnels used when not aiming (stones-ready gate, `stopAutoPlay`,
`reanalyze`, hold-to-repeat already wired). `.buttonX`/`.buttonY` remain
dropped while aiming. `TVSelfPlayScreen`'s guard is untouched (its L1/R1
mean undo/skip-slide, not navigation). `TVControllerLegend.rows` is updated
in the same file so Settings stays truthful.

### Constraints honored

- Never install a `GCEventViewController`; A, B/Menu, D-pad, Options, Home
  stay unbound via GameController (UIPress/focus-engine owns them).
- `TVControllerInput` remains the single `pressedChangedHandler` owner
  (LIFO handler stack).
- `isAiming` stays plain state flipped in-transaction (FocusState writes
  are post-render on tvOS); the Menu-exit ordering is preserved.
- The `tvSelectPress` invariant (nothing else wants Select while enabled)
  is unchanged — no new Select consumers.
- The broadcast engine-state protocol (`analysisStatus` `.clear`,
  `suppressesGenMove` true, one licensed gen-move per cycle in live mode)
  is not modified — replay mode subtracts the gen-move, adds nothing.
- `GameRecord` (frozen @Model) is read-only here: `comments` is only read.
- FoundationModels stays untouched; all spoken text is deterministic.

## Testing

- **Package tests (`swift test`, KataGoUICore):** replay-mode
  `BroadcastController` cycle with a fake engine and fake
  `NarrationSpeaking` — cycle ends in the replay closure not a gen-move;
  slide advance waits for speech; skip/pause cancel speech; comment slide
  appears exactly when the index has a comment; speed-profile table maps as
  specified.
- **iOS-host tests ("KataGo Anytime" test target):** `LastMoveKey`
  extraction, `TVControllerLegendTests` for the new rows,
  `TVAutoPlayPolicy` suite updated if its signature changes.
- **Device QA (Apple TV):** audible narration in review replay and live
  self-play; toggle silences both; slow/normal/fast pacing feel; L1/R1
  stepping and L2/R2 jumps while aiming with the cursor re-snapping to the
  last move; cursor reveals at the last move on focus; auto-play →
  continue-live handoff still seamless; Siri-Remote-only flows unchanged.
