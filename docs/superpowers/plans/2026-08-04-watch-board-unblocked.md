# Watch Board Unblocked — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Take every readout off the KataGo Anytime Watch board — the score and win rate move to the second page, staleness and the scrub position move into the navigation title — so no stone is ever covered.

**Architecture:** Two pure helpers land in the `KataGoGameStore` package (`WatchBoardTitle`, `WatchBoardFrame.winratePercentText`) because the watch app target has no test bundle; a small shared SwiftUI section (`WatchAnalysisSummary`) is added to both second pages; then the three board overlays are deleted and the titles wired up. Additive tasks land before subtractive ones, so no commit ever leaves a readout with nowhere to live.

**Tech Stack:** SwiftUI (watchOS 26), Swift Testing (`import Testing`, `@Test`, `#expect`), SwiftPM package `KataGoUICore` vending the `KataGoGameStore` product, Xcode project `ios/KataGo iOS/KataGo Anytime.xcodeproj`.

**Spec:** `docs/superpowers/specs/2026-08-04-watch-board-unblocked-design.md`

## Global Constraints

- **All commands run from `ios/KataGo iOS/`** unless a path says otherwise.
- **The watch target links only bridge-free products** — `KataGoGameStore` and `GoRulesKit`. Never `KataGoUICore`. Every shared helper in this plan goes in `KataGoUICore/Sources/KataGoGameStore/`.
- **The watch target has no test bundle.** Logic placed in the watch target cannot be tested at all. Anything with a rule in it goes in the package and is tested from `KataGo iOSTests`.
- **`swift test` does not gate this work, `xcodebuild test` does.** The package's own SwiftPM tests never run under `xcodebuild test`; the tests in this plan live in the `KataGo AnytimeTests` target, which does.
- **Never run two `xcodebuild` invocations at once.** A DerivedData lock produces a spurious `TEST FAILED`.
- **Piped `xcodebuild` exit codes lie.** Always confirm by grepping for `BUILD SUCCEEDED` / `TEST SUCCEEDED` in the output, never by `$?`.
- **New `.swift` files must be registered in `project.pbxproj`** — the project uses no filesystem-synchronized groups. Package files (`KataGoUICore/Sources/...`) need no registration; app-target and test-target files do.
- **English only in all committed content.** No CJK anywhere in source, comments, docs, or commit messages.
- **Do not modify any SwiftData `@Model`.** The schema is frozen for CloudKit. Nothing in this plan touches one.
- **Commit message trailers** (every commit):
  ```
  Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
  ```

---

## File Structure

| File | Responsibility | Task |
|------|----------------|------|
| `KataGoUICore/Sources/KataGoGameStore/WatchBoardTitle.swift` | **Create.** Pure state → board-page title, with the precedence rules. | 2 |
| `KataGo iOSTests/WatchBoardTitleTests.swift` | **Create.** Pins every precedence row. | 2 |
| `KataGoUICore/Sources/KataGoGameStore/WatchBoardFrame.swift` | **Modify.** Add `winratePercentText`. | 3 |
| `KataGo iOSTests/WatchBoardFrameTests.swift` | **Modify.** Rounding boundaries. | 3 |
| `KataGo Anytime Watch/WatchAnalysisSummary.swift` | **Create.** The shared status rows for both second pages. | 4 |
| `KataGo Anytime Watch/WatchMovesPage.swift` | **Modify.** Host the summary + staleness detail. | 4 |
| `KataGo Anytime Watch/WatchStoredGameView.swift` | **Modify.** Host the summary; fix the "no analysis" condition (4); drop the counter pill, add the title (6). | 4, 6 |
| `KataGo Anytime Watch/WatchFrameBoard.swift` | **Modify.** Delete `statusCluster` and three parameters. | 5 |
| `KataGo Anytime Watch/WatchBoardPage.swift` | **Modify.** Delete `statusPill` and `staleAccessibilityLabel`. | 5 |
| `KataGo Anytime Watch/WatchRootView.swift` | **Modify.** Dynamic live title. | 5 |

---

### Task 1: Confirm the navigation title is usable chrome

The entire design rests on a `TabView`-level `.navigationTitle` showing on the board page while `WatchMovesPage`'s own title wins on page two. The reported screenshot already shows `Live` over the board, which confirms half of it. This task confirms the other half before any code is deleted. **No code changes.**

**Files:** none.

- [ ] **Step 1: Build the watch scheme**

```bash
cd "ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime Watch" \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' \
  2>&1 | tail -40
```

Expected: output contains `BUILD SUCCEEDED`.

- [ ] **Step 2: Launch and land on the live mirror**

Boot the watch simulator and launch the app. If no snapshot is present the app opens the library; open any game to reach a board page.

- [ ] **Step 3: Read the title on both pages**

Screenshot the board page, then swipe up to the second page and screenshot again.

Expected: the board page shows the outer title (`Live` for the live mirror, or the game's name for a stored game); the second page shows its own title (`Top Moves` / `Review`).

- [ ] **Step 4: Record the result**

If confirmed, continue to Task 2.

**If NOT confirmed** — if the outer title is suppressed on the board page, or page two shows the outer title instead of its own — **stop and report.** Decisions 2 and 3 of the spec are invalid and the design needs re-work; do not proceed to any later task, because Tasks 5 and 6 delete the only other place this information is shown.

---

### Task 2: `WatchBoardTitle`

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchBoardTitle.swift`
- Test: `ios/KataGo iOS/KataGo iOSTests/WatchBoardTitleTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `WatchBoardTitle.live(stale: Bool, pendingTarget: Int?, hostMoveIndex: Int?, hostMoveCount: Int?, sharedCursorAvailable: Bool, movesBehindLive: Int) -> String`
  - `WatchBoardTitle.stored(name: String, index: Int, count: Int, showsCounter: Bool) -> String`

- [ ] **Step 1: Create the test file**

Create `ios/KataGo iOS/KataGo iOSTests/WatchBoardTitleTests.swift`:

```swift
import Testing
@testable import KataGoGameStore

struct WatchBoardTitleTests {
    /// Every argument that is not under test held at its healthy, at-the-head
    /// value, so each test varies exactly one thing.
    private func live(stale: Bool = false,
                      pendingTarget: Int? = nil,
                      hostMoveIndex: Int? = 50,
                      hostMoveCount: Int? = 50,
                      sharedCursorAvailable: Bool = true,
                      movesBehindLive: Int = 0) -> String {
        WatchBoardTitle.live(stale: stale,
                             pendingTarget: pendingTarget,
                             hostMoveIndex: hostMoveIndex,
                             hostMoveCount: hostMoveCount,
                             sharedCursorAvailable: sharedCursorAvailable,
                             movesBehindLive: movesBehindLive)
    }

    @Test func atTheHostsPositionItSaysLive() {
        #expect(live() == "Live")
    }

    @Test func cursorModeParkedBehindReportsThePosition() {
        #expect(live(hostMoveIndex: 3, hostMoveCount: 50) == "3/50")
    }

    @Test func pendingScrubReportsItsTarget() {
        #expect(live(pendingTarget: 5, hostMoveIndex: 3, hostMoveCount: 50) == "→ 5/50")
    }

    /// Staleness outranks a pending scrub: `WatchLiveModel.scrub` gates on
    /// `sharedCursorAvailable`, so a pending target can survive INTO a stale
    /// state but never be created in one, and it will never be confirmed.
    @Test func staleBeatsAPendingScrub() {
        #expect(live(stale: true, pendingTarget: 5,
                     hostMoveIndex: 3, hostMoveCount: 50) == "Offline")
    }

    @Test func staleBeatsEveryOtherState() {
        #expect(live(stale: true) == "Offline")
        #expect(live(stale: true, hostMoveIndex: 3, hostMoveCount: 50) == "Offline")
        #expect(live(stale: true, sharedCursorAvailable: false,
                     movesBehindLive: 3) == "Offline")
    }

    @Test func ringModeCountsMovesBehind() {
        #expect(live(sharedCursorAvailable: false, movesBehindLive: 3) == "3 behind")
    }

    @Test func ringModeAtTheNewestFrameSaysLive() {
        #expect(live(sharedCursorAvailable: false, movesBehindLive: 0) == "Live")
    }

    /// A v0 phone sends no host cursor at all. Cursor mode must not print
    /// "nil/nil" or fabricate a position.
    @Test func cursorModeWithoutAHostCursorSaysLive() {
        #expect(live(hostMoveIndex: nil, hostMoveCount: nil) == "Live")
    }

    @Test func storedShowsTheCounterOnlyWhileScrubbing() {
        #expect(WatchBoardTitle.stored(name: "Sanren-sei", index: 3, count: 50,
                                       showsCounter: true) == "3/50")
        #expect(WatchBoardTitle.stored(name: "Sanren-sei", index: 3, count: 50,
                                       showsCounter: false) == "Sanren-sei")
    }
}
```

- [ ] **Step 2: Register the test file in the Xcode project**

```bash
cd "ios/KataGo iOS"
ruby -e '
require "xcodeproj"
proj   = Xcodeproj::Project.open("KataGo Anytime.xcodeproj")
target = proj.targets.find { |t| t.name == ARGV[0] }
anchor = proj.files.find { |f| f.path == ARGV[1] }
group  = anchor.parent
fname  = ARGV[2]
unless proj.files.any? { |f| f.path == fname }
  ref = group.new_file(fname)
  target.source_build_phase.add_file_reference(ref, true)
end
proj.save
' "KataGo AnytimeTests" "WatchBoardFrameTests.swift" "WatchBoardTitleTests.swift"
```

Expected: no output, exit 0. If `xcodeproj` is missing: `gem install --user-install xcodeproj` (Ruby is at `/usr/local/opt/ruby`).

- [ ] **Step 3: Run the tests to verify they fail**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchBoardTitleTests" 2>&1 | tail -30
```

Expected: compilation failure — `cannot find 'WatchBoardTitle' in scope`.

- [ ] **Step 4: Write the implementation**

Create `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchBoardTitle.swift`:

```swift
//
//  WatchBoardTitle.swift
//  KataGoGameStore
//
//  What the board page's navigation title says.
//
//  The watch board fills its whole page, so the title is the only chrome left
//  that can report status without covering stones — and after this change it is
//  the ONLY thing reporting it. That is why the precedence lives here, in one
//  testable place, rather than inline in a view: the watch target has no test
//  bundle, so a rule spelled out there cannot be tested at all.
//

import Foundation

public enum WatchBoardTitle {
    /// The live mirror's title. Precedence, highest first:
    ///
    ///   1. `Offline`   — the phone has stopped sending frames
    ///   2. `→ 5/50`    — a scrub is waiting on the phone to confirm
    ///   3. `3/50`      — cursor mode, parked behind the host's position
    ///   4. `3 behind`  — ring mode, parked behind the newest frame received
    ///   5. `Live`
    ///
    /// Staleness outranks a pending scrub deliberately. `WatchLiveModel.scrub`
    /// gates on `sharedCursorAvailable` (`!isStale && isReachable`), so a
    /// pending target can survive INTO a stale state but can never be created
    /// in one — and once the phone is unreachable it will never be confirmed.
    /// Reporting `→ 5/50` there would promise an arrival that cannot happen.
    public static func live(stale: Bool,
                            pendingTarget: Int?,
                            hostMoveIndex: Int?,
                            hostMoveCount: Int?,
                            sharedCursorAvailable: Bool,
                            movesBehindLive: Int) -> String {
        if stale { return "Offline" }
        if let pendingTarget { return "→ \(pendingTarget)/\(hostMoveCount ?? 0)" }
        if sharedCursorAvailable {
            // A pre-v1.1 phone sends no cursor at all, so an absent index is
            // "no position to report", not "position zero".
            guard let hostMoveIndex, let hostMoveCount,
                  hostMoveIndex < hostMoveCount else { return "Live" }
            return "\(hostMoveIndex)/\(hostMoveCount)"
        }
        return movesBehindLive > 0 ? "\(movesBehindLive) behind" : "Live"
    }

    /// A stored game's title: the scrub counter while the Crown is moving, the
    /// game's name once it settles.
    public static func stored(name: String, index: Int, count: Int,
                              showsCounter: Bool) -> String {
        showsCounter ? "\(index)/\(count)" : name
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchBoardTitleTests" 2>&1 | tail -20
```

Expected: output contains `TEST SUCCEEDED`; 9 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchBoardTitle.swift" \
        "ios/KataGo iOS/KataGo iOSTests/WatchBoardTitleTests.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -F - <<'EOF'
feat(watch): resolve the board page's title in one testable place

The board fills its whole page, so the title is the only chrome left that
can report status without covering stones. Put the precedence in the
package, where the watch target's untestable code cannot hide it.

Stale outranks a pending scrub: scrub gates on sharedCursorAvailable, so a
pending target can survive into a stale state but never be created in one,
and it will never be confirmed.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
```

---

### Task 3: `winratePercentText`

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchBoardFrame.swift` (add beside `scoreText`, currently at line 173)
- Test: `ios/KataGo iOS/KataGo iOSTests/WatchBoardFrameTests.swift` (append inside the existing struct)

**Interfaces:**
- Consumes: nothing.
- Produces: `WatchBoardFrame.winratePercentText(_ winrateBlack: Float) -> String`

- [ ] **Step 1: Write the failing test**

Append inside the existing `struct` in `ios/KataGo iOS/KataGo iOSTests/WatchBoardFrameTests.swift`, directly after `scoreTextReadsFromWhicheverSideLeads`:

```swift
    /// Every input here is exactly representable in Float, so the rounding
    /// boundaries are deterministic rather than dependent on binary
    /// approximation of the literal.
    @Test func winratePercentRoundsHalvesAwayFromZero() {
        #expect(WatchBoardFrame.winratePercentText(0) == "0%")
        #expect(WatchBoardFrame.winratePercentText(0.375) == "38%")
        #expect(WatchBoardFrame.winratePercentText(0.5) == "50%")
        #expect(WatchBoardFrame.winratePercentText(0.625) == "63%")
        #expect(WatchBoardFrame.winratePercentText(1) == "100%")
    }

    /// A win rate a hair under 1 must read 100%, not 99% — the watch reports
    /// what the phone computed, and truncation would understate a won game.
    @Test func winratePercentRoundsRatherThanTruncates() {
        #expect(WatchBoardFrame.winratePercentText(0.999) == "100%")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchBoardFrameTests" 2>&1 | tail -30
```

Expected: compilation failure — `type 'WatchBoardFrame' has no member 'winratePercentText'`.

- [ ] **Step 3: Write the implementation**

In `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchBoardFrame.swift`, immediately after the closing brace of `scoreText`, add:

```swift
    /// "62%" from Black's win rate.
    ///
    /// Black-perspective to agree with the gutter bar beside the board, which
    /// fills from the bottom for Black, and with that bar's accessibility
    /// label — the number and the picture must never disagree about whose win
    /// rate is being shown.
    public static func winratePercentText(_ winrateBlack: Float) -> String {
        "\(Int((winrateBlack * 100).rounded()))%"
    }
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchBoardFrameTests" 2>&1 | tail -20
```

Expected: `TEST SUCCEEDED`, 0 failures.

- [ ] **Step 5: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchBoardFrame.swift" \
        "ios/KataGo iOS/KataGo iOSTests/WatchBoardFrameTests.swift"
git commit -F - <<'EOF'
feat(watch): render Black's win rate as text

The gutter bar shows the win rate as a picture; the second page needs it as
a number. Black-perspective so the two can never disagree about whose rate
is on screen.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
```

---

### Task 4: The second pages gain the readouts

Additive only — after this task the score appears in **two** places (board and second page). Task 5 removes it from the board. This ordering means no commit ever has the score missing entirely.

**Files:**
- Create: `ios/KataGo iOS/KataGo Anytime Watch/WatchAnalysisSummary.swift`
- Modify: `ios/KataGo iOS/KataGo Anytime Watch/WatchMovesPage.swift:10` (top of the `List`)
- Modify: `ios/KataGo iOS/KataGo Anytime Watch/WatchStoredGameView.swift:106-133` (`reviewPage`)

**Interfaces:**
- Consumes: `WatchBoardFrame.winratePercentText`, `WatchBoardFrame.scoreText` (Task 3).
- Produces: `WatchAnalysisSummary(winrateBlack: Float?, scoreLeadBlack: Float?, staleSince: Date?)` — a `View` whose body is a set of sibling `List` rows, not a container.

- [ ] **Step 1: Create the shared section**

Create `ios/KataGo iOS/KataGo Anytime Watch/WatchAnalysisSummary.swift`:

```swift
import SwiftUI
import KataGoGameStore

/// The analysis readouts that used to be drawn on the board. Shared by the
/// live mirror's Top Moves page and a stored game's Review page for the same
/// reason WatchFrameBoard is shared: the two worlds must not drift apart.
///
/// The body is a set of sibling rows rather than a container, so a caller can
/// drop it straight into its own `List` and keep one flat list of rows.
///
/// Rows are omitted rather than zeroed when a value is absent — the watch
/// never invents a number.
struct WatchAnalysisSummary: View {
    let winrateBlack: Float?
    let scoreLeadBlack: Float?
    /// When the phone was last heard from. Non-nil only on the live mirror and
    /// only once the connection has gone stale.
    var staleSince: Date? = nil

    var body: some View {
        if let winrateBlack, winrateBlack.isFinite {
            LabeledContent("Black",
                           value: WatchBoardFrame.winratePercentText(winrateBlack))
        }
        if let scoreLeadBlack, scoreLeadBlack.isFinite {
            LabeledContent("Score", value: WatchBoardFrame.scoreText(scoreLeadBlack))
        }
        if let staleSince {
            Label {
                Text("Last update \(staleSince, style: .relative) ago")
            } icon: {
                Image(systemName: "wifi.slash")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            // The exact wording the deleted board glyph handed VoiceOver. The
            // visible row is shorter because the title already says "Offline";
            // the spoken one stays self-contained because a title is not read
            // alongside every row.
            .accessibilityElement()
            .accessibilityLabel(
                Text("Not receiving updates; last update \(staleSince, style: .relative) ago"))
        }
    }
}
```

- [ ] **Step 2: Register it in the Xcode project**

```bash
cd "ios/KataGo iOS"
ruby -e '
require "xcodeproj"
proj   = Xcodeproj::Project.open("KataGo Anytime.xcodeproj")
target = proj.targets.find { |t| t.name == ARGV[0] }
anchor = proj.files.find { |f| f.path == ARGV[1] }
group  = anchor.parent
fname  = ARGV[2]
unless proj.files.any? { |f| f.path == fname }
  ref = group.new_file(fname)
  target.source_build_phase.add_file_reference(ref, true)
end
proj.save
' "KataGo Anytime Watch" "KataGo Anytime Watch/WatchFrameBoard.swift" "KataGo Anytime Watch/WatchAnalysisSummary.swift"
```

Note the **path-qualified** filename here. Watch-target file references carry the full `KataGo Anytime Watch/...` path (unlike the test group, whose group carries the path and takes a bare filename) — verify with:

```bash
grep -c 'path = "KataGo Anytime Watch/WatchAnalysisSummary.swift"' \
  "KataGo Anytime.xcodeproj/project.pbxproj"
```

Expected: `1`.

- [ ] **Step 3: Add the summary to the live mirror's second page**

In `ios/KataGo iOS/KataGo Anytime Watch/WatchMovesPage.swift`, replace the opening of the `List` (currently `List {` followed directly by `if let live, live.analysisRunning, ...`) so the summary comes first:

```swift
        List {
            WatchAnalysisSummary(
                winrateBlack: live?.rootWinrateBlack,
                scoreLeadBlack: live?.rootScoreLeadBlack,
                // The board no longer says the phone has gone quiet, only the
                // title does — and a one-word title cannot say HOW quiet.
                staleSince: model.isStale
                    ? (model.receivedAt ?? live?.hostTimestamp) : nil)

            if let live, live.analysisRunning, live.isHumanTurn == false {
```

The rest of the `List` body is unchanged.

Note: the rows show whenever a snapshot exists, including while analysis is off. That is exact parity with the capsule being deleted in Task 5 — `WatchSnapshot.rootWinrateBlack`/`rootScoreLeadBlack` are non-optional, so `WatchBoardFrame.live` always populated them and the capsule always drew. Changing that is a separate decision, not this change.

- [ ] **Step 4: Add the summary to the stored game's Review page**

In `ios/KataGo iOS/KataGo Anytime Watch/WatchStoredGameView.swift`, replace the whole of `reviewPage` with:

```swift
    private func reviewPage(_ frame: WatchBoardFrame) -> some View {
        List {
            WatchAnalysisSummary(winrateBlack: frame.winrateBlack,
                                 scoreLeadBlack: frame.scoreLeadBlack)

            // Always present and always enabled, even at the many indices with
            // no cached analysis: the setting is global, and a control that
            // appeared and vanished as the user scrubbed would read as a
            // per-move property of the game rather than a preference.
            Toggle("Show best move", isOn: $showBestMove)

            // The one case where the vertex still has to be spelled out. A
            // cached "pass" cannot be drawn on the board, so with the toggle
            // on and no caption the user could not tell it apart from "nothing
            // was analyzed here" — which at the end of a scored game is
            // exactly the wrong conclusion.
            if case .unrenderable(let vertex) = frame.bestMoveMark(showBestMove: showBestMove) {
                Text("Best: \(vertex)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let comment = frame.comment {
                Text(comment).font(.caption)
            }
            // All four, not just two. A record can cache a win rate and a
            // score at an index while caching neither a best move nor a
            // comment; testing only the latter pair would print this denial
            // directly beneath a score the page had just displayed.
            if frame.winrateBlack == nil, frame.scoreLeadBlack == nil,
               frame.bestMove == nil, frame.comment == nil {
                Text("No analysis saved for this move").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Review")
    }
```

- [ ] **Step 5: Build the watch scheme**

```bash
cd "ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime Watch" \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' \
  2>&1 | tail -30
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Verify on the simulator**

Launch, open a stored game, swipe to `Review`. Expected: `Black` and `Score` above the `Show best move` toggle at an index with cached analysis; both absent at an index without it, where `No analysis saved for this move` appears instead.

Also check **how** they render. `WatchAnalysisSummary`'s body is several sibling views, and whether `List` flattens a custom view's body into separate rows or renders it as one merged row is not something to assume. If they come out as ordinary separate rows, done. If they render merged into a single row, that is cosmetic only — the readouts are off the board either way, which is the point — but say so in the task report rather than leaving it unremarked, so the choice to add a `Section` is made deliberately.

- [ ] **Step 7: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git add "ios/KataGo iOS/KataGo Anytime Watch/WatchAnalysisSummary.swift" \
        "ios/KataGo iOS/KataGo Anytime Watch/WatchMovesPage.swift" \
        "ios/KataGo iOS/KataGo Anytime Watch/WatchStoredGameView.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -F - <<'EOF'
feat(watch): report win rate, score and staleness on the second page

Gives the readouts a home off the board before the next commit takes them
off it. Shared by the live mirror and the offline browser so the two cannot
drift apart.

Review's "no analysis saved" now tests all four cached fields: a record can
cache a win rate and a score while caching neither a best move nor a
comment, and the old two-field test would have printed that denial directly
beneath a score.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
```

---

### Task 5: Clear the live mirror's board

**Files:**
- Modify: `ios/KataGo iOS/KataGo Anytime Watch/WatchFrameBoard.swift` (delete `statusCluster`, `isStale`, `staleAccessibilityLabel`, `suppressesScore`)
- Modify: `ios/KataGo iOS/KataGo Anytime Watch/WatchBoardPage.swift` (delete `statusPill`, `staleAccessibilityLabel`, the top overlay)
- Modify: `ios/KataGo iOS/KataGo Anytime Watch/WatchRootView.swift` (dynamic title)

**Interfaces:**
- Consumes: `WatchBoardTitle.live` (Task 2).
- Produces: `WatchFrameBoard(frame:showBestMove:)` — the two stale/score parameters are gone. `WatchStoredGameView` already calls it without them, so its call site needs no change.

- [ ] **Step 1: Slim `WatchFrameBoard`**

In `ios/KataGo iOS/KataGo Anytime Watch/WatchFrameBoard.swift`:

1. Delete the `staleAccessibilityLabel` and `suppressesScore` properties (lines 27-38 keep only the `showBestMove` property and its comment).
2. Delete the `isStale` computed property.
3. Delete the entire `statusCluster` property.
4. Delete `.overlay(alignment: .bottomLeading) { statusCluster }` from `board`.

The declaration block becomes:

```swift
struct WatchFrameBoard: View {
    let frame: WatchBoardFrame
    /// Whether to blend the record's cached best move onto the board. Defaults
    /// to false so the live mirror is provably unaffected — live frames carry
    /// no `bestMove` anyway (`WatchBoardFrame.live` hard-codes it nil), and
    /// only the stored browser's Review toggle passes true.
    var showBestMove: Bool = false
```

and `board` ends at:

```swift
                        style: .classicGoban(drawsOwnWood: true))
            .aspectRatio(CGFloat(frame.boardWidth) / CGFloat(frame.boardHeight),
                         contentMode: .fit)
    }
```

Leave the existing header comment intact — including the paragraph beginning "The board is HEIGHT-limited on every watch size", which is still true and still explains why the gutter is free. Append one paragraph to the end of it:

```swift
/// Nothing is drawn over the wood. Readouts that used to sit here — the score,
/// the staleness glyph, the scrub position — moved to the navigation title and
/// the second page. The corner they occupied is not information-sparse: on a
/// 9x9 it is as contested as anywhere else, and on smaller boards it is worse.
```

- [ ] **Step 2: Strip `WatchBoardPage`**

In `ios/KataGo iOS/KataGo Anytime Watch/WatchBoardPage.swift`:

1. Delete the `.overlay(alignment: .top) { statusPill }` line.
2. Delete the `staleAccessibilityLabel` computed property.
3. Delete the entire `statusPill` computed property.
4. Change the `WatchFrameBoard` call to:

```swift
            if let frame = liveFrame {
                WatchFrameBoard(frame: frame)
            }
```

`let peek = model.peek` at the top of `body` is still used by the `.onChange(of: peek.viewIndex, ...)` modifier — leave it.

- [ ] **Step 3: Make the live title dynamic**

In `ios/KataGo iOS/KataGo Anytime Watch/WatchRootView.swift`, replace `.navigationTitle("Live")` with `.navigationTitle(liveTitle)` and add this computed property to the struct, directly after `liveMirror`:

```swift
    /// The board page's only status readout. `hostMoveIndex` rather than the
    /// Crown's position deliberately: this reports what the PHONE has
    /// confirmed, exactly as the deleted pill did, while `pendingTarget`
    /// covers the in-flight value.
    private var liveTitle: String {
        WatchBoardTitle.live(stale: model.isStale,
                             pendingTarget: model.cursorPendingTarget,
                             hostMoveIndex: model.latest?.hostMoveIndex,
                             hostMoveCount: model.latest?.hostMoveCount,
                             sharedCursorAvailable: model.sharedCursorAvailable,
                             movesBehindLive: model.peek.movesBehindLive)
    }
```

- [ ] **Step 4: Build the watch scheme**

```bash
cd "ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime Watch" \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' \
  2>&1 | tail -30
```

Expected: `BUILD SUCCEEDED`, and no warning about an unused `staleAccessibilityLabel` or `suppressesScore`.

- [ ] **Step 5: Verify the board is clear**

Launch the live mirror against a paired phone simulator. Expected: no capsule, no glyph, no pill anywhere on the wood; the title reads `Live`. Scrub back with the Crown and confirm it reads `3/50`. Stop the phone app and wait past the 10-second staleness threshold; confirm it reads `Offline`.

- [ ] **Step 6: Try tinting `Offline` red**

Change the title to:

```swift
        .navigationTitle(Text(liveTitle)
            .foregroundStyle(model.isStale ? Color.red : Color.primary))
```

Rebuild, go stale, and screenshot.

**If the title renders red, keep it.** **If watchOS ignores the styling, revert this step** — restore `.navigationTitle(liveTitle)` — rather than leaving a modifier that does nothing. The word carries the meaning either way; nothing else depends on this.

- [ ] **Step 7: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git add "ios/KataGo iOS/KataGo Anytime Watch/WatchFrameBoard.swift" \
        "ios/KataGo iOS/KataGo Anytime Watch/WatchBoardPage.swift" \
        "ios/KataGo iOS/KataGo Anytime Watch/WatchRootView.swift"
git commit -F - <<'EOF'
fix(watch): stop drawing readouts over the live board

Reported from the device: on a 9x9 the score capsule and the staleness
glyph cover the bottom-left corner outright. The previous change maximized
the board and overlaid these on the wood on the theory that the corner is
information-sparse. It is not.

The score is already on the second page; staleness and the scrub position
move into the navigation title, which is chrome that exists above the board
and so costs no board area. Tapping the pill to return to live goes with
it — the Crown still reaches the head.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
```

---

### Task 6: Clear the stored browser's board

**Files:**
- Modify: `ios/KataGo iOS/KataGo Anytime Watch/WatchStoredGameView.swift`

**Interfaces:**
- Consumes: `WatchBoardTitle.stored` (Task 2).
- Produces: nothing.

- [ ] **Step 1: Delete the counter pill and move it into the title**

In `ios/KataGo iOS/KataGo Anytime Watch/WatchStoredGameView.swift`:

1. Delete the entire `counterPill(_:)` method.
2. In `boardPage`, delete `.overlay(alignment: .top) { counterPill(frame) }` **and** the `.animation(.easeInOut(duration: 0.2), value: showsCounter)` line beneath it.

   The `.animation` drove the pill's opacity transition. A `navigationTitle` is not animated by a SwiftUI animation applied to the board's `VStack`, so leaving it would be a modifier that animates nothing. **This deviates from the spec**, which said to keep it; the spec was wrong about what it affected.

3. Replace `.navigationTitle(model?.row.name ?? row.name)` with:

```swift
        .navigationTitle(WatchBoardTitle.stored(name: model?.row.name ?? row.name,
                                                index: model?.index ?? 0,
                                                count: model?.moveCount ?? 0,
                                                showsCounter: showsCounter))
```

4. Update the `showsCounter` doc comment to:

```swift
    /// Whether the title shows the scrub counter instead of the game's name.
    /// The board takes the whole page and nothing is drawn on the wood, so the
    /// counter lives in the title; showing it permanently would mean a game's
    /// name was never on screen, so it appears while the Crown is moving and
    /// gets out of the way afterwards.
    @State private var showsCounter = false
```

Leave `.task(id: crownIndex)` and its comment exactly as they are — that debounce is what makes this work, and it is unchanged.

- [ ] **Step 2: Build the watch scheme**

```bash
cd "ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime Watch" \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' \
  2>&1 | tail -30
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Verify on the simulator**

Open a stored game. Expected: the title shows `3/50` on open, then settles to the game's name after two seconds. Turn the Crown: it returns to `3/50` while turning and settles again two seconds after the last detent. Nothing is drawn on the wood at any point.

- [ ] **Step 4: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git add "ios/KataGo iOS/KataGo Anytime Watch/WatchStoredGameView.swift"
git commit -F - <<'EOF'
fix(watch): move the stored game's scrub counter into the title

The last thing drawn on the wood. Same two-second debounce as before, so
the counter still appears while the Crown moves and gets out of the way
afterwards — it just no longer covers the board's top edge to do it.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF
EOF
```

---

### Task 7: Whole-product verification

**Files:** none (verification only).

- [ ] **Step 1: Run the full test suite**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -30
```

Expected: `TEST SUCCEEDED`, 0 failures. Judge by the failure count, not the exit code.

- [ ] **Step 2: Build every scheme, one at a time**

Never concurrently — a DerivedData lock yields a spurious failure.

```bash
cd "ios/KataGo iOS"
for s in "KataGo Anytime:platform=iOS Simulator,name=iPhone 17" \
         "KataGo Anytime Mac:platform=macOS" \
         "KataGo Anytime Vision:platform=visionOS Simulator,name=Apple Vision Pro" \
         "KataGo Anytime TV:platform=tvOS Simulator,name=Apple TV" \
         "KataGo Anytime Watch:platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)"; do
  scheme="${s%%:*}"; dest="${s#*:}"
  echo "=== $scheme ==="
  xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "$scheme" \
    -destination "$dest" -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
done
```

Expected: five `BUILD SUCCEEDED` lines.

- [ ] **Step 3: Confirm the reported bug is fixed**

Reproduce the original report: a 9x9 with stones in the bottom-left, mirrored live, allowed to go stale. Screenshot.

Expected: every stone in the bottom-left corner is visible; the title reads `Offline`; the score is on the second page.

- [ ] **Step 4: Check the states that were not reported**

- Small board (2x2 or 5x5) — nothing on the wood.
- Wide board (13x9) — nothing on the wood, and the win-rate gutter still spans exactly the board's height, not the page's.
- Rejection banner — attempt an illegal move from the watch and confirm the banner still appears over the board's bottom edge and self-clears. This is the one deliberate exception (spec Decision 4); it must still work.

- [ ] **Step 5: Report**

Summarize what was verified and what was left for on-wrist QA. **Do not push** — pushes to `ios-dev` trigger an Xcode Cloud archive and TestFlight build, and are spaced at least a day apart. There are already unpushed commits on this branch; leave the push decision to the user.
