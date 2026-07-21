# tvOS Broadcast Resume-After-Pause Gen-Move Stall Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After Pause→Resume in the tvOS broadcast, the resumed cycle's licensed gen-move must survive — today the root's `analysisStatus` observer sends a `"stop"` that lands right behind `kata-search_analyze_cancellable` on the engine FIFO and cancels it (the engine prints `play cancelled`, no stone lands, and the broadcast parks in `.awaitingMove` forever).

**Architecture:** One-line gate: the TV root's `.clear → "stop"` observer is suppressed while the broadcast's one-shot gen-move license (`broadcastGenMovePending`) is armed. The license is armed in the same synchronous MainActor job as the `.run → .clear` flip inside `issueGenMove`, so whenever the observer fires for that flip the license is still armed; every legitimate stop path (tearDown user-off restore, review-screen analysis-off, restart, screen entry) has the license false and keeps its stop. Plus: correct four comment sites that carry the wrong "a cancelled search still prints its best-so-far `play <vertex>`" model (the engine actually prints the literal `play cancelled` on any interrupt — proven by `cpp/tests/results/gtp/searchcancellable.stdout:11-14`), and pin both the gate and the real reply shape with tests.

**Tech Stack:** Swift / SwiftUI (tvOS target + KataGoUICore SwiftPM package), Swift Testing (`@Test`/`#expect`), xcodebuild.

## Global Constraints

- Working directory for every build/test command: `ios/KataGo iOS/` (note the space).
- Judge builds/tests ONLY by `** BUILD SUCCEEDED **` / `** TEST SUCCEEDED **` markers with `set -o pipefail` (piped xcodebuild exit codes lie).
- `-only-testing` CANNOT select a Swift Testing suite (0 tests = vacuous pass) — run the full test action.
- Production changes are EXACTLY: one predicate added to `GobanState.swift`, one gated observer in `TVRootView.swift`, comment-only rewrites in `BroadcastController.swift` and `GameSession.swift`. Nothing else. In particular:
  - `VisionRootView.swift` has an identical observer — leave it UNTOUCHED (no broadcast on visionOS; the license is never armed there).
  - The similar-sounding comment at `TVSelfPlayScreen.swift:516-518` is CORRECT for the entry path — leave it untouched.
  - Do not touch `postProcessAIMove`'s logic: consuming the license on ANY `"play "` line (including `play cancelled`) is correct and load-bearing.
- Count `"stop"` commands in tests by `hasSuffix("stop")` (message texts carry a `"> "` display prefix; exact `==` never matches).
- English-only in all committed content. Never push to remote (the user decides timing).
- Every commit message ends with both trailers, exactly:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01BaAS47ebfehEhSq2vXwpVy`

---

### Task 1: License-gate the root stop observer (+ comment rewrites + composition tests)

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/GobanState.swift` (insert after line 48, the `broadcastGenMovePending` declaration)
- Modify: `ios/KataGo iOS/KataGo Anytime TV/TVRootView.swift:163-168`
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/BroadcastController.swift:17-19` and `:434-438` (comments only)
- Test: `ios/KataGo iOS/KataGo iOSTests/BroadcastControllerTests.swift`

**Interfaces:**
- Produces: `GobanState.shouldStopEngineOnAnalysisClear: Bool` (computed, public) — consumed by `TVRootView` and by the new tests.

- [ ] **Step 1: Write the two failing composition tests**

In `BroadcastControllerTests.swift`, add to the `Fixture` struct (after the `sentCount` helper at line 74):

```swift
        /// Exact "stop" commands on the wire. Message texts carry a "> "
        /// display prefix, so match the suffix (no other command in these
        /// fixtures ends in "stop").
        var stopCommandCount: Int {
            session.messageList.messages.filter { $0.text.hasSuffix("stop") }.count
        }
```

Then add two tests directly after `resumeRestoresProtocol` (after line 208):

```swift
    /// The root's stop observer fires one MainActor pass AFTER
    /// issueGenMove's .run→.clear flip — with the license armed in the
    /// same synchronous job, the gate must keep its "stop" off the wire
    /// (an ungated stop cancels the licensed search: the engine prints
    /// "play cancelled" and the broadcast parks in .awaitingMove forever —
    /// the pause→resume stall).
    @Test("Resumed cycle: license armed at the flip; the gated root stop stays silent")
    func resumedCycleKeepsLicenseArmedAtTheFlipAndGatesTheRootStop() async {
        let f = Fixture()

        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.phase == .awaitingMove })
        await f.controller.pause(game: f.record)
        // The prior cycle's reply consumed the license while paused.
        f.session.gobanState.broadcastGenMovePending = false
        let stopsBefore = f.stopCommandCount

        f.controller.resume(game: f.record)
        await f.pump(until: { f.controller.phase == .awaitingMove })

        // The flip and the license arm are one synchronous MainActor job:
        // whenever the observer later fires for this flip, the license is
        // armed — the invariant the gate depends on.
        #expect(f.session.gobanState.analysisStatus == .clear)
        #expect(f.session.gobanState.broadcastGenMovePending)

        // TVRootView's observer body, verbatim: gated, it sends nothing.
        if f.session.gobanState.analysisStatus == .clear,
           f.session.gobanState.shouldStopEngineOnAnalysisClear {
            f.session.messageList.appendAndSend(command: "stop")
        }
        #expect(f.stopCommandCount == stopsBefore)
    }

    /// A pass picked while paused routes resume through the endgame
    /// formality (startCycle → immediate issueGenMove, no report) — same
    /// .run→.clear flip, same gate.
    @Test("Resumed endgame formality: license armed; the gated root stop stays silent")
    func resumedEndgameFormalityGatesTheRootStop() async {
        let f = Fixture()

        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.phase == .awaitingMove })
        await f.controller.pause(game: f.record)
        f.session.gobanState.broadcastGenMovePending = false
        f.session.gobanState.passCount = 1
        let stopsBefore = f.stopCommandCount

        f.controller.resume(game: f.record)
        await f.pump(until: { f.controller.phase == .awaitingMove })

        #expect(f.session.gobanState.analysisStatus == .clear)
        #expect(f.session.gobanState.broadcastGenMovePending)
        if f.session.gobanState.analysisStatus == .clear,
           f.session.gobanState.shouldStopEngineOnAnalysisClear {
            f.session.messageList.appendAndSend(command: "stop")
        }
        #expect(f.stopCommandCount == stopsBefore)
    }
```

- [ ] **Step 2: Verify the tests fail (red)**

Run (from `ios/KataGo iOS/`, `set -o pipefail`):
```bash
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17'
```
Expected: **compile failure** — `shouldStopEngineOnAnalysisClear` does not exist yet. That is the red for this task (the semantic red comes from the mutation check in Step 5).

- [ ] **Step 3: Implement the predicate, the gate, and the comment rewrites**

(a) `GobanState.swift` — insert directly after the `broadcastGenMovePending` declaration (line 48):

```swift
    /// Gate for the tvOS root's analysisStatus observer: it sends the GTP
    /// "stop" whenever the status transitions to .clear, but SwiftUI's
    /// onChange fires one MainActor update pass AFTER the write — by then
    /// issueGenMove has already sent the licensed
    /// kata-search_analyze_cancellable, and a trailing "stop" would cancel
    /// it (the engine prints "play cancelled", no stone lands, and the
    /// broadcast parks in .awaitingMove forever — the pause→resume stall).
    /// Sound because the .clear flip and the license arm execute in the
    /// same synchronous MainActor job (issueGenMove →
    /// requestBroadcastGenMove): whenever the observer fires for that
    /// flip, the license is still armed. If requestBroadcastGenMove
    /// early-returns without arming (unknown side, maxTime 0), this stays
    /// true and the stop goes out — safe degradation.
    public var shouldStopEngineOnAnalysisClear: Bool { !broadcastGenMovePending }
```

(b) `TVRootView.swift` — replace lines 163-168:

```swift
                .onChange(of: session.gobanState.analysisStatus) { _, newValue in
                    // User toggled analysis off (TVReviewScreen sets .clear) —
                    // but never while the broadcast's licensed gen-move is in
                    // flight; see GobanState.shouldStopEngineOnAnalysisClear.
                    if newValue == .clear,
                       session.gobanState.shouldStopEngineOnAnalysisClear {
                        session.messageList.appendAndSend(command: "stop")
                    }
                }
```

(c) `BroadcastController.swift` — replace header lines 17-19:

```swift
//  - issueGenMove re-asserts .clear BEFORE sending (a paused-interactive
//    stretch runs .run). The TV root's status observer fires one MainActor
//    update pass LATER — after the gen-move is already on the FIFO — so it
//    is gated on the armed license (shouldStopEngineOnAnalysisClear): an
//    ungated "stop" would cancel the licensed search, which then prints
//    "play cancelled" instead of a vertex and the broadcast would park in
//    .awaitingMove forever (the pause→resume stall).
```

(d) `BroadcastController.swift` — replace the comment inside `issueGenMove` (lines 434-438):

```swift
        // Restore the broadcast protocol BEFORE the gen-move: after a
        // paused-interactive stretch status is .run, and .clear keeps
        // BoardView's turn observer silent at the upcoming turn change.
        // The TV root's status observer reacts one update pass LATER —
        // after the gen-move below is on the FIFO — and is gated on the
        // armed license (GobanState.shouldStopEngineOnAnalysisClear), so
        // its "stop" cannot cancel this search (a stop-cancelled search
        // prints "play cancelled", never a vertex, and the cycle would
        // park in .awaitingMove forever).
```

- [ ] **Step 4: Run the full suite — green**

Same command as Step 2. Expected: `** TEST SUCCEEDED **`, 0 failures.

- [ ] **Step 5: Mutation red-check (semantic evidence the tests bite)**

Temporarily change the predicate body to `{ true }` (ungated). Re-run the full suite: EXACTLY the two new composition tests must fail (stop count grew). Revert the mutation; confirm `git diff` on production files matches Step 3 only. Record the observed failing test names in the task report.

- [ ] **Step 6: Build the TV scheme (production view changed)**

```bash
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime TV" -destination 'platform=tvOS Simulator,name=Apple TV'
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add "KataGoUICore/Sources/KataGoUICore/Model/GobanState.swift" "KataGo Anytime TV/TVRootView.swift" "KataGoUICore/Sources/KataGoUICore/Report/BroadcastController.swift" "KataGo iOSTests/BroadcastControllerTests.swift"
git commit -m "fix(tv): root stop observer yields to the licensed gen-move

After Pause→Resume, issueGenMove's .run→.clear protocol flip fired the
root's stop observer one update pass later — its \"stop\" landed right
behind kata-search_analyze_cancellable on the engine FIFO and cancelled
it. The engine prints the literal \"play cancelled\" for any interrupted
cancellable search (never a best-so-far vertex), the vertex regex drops
it after consuming the one-shot license, and the broadcast parked in
.awaitingMove forever. Gate the observer on the armed license: the flip
and the arm are one synchronous MainActor job, and every legitimate stop
path (teardown, review-screen analysis-off, restart, entry) clears or
never arms the license first."
```
(with both trailers appended).

---

### Task 2: Pin the engine's `play cancelled` reply; correct the cancelled-search comments

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Session/GameSession.swift:445-459` (comment only)
- Test: `ios/KataGo iOS/KataGo iOSTests/GameSessionPostProcessAIMoveGuardTests.swift` (header comment + one new test)

**Interfaces:**
- Consumes: `GameSession.maybeCollectPlay(message:navigationContext:audioModel:aiMove:)` (internal, via `@testable import`), `GobanState.broadcastGenMovePending`.

- [ ] **Step 1: Add the characterization test**

In `GameSessionPostProcessAIMoveGuardTests.swift`, add after `defaultPlaysAIMove` (line 95):

```swift
    @Test("Interrupted search ('play cancelled'): license consumed, nothing plays")
    func playCancelledConsumesTheLicenseWithoutPlaying() {
        let f = Fixture()
        // Broadcast state: spectator suppression with the one-shot license
        // armed. "play cancelled" is the engine's literal reply when a
        // queued line cancels the licensed kata-search_analyze_cancellable
        // mid-search (cpp/tests/results/gtp/searchcancellable.stdout).
        f.session.gobanState.suppressesGenMove = true
        f.session.gobanState.broadcastGenMovePending = true

        let captured = f.captured
        f.session.maybeCollectPlay(message: "play cancelled",
                                   navigationContext: f.navigation,
                                   audioModel: f.audioModel,
                                   aiMove: Binding(get: { captured.value },
                                                   set: { captured.value = $0 }))

        // Consumed even though nothing plays: a stale license must never
        // leak a later stray reply through the suppression guard.
        #expect(!f.session.gobanState.broadcastGenMovePending)
        #expect(f.captured.value == nil)
        #expect(f.record.currentIndex == 0)
        #expect(!f.sent("play b cancelled"))
    }
```

Note: this is a characterization pin of EXISTING behavior (it must pass without any production change) — say so in the task report; there is no red step for it. It documents the reply shape the stale comments misdescribed and routes through `maybeCollectPlay` to pin the `"play "` prefix routing.

- [ ] **Step 2: Rewrite the stale comment in `GameSession.swift`**

Replace lines 445-459 (the comment block above `let broadcastLicensed`; keep the code below untouched):

```swift
        // A kata-search_analyze_cancellable that runs to completion prints
        // "play <vertex>" (the engine never plays it on its own board); one
        // interrupted by ANY queued line — kata-check-move, a replay burst,
        // "stop" — prints the literal "play cancelled", which the vertex
        // regex below ignores. A completed reply can still arrive stale:
        // while the session is a spectator or paused (suppressesGenMove),
        // replaying (isAutoPlaying — the wand's command burst cancelled the
        // in-flight gen-move, and a stray reply would truncate the record
        // via the editing path), or a user pick is mid-legality-check
        // (pendingMoveTurn set), it must not be played into the record.
        // shouldGenMove forbids issuing gen-moves in all three states, so no
        // legitimate reply is ever dropped here.
        // The tvOS broadcast licenses exactly ONE gen-move reply through the
        // suppression guard (suppressesGenMove stays true for its whole
        // lifetime). The license is consumed on ANY "play " line — including
        // "play cancelled" — even when a later guard drops it: the broadcast
        // re-issues per cycle, and a stale license must never leak a future
        // stray reply through.
```

- [ ] **Step 3: Rewrite the stale test-file header**

Replace `GameSessionPostProcessAIMoveGuardTests.swift` header lines 5-12:

```swift
//  Pins the drop guard at the top of GameSession.postProcessAIMove. A
//  kata-search_analyze_cancellable that completes prints its "play <vertex>"
//  line (the engine never plays it on its own board); one cancelled
//  mid-search prints the literal "play cancelled". A completed line can
//  still arrive stale: while a screen is a spectator or paused
//  (suppressesGenMove) or a user pick is mid-legality-check
//  (pendingMoveTurn set — the kata-check-move is what cancelled the
//  search), it must be dropped, not played into the record. With neither
//  condition, the reply plays exactly as before the guard existed (the
//  iOS/macOS regression pin).
```

- [ ] **Step 4: Run the full suite — green**

From `ios/KataGo iOS/`, `set -o pipefail`:
```bash
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17'
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add "KataGoUICore/Sources/KataGoUICore/Session/GameSession.swift" "KataGo iOSTests/GameSessionPostProcessAIMoveGuardTests.swift"
git commit -m "test(session): pin the engine's literal 'play cancelled' reply; correct the cancelled-search comments"
```
(with both trailers appended).

---

### Task 3: Whole-branch verification

**Files:** none modified (verification only; fixes loop back into the owning task's files).

- [ ] **Step 1: Full test suite** — `** TEST SUCCEEDED **`, 0 failures.
- [ ] **Step 2: All five scheme builds** (`KataGo Anytime`, `KataGo Anytime Mac`, `KataGo Anytime Vision`, `KataGo Anytime TV`, `KataGo Anytime Watch` — commands in CLAUDE.md), each judged by its `** BUILD SUCCEEDED **` marker with pipefail.
- [ ] **Step 3: tvOS simulator forensics (regression only)** — boot an Apple TV simulator, install "KataGo TV.app" from the real DerivedData products dir ("DerivedData/KataGo Anytime/Build/Products"), launch, let attract auto-entry (180 s) reach the broadcast, then verify over ≥3 cycles via logs + CPU sampling: licensed stones land (~designed cadence), engine idles under slides, no runaway kata-analyze. Pause→resume CANNOT be driven in the simulator (synthetic remote keys never reach it) — that behavior is pinned by Task 1's composition tests and goes to hands-on device QA.
- [ ] **Step 4: Record outcome in the progress ledger.** Hands-on Apple TV QA items for the user: (a) pause → resume → after the third card a stone must land and the next "Analyzing…" cycle start; repeat twice in a row; (b) pause during the final card, then resume; (c) undo-then-resume (stepBack leaves `.pause`; same flip, same gate).
