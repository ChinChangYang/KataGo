# tvOS Auto-Play for All Games + Game Controller Support — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On Apple TV, any saved game can replay itself hands-free (Auto-Play on `TVReviewScreen`), and when an *unfinished* game runs out of recorded moves it hands off to a seeded live self-play broadcast that pops back when done; separately, a paired game controller gains focus-safe X / Y / L1 / R1 / L2 / R2 bindings on both game screens.

**Architecture:** All decision logic is pure and lives in `KataGoUICore` (`TVAutoPlaySpeed`, `TVAutoPlayPolicy`, `SelfPlaySeed`, `SelfPlayGame.recordedGameIsFinished`, `TVControllerLegend`) so it is unit-testable from the iOS test host — TV-target code is unreachable from every test target in this project. The TV target keeps only a cancellable `Task` loop, `GameController` plumbing, and views. The live continuation reuses `TVSelfPlayScreen`'s existing broadcast machinery untouched by seeding a **new in-memory `GameRecord`** into `TVSampleGameStore`'s private container, so the CloudKit-synced record is never a write target during the handoff.

**Tech Stack:** Swift 6 / SwiftUI (tvOS 26 target + `KataGoUICore` SwiftPM package), GameController, Swift Testing (`@Test`/`#expect`), xcodebuild, the `xcodeproj` Ruby gem.

## Global Constraints

- Working directory for every build/test command: `ios/KataGo iOS/` (note the space in the path).
- Judge builds/tests ONLY by the `** BUILD SUCCEEDED **` / `** TEST SUCCEEDED **` markers with `set -o pipefail` — piped xcodebuild exit codes lie.
- **Every new file in `KataGo iOSTests/` and in `KataGo Anytime TV/` MUST be registered in `project.pbxproj` via the `xcodeproj` Ruby gem before it is built.** The project has no file-system-synchronized groups: an unregistered test file compiles nowhere and the suite still reports green — a vacuous pass. Files under `KataGoUICore/Sources/` are auto-discovered and must NOT be registered (`project.pbxproj` contains 0 occurrences of `KataGoUICore/Sources`).
- All new tests go in the Xcode target **`KataGo AnytimeTests`** (directory `KataGo iOSTests/`). `KataGoUICore` has **no** SwiftPM test target, and package test targets never execute under `xcodebuild test`.
- `-only-testing` takes the TARGET name `KataGo AnytimeTests`, never the directory name `KataGo iOSTests`.
- Swift Testing (`import Testing`, `@Test`, `#expect`), plain `struct` suites, `@MainActor` only where the code under test requires it. Not XCTest.
- Every hand-written fixture SGF MUST carry an `RU[...]` tag (e.g. `RU[koSIMPLEscoreAREAtaxNONEsui0whbN]`). Without it the C++ `Sgf::getRulesOrFail` throws, and a C++ exception crossing into Swift **aborts the process** — uncatchable.
- There are NO tvOS test targets (the TV scheme's `<Testables>` block is empty). tvOS verification = unit tests on the pure logic + TV scheme build + `RenderPreview` + hands-on device QA.
- English-only in all committed content. Never push to the remote — the user decides timing.
- Do NOT touch `VisionControllerInput.swift` or `VisionRootView.swift`. The visionOS controller mapping is already device-QA'd; this plan adds a separate tvOS type.
- Do NOT reuse `GobanState.isAutoPlaying` for tvOS Auto-Play (see Task 6 rationale). It is a live guard inside `AnalysisView`, inside `maybeSendAsymmetricHumanAnalysisCommands`, and it is force-cleared by `loadGame` — while the only machinery that restores what it suppresses (`GameSplitView.processIsAutoPlayingChange`) is in the **iOS** target and is not compiled for tvOS.
- Every commit message ends with both trailers, exactly:
  `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF`

### Design decisions locked in by grilling (do not re-litigate)

| Decision | Value |
|---|---|
| What Auto-Play does | Auto-advances the game's **recorded** moves on a timer |
| Control | Siri Remote Play/Pause + a second full-width toggle **stacked above** the Analysis toggle (panel stays 500 pt wide) |
| Speed | New Settings picker: Slow 3.0 s / **Normal 1.5 s** / Fast 0.7 s |
| Stops on | Timeline step/swipe, board focus (aiming), Top Moves pick, screen exit, thermal `.serious`/`.critical` |
| Analysis | Never modified by Auto-Play (the one-bit invariant holds) |
| End of an **unfinished** game | ~2 s "Continuing live…" beat → push `TVSelfPlayScreen` seeded from this position |
| End of a **finished** game (two trailing passes or `RE[]`) | **No handoff.** Stop and show the result |
| Continuation config | Symmetric full-strength AI (fresh `Config()` + both `maxTime`), inheriting position/board size/komi/rules only |
| Continuation ends | Result card, then **pop back to the review screen** (not `restart()` into a fresh demo) |
| Manual stepping to the last move | Never pushes |
| Play pressed while already at the last move | Pushes immediately (or stops, if the game is finished) |
| Controller depth | Focus-engine parity + focus-safe extras only |
| Controller bindings | X, Y, L1, R1, L2, R2 via `GCExtendedGamepad`. **Never** A / B / Menu / Options / Home / dpad |
| Controller discovery | A "Game Controller" section in tvOS Settings, shown only while one is connected |

### Facts established by investigation (rely on these; do not re-derive)

- **`GCSupportsControllerUserInteraction` is NOT an event-routing switch on tvOS.** It is a capability/badge/remapping declaration. An extended gamepad already drives the focus engine through the responder chain by default (`GCEventViewController.h:15-42`). Setting it is still correct (it enables user remapping in Settings), but it is not what makes the feature work.
- **`.handlesGameControllerEvents(matching:)` and `GCEventInteraction` are `API_UNAVAILABLE(tvos)`** — hard compile errors. Do not port them from visionOS.
- **Never introduce a `GCEventViewController`.** Its `controllerUserInteractionEnabled` defaults to `false`, which suppresses UIEvents from controllers and would kill the focus engine, `TVSelectPressCatcher`, `.onMoveCommand`, `.onExitCommand` and `.onPlayPauseCommand` in one stroke.
- On tvOS a gamepad's **A arrives as `UIPress.PressType.select`** (already consumed by the window-level `TVSelectPressCatcher`) and **Menu as `.menu`** (already consumed by `.onExitCommand`). Binding them in GameController would double-fire.
- `UIPress.PressType` has **no cases** for X, Y, shoulders or triggers — GameController is the only way to read them, and binding them cannot collide with UIKit.
- On `GCExtendedGamepad`, `buttonX`, `buttonY`, `leftShoulder`, `rightShoulder`, `leftTrigger`, `rightTrigger`, `buttonMenu` are **non-optional**; `buttonOptions`, `buttonHome`, and the thumbstick buttons are `Optional`. `buttonOptions` is additionally bound to a system screenshot long-press and is delayed — do not bind it.
- `GCController.current` on tvOS is often the **Siri Remote** (whose `extendedGamepad` is nil) — the `?? GCController.controllers().compactMap(\.extendedGamepad).first` fallback is mandatory.
- `forwardMoves` at the end of a game executes zero moves but **still sends `showboard` + a kata-analyze restart**, and does not lower `stones.isReady` — so an unguarded timer would spam GTP forever. The end predicate must be checked **before** the call.
- `TVReviewScreen.loadIfNeeded` is one-shot behind `@State didLoad`, which **survives a push**. Popping back without resetting it leaves `isEditing == true` and `forcesBranchOnPlay == false` on a CloudKit-synced record — the build-291 corruption class. Task 7 fixes this and is a **prerequisite for the handoff**.
- `SelfPlayRoute` is registered as a `navigationDestination` **only on the Library tab's stack**. The Search tab also pushes `TVReviewScreen` and has no `SelfPlayRoute` destination and no path binding.
- `GameRecord.createGameRecord` derives board size and komi from the SGF but **not** `Config.rule` — it must be set explicitly (the `SampleGames.makeEarReddeningRecord` precedent).
- A seeded (non-`defaultSgf`) record loads **LOCKED** unless `unlockEditingOnReload` is requested — `TVSelfPlayScreen.startIfNeeded` already does this unconditionally.
- `GameRecord.clone()` copies the source `Config` wholesale (human-SL profiles, per-side max times) and renames to `"… (copy)"`. **Do not use it for the seed** — build on `createGameRecord`, which makes a fresh symmetric `Config()`.

---

### Task 1: `TVAutoPlaySpeed` — the cadence preference

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Util/TVAutoPlaySpeed.swift`
- Test: `ios/KataGo iOS/KataGo iOSTests/TVAutoPlaySpeedTests.swift`

**Interfaces:**
- Produces: `public enum TVAutoPlaySpeed: String, CaseIterable, Identifiable, Sendable` with `static let defaultsKey: String`, `static let defaultValue: TVAutoPlaySpeed`, `var label: String`, `var seconds: Double`, `var interval: Duration`. Consumed by Tasks 5 and 6.

- [ ] **Step 1: Write the failing test**

Create `ios/KataGo iOS/KataGo iOSTests/TVAutoPlaySpeedTests.swift`:

```swift
//
//  TVAutoPlaySpeedTests.swift
//  KataGo AnytimeTests
//

import Foundation
import Testing
@testable import KataGoUICore

struct TVAutoPlaySpeedTests {
    @Test func casesAreOrderedSlowestFirstForTheSegmentedPicker() {
        #expect(TVAutoPlaySpeed.allCases == [.slow, .normal, .fast])
    }

    @Test func secondsMatchTheAgreedCadence() {
        #expect(TVAutoPlaySpeed.slow.seconds == 3.0)
        #expect(TVAutoPlaySpeed.normal.seconds == 1.5)
        #expect(TVAutoPlaySpeed.fast.seconds == 0.7)
    }

    @Test func intervalMirrorsSeconds() {
        for speed in TVAutoPlaySpeed.allCases {
            #expect(speed.interval == .seconds(speed.seconds))
        }
    }

    @Test func rawValuesRoundTrip() {
        for speed in TVAutoPlaySpeed.allCases {
            #expect(TVAutoPlaySpeed(rawValue: speed.rawValue) == speed)
        }
    }

    /// The store/@AppStorage fallback path depends on an unknown raw value
    /// failing to decode rather than trapping.
    @Test func unknownRawValueDecodesToNil() {
        #expect(TVAutoPlaySpeed(rawValue: "garbage") == nil)
    }

    @Test func defaultIsNormalAndTheKeyIsNamespaced() {
        #expect(TVAutoPlaySpeed.defaultValue == .normal)
        #expect(TVAutoPlaySpeed.defaultsKey == "TVSettings.autoPlaySpeed")
    }

    @Test func labelsAreTheUserFacingStrings() {
        #expect(TVAutoPlaySpeed.slow.label == "Slow")
        #expect(TVAutoPlaySpeed.normal.label == "Normal")
        #expect(TVAutoPlaySpeed.fast.label == "Fast")
    }
}
```

- [ ] **Step 2: Register the test file in the pbxproj**

```bash
cd "ios/KataGo iOS" && ruby -e '
require "xcodeproj"
project = Xcodeproj::Project.open("KataGo Anytime.xcodeproj")
target = project.targets.find { |t| t.name == "KataGo AnytimeTests" }
group = project.main_group.find_subpath("KataGo iOSTests", false)
ref = group.new_reference("TVAutoPlaySpeedTests.swift")
target.source_build_phase.add_file_reference(ref)
project.save
'
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
cd "ios/KataGo iOS" && set -o pipefail && xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/TVAutoPlaySpeedTests" 2>&1 | tail -30
```
Expected: `** TEST FAILED **` with `cannot find 'TVAutoPlaySpeed' in scope`.

- [ ] **Step 4: Write the implementation**

Create `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Util/TVAutoPlaySpeed.swift`:

```swift
//
//  TVAutoPlaySpeed.swift
//  KataGoUICore
//
//  How fast TVReviewScreen's Auto-Play steps through a saved game's recorded
//  moves. Extracted into KataGoUICore (dependency-light, platform-agnostic) so
//  the cadence is unit-testable from the iOS test host: its consumers —
//  TVReviewScreen and TVSettingsScreen — are TV-target-only views that no test
//  target in this project can reach (the TimelineStepClassifier precedent).
//

import Foundation

public enum TVAutoPlaySpeed: String, CaseIterable, Identifiable, Sendable {
    case slow
    case normal
    case fast

    /// The one UserDefaults key, shared by the Settings picker's `@AppStorage`
    /// and the review screen's per-tick read.
    public static let defaultsKey = "TVSettings.autoPlaySpeed"

    /// One source of truth for the default so the picker's declared default and
    /// any non-View fallback can never drift (today's `soundEffects` default is
    /// duplicated across TVSettingsScreen and TVSettingsStore — don't repeat it).
    public static let defaultValue: TVAutoPlaySpeed = .normal

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .slow: "Slow"
        case .normal: "Normal"
        case .fast: "Fast"
        }
    }

    /// Seconds between auto-advanced moves.
    public var seconds: Double {
        switch self {
        case .slow: 3.0
        case .normal: 1.5
        case .fast: 0.7
        }
    }

    /// The same cadence as a `Duration`, for `Task.sleep(for:)`.
    public var interval: Duration { .seconds(seconds) }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Same command as Step 3. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev" && git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Util/TVAutoPlaySpeed.swift" "ios/KataGo iOS/KataGo iOSTests/TVAutoPlaySpeedTests.swift" "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj" && git commit -m "$(cat <<'EOF'
feat(tv): add the Auto-Play cadence preference type

Slow 3.0 s / Normal 1.5 s / Fast 0.7 s, with one shared defaults key and
one shared default so the picker and any non-View reader cannot drift.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
)"
```

---

### Task 2: `SelfPlayGame.recordedGameIsFinished` — the "don't hand off" predicate

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/SelfPlayGame.swift` (append to the `SelfPlayGame` enum, after `marginText` )
- Test: `ios/KataGo iOS/KataGo iOSTests/SelfPlayGameTests.swift` (existing file — append)

**Interfaces:**
- Consumes: `SelfPlayGame.result(fromSgf:)` (existing), `SgfOperations(sgf:)`, `Move.location.pass`.
- Produces: `SelfPlayGame.trailingPassCount(inSgf: String) -> Int` and `SelfPlayGame.recordedGameIsFinished(sgf: String) -> Bool`. Consumed by Tasks 3, 6 and 10.

- [ ] **Step 1: Write the failing tests**

Append to `ios/KataGo iOS/KataGo iOSTests/SelfPlayGameTests.swift`, inside the existing suite:

```swift
    // MARK: - recordedGameIsFinished

    /// A 9x9 SGF with an RU tag (mandatory — a missing RU aborts the process
    /// inside the C++ parser) and the given move body.
    private static func sgf(moves: String) -> String {
        "(;FF[4]GM[1]SZ[9]KM[7]RU[koSIMPLEscoreAREAtaxNONEsui0whbN]\(moves))"
    }

    @Test func trailingPassCountCountsOnlyTrailingPassesAndClampsAtTwo() {
        #expect(SelfPlayGame.trailingPassCount(inSgf: Self.sgf(moves: ";B[cc];W[dd]")) == 0)
        #expect(SelfPlayGame.trailingPassCount(inSgf: Self.sgf(moves: ";B[cc];W[]")) == 1)
        #expect(SelfPlayGame.trailingPassCount(inSgf: Self.sgf(moves: ";B[];W[]")) == 2)
        // A pass in the middle is not a trailing pass.
        #expect(SelfPlayGame.trailingPassCount(inSgf: Self.sgf(moves: ";B[];W[dd]")) == 0)
        // Clamped: never reports more than 2.
        #expect(SelfPlayGame.trailingPassCount(inSgf: Self.sgf(moves: ";B[];W[];B[]")) == 2)
    }

    @Test func trailingPassCountIsZeroForAnEmptyGame() {
        #expect(SelfPlayGame.trailingPassCount(inSgf: Self.sgf(moves: "")) == 0)
    }

    /// The handoff gate: a game that already ended must NOT push a live
    /// continuation (the engine would simply pass again).
    @Test func recordedGameIsFinishedForTwoTrailingPasses() {
        #expect(SelfPlayGame.recordedGameIsFinished(sgf: Self.sgf(moves: ";B[];W[]")))
    }

    @Test func recordedGameIsFinishedForAResultTag() {
        let resigned = "(;FF[4]GM[1]SZ[9]KM[7]RU[koSIMPLEscoreAREAtaxNONEsui0whbN]RE[W+R];B[cc])"
        #expect(SelfPlayGame.recordedGameIsFinished(sgf: resigned))
    }

    @Test func anUnfinishedGameIsNotFinished() {
        #expect(!SelfPlayGame.recordedGameIsFinished(sgf: Self.sgf(moves: ";B[cc];W[dd]")))
        #expect(!SelfPlayGame.recordedGameIsFinished(sgf: Self.sgf(moves: ";B[cc];W[]")))
    }
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd "ios/KataGo iOS" && set -o pipefail && xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/SelfPlayGameTests" 2>&1 | tail -30
```
Expected: `** TEST FAILED **` with `type 'SelfPlayGame' has no member 'trailingPassCount'`.

- [ ] **Step 3: Write the implementation**

Append inside `public enum SelfPlayGame` in `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/SelfPlayGame.swift`:

```swift
    // MARK: - Recorded-game completion

    /// How many of the SGF's LAST moves are passes, clamped at 2. Used to tell
    /// a game that ended from one that was merely abandoned mid-board.
    ///
    /// Not derived from `GobanState.passCount`: that is a running counter
    /// mutated only by `play`/`undo` and is never seeded from an SGF, so it
    /// says nothing about a game the user just opened.
    public static func trailingPassCount(inSgf sgf: String) -> Int {
        let operations = SgfOperations(sgf: sgf)
        guard let moveSize = operations.moveSize, moveSize > 0 else { return 0 }
        var count = 0
        var index = moveSize - 1
        while index >= 0, count < 2, let move = operations.getMove(at: index), move.location.pass {
            count += 1
            index -= 1
        }
        return count
    }

    /// True when the recorded game already ended — two trailing passes, or a
    /// parsed `RE[]` tag (a resignation has no passes at all).
    ///
    /// This is the Auto-Play handoff gate: continuing a finished game would
    /// seed the engine with a position it answers by passing twice, so the
    /// "continuation" would be a flash of the result card. Auto-Play stops on
    /// such a game instead of pushing.
    public static func recordedGameIsFinished(sgf: String) -> Bool {
        if result(fromSgf: sgf) != .unknown { return true }
        return trailingPassCount(inSgf: sgf) >= 2
    }
```

- [ ] **Step 4: Run to verify it passes**

Same command as Step 2. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev" && git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/SelfPlayGame.swift" "ios/KataGo iOS/KataGo iOSTests/SelfPlayGameTests.swift" && git commit -m "$(cat <<'EOF'
feat(tv): detect an already-finished recorded game from its SGF

Two trailing passes or an RE[] tag. Auto-Play uses this to stop at the end
instead of handing off to a live continuation the engine would answer by
passing twice.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
)"
```

---

### Task 3: `TVAutoPlayPolicy` — the per-tick decision

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Util/TVAutoPlayPolicy.swift`
- Test: `ios/KataGo iOS/KataGo iOSTests/TVAutoPlayPolicyTests.swift`

**Interfaces:**
- Consumes: `SelfPlayAttract.shouldStop(thermalState:)` (existing, `SelfPlayGame.swift:122-127`).
- Produces: `public enum TVAutoPlayStopReason`, `public enum TVAutoPlayTick`, `public enum TVAutoPlayPolicy` with `static func tick(hasNextMove:isBranchActive:stonesReady:recordedGameIsFinished:thermalState:) -> TVAutoPlayTick` and `static let handoffBeatSeconds: Double`. Consumed by Tasks 6 and 10.

- [ ] **Step 1: Write the failing test**

Create `ios/KataGo iOS/KataGo iOSTests/TVAutoPlayPolicyTests.swift`:

```swift
//
//  TVAutoPlayPolicyTests.swift
//  KataGo AnytimeTests
//

import Foundation
import Testing
@testable import KataGoUICore

struct TVAutoPlayPolicyTests {
    private func tick(hasNextMove: Bool = true,
                      isBranchActive: Bool = false,
                      stonesReady: Bool = true,
                      recordedGameIsFinished: Bool = false,
                      thermalState: ProcessInfo.ThermalState = .nominal) -> TVAutoPlayTick {
        TVAutoPlayPolicy.tick(hasNextMove: hasNextMove,
                              isBranchActive: isBranchActive,
                              stonesReady: stonesReady,
                              recordedGameIsFinished: recordedGameIsFinished,
                              thermalState: thermalState)
    }

    @Test func theHappyPathAdvancesOneMove() {
        #expect(tick() == .advance)
    }

    /// The board refresh from the previous move is still in flight: skip this
    /// tick rather than piling GTP batches into the queue.
    @Test func anUnreadyBoardHoldsTheTick() {
        #expect(tick(stonesReady: false) == .hold)
    }

    /// A variation is throwaway state; the mainline is what replays.
    @Test func anActiveBranchStops() {
        #expect(tick(isBranchActive: true) == .stop(.branchActive))
    }

    /// A fanless Apple TV must not replay a 250-move game while hot. Reuses
    /// the attract-mode thermal rule so both features agree.
    @Test func seriousAndCriticalThermalStateStop() {
        #expect(tick(thermalState: .serious) == .stop(.thermal))
        #expect(tick(thermalState: .critical) == .stop(.thermal))
        #expect(tick(thermalState: .fair) == .advance)
    }

    /// Branch and thermal outrank readiness: neither should be masked by a
    /// board that happens to be mid-refresh.
    @Test func branchAndThermalOutrankAnUnreadyBoard() {
        #expect(tick(isBranchActive: true, stonesReady: false) == .stop(.branchActive))
        #expect(tick(stonesReady: false, thermalState: .critical) == .stop(.thermal))
    }

    @Test func runningOutOfMovesInAnUnfinishedGameContinuesLive() {
        #expect(tick(hasNextMove: false, recordedGameIsFinished: false)
                == .finish(continuesLive: true))
    }

    /// The user decision: a game that already ended just stops.
    @Test func runningOutOfMovesInAFinishedGameDoesNotContinueLive() {
        #expect(tick(hasNextMove: false, recordedGameIsFinished: true)
                == .finish(continuesLive: false))
    }

    /// An unready board must not be mistaken for the end of the game.
    @Test func endOfGameIsOnlyReportedOnceTheBoardIsSettled() {
        #expect(tick(hasNextMove: false, stonesReady: false) == .hold)
    }
}
```

- [ ] **Step 2: Register the test file**

```bash
cd "ios/KataGo iOS" && ruby -e '
require "xcodeproj"
project = Xcodeproj::Project.open("KataGo Anytime.xcodeproj")
target = project.targets.find { |t| t.name == "KataGo AnytimeTests" }
group = project.main_group.find_subpath("KataGo iOSTests", false)
ref = group.new_reference("TVAutoPlayPolicyTests.swift")
target.source_build_phase.add_file_reference(ref)
project.save
'
```

- [ ] **Step 3: Run to verify it fails**

```bash
cd "ios/KataGo iOS" && set -o pipefail && xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/TVAutoPlayPolicyTests" 2>&1 | tail -30
```
Expected: `** TEST FAILED **` with `cannot find 'TVAutoPlayPolicy' in scope`.

- [ ] **Step 4: Write the implementation**

Create `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Util/TVAutoPlayPolicy.swift`:

```swift
//
//  TVAutoPlayPolicy.swift
//  KataGoUICore
//
//  The per-tick decision for TVReviewScreen's Auto-Play, kept pure so the whole
//  truth table is unit-testable from the iOS test host (the SelfPlayAttract
//  precedent). The TV screen owns only the Task loop that asks this what to do.
//

import Foundation

/// Why the POLICY stopped a running Auto-Play. Deliberately only the two
/// reasons the policy itself can detect: reaching the end is reported through
/// `TVAutoPlayTick.finish`, and the user-driven stops (a timeline step, a pick,
/// aiming, leaving the screen) never go through `tick` at all — the screen calls
/// its stop directly. Adding cases the policy cannot return would be dead code.
public enum TVAutoPlayStopReason: Equatable, Sendable {
    /// A variation is active — the mainline is what replays.
    case branchActive
    /// Thermal pressure on a fanless box.
    case thermal
}

public enum TVAutoPlayTick: Equatable, Sendable {
    /// Step exactly one recorded move forward.
    case advance
    /// Skip this tick: the previous move's board refresh is still in flight.
    case hold
    /// No recorded move is left. `continuesLive` is true only when the recorded
    /// game had NOT already ended, i.e. a live continuation is worth pushing.
    case finish(continuesLive: Bool)
    /// Stop for an interruption.
    case stop(TVAutoPlayStopReason)
}

public enum TVAutoPlayPolicy {
    /// How long the "Continuing live…" beat shows before the handoff push, so
    /// the screen change is announced rather than abrupt.
    public static let handoffBeatSeconds: Double = 2.0

    /// Decide what one Auto-Play tick should do.
    ///
    /// Order is load-bearing:
    /// 1. `isBranchActive` and thermal are hard stops that must not be masked
    ///    by an unsettled board.
    /// 2. `stonesReady` gates everything below it — including the end-of-game
    ///    test, because reporting the end while a move is still landing would
    ///    hand off from a position the engine has not finished applying.
    /// 3. `hasNextMove` is checked BEFORE any call to `forwardMoves`: at the end
    ///    of a game that call executes zero moves but still emits `showboard`
    ///    plus a kata-analyze restart, so a driver that leaned on it being a
    ///    no-op would spam GTP forever.
    public static func tick(hasNextMove: Bool,
                            isBranchActive: Bool,
                            stonesReady: Bool,
                            recordedGameIsFinished: Bool,
                            thermalState: ProcessInfo.ThermalState) -> TVAutoPlayTick {
        if isBranchActive { return .stop(.branchActive) }
        if SelfPlayAttract.shouldStop(thermalState: thermalState) { return .stop(.thermal) }
        guard stonesReady else { return .hold }
        guard hasNextMove else { return .finish(continuesLive: !recordedGameIsFinished) }
        return .advance
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Same command as Step 3. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev" && git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Util/TVAutoPlayPolicy.swift" "ios/KataGo iOS/KataGo iOSTests/TVAutoPlayPolicyTests.swift" "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj" && git commit -m "$(cat <<'EOF'
feat(tv): add the pure Auto-Play tick policy

advance / hold / finish(continuesLive:) / stop(reason), with branch and
thermal outranking board readiness and the end-of-game test gated behind a
settled board.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
)"
```

---

### Task 4: `SelfPlaySeed` + the seeded record factory

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/SelfPlaySeed.swift`
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/SelfPlayGame.swift` (add `makeRecord(seed:)` after the existing `makeRecord(maxBoardLength:)`)
- Test: `ios/KataGo iOS/KataGo iOSTests/SelfPlaySeedTests.swift`

**Interfaces:**
- Consumes: `GameRecord.createGameRecord(sgf:currentIndex:name:scoreLeads:winRates:)`, `SelfPlayGame.moveTime`.
- Produces: `public struct SelfPlaySeed: Hashable, Sendable` with `sgf`, `moveCount`, `rule`, `name`, `scoreLeads`, `winRates`; and `SelfPlayGame.makeRecord(seed: SelfPlaySeed) -> GameRecord`. Consumed by Tasks 8, 9 and 10.

- [ ] **Step 1: Write the failing test**

Create `ios/KataGo iOS/KataGo iOSTests/SelfPlaySeedTests.swift`:

```swift
//
//  SelfPlaySeedTests.swift
//  KataGo AnytimeTests
//

import Foundation
import Testing
@testable import KataGoUICore

@MainActor
struct SelfPlaySeedTests {
    /// A 9x9 game two moves deep. The RU tag is mandatory — the C++ parser
    /// aborts the process without it.
    private static let sgf =
        "(;FF[4]GM[1]SZ[9]KM[7]RU[koSIMPLEscoreAREAtaxNONEsui0whbN];B[cc];W[gg])"

    private func seed(rule: Int = 1) -> SelfPlaySeed {
        SelfPlaySeed(sgf: Self.sgf,
                     moveCount: 2,
                     rule: rule,
                     name: "Kim vs Lee",
                     scoreLeads: [0: 0.5, 1: 1.5, 2: 2.5],
                     winRates: [0: 0.5, 1: 0.52, 2: 0.55])
    }

    @Test func theSeededRecordCarriesThePositionAtItsTip() {
        let record = SelfPlayGame.makeRecord(seed: seed())
        #expect(record.sgf == Self.sgf)
        // currentIndex MUST equal the SGF's move count: isOverwriting is
        // `currentIndex < moveSize && (isEditing || isBranchActive)`, and the
        // seeded record loads unlocked — a mid-game index would latch the
        // AI-overwrite confirmation, which no tvOS view renders.
        #expect(record.currentIndex == 2)
        #expect(record.name == "Kim vs Lee")
    }

    @Test func boardSizeAndKomiAreInheritedFromTheSgf() {
        let config = SelfPlayGame.makeRecord(seed: seed()).concreteConfig
        #expect(config.boardWidth == 9)
        #expect(config.boardHeight == 9)
        #expect(config.komi == 7)
    }

    /// createGameRecord derives board size and komi from the SGF but NOT the
    /// rule index — the same gap SampleGames.makeEarReddeningRecord patches.
    @Test func theRuleIndexIsCarriedExplicitly() {
        #expect(SelfPlayGame.makeRecord(seed: seed(rule: 1)).concreteConfig.rule == 1)
        #expect(SelfPlayGame.makeRecord(seed: seed(rule: 3)).concreteConfig.rule == 3)
    }

    /// The broadcast invariant: an asymmetric human-SL config makes BoardView's
    /// turn observer inject kata-set-param acks at every cycle start, which
    /// desyncs the ReportCollector FIFO. The continuation must be symmetric AI.
    @Test func bothSidesAreSymmetricFullStrengthAI() {
        let config = SelfPlayGame.makeRecord(seed: seed()).concreteConfig
        #expect(config.blackMaxTime == SelfPlayGame.moveTime)
        #expect(config.whiteMaxTime == SelfPlayGame.moveTime)
        #expect(config.effectiveHumanProfileForBlack == "AI")
        #expect(config.effectiveHumanProfileForWhite == "AI")
        #expect(config.isEqualBlackWhiteEffectiveHumanSettings)
    }

    /// The report generator's narration path is FoundationModels-only and
    /// tvOS has none; `.narrating` is not a settled stage, so leaving this on
    /// would park the broadcast's slide loop polling.
    @Test func theSeededConfigNeverAsksForLLMNarration() {
        #expect(SelfPlayGame.makeRecord(seed: seed()).concreteConfig.useLLM == false)
    }

    /// Chart continuity: the continuation's score chart picks up where the
    /// reviewed game left off instead of starting empty.
    @Test func perMoveHistoryIsInherited() {
        let record = SelfPlayGame.makeRecord(seed: seed())
        #expect(record.scoreLeads?[2] == 2.5)
        #expect(record.winRates?[2] == 0.55)
    }

    /// A seeded SGF never equals GameRecord.defaultSgf, so it loads LOCKED
    /// unless the caller requests the one-shot unlock. Pinning it here is what
    /// makes TVSelfPlayScreen's unconditional `unlockEditingOnReload = true`
    /// load-bearing rather than incidental.
    @Test func aSeededSgfWouldLoadLockedWithoutTheOneShotUnlock() {
        #expect(!GobanState.editingAfterLoad(sgf: Self.sgf, unlockRequested: false))
        #expect(GobanState.editingAfterLoad(sgf: Self.sgf, unlockRequested: true))
    }

    @Test func theSeedIsHashableSoItCanRideInANavigationPath() {
        #expect(seed() == seed())
        #expect(Set([seed(), seed()]).count == 1)
    }
}
```

- [ ] **Step 2: Register the test file**

```bash
cd "ios/KataGo iOS" && ruby -e '
require "xcodeproj"
project = Xcodeproj::Project.open("KataGo Anytime.xcodeproj")
target = project.targets.find { |t| t.name == "KataGo AnytimeTests" }
group = project.main_group.find_subpath("KataGo iOSTests", false)
ref = group.new_reference("SelfPlaySeedTests.swift")
target.source_build_phase.add_file_reference(ref)
project.save
'
```

- [ ] **Step 3: Run to verify it fails**

```bash
cd "ios/KataGo iOS" && set -o pipefail && xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/SelfPlaySeedTests" 2>&1 | tail -30
```
Expected: `** TEST FAILED **` with `cannot find 'SelfPlaySeed' in scope`.

- [ ] **Step 4: Write `SelfPlaySeed`**

Create `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/SelfPlaySeed.swift`:

```swift
//
//  SelfPlaySeed.swift
//  KataGoUICore
//
//  The value carried from TVReviewScreen into TVSelfPlayScreen when Auto-Play
//  reaches the end of an unfinished recorded game and hands off to a live AI
//  continuation.
//
//  A VALUE, not a GameRecord or a PersistentIdentifier: it rides inside a
//  NavigationPath (which requires only Hashable), and a freshly built model
//  carries a temporary identifier that SwiftData remaps on save — which would
//  change the route's hash after it is already on the path.
//

import Foundation

public struct SelfPlaySeed: Hashable, Sendable {
    /// The reviewed game's SGF, verbatim. Board size, komi and rules ride
    /// inside it: `loadGame` overwrites the Config's rule/komi fields from the
    /// SGF on every load, so carrying them on the Config alone would be lost.
    public let sgf: String
    /// The SGF's move count. The seeded record sits at its TIP so
    /// `isOverwriting` stays false and `loadGame`'s rewind loop runs zero times.
    public let moveCount: Int
    /// `Config.rule`, the one field `createGameRecord` does NOT derive from the
    /// SGF.
    public let rule: Int
    /// Shown as the continuation's title, so it does not claim to be the demo.
    public let name: String
    /// Per-move history so the continuation's chart continues the reviewed
    /// game's curve instead of starting empty.
    public let scoreLeads: [Int: Float]
    public let winRates: [Int: Float]

    public init(sgf: String,
                moveCount: Int,
                rule: Int,
                name: String,
                scoreLeads: [Int: Float] = [:],
                winRates: [Int: Float] = [:]) {
        self.sgf = sgf
        self.moveCount = moveCount
        self.rule = rule
        self.name = name
        self.scoreLeads = scoreLeads
        self.winRates = winRates
    }
}
```

- [ ] **Step 5: Write `makeRecord(seed:)`**

Append inside `public enum SelfPlayGame`, directly after the existing `makeRecord(maxBoardLength:)`:

```swift
    /// A live-continuation record seeded from a reviewed game's final position.
    ///
    /// Built on `createGameRecord` — NOT `GameRecord.clone()`, which copies the
    /// source Config wholesale (human-SL profiles, per-side max times) and would
    /// hand a Human-vs-9d game off as Human-vs-9d, never moving. The fresh
    /// `Config()` inside the factory already resolves both effective human
    /// profiles to "AI"; this only adds the per-move times, the rule index the
    /// factory does not derive from the SGF, and `useLLM = false` (tvOS has no
    /// FoundationModels, and `.narrating` is not a settled report stage).
    ///
    /// The caller owns keeping this record OUT of the CloudKit store — insert it
    /// into an in-memory container only. Every continuation move mutates it.
    @MainActor
    public static func makeRecord(seed: SelfPlaySeed) -> GameRecord {
        let record = GameRecord.createGameRecord(sgf: seed.sgf,
                                                 currentIndex: seed.moveCount,
                                                 name: seed.name,
                                                 scoreLeads: seed.scoreLeads,
                                                 winRates: seed.winRates)
        let config = record.concreteConfig
        config.rule = seed.rule
        config.blackMaxTime = moveTime
        config.whiteMaxTime = moveTime
        config.useLLM = false
        return record
    }
```

- [ ] **Step 6: Run to verify it passes**

Same command as Step 3. Expected: `** TEST SUCCEEDED **`.

(`Config.useLLM` is verified to exist at `KataGoUICore/Sources/KataGoGameStore/ConfigModel.swift:743`.)

- [ ] **Step 7: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev" && git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/SelfPlaySeed.swift" "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/SelfPlayGame.swift" "ios/KataGo iOS/KataGo iOSTests/SelfPlaySeedTests.swift" "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj" && git commit -m "$(cat <<'EOF'
feat(tv): add the live-continuation seed and its record factory

A Hashable value that rides in a NavigationPath, plus a factory that builds
the in-memory continuation record on a FRESH symmetric Config — never
GameRecord.clone(), which would inherit human-SL profiles and stall the
broadcast's report collector.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
)"
```

---

### Task 5: Settings — the Playback (Auto-Play Speed) section

**Files:**
- Modify: `ios/KataGo iOS/KataGo Anytime TV/TVSettingsScreen.swift` (property after line 21; `playbackSection` after `boardSizeSection`; body insertion after line 44)

**Interfaces:**
- Consumes: `TVAutoPlaySpeed` (Task 1).
- Produces: the persisted value under `TVAutoPlaySpeed.defaultsKey`, read by Task 6.

- [ ] **Step 1: Add the persisted property**

In `TVSettingsScreen.swift`, directly after `@AppStorage("TVSettings.showMemoryOverlay") private var showMemoryOverlay = false` (line 21):

```swift
    /// Auto-Play cadence on the review screen. A plain @AppStorage (unlike
    /// `boardSize`, whose key is derived from a model file name at runtime and
    /// therefore needs the @State + BackendSettings round-trip).
    @AppStorage(TVAutoPlaySpeed.defaultsKey) private var autoPlaySpeed = TVAutoPlaySpeed.defaultValue
```

- [ ] **Step 2: Add the section**

Insert a new `// MARK: - Playback` block immediately after the `boardSizeSection` property:

```swift
    // MARK: - Playback

    private var playbackSection: some View {
        section("Playback") {
            Picker("Auto-Play Speed", selection: $autoPlaySpeed) {
                ForEach(TVAutoPlaySpeed.allCases) { speed in
                    Text(speed.label).tag(speed)
                }
            }
            .pickerStyle(.segmented)
            // Deliberately NO .disabled(engine.phase…) and NO .onChange:
            // unlike Max Board Size, a speed change must never restart the
            // engine, and the review screen re-reads the key every tick.

            Text("How fast Auto-Play steps through a saved game's recorded moves. Start and stop Auto-Play with the Play/Pause button while reviewing a game.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
```

- [ ] **Step 3: Compose it into the body**

In `var body`, change the section list so `playbackSection` follows `boardSizeSection`:

```swift
                recoverySection
                boardSizeSection
                playbackSection
                soundSection
                aboutSection
                diagnosticsFooter
```

- [ ] **Step 4: Build the TV scheme**

```bash
cd "ios/KataGo iOS" && set -o pipefail && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime TV" -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Visually verify the new section**

Use the Xcode MCP `RenderPreview` with `sourceFilePath: "KataGo Anytime TV/TVSettingsScreen.swift"`, `previewDefinitionIndexInFile: 0`, active scheme `KataGo Anytime TV`. Confirm the Playback card renders between Board Size and Sound, the segmented picker shows Slow / Normal / Fast left-to-right, and Normal is selected.

- [ ] **Step 6: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev" && git add "ios/KataGo iOS/KataGo Anytime TV/TVSettingsScreen.swift" && git commit -m "$(cat <<'EOF'
feat(tv): add the Auto-Play Speed picker to Settings

Board Size's picker chrome with Sound's persistence: no engine restart, no
mirroring — the review screen re-reads the key each tick.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
)"
```

---

### Task 6: TVReviewScreen — the Auto-Play control and its driver

**Files:**
- Modify: `ios/KataGo iOS/KataGo Anytime TV/TVReviewScreen.swift` (state block after line 73; the panel bottom at lines 326-330; a new `autoPlayToggle`; `stepBy`, `submit`, the board-focus `onChange`, `onExitCommand`, `onDisappear`, and the `reviewContent` modifier chain)

**Interfaces:**
- Consumes: `TVAutoPlaySpeed.interval` (Task 1), `SelfPlayGame.recordedGameIsFinished(sgf:)` (Task 2), `TVAutoPlayPolicy.tick(...)` / `TVAutoPlayTick` (Task 3), `GobanState.getNextMove(gameRecord:)`, `GobanState.forwardMoves(limit:gameRecord:board:messageList:player:audioModel:stones:)`.
- Produces: `private func toggleAutoPlay()`, `private func stopAutoPlay()`, `private func advanceOneMove()`, and `private func finishAutoPlay(continuesLive:)` — the last is completed by the handoff in Task 10.

> **Layout, settled by measurement.** A first attempt STACKED a second full-width `TVToggleButton` above Analysis. It does not fit: on tvOS 26.5 the "Analysis On" pill ran **16 pt off the bottom of the screen**, and **46 pt** would have had to come out of the panel to sit inside its designed content area. Two fallbacks were tried and recovered only 7.5 pt. The decisive finding: **tvOS 26.5's `.bordered` / `.borderedProminent` style floors a pill at 66 pt regardless of `minHeight`**, so shrinking `minHeight` gains nothing — a height fix must change the button style or the font, not the frame.
>
> The remedy keeps the panel at 500 pt and keeps ONE control row: the Auto-Play control becomes a compact **icon-only** button placed BESIDE the Analysis toggle. One row means zero added height, so the overflow disappears rather than being shaved. The symbol carries the state (`play.fill` → `pause.fill`), so there is no "On/Off" text to shrink, and at ~96 pt wide it leaves the Analysis pill ~388 pt against a 379.5 pt intrinsic width — no truncation. **Step 9 is still a hard gate:** verify it on the simulator, and if it clips, STOP and report rather than shaving further.

- [ ] **Step 1: Add the state**

In `TVReviewScreen.swift`, after `@State private var highlightedPoint: BoardPoint?` (line 73) and before `private var config: Config` (line 75):

```swift
    /// Auto-Play: the recorded moves advancing on a timer. Plain state, NOT
    /// `GobanState.isAutoPlaying` — that flag is the iOS wand's, is consulted
    /// by ~10 live guards (AnalysisView, BoardView, the asymmetric human-SL
    /// sends), is force-cleared by loadGame, and the only code that restores
    /// what it suppresses lives in the iOS target and is not compiled for tvOS.
    @State private var isAutoPlaying = false
    /// The running tick loop, cancelled by every stop path.
    @State private var autoPlayTask: Task<Void, Never>?
    /// Auto-Play cadence, re-read every tick so a change in Settings applies on
    /// return without restarting the driver.
    @AppStorage(TVAutoPlaySpeed.defaultsKey) private var autoPlaySpeed = TVAutoPlaySpeed.defaultValue
```

- [ ] **Step 2: Add the compact icon button type**

Beside the existing `TVToggleButton` definition near the bottom of the file:

```swift
/// The Auto-Play transport. Icon-only, and NOT greedy, so it fits beside the
/// Analysis toggle in the panel's single control row — two full-width toggles
/// stacked overflow the 1020 pt panel by 46 pt (measured on tvOS 26.5), and
/// `minHeight` cannot fix that because the bordered style floors a pill at
/// 66 pt. One row costs zero extra height.
///
/// The SYMBOL carries the state (play → pause), so there is no "On/Off" label
/// to shrink; `accessibilityLabel` is what names the control for VoiceOver.
/// Styling otherwise mirrors TVToggleButton so the two pills read as a set.
private struct TVIconToggleButton: View {
    let systemName: String
    let accessibilityLabel: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        let content = Image(systemName: systemName)
            .font(.title3)
            // No `.frame(width:minHeight:)` overload exists — pin the width
            // with matching min/max so the pill stays narrow beside Analysis.
            .frame(minWidth: 36, maxWidth: 36, minHeight: 56)

        if isOn {
            // Dark glyph on the wood fill unfocused; the focused white lift
            // also takes a dark glyph, so forcing black is safe in both states.
            Button(action: action) { content.foregroundStyle(.black) }
                .buttonStyle(.borderedProminent)
                .tint(.tvWoodAccent)
                .accessibilityLabel(accessibilityLabel)
        } else {
            Button(action: action) { content }
                .buttonStyle(.bordered)
                .accessibilityLabel(accessibilityLabel)
        }
    }
}
```

- [ ] **Step 3: Add the Auto-Play control and put it in the existing row**

Directly above the existing `analysisToggle` property:

```swift
    /// Auto-Play: step the recorded moves on a timer. Disabled while a
    /// variation is active — the mainline is what replays — which is also why
    /// `$toggleFocused` stays on the Analysis button: it is the timeline's
    /// programmatic down-hop target and must never be unfocusable.
    private var autoPlayToggle: some View {
        TVIconToggleButton(systemName: isAutoPlaying ? "pause.fill" : "play.fill",
                           accessibilityLabel: "Auto-Play",
                           isOn: isAutoPlaying) {
            toggleAutoPlay()
        }
        .disabled(gobanState.isBranchActive)
    }
```

Then replace panel lines 326-330 — ONE row, so the panel's vertical budget is unchanged:

```swift
            Spacer()

            HStack(spacing: 16) {
                autoPlayToggle

                analysisToggle
                    .focused($toggleFocused)
            }
        }
```

- [ ] **Step 4: Write the driver**

Add a `// MARK: - Auto-Play` block beside the other actions:

```swift
    // MARK: - Auto-Play

    private func toggleAutoPlay() {
        if isAutoPlaying {
            stopAutoPlay()
        } else {
            startAutoPlay()
        }
    }

    /// Start replaying the recorded moves. Already parked at the last move is
    /// not an error: there is nothing to replay, so this reports the end
    /// immediately (Task 10 turns that into the live handoff).
    private func startAutoPlay() {
        guard !gobanState.isBranchActive, !isAutoPlaying else { return }
        guard gobanState.getNextMove(gameRecord: game) != nil else {
            finishAutoPlay(continuesLive: !SelfPlayGame.recordedGameIsFinished(sgf: game.sgf))
            return
        }
        isAutoPlaying = true
        // Lean-back viewing with no remote input: keep the system screensaver
        // from covering the replay (the TVSelfPlayScreen precedent).
        UIApplication.shared.isIdleTimerDisabled = true
        autoPlayTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: autoPlaySpeed.interval)
                guard !Task.isCancelled else { return }
                switch TVAutoPlayPolicy.tick(
                    hasNextMove: gobanState.getNextMove(gameRecord: game) != nil,
                    isBranchActive: gobanState.isBranchActive,
                    stonesReady: stones.isReady,
                    recordedGameIsFinished: SelfPlayGame.recordedGameIsFinished(sgf: game.sgf),
                    thermalState: ProcessInfo.processInfo.thermalState
                ) {
                case .hold:
                    continue
                case .advance:
                    advanceOneMove()
                case .finish(let continuesLive):
                    finishAutoPlay(continuesLive: continuesLive)
                    return
                case .stop:
                    // The reason is the policy's testable output, not
                    // something this screen acts on differently.
                    stopAutoPlay()
                    return
                }
            }
        }
    }

    /// Every stop path funnels here. Safe to call from inside the tick loop:
    /// cancelling the task that is running is fine because the caller returns
    /// immediately afterwards.
    private func stopAutoPlay() {
        guard isAutoPlaying || autoPlayTask != nil else { return }
        isAutoPlaying = false
        autoPlayTask?.cancel()
        autoPlayTask = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Reached the end of the recorded moves. Task 10 adds the live handoff for
    /// an unfinished game; a finished game stops here for good.
    private func finishAutoPlay(continuesLive: Bool) {
        stopAutoPlay()
    }

    /// One recorded move forward. Deliberately NOT routed through `stepBy`,
    /// which stops Auto-Play — a tick calling it would cancel its own timer.
    private func advanceOneMove() {
        gobanState.forwardMoves(limit: 1, gameRecord: game, board: board,
                                messageList: messageList, player: player,
                                audioModel: audioModel, stones: stones)
        reanalyze()
    }
```

- [ ] **Step 5: Make every manual step stop Auto-Play**

Add the stop as the first line of `stepBy` (this covers the timeline's click-step, its 10-move swipe, its hold-repeat scrub, and the controller's L1/R1 in Task 13 — every caller is a user action; the Auto-Play tick uses `advanceOneMove` instead):

```swift
    private func stepBy(_ delta: Int) {
        // Any manual step is the user taking over. The Auto-Play tick calls
        // advanceOneMove() directly, so this can never cancel its own timer.
        stopAutoPlay()
        // Drop ticks while a previous batch's board refresh is in flight
        …unchanged…
```

- [ ] **Step 6: Stop on a pick, on aiming, on Menu, and on exit**

At the top of `submit(vertex:)`, before its guards (covers both a Top Moves pick and a board-cursor play, and stops even when the guards reject the move):

```swift
    private func submit(vertex: String) {
        // Playing a variation takes over from the replay.
        stopAutoPlay()
        guard stones.isReady,
        …unchanged…
```

In the board-focus `onChange`, inside the `if focused` arm:

```swift
                .onChange(of: boardFocused) { _, focused in
                    isAiming = focused
                    if focused {
                        // Aiming the play cursor is taking over.
                        stopAutoPlay()
                        ghost.activate(width: Int(board.width),
                                       height: Int(board.height))
                    } else {
                        ghost.reset()
                    }
                }
```

In `onExitCommand`, as the first statement of the closure (both arms — the aiming arm is a user interaction, the dismiss arm stops early rather than waiting for `onDisappear`):

```swift
        .onExitCommand {
            stopAutoPlay()
            if boardFocused {
```

In `onDisappear`, as the first statement:

```swift
        .onDisappear {
            stopAutoPlay()
            // Silent discard (user decision): variations explored here are
            …unchanged…
```

- [ ] **Step 7: Wire the remote's Play/Pause**

Add to the `reviewContent` modifier chain, immediately after `.defaultFocus($timelineFocused, true)` and before `.onExitCommand`:

```swift
        // The transport button. Attached here — above the panel's
        // `.disabled(isAiming)` subtree and inside the boardFits gate, so the
        // too-large branch stays engine-free. Ignored while aiming: the board
        // cursor owns the screen then, and board focus is itself a stop.
        .onPlayPauseCommand {
            guard !isAiming else { return }
            toggleAutoPlay()
        }
```

- [ ] **Step 8: Stop on thermal pressure even between ticks**

Add to the same chain (the `TVSelfPlayScreen` precedent — read the state fresh from `ProcessInfo`, never capture the non-Sendable `Notification`):

```swift
        .onReceive(NotificationCenter.default
            .publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: RunLoop.main)) { _ in
                if SelfPlayAttract.shouldStop(thermalState: ProcessInfo.processInfo.thermalState) {
                    stopAutoPlay()
                }
            }
```

- [ ] **Step 9: Build, run the suite, then GATE on the real layout**

```bash
cd "ios/KataGo iOS" && set -o pipefail && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime TV" -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | tail -5
cd "ios/KataGo iOS" && set -o pipefail && xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **` and `** TEST SUCCEEDED **`.

Now verify the panel on the real simulator. **Do NOT use the Xcode MCP `RenderPreview` for this** — it was measured timing out after 30 minutes on this project, because a preview build compiles the C++ engine. Use a pixel-exact simulator screenshot instead:

1. Add a TEMPORARY route push in `TVRootView.swift`'s engine-ready `.task`, gated on `ProcessInfo.processInfo.arguments.contains("-qaAutoPlay")`, that pushes the bundled sample game onto `libraryPath`.
2. Build the TV scheme, install and launch:
```bash
xcrun simctl list devices booted | grep -i "apple tv"
xcrun simctl install <APPLE_TV_UDID> "DerivedData/KataGo Anytime/Build/Products/Debug-appletvsimulator/KataGo TV.app"
xcrun simctl launch <APPLE_TV_UDID> <BUNDLE_ID> -qaAutoPlay
```
(Get the bundle id from `xcrun simctl listapps <UDID> | grep -i katago`.)
3. Wait for the engine to boot, then capture the native 1920×1080 frame:
```bash
xcrun simctl io <APPLE_TV_UDID> screenshot /tmp/tv-review-panel.png
```
4. Read the screenshot. **The Analysis label must be fully legible and untruncated, BOTH pills fully on screen with the row entirely inside the panel, and the board still a 1080 pt square.** The Auto-Play pill is icon-only, so check its glyph is centred and not clipped. Capture it twice — once with analysis ON (the tallest layout, 3 Top Moves rows) and once after playing a variation move so the Exit Variation row is present and Auto-Play is disabled (dimmed).
5. REVERT the temporary route push.

Record the observation explicitly in the commit body.

- [ ] **Step 10: If it clips, STOP**

Do NOT shave further. The two obvious fallbacks were already tried on the stacked design and recovered 7.5 pt against a 46 pt deficit, and `minHeight` is inert because the bordered style floors a pill at 66 pt. If the single row still clips, or the Analysis label truncates, report BLOCKED with the screenshot path and what you measured — the remaining options (widening the panel, restyling both pills away from the system button style) reverse decisions the user has already made and are not yours to take.

- [ ] **Step 11: Simulator smoke test of the replay itself**

With the same temporary route push still in place, drive the app with **Window ▸ Show Apple TV Remote** (⇧⌘R — synthetic keyboard events never reach the tvOS simulator, and the remote window must be the ACTIVE window or macOS eats its first click as click-to-activate). Verify: Play/Pause starts the replay; stones appear at ~1.5 s intervals; the toggle reads "Auto-Play On"; a left/right click on the timeline stops it. Then REVERT the temporary hack and confirm `git status` is clean of it.

- [ ] **Step 12: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev" && git add "ios/KataGo iOS/KataGo Anytime TV/TVReviewScreen.swift" && git commit -m "$(cat <<'EOF'
feat(tv): replay a saved game's recorded moves on a timer

Play/Pause (or the new Auto-Play toggle) starts a cancellable tick loop that
asks the pure policy what to do each tick: advance, hold while the board
refresh is in flight, or stop. Every manual navigation stops it; so does
thermal pressure. The Analysis setting is never touched.

The control is an icon-only pill beside the Analysis toggle, not a second
full-width row: stacking overflowed the 1020 pt panel by 46 pt, and minHeight
cannot fix that because tvOS floors a bordered pill at 66 pt. One row costs no
height, and the symbol carries the state so there is no label to truncate.
$toggleFocused stays on Analysis — it is the timeline's down-hop target, and
Auto-Play is disabled during a variation. Panel verified on the simulator.

Ends at the last recorded move — the live handoff lands in a later commit.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
)"
```

---
### Task 7: TVReviewScreen — re-normalize on every appearance (handoff prerequisite)

**Files:**
- Modify: `ios/KataGo iOS/KataGo Anytime TV/TVReviewScreen.swift` (`onDisappear`, `loadIfNeeded`)

> **Why this is not optional.** `loadIfNeeded` is one-shot behind `@State didLoad`, and that state survives a push. `TVSelfPlayScreen` sets `forcesBranchOnPlay = false` and (via `unlockEditingOnReload`) `isEditing = true`. Popping back into a review screen that does not re-normalize means the next Top Moves pick takes the **editing** path on a **CloudKit-synced record** — `clearData(after:)` truncation plus a printsgf overwrite of the synced SGF. That is the build-291 corruption class, re-opened.

- [ ] **Step 1: Reset the load latch and stop clobbering a foreign selection**

Replace the `onDisappear` closure body:

```swift
        .onDisappear {
            stopAutoPlay()
            // Silent discard (user decision): variations explored here are
            // throwaway — the synced record was never written.
            //
            // Identity-guarded: on a PUSH (the live handoff) SwiftUI can fire
            // the destination's onAppear BEFORE this, and TVSelfPlayScreen's
            // entry has already pointed the selection at its own seeded record.
            // An unconditional nil would strand its licensed gen-move reply in
            // postProcessAIMove's `if let gameRecord` and park the broadcast in
            // .awaitingMove forever.
            if navigationContext.selectedGameRecord === game {
                navigationContext.selectedGameRecord = nil
            }
            gobanState.deactivateBranch()
            gobanState.forcesBranchOnPlay = false
            gobanState.maybePauseAnalysis()
            // Re-arm the entry protocol for the next appearance. Without this
            // a pop back from the live continuation resumes with isEditing ==
            // true and forcesBranchOnPlay == false inherited from the self-play
            // screen — the editing path on a synced record (build-291).
            didLoad = false
        }
```

- [ ] **Step 2: Change nothing else in `loadIfNeeded`**

It already re-asserts `suppressesGenMove = true`, `forcesBranchOnPlay = true`, `selectedGameRecord = nil`, `loadGame(...)`, `isEditing = false`, `totalMoves`, and the `.pause → .run` analysis normalization. With Step 1's latch reset, all of that now runs again on a pop-back. **Do not add a `passCount` reset here** — a continuation that ended on two passes is handled at the source, in the seeded teardown (Task 9 Step 4), and resetting it here would also silence analysis for anyone simply opening a finished game from the library, which works today.

- [ ] **Step 3: Build and run the full suite**

```bash
cd "ios/KataGo iOS" && set -o pipefail && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime TV" -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | tail -5
cd "ios/KataGo iOS" && set -o pipefail && xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **` and `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev" && git add "ios/KataGo iOS/KataGo Anytime TV/TVReviewScreen.swift" && git commit -m "$(cat <<'EOF'
fix(tv): re-run the review screen's entry protocol on every appearance

didLoad is @State and survives a push, so returning from a pushed screen
resumed review with isEditing == true and forcesBranchOnPlay == false —
routing the next pick through the editing path on a CloudKit-synced record
(the build-291 corruption class). Reset the latch on disappear, guard the
selection clear by identity so a push cannot strand the destination's own
selection, and resync passCount from the SGF.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
)"
```

---

### Task 8: Navigation plumbing for the handoff

**Files:**
- Modify: `ios/KataGo iOS/KataGo Anytime TV/TVSelfPlayScreen.swift:25-34` (`SelfPlayRoute`)
- Modify: `ios/KataGo iOS/KataGo Anytime TV/TVReviewScreen.swift` (a defaulted `onContinueLive` closure property)
- Modify: `ios/KataGo iOS/KataGo Anytime TV/TVRootView.swift:69-95` (a Search-tab path + both destinations)

**Interfaces:**
- Consumes: `SelfPlaySeed` (Task 4).
- Produces: `SelfPlayRoute(entry:seed:)`, `TVReviewScreen.onContinueLive: ((SelfPlaySeed) -> Void)?`. Consumed by Tasks 9 and 10.

- [ ] **Step 1: Give the route a defaulted seed**

In `TVSelfPlayScreen.swift`, replace the `SelfPlayRoute` declaration:

```swift
struct SelfPlayRoute: Hashable {
    enum Entry: Hashable {
        /// User chose the card — Menu exits, other presses are ignored.
        case manual
        /// Idle attract mode started it — ANY remote press exits.
        case attract
    }

    let entry: Entry
    /// Set when Auto-Play handed off at the end of an unfinished recorded game:
    /// the continuation starts from that position instead of an empty board,
    /// and pops back to review when it ends instead of restarting.
    ///
    /// `var` with a default (not `let`): a `let` with an initial value is
    /// dropped from the memberwise init entirely, which would break all four
    /// existing `SelfPlayRoute(entry:)` call sites.
    var seed: SelfPlaySeed? = nil
}
```

- [ ] **Step 2: Give the review screen a handoff seam**

In `TVReviewScreen.swift`, after the `#if DEBUG previewSkipsLoad` block and before the `@Environment` list:

```swift
    /// Supplied by the navigationDestination that created this screen, so the
    /// handoff pushes onto the SAME stack the user is looking at. A single
    /// root-level closure would append to the Library path even when the
    /// visible stack is Search.
    var onContinueLive: ((SelfPlaySeed) -> Void)? = nil
```

- [ ] **Step 3: Register the destination on both stacks and give Search a path**

In `TVRootView.swift`, add beside `libraryPath`:

```swift
    /// The Search tab's own stack path. Separate from `libraryPath`: the live
    /// handoff must push onto whichever stack the review screen was opened on.
    @State private var searchPath = NavigationPath()
```

Then replace the two `NavigationStack` blocks:

```swift
                    NavigationStack(path: $libraryPath) {
                        TVLibraryView()
                            .navigationDestination(for: GameRecord.self) { game in
                                TVReviewScreen(game: game, onContinueLive: { seed in
                                    libraryPath.append(SelfPlayRoute(entry: .manual, seed: seed))
                                })
                                    .toolbar(.hidden, for: .tabBar)
                            }
                            .navigationDestination(for: SelfPlayRoute.self) { route in
                                TVSelfPlayScreen(route: route)
                                    .toolbar(.hidden, for: .tabBar)
                            }
                    }
                    .tabItem { Label("Library", systemImage: "square.grid.2x2") }
                    .tag(TVTab.library)

                    // Search is its own tab so tvOS renders its full-screen
                    // keyboard there instead of pinning it above the Library
                    // grid. Selecting a result pushes review inside this stack —
                    // which therefore needs the SelfPlayRoute destination too,
                    // or the live handoff silently no-ops for a game opened
                    // from Search.
                    NavigationStack(path: $searchPath) {
                        TVSearchView()
                            .navigationDestination(for: GameRecord.self) { game in
                                TVReviewScreen(game: game, onContinueLive: { seed in
                                    searchPath.append(SelfPlayRoute(entry: .manual, seed: seed))
                                })
                                    .toolbar(.hidden, for: .tabBar)
                            }
                            .navigationDestination(for: SelfPlayRoute.self) { route in
                                TVSelfPlayScreen(route: route)
                                    .toolbar(.hidden, for: .tabBar)
                            }
                    }
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                    .tag(TVTab.search)
```

- [ ] **Step 4: Leave attract mode alone**

No change is needed and none should be made. `refreshAttractIdle()` already reads `let idleAtLibrary = (selectedTab == .library) && libraryPath.isEmpty` (`TVRootView.swift:265-266`), so a Search-tab drill-down already disarms attract via the tab term, and a Library-tab push already disarms it via the path term. Adding `searchPath` to that condition would be redundant.

- [ ] **Step 5: Build**

```bash
cd "ios/KataGo iOS" && set -o pipefail && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime TV" -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev" && git add "ios/KataGo iOS/KataGo Anytime TV/TVSelfPlayScreen.swift" "ios/KataGo iOS/KataGo Anytime TV/TVReviewScreen.swift" "ios/KataGo iOS/KataGo Anytime TV/TVRootView.swift" && git commit -m "$(cat <<'EOF'
feat(tv): carry a continuation seed on the self-play route

SelfPlayRoute gains a defaulted seed (var, so the four existing call sites
keep compiling), the review screen gains a handoff closure supplied by
whichever navigationDestination created it, and the Search tab gets its own
path plus the SelfPlayRoute destination — without it the handoff would push
into an invisible stack.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
)"
```

---

### Task 9: TVSelfPlayScreen — seeded entry, seeded exit

**Files:**
- Modify: `ios/KataGo iOS/KataGo Anytime TV/TVSampleGameStore.swift` (a seeded factory)
- Modify: `ios/KataGo iOS/KataGo Anytime TV/TVSelfPlayScreen.swift` (`startIfNeeded`, `scheduleRestart`, `tearDown`, the panel title, the interstitial copy)

**Interfaces:**
- Consumes: `SelfPlaySeed`, `SelfPlayGame.makeRecord(seed:)`, `SelfPlayGame.trailingPassCount(inSgf:)`.
- Produces: a self-play screen that starts from a seeded position and pops back when the game ends.

- [ ] **Step 1: Add the seeded factory**

In `TVSampleGameStore.swift`, beside `newSelfPlayGame(maxBoardLength:)`:

```swift
    /// A live-continuation game seeded from a reviewed position, inserted into
    /// the SAME private in-memory container as the demo — so a continuation of
    /// a CloudKit-synced game can never itself reach iCloud.
    ///
    /// Deliberately no `maxBoardLength` clamp: `createGameRecord` only swaps in
    /// a smaller default board when the SGF IS `defaultSgf`, and a seeded SGF
    /// never is. The reviewed board already passed `TVReviewScreen`'s
    /// `boardFits` gate, which is what keeps an oversized board away from the
    /// engine.
    static func newSelfPlayGame(seed: SelfPlaySeed) -> GameRecord? {
        guard let container else { return nil }
        let record = SelfPlayGame.makeRecord(seed: seed)
        container.mainContext.insert(record)
        return record
    }
```

- [ ] **Step 2: Use the seed in `startIfNeeded`**

Replace the record-creation line in `startIfNeeded`:

```swift
        let created = route.seed.map { TVSampleGameStore.newSelfPlayGame(seed: $0) }
            ?? TVSampleGameStore.newSelfPlayGame(maxBoardLength: engine.maxBoardLength)
        guard let newGame = created else {
            dismiss()
            return
        }
        game = newGame
```

Then replace the unconditional `gobanState.passCount = 0` with a seed-aware version:

```swift
        // A prior review session stepping through recorded passes leaves this
        // nonzero, which would veto the first gen-move. A SEEDED game must not
        // be zeroed blindly either: its position may legitimately carry one
        // trailing pass, and the engine's loaded history has it.
        gobanState.passCount = route.seed.map {
            SelfPlayGame.trailingPassCount(inSgf: $0.sgf)
        } ?? 0
```

Everything else in `startIfNeeded` stays byte-identical — in particular `unlockEditingOnReload = true`, which a seeded (non-`defaultSgf`) record needs exactly as much as a clamped demo board does.

- [ ] **Step 3: Pop back instead of restarting**

In `scheduleRestart()`, branch the tail of the task:

```swift
    private func scheduleRestart() {
        guard restartTask == nil else { return }
        restartTask = Task {
            try? await Task.sleep(for: .seconds(SelfPlayGame.interstitialSeconds))
            guard !Task.isCancelled else { return }
            restartTask = nil
            // A seeded continuation is a finite excursion from one reviewed
            // game: show the result, then hand the user back to review. Only
            // the demo loops into a fresh game.
            if route.seed != nil {
                dismiss()
            } else {
                restart()
            }
        }
    }
```

- [ ] **Step 4: Hand back the state a pop does not otherwise restore**

In `tearDown()`, after the existing analysis-restore block and before the `discard`:

```swift
        // Seeded exits return to TVReviewScreen, whose spectator protections
        // this screen switched off. Restore them here so EVERY exit path (the
        // result pop, Menu, a thermal dismiss) is covered, not just the happy
        // one. The review screen re-asserts them too, in loadIfNeeded — this is
        // belt and braces, and it is what keeps the window between the pop and
        // the reload safe.
        if route.seed != nil {
            gobanState.passCount = 0
            gobanState.isEditing = false
            gobanState.forcesBranchOnPlay = true
        }
```

- [ ] **Step 5: Stop claiming to be the demo**

Panel title — replace `Text(SelfPlayGame.demoName)` with the record's own name:

```swift
            Text(game.name.isEmpty ? SelfPlayGame.demoName : game.name)
```

Interstitial third line — replace `Text("Next game starting…")` with a route-aware string:

```swift
            Text(route.seed == nil ? "Next game starting…" : "Returning to review…")
```

- [ ] **Step 6: Build and verify the previews still render**

```bash
cd "ios/KataGo iOS" && set -o pipefail && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime TV" -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`. Then `RenderPreview` `KataGo Anytime TV/TVSelfPlayScreen.swift` index 0 and confirm the demo still titles itself "KataGo vs KataGo".

- [ ] **Step 7: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev" && git add "ios/KataGo iOS/KataGo Anytime TV/TVSampleGameStore.swift" "ios/KataGo iOS/KataGo Anytime TV/TVSelfPlayScreen.swift" && git commit -m "$(cat <<'EOF'
feat(tv): let the self-play broadcast start from a seeded position

A seeded route builds its record from the reviewed game's SGF into the same
in-memory container, seeds passCount from the SGF's trailing passes rather
than zeroing it, titles itself after the real game, and pops back to review
when the game ends instead of looping into a fresh demo. Every seeded exit
restores the review screen's spectator flags.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
)"
```

---

### Task 10: Wire the handoff

**Files:**
- Modify: `ios/KataGo iOS/KataGo Anytime TV/TVReviewScreen.swift` (`finishAutoPlay`, a `makeSeed` helper, an `isHandingOff` overlay, `onDisappear`)

**Interfaces:**
- Consumes: `onContinueLive` (Task 8), `SelfPlaySeed` (Task 4), `TVAutoPlayPolicy.handoffBeatSeconds` (Task 3).

- [ ] **Step 1: Add the handoff state**

Beside the other Auto-Play state:

```swift
    /// The "Continuing live…" beat between the last recorded move and the push.
    @State private var isHandingOff = false
    @State private var handoffTask: Task<Void, Never>?
```

- [ ] **Step 2: Implement the real `finishAutoPlay`**

```swift
    /// Reached the end of the recorded moves. An unfinished game hands off to a
    /// live AI continuation after a short announced beat; a game that already
    /// ended just stops on its final position (continuing it would seed the
    /// engine with a position it answers by passing twice).
    private func finishAutoPlay(continuesLive: Bool) {
        stopAutoPlay()
        guard continuesLive,
              let onContinueLive,
              let seed = makeSeed() else { return }
        isHandingOff = true
        handoffTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(TVAutoPlayPolicy.handoffBeatSeconds))
            guard !Task.isCancelled else { return }
            isHandingOff = false
            // Cleared BEFORE the push, not left to onDisappear: SwiftUI fires
            // the destination's onAppear first, and TVSelfPlayScreen's entry
            // points the selection at its own seeded record.
            navigationContext.selectedGameRecord = nil
            onContinueLive(seed)
        }
    }

    /// The value the continuation starts from. Nil while a variation is active
    /// — a branch means the synced record is already selected and the printsgf
    /// routing depends on flags the self-play entry clears.
    private func makeSeed() -> SelfPlaySeed? {
        guard !gobanState.isBranchActive else { return nil }
        return SelfPlaySeed(sgf: game.sgf,
                            moveCount: totalMoves,
                            rule: config.rule,
                            name: game.name.isEmpty ? SelfPlayGame.demoName : game.name,
                            scoreLeads: game.scoreLeads ?? [:],
                            winRates: game.winRates ?? [:])
    }
```

- [ ] **Step 3: Add the beat overlay**

On `reviewContent`, in the same modifier run:

```swift
        .overlay {
            if isHandingOff {
                // Announce the screen change rather than jump-cutting to it.
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Continuing live…")
                        .font(.title2.bold())
                    Text("KataGo plays on from here.")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .padding(48)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 32))
            }
        }
```

- [ ] **Step 4: Cancel the beat on exit**

In `onDisappear`, beside `stopAutoPlay()`:

```swift
            handoffTask?.cancel()
            handoffTask = nil
            isHandingOff = false
```

- [ ] **Step 5: Build, full suite, simulator smoke test**

```bash
cd "ios/KataGo iOS" && set -o pipefail && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime TV" -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | tail -5
cd "ios/KataGo iOS" && set -o pipefail && xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```
Both must print their SUCCEEDED markers.

Then re-add the temporary `-qaAutoPlay` route push from Task 6, this time pushing a SHORT unfinished game (seed one with a 3-move SGF that does not end in passes), and verify end-to-end on the simulator: replay runs out of moves → "Continuing live…" → the self-play screen appears titled with the game's name → a stone eventually lands. Then REVERT the hack.

- [ ] **Step 6: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev" && git add "ios/KataGo iOS/KataGo Anytime TV/TVReviewScreen.swift" && git commit -m "$(cat <<'EOF'
feat(tv): hand off to a live AI continuation at the end of a replay

When Auto-Play consumes the last recorded move of an UNFINISHED game, a two
second announced beat precedes a push into the self-play broadcast seeded
from that position. A game that already ended stops instead. The selection
is cleared before the push, not left to onDisappear ordering.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
)"
```

---

### Task 11: Declare game-controller support on the tvOS target

**Files:**
- Modify: `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj` (BOTH TV build configurations)

> The TV target uses `GENERATE_INFOPLIST_FILE = YES` with no `INFOPLIST_FILE`, so this is a build setting, not a plist edit. Adding it to only one configuration is a silent Debug/Release mismatch.

- [ ] **Step 1: Add the setting to both configurations**

```bash
cd "ios/KataGo iOS" && ruby -e '
require "xcodeproj"
project = Xcodeproj::Project.open("KataGo Anytime.xcodeproj")
target = project.targets.find { |t| t.name == "KataGo Anytime TV" }
target.build_configurations.each do |config|
  config.build_settings["INFOPLIST_KEY_GCSupportsControllerUserInteraction"] = "YES"
  puts "#{config.name}: #{config.build_settings["INFOPLIST_KEY_GCSupportsControllerUserInteraction"]}"
end
project.save
'
```
Expected output: two lines, `Debug: YES` and `Release: YES`.

- [ ] **Step 2: Verify it reaches the built Info.plist**

```bash
cd "ios/KataGo iOS" && set -o pipefail && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime TV" -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | tail -5
plutil -p "DerivedData/KataGo Anytime/Build/Products/Debug-appletvsimulator/KataGo TV.app/Info.plist" | grep -i GCSupports
```
Expected: `** BUILD SUCCEEDED **` then `"GCSupportsControllerUserInteraction" => 1`.

- [ ] **Step 3: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev" && git add "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj" && git commit -m "$(cat <<'EOF'
feat(tv): declare game-controller support

INFOPLIST_KEY_ in both configurations (the TV target generates its Info.plist,
so there is no file to edit). This is the capability/remapping declaration —
NOT an event-routing switch: a gamepad already drives the tvOS focus engine
through the responder chain.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
)"
```

---

### Task 12: `TVControllerEvent` + `TVControllerLegend` + `TVControllerInput`

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Util/TVControllerEvent.swift`
- Create: `ios/KataGo iOS/KataGo Anytime TV/TVControllerInput.swift`
- Test: `ios/KataGo iOS/KataGo iOSTests/TVControllerLegendTests.swift`

**Interfaces:**
- Produces: `public enum TVControllerEvent`, `public struct TVControllerLegendRow`, `public enum TVControllerLegend` (all in `KataGoUICore`); `@Observable @MainActor final class TVControllerInput` with `isConnected`, `vendorName`, `pushHandler(_:_:)`, `popHandler(_:)` (TV target). Consumed by Tasks 13 and 14.

- [ ] **Step 1: Write the failing legend test**

Create `ios/KataGo iOS/KataGo iOSTests/TVControllerLegendTests.swift`:

```swift
//
//  TVControllerLegendTests.swift
//  KataGo AnytimeTests
//

import Foundation
import Testing
@testable import KataGoUICore

struct TVControllerLegendTests {
    /// A/B/Menu belong to the tvOS focus engine — binding them in GameController
    /// would double-fire against TVSelectPressCatcher and .onExitCommand. The
    /// event enum is the single list of what the app is allowed to bind.
    @Test func onlyFocusSafeButtonsAreModelled() {
        #expect(TVControllerEvent.allCases == [.buttonX, .buttonY, .leftShoulder,
                                               .rightShoulder, .leftTrigger, .rightTrigger])
    }

    @Test func everyBoundButtonHasALegendRow() {
        let covered = Set(TVControllerLegend.rows.map(\.event))
        #expect(covered == Set(TVControllerEvent.allCases))
    }

    @Test func legendRowsDescribeBothScreens() {
        for row in TVControllerLegend.rows {
            #expect(!row.symbol.isEmpty)
            #expect(!row.name.isEmpty)
            #expect(!row.review.isEmpty)
            #expect(!row.live.isEmpty)
        }
    }

    @Test func theTransportButtonIsX() {
        let row = TVControllerLegend.rows.first { $0.event == .buttonX }
        #expect(row?.review == "Auto-Play")
        #expect(row?.live == "Pause / Resume")
    }
}
```

- [ ] **Step 2: Register the test file**

```bash
cd "ios/KataGo iOS" && ruby -e '
require "xcodeproj"
project = Xcodeproj::Project.open("KataGo Anytime.xcodeproj")
target = project.targets.find { |t| t.name == "KataGo AnytimeTests" }
group = project.main_group.find_subpath("KataGo iOSTests", false)
ref = group.new_reference("TVControllerLegendTests.swift")
target.source_build_phase.add_file_reference(ref)
project.save
'
```

- [ ] **Step 3: Run to verify it fails**

```bash
cd "ios/KataGo iOS" && set -o pipefail && xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/TVControllerLegendTests" 2>&1 | tail -30
```
Expected: `** TEST FAILED **` with `cannot find 'TVControllerEvent' in scope`.

- [ ] **Step 4: Write the shared model**

Create `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Util/TVControllerEvent.swift`:

```swift
//
//  TVControllerEvent.swift
//  KataGoUICore
//
//  The tvOS game-controller buttons the app is allowed to bind, and the legend
//  shown in Settings. Kept here so the "which buttons are focus-safe" rule and
//  the user-facing legend are unit-testable — the TV views are unreachable from
//  every test target in this project.
//
//  Named after the PHYSICAL button, not an action: the same button means
//  different things on the review screen and the live broadcast, and the screens
//  own that mapping.
//
//  Deliberately absent: A (arrives as UIPress .select, already consumed by the
//  window-level TVSelectPressCatcher), B / Menu (arrive as .menu, already
//  consumed by .onExitCommand), the D-pad (the focus engine's), Options (bound
//  to a system screenshot long-press, so its input is delayed or swallowed) and
//  Home. Binding any of them would double-fire.
//

import Foundation

public enum TVControllerEvent: String, CaseIterable, Sendable, Equatable {
    case buttonX
    case buttonY
    case leftShoulder
    case rightShoulder
    case leftTrigger
    case rightTrigger
}

public struct TVControllerLegendRow: Identifiable, Sendable, Equatable {
    public let event: TVControllerEvent
    /// SF Symbol shown beside the row.
    public let symbol: String
    /// The button as a user names it.
    public let name: String
    /// What it does while reviewing a saved game.
    public let review: String
    /// What it does during the live broadcast.
    public let live: String

    public var id: String { event.rawValue }
}

public enum TVControllerLegend {
    public static let rows: [TVControllerLegendRow] = [
        TVControllerLegendRow(event: .buttonX,
                              symbol: "square.circle",
                              name: "X",
                              review: "Auto-Play",
                              live: "Pause / Resume"),
        TVControllerLegendRow(event: .buttonY,
                              symbol: "triangle.circle",
                              name: "Y",
                              review: "Analysis on / off",
                              live: "—"),
        TVControllerLegendRow(event: .leftShoulder,
                              symbol: "l1.rectangle.roundedbottom",
                              name: "L1",
                              review: "Back one move (hold to repeat)",
                              live: "Undo (while paused)"),
        TVControllerLegendRow(event: .rightShoulder,
                              symbol: "r1.rectangle.roundedbottom",
                              name: "R1",
                              review: "Forward one move (hold to repeat)",
                              live: "Skip the current slide"),
        TVControllerLegendRow(event: .leftTrigger,
                              symbol: "l2.rectangle.roundedtop",
                              name: "L2",
                              review: "Jump to the start",
                              live: "—"),
        TVControllerLegendRow(event: .rightTrigger,
                              symbol: "r2.rectangle.roundedtop",
                              name: "R2",
                              review: "Jump to the end",
                              live: "—"),
    ]
}
```

- [ ] **Step 5: Run to verify it passes**

Same command as Step 3. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Write the tvOS plumbing**

Create `ios/KataGo iOS/KataGo Anytime TV/TVControllerInput.swift`:

```swift
//
//  TVControllerInput.swift
//  KataGo Anytime TV
//
//  GCController plumbing for the focus-SAFE buttons only. Ported from
//  VisionControllerInput, minus everything that does not exist on tvOS:
//  `.handlesGameControllerEvents(matching:)` and `GCEventInteraction` are
//  API_UNAVAILABLE(tvos), and none is needed — the tvOS default already
//  delivers controller input through the responder chain (so the focus engine
//  drives the UI) while GameController element handlers fire alongside it.
//
//  NEVER install a GCEventViewController: its controllerUserInteractionEnabled
//  defaults to false, which suppresses UIEvents from controllers and would kill
//  the focus engine, TVSelectPressCatcher, .onMoveCommand, .onExitCommand and
//  .onPlayPauseCommand in one stroke.
//
//  ONE owner, a handler STACK: `pressedChangedHandler` is a single assignable
//  slot per button, and the review screen and the self-play screen coexist on
//  the same NavigationStack path — two owners would silently clobber each other
//  and leave the review screen's bindings dead after a pop.
//

import Foundation
import GameController
import Observation
import KataGoUICore

@Observable
@MainActor
final class TVControllerInput {
    /// True only for a real gamepad: the Siri Remote vends microGamepad /
    /// directionalGamepad, never extendedGamepad.
    private(set) var isConnected = false
    /// For the Settings section's heading. Nullable and not unique per Apple.
    private(set) var vendorName: String?

    /// LIFO: only the topmost screen receives events.
    @ObservationIgnored
    private var handlers: [(token: UUID, handler: (TVControllerEvent) -> Void)] = []

    @ObservationIgnored
    private var repeatTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// L1/R1 hold-repeat cadence: first repeat after the delay, then steady.
    private static let repeatInitialDelay: Duration = .milliseconds(400)
    private static let repeatInterval: Duration = .milliseconds(125)

    @ObservationIgnored
    private nonisolated(unsafe) var observerTokens: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observerTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshConnection() }
            })
        }
        refreshConnection()
    }

    deinit {
        observerTokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Subscribers

    func pushHandler(_ token: UUID, _ handler: @escaping (TVControllerEvent) -> Void) {
        handlers.removeAll { $0.token == token }
        handlers.append((token, handler))
    }

    func popHandler(_ token: UUID) {
        handlers.removeAll { $0.token == token }
    }

    private func deliver(_ event: TVControllerEvent) {
        handlers.last?.handler(event)
    }

    // MARK: - Pad

    /// GCController.current on tvOS is "the most recently used controller",
    /// which is frequently the Siri Remote (extendedGamepad nil) — the fallback
    /// is what keeps the bindings alive after the user touches the remote.
    private var currentPad: GCExtendedGamepad? {
        GCController.current?.extendedGamepad
            ?? GCController.controllers().compactMap(\.extendedGamepad).first
    }

    private func refreshConnection() {
        let pads = GCController.controllers().filter { $0.extendedGamepad != nil }
        isConnected = !pads.isEmpty
        vendorName = pads.first?.vendorName
        bindButtons()
    }

    private func bindButtons() {
        // A pad that just vanished never delivers its release edge.
        cancelRepeats()
        guard let pad = currentPad else { return }
        bind(pad.buttonX, to: .buttonX)
        bind(pad.buttonY, to: .buttonY)
        bindRepeating(pad.leftShoulder, to: .leftShoulder)
        bindRepeating(pad.rightShoulder, to: .rightShoulder)
        bind(pad.leftTrigger, to: .leftTrigger)
        bind(pad.rightTrigger, to: .rightTrigger)
        // buttonA / buttonB / buttonMenu / dpad are NOT bound — the focus
        // engine already delivers them as UIPress events.
    }

    /// The handler block is a plain ObjC block on GCDevice.handlerQueue, not
    /// statically MainActor-isolated under Swift 6 — hop explicitly.
    private func bind(_ button: GCControllerButtonInput, to event: TVControllerEvent) {
        button.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            Task { @MainActor in self?.deliver(event) }
        }
    }

    /// One event on the press edge, then auto-repeat while held. The loop
    /// re-checks `button.isPressed` so a lost release edge can never wedge a
    /// runaway repeat — which on the review screen would run the timeline away.
    private func bindRepeating(_ button: GCControllerButtonInput, to event: TVControllerEvent) {
        let key = ObjectIdentifier(button)
        button.pressedChangedHandler = { [weak self] _, _, pressed in
            Task { @MainActor in
                guard let self else { return }
                self.repeatTasks.removeValue(forKey: key)?.cancel()
                guard pressed else { return }
                self.deliver(event)
                self.repeatTasks[key] = Task { @MainActor [weak self, weak button] in
                    try? await Task.sleep(for: Self.repeatInitialDelay)
                    while !Task.isCancelled, let self, let button, button.isPressed {
                        self.deliver(event)
                        try? await Task.sleep(for: Self.repeatInterval)
                    }
                }
            }
        }
    }

    private func cancelRepeats() {
        repeatTasks.values.forEach { $0.cancel() }
        repeatTasks.removeAll()
    }
}
```

- [ ] **Step 7: Register the TV file and build**

```bash
cd "ios/KataGo iOS" && ruby -e '
require "xcodeproj"
project = Xcodeproj::Project.open("KataGo Anytime.xcodeproj")
target = project.targets.find { |t| t.name == "KataGo Anytime TV" }
group = project.main_group.find_subpath("KataGo Anytime TV", false)
ref = group.new_reference("TVControllerInput.swift")
target.source_build_phase.add_file_reference(ref)
project.save
'
cd "ios/KataGo iOS" && set -o pipefail && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime TV" -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev" && git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Util/TVControllerEvent.swift" "ios/KataGo iOS/KataGo Anytime TV/TVControllerInput.swift" "ios/KataGo iOS/KataGo iOSTests/TVControllerLegendTests.swift" "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj" && git commit -m "$(cat <<'EOF'
feat(tv): add game-controller plumbing for the focus-safe buttons

X / Y / L1 / R1 / L2 / R2 only — A, B, Menu, the D-pad and Options are the
focus engine's or the system's, and binding them would double-fire. One
owner with a LIFO handler stack, because the review and self-play screens
coexist on one NavigationStack and pressedChangedHandler is a single slot.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
)"
```

---

### Task 13: Wire the controller into both game screens

**Files:**
- Modify: `ios/KataGo iOS/KataGo Anytime TV/TVRootView.swift` (own + inject `TVControllerInput`)
- Modify: `ios/KataGo iOS/KataGo Anytime TV/TVReviewScreen.swift` (subscribe + map)
- Modify: `ios/KataGo iOS/KataGo Anytime TV/TVSelfPlayScreen.swift` (subscribe + map)

- [ ] **Step 1: Own and inject it at the root**

In `TVRootView.swift`, beside the other `@State` models:

```swift
    /// ONE owner for the whole app: pressedChangedHandler is a single slot per
    /// button, and the review and self-play screens coexist on one stack.
    @State private var controllerInput = TVControllerInput()
```

and add to the TabView's environment block, beside `.environment(engineController)`:

```swift
                .environment(controllerInput)
```

- [ ] **Step 2: Subscribe on the review screen**

In `TVReviewScreen.swift`, add the environment + token:

```swift
    @Environment(TVControllerInput.self) private var controllerInput
    /// This screen's slot in the controller's LIFO handler stack.
    @State private var controllerToken = UUID()
```

Add the mapping:

```swift
    /// Focus-safe controller buttons. Inert while aiming: the board cursor owns
    /// the screen then, exactly as the D-pad does.
    private func handleControllerEvent(_ event: TVControllerEvent) {
        guard !isAiming else { return }
        switch event {
        case .buttonX:
            toggleAutoPlay()
        case .buttonY:
            toggleAnalysis()
        case .leftShoulder:
            stepBy(-1)
        case .rightShoulder:
            stepBy(1)
        case .leftTrigger:
            stopAutoPlay()
            guard stones.isReady else { return }
            gobanState.backwardMoves(limit: nil, gameRecord: game,
                                     messageList: messageList,
                                     player: player, stones: stones)
            reanalyze()
        case .rightTrigger:
            stopAutoPlay()
            guard stones.isReady else { return }
            gobanState.forwardMoves(limit: nil, gameRecord: game, board: board,
                                    messageList: messageList, player: player,
                                    audioModel: audioModel, stones: stones)
            reanalyze()
        }
    }
```

Extract the Analysis action so both the toggle and Y share one implementation — replace `analysisToggle`'s closure body with a call to a new `toggleAnalysis()` holding exactly the code that is there today:

```swift
    private func toggleAnalysis() {
        if gobanState.analysisStatus == .run {
            gobanState.analysisStatus = .clear
            gobanState.eyeStatus = .closed
        } else {
            gobanState.eyeStatus = .opened
            gobanState.analysisStatus = .run
            reanalyze()
        }
    }

    private var analysisToggle: some View {
        TVToggleButton(systemName: "sparkles", title: "Analysis",
                       isOn: gobanState.analysisStatus == .run) {
            toggleAnalysis()
        }
    }
```

Register in the existing lifecycle modifiers:

```swift
        .onAppear {
            loadIfNeeded()
            controllerInput.pushHandler(controllerToken) { event in
                handleControllerEvent(event)
            }
        }
```
(replacing `.onAppear(perform: loadIfNeeded)`), and in `onDisappear`:

```swift
            controllerInput.popHandler(controllerToken)
```

- [ ] **Step 3: Subscribe on the self-play screen**

In `TVSelfPlayScreen.swift`, add the same environment + token, then:

```swift
    /// Focus-safe controller buttons. X is the transport on BOTH game screens;
    /// L1/R1 mean "move things along" on both. Inert while aiming.
    private func handleControllerEvent(_ event: TVControllerEvent) {
        guard !isAiming else { return }
        switch event {
        case .buttonX:
            togglePause()
        case .rightShoulder:
            broadcast?.skipSlide()
        case .leftShoulder:
            // stepBack() guards on `game`, `!isGameOver`, `stones.isReady` and
            // `pendingMoveTurn == nil` (TVSelfPlayScreen.swift:728-731) but NOT
            // on isPaused — Undo is a paused-interactive action, so the gate
            // belongs here rather than inside stepBack, whose existing callers
            // are already paused-only.
            guard isPaused else { return }
            stepBack()
        case .buttonY, .leftTrigger, .rightTrigger:
            break
        }
    }
```

Register it in the screen's existing `.onAppear` / `.onDisappear` pair (the `.onDisappear(perform: tearDown)` becomes a closure calling `tearDown()` and `controllerInput.popHandler(controllerToken)`).

- [ ] **Step 4: Build and run the full suite**

```bash
cd "ios/KataGo iOS" && set -o pipefail && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime TV" -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | tail -5
cd "ios/KataGo iOS" && set -o pipefail && xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```
Both must print their SUCCEEDED markers.

> The previews inject environments explicitly (`TVReviewPreviewHost`, `TVPreviewSupport`). Adding `@Environment(TVControllerInput.self)` will crash any preview that does not provide it — add `.environment(TVControllerInput())` to `TVReviewPreviewHost` and to the self-play preview host, and re-render one preview per file to confirm.

- [ ] **Step 5: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev" && git add "ios/KataGo iOS/KataGo Anytime TV/TVRootView.swift" "ios/KataGo iOS/KataGo Anytime TV/TVReviewScreen.swift" "ios/KataGo iOS/KataGo Anytime TV/TVSelfPlayScreen.swift" && git commit -m "$(cat <<'EOF'
feat(tv): map the controller's focus-safe buttons on both game screens

X is the transport on both (Auto-Play in review, Pause/Resume live), L1/R1
step or skip, L2/R2 jump to the ends of a review. All inert while the board
cursor is aiming, matching the D-pad's semantics.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
)"
```

---

### Task 14: Settings — the Game Controller section

**Files:**
- Modify: `ios/KataGo iOS/KataGo Anytime TV/TVSettingsScreen.swift`

- [ ] **Step 1: Add the environment and the section**

```swift
    @Environment(TVControllerInput.self) private var controllerInput
```

```swift
    // MARK: - Game Controller

    private var gameControllerSection: some View {
        section("Game Controller") {
            Text(controllerInput.vendorName ?? "Controller connected")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow {
                    Text("").gridCellUnsizedAxes(.horizontal)
                    Text("Reviewing").font(.callout).foregroundStyle(.secondary)
                    Text("Live").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(TVControllerLegend.rows) { row in
                    GridRow {
                        Label(row.name, systemImage: row.symbol)
                        Text(row.review)
                        Text(row.live)
                    }
                }
            }

            Text("The D-pad, A and B navigate the interface as usual.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
```

- [ ] **Step 2: Compose it conditionally, between two focusable sections**

> tvOS ScrollViews scroll by focus movement. A text-only card appended after the last focusable control can be unreachable — insert it BETWEEN `soundSection` and `aboutSection`, never at the end.

```swift
                recoverySection
                boardSizeSection
                playbackSection
                soundSection
                if controllerInput.isConnected {
                    gameControllerSection
                }
                aboutSection
                diagnosticsFooter
```

- [ ] **Step 3: Fix the preview**

`TVSettingsScreen`'s `#Preview` must provide the new environment:

```swift
    return NavigationStack { TVSettingsScreen() }
        .environment(TVControllerInput())
```

- [ ] **Step 4: Build and render**

```bash
cd "ios/KataGo iOS" && set -o pipefail && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime TV" -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`. Then `RenderPreview` `KataGo Anytime TV/TVSettingsScreen.swift` index 0 — with no controller attached the section is correctly absent; confirm the other six sections still render in order.

- [ ] **Step 5: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev" && git add "ios/KataGo iOS/KataGo Anytime TV/TVSettingsScreen.swift" && git commit -m "$(cat <<'EOF'
feat(tv): show the controller mapping in Settings while one is connected

Placed between two focusable sections: a text-only card at the end of a tvOS
ScrollView can be unreachable, since the list scrolls by focus movement.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
)"
```

---

### Task 15: Full verification sweep + device QA checklist

**Files:**
- Create: `ios/KataGo iOS/docs/2026-07-28-tvos-autoplay-controller-qa.md`

- [ ] **Step 1: Build every scheme**

```bash
cd "ios/KataGo iOS" && for s in "KataGo Anytime" "KataGo Anytime Mac" "KataGo Anytime Vision" "KataGo Anytime TV" "KataGo Anytime Watch"; do
  case "$s" in
    "KataGo Anytime") d='platform=iOS Simulator,name=iPhone 17';;
    "KataGo Anytime Mac") d='platform=macOS';;
    "KataGo Anytime Vision") d='platform=visionOS Simulator,name=Apple Vision Pro';;
    "KataGo Anytime TV") d='platform=tvOS Simulator,name=Apple TV';;
    "KataGo Anytime Watch") d='platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)';;
  esac
  echo "=== $s ==="
  set -o pipefail && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "$s" -destination "$d" 2>&1 | tail -3
done
```
All five must print `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Full unit suite**

```bash
cd "ios/KataGo iOS" && set -o pipefail && xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **` with a test count at least 1238 + the ~25 tests this plan adds, and **0 failures**.

- [ ] **Step 3: Confirm no temporary QA hacks survived**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev" && git diff master...HEAD -- "ios/KataGo iOS/KataGo Anytime TV/" | grep -n "qaAutoPlay\|TEMP\|FIXME" || echo "clean"
```
Expected: `clean`.

- [ ] **Step 4: Write the device QA checklist**

Create `ios/KataGo iOS/docs/2026-07-28-tvos-autoplay-controller-qa.md` containing exactly these items (everything below is device-only — the tvOS Simulator cannot receive synthetic remote input at all, and a gamepad reaches it only through I/O ▸ Input ▸ Send Game Controller to Device, which Apple documents only for visionOS):

**Auto-Play — Siri Remote**
1. Open a saved unfinished game. Press Play/Pause: stones advance at ~1.5 s. Press again: it stops.
2. Settings ▸ Playback ▸ Fast, return to the game, press Play/Pause: the cadence is visibly quicker without restarting the engine.
3. While replaying, click the timeline left/right — Auto-Play stops on the first click.
4. While replaying, press left from the panel to focus the board — Auto-Play stops and the ghost cursor appears.
5. While replaying, pick a Top Move — Auto-Play stops and the variation is played.
6. Replay with Analysis ON and with Analysis OFF: the toggle state is never changed by Auto-Play, and OFF shows the persisted per-move numbers.
7. Replay a long game to the end with the remote untouched: the screensaver never covers it.
8. Both panel toggles are fully legible at 10 feet with no truncated labels (this is the layout gate from Task 6 — confirm on a real TV).
9. Press down from the timeline while Auto-Play is ON and while a variation is active: focus always lands somewhere legal (never a dead press).

**Handoff**
10. Replay an UNFINISHED game to its last move: "Continuing live…" appears for ~2 s, then the broadcast screen opens titled with the game's name and a stone eventually lands.
11. When that continuation ends, the result card shows "Returning to review…" and the app pops back to the review screen.
12. **After the pop, play a Top Moves move on the review screen, exit, and reopen the game from the library — the recorded game is UNCHANGED.** (This is the build-291 regression check; it is the single most important item on this list.)
13. Replay a FINISHED game (one ending in two passes) to its last move: it stops on the final position and does NOT push.
14. Manually step to the last move of an unfinished game with the D-pad: nothing is pushed.
15. Park at the last move of an unfinished game and press Play/Pause: it pushes immediately.
16. Repeat item 10 for a game opened from the **Search** tab.
17. Press Menu during the "Continuing live…" beat: it cancels cleanly and no push happens.

**Controller**
18. Pair a controller. Settings shows the Game Controller section with the correct vendor name; unpair it and the section disappears.
19. D-pad navigates focus, A selects, B goes back — exactly as the remote does.
20. On the review screen: X toggles Auto-Play, Y toggles Analysis, L1/R1 step one move (and auto-repeat when held), L2/R2 jump to the start/end.
21. Focus the board (aiming): L1/R1/L2/R2/X/Y all become inert, and the D-pad steps the ghost cursor.
22. On the live broadcast: X pauses and resumes, R1 skips the current slide, L1 undoes while paused.
23. Disconnect the controller mid-hold of L1: the auto-repeat stops and does not run the timeline away.
24. Push review → live → pop back, then press X on the review screen: it still works (the handler-stack check).

- [ ] **Step 5: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev" && git add "ios/KataGo iOS/docs/2026-07-28-tvos-autoplay-controller-qa.md" && git commit -m "$(cat <<'EOF'
docs(tv): add the device QA checklist for Auto-Play and controller support

24 items, all device-only: the tvOS Simulator takes no synthetic remote
input, and item 12 is the build-291 regression check.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
)"
```

---

## Deferred / explicitly out of scope

- **`GCSupportedGameControllers`** (the `ExtendedGamepad` profile array that produces the App Store controller badge) cannot be expressed as an `INFOPLIST_KEY_` scalar; it would require giving the TV target a real `Info.plist` plus `INFOPLIST_FILE`. The app ships via TestFlight, so the badge buys nothing today.
- **Thumbstick aiming of the ghost cursor.** tvOS has no per-frame tick to poll a stick from (visionOS polls from its RealityKit update loop), so it would need its own timer. The D-pad already aims.
- **`sfSymbolsName` / `localizedName` in the legend.** Reading the live element names would reflect a user's Settings remapping, but adds a `GCControllerDidBecomeCurrent` observer for a cosmetic gain.
- **The duplicate analysis request per step.** `forwardMoves` already calls `maybeRequestAnalysis` via `sendPostExecutionCommands`, and `stepBy`/`advanceOneMove` then call `reanalyze()` on top. This double-request is pre-existing for manual stepping; Auto-Play inherits it. If device QA shows thermal trouble at Fast, drop the extra `reanalyze()` from `advanceOneMove` only.
- **Auto-play's per-tick write of `gameRecord.currentIndex`.** Every advanced move dirties a CloudKit-mirrored field (≈1.4×/s at Fast). `lastModificationDate` is untouched so library ordering does not churn, and manual stepping already does exactly this — but the sustained rate is new. Watch for CloudKit export chatter during device QA.
