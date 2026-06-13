# Branch Mode Indicator & Branch Commit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make branch mode unmistakable (red border around the board) and give it a non-destructive exit (a dialog offering to replace the saved game with the branch, instead of discard-only).

**Architecture:** A new `GobanState.commitBranch(gameRecord:)` commits the live branch line (`branchSgf`/`branchIndex`) into the `GameRecord` — clearing per-index analysis data past the divergence point first — then deactivates the branch so the existing `onChange(of: branchSgf)` machinery reloads the (now-committed) SGF into the engine. The `confirmingBranchDeactivation` dialog in `GameSplitView` grows from one action ("Restore") to three (Replace / Discard / Cancel). The indicator is a red `Rectangle().stroke` in `BoardView`'s ZStack with the exact geometry of the wood board image, gated on `gobanState.isBranchActive`.

**Tech Stack:** SwiftUI, Swift Testing (`import Testing`, `@Test`, `#expect`), SwiftData (`GameRecord` @Model — schema frozen, no stored-property changes), `xcodeproj` Ruby gem for pbxproj registration.

**Spec:** `docs/superpowers/specs/2026-06-13-branch-mode-indicator-design.md`

**Key background for a zero-context engineer:**

- Repo root: `/Users/chinchangyang/Code/KataGo-ios-dev`, branch `ios-dev` (work directly on it; commit but NEVER push). App sources: `ios/KataGo iOS/KataGo iOS/`; unit tests: `ios/KataGo iOS/KataGo iOSTests/` (target `KataGo AnytimeTests`, module `KataGo_Anytime`).
- The Xcode project has no synchronized groups — new `.swift` files must be registered in `project.pbxproj` via the `xcodeproj` Ruby gem (snippet in Task 1). Saving via the gem may mechanically reorder unrelated pbxproj entries; that's normal.
- Branch-mode model: while a branch is active, `GobanState.branchSgf` holds the live branch SGF (updated by `printsgf` responses in `ContentView.maybeCollectSgf`), `GobanState.branchIndex` is the position within it, and crucially `gameRecord.currentIndex` still sits at the **divergence point** (branch navigation moves `branchIndex`, not `currentIndex` — see `GobanState.undoIndex`). `gameRecord.sgf` is the untouched original.
- Inactive sentinels: `String.inActiveSgf == ""`, `Int.inActiveCurrentIndex == -1`, with `isActiveSgf`/`isActiveSgfIndex` helpers (`KataGoModel.swift:510-525`). `GobanState.isBranchActive` (GobanState.swift:393-395) checks both; `deactivateBranch()` (GobanState.swift:397-400) resets both.
- `GameRecord.clearData(after: index)` (GameRecord.swift:285) filters every per-index dictionary (comments, winRates, scoreLeads, bestMoves, ownership, etc.) to keys `<= index`.
- `GameRecord` is a SwiftData `@Model` with a frozen CloudKit schema — do NOT add stored properties. `commitBranch` only writes existing properties (`sgf`, `currentIndex`, `lastModificationDate`).
- Tests run on the iOS Simulator only. Builds must succeed on iOS, macOS, and visionOS.

---

### Task 1: `GobanState.commitBranch(gameRecord:)` (TDD)

**Files:**
- Create: `ios/KataGo iOS/KataGo iOSTests/GobanStateBranchTests.swift`
- Modify: `ios/KataGo iOS/KataGo iOS/GobanState.swift` (after `deactivateBranch()`, GobanState.swift:397-400)
- Modify: `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj` (via Ruby gem only)

- [ ] **Step 1: Register the new test file in the Xcode project**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
touch "KataGo iOSTests/GobanStateBranchTests.swift"

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
' "KataGo AnytimeTests" "NavigationContextTests.swift" "GobanStateBranchTests.swift"
```

If `require "xcodeproj"` fails, use `/usr/local/opt/ruby/bin/ruby` instead of `ruby`.

- [ ] **Step 2: Write the failing tests**

Full content of `ios/KataGo iOS/KataGo iOSTests/GobanStateBranchTests.swift`:

```swift
//
//  GobanStateBranchTests.swift
//  KataGo AnytimeTests
//

import Testing
@testable import KataGo_Anytime

struct GobanStateBranchTests {
    // Original line: 4 moves. Branch diverges after move 2 with 3 new moves.
    private static let originalSgf = "(;FF[4]GM[1]SZ[9];B[aa];W[bb];B[cc];W[dd])"
    private static let branchLineSgf = "(;FF[4]GM[1]SZ[9];B[aa];W[bb];B[ee];W[ff];B[gg])"

    @Test func commitBranchReplacesGame() {
        // Divergence at index 2: data at indices <= 2 is shared with the
        // branch and must survive; index 3+ belongs to the original tail.
        let gameRecord = GameRecord.createGameRecord(
            sgf: Self.originalSgf,
            currentIndex: 2,
            comments: [1: "shared", 2: "at divergence", 3: "original tail"],
            winRates: [1: 0.5, 2: 0.6, 3: 0.7]
        )
        let dateBefore = gameRecord.lastModificationDate
        let gobanState = GobanState()
        gobanState.branchSgf = Self.branchLineSgf
        gobanState.branchIndex = 5

        gobanState.commitBranch(gameRecord: gameRecord)

        #expect(gameRecord.sgf == Self.branchLineSgf)
        #expect(gameRecord.currentIndex == 5)
        #expect(gameRecord.comments == [1: "shared", 2: "at divergence"])
        #expect(gameRecord.winRates == [1: 0.5, 2: 0.6])
        #expect(gameRecord.lastModificationDate != dateBefore)
        #expect(gobanState.isBranchActive == false)
        #expect(gobanState.branchSgf == .inActiveSgf)
        #expect(gobanState.branchIndex == .inActiveCurrentIndex)
    }

    @Test func commitBranchWithoutActiveBranchIsNoOp() {
        let gameRecord = GameRecord.createGameRecord(
            sgf: Self.originalSgf,
            currentIndex: 4,
            comments: [1: "keep", 4: "keep too"]
        )
        let dateBefore = gameRecord.lastModificationDate
        let gobanState = GobanState() // branch fields at inactive sentinels

        gobanState.commitBranch(gameRecord: gameRecord)

        #expect(gameRecord.sgf == Self.originalSgf)
        #expect(gameRecord.currentIndex == 4)
        #expect(gameRecord.comments == [1: "keep", 4: "keep too"])
        #expect(gameRecord.lastModificationDate == dateBefore)
    }

    @Test func commitBranchClearsDataPastDivergenceNotPastNewIndex() {
        // Divergence at index 1; the branch ends at index 3. Data at
        // indices 2-4 belongs to the original tail and must be dropped
        // even though they are <= the NEW currentIndex (3) — i.e.
        // clearData must run before currentIndex is reassigned.
        let gameRecord = GameRecord.createGameRecord(
            sgf: Self.originalSgf,
            currentIndex: 1,
            comments: [0: "root", 1: "divergence", 2: "tail", 3: "tail", 4: "tail"]
        )
        let gobanState = GobanState()
        gobanState.branchSgf = Self.branchLineSgf
        gobanState.branchIndex = 3

        gobanState.commitBranch(gameRecord: gameRecord)

        #expect(gameRecord.comments == [0: "root", 1: "divergence"])
        #expect(gameRecord.currentIndex == 3)
        #expect(gobanState.isBranchActive == false)
    }
}
```

Note on `createGameRecord`: it's a class func with defaulted parameters in the order `sgf, currentIndex, name, comments, thumbnail, scoreLeads, bestMoves, winRates, ...` (GameRecord.swift:316) — the calls above skip defaulted parameters but keep the declaration order, which Swift requires.

- [ ] **Step 3: Run the tests to verify they fail**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/GobanStateBranchTests"
```

Expected: **build failure** — `value of type 'GobanState' has no member 'commitBranch'`. Large build; use a 10-minute timeout, pipe through `tail -40`.

- [ ] **Step 4: Implement `commitBranch`**

In `ios/KataGo iOS/KataGo iOS/GobanState.swift`, directly after `deactivateBranch()` (lines 397-400), add:

```swift
    /// Replaces the saved game with the active branch line. Per-index data
    /// past the divergence point (where the original and branch lines stop
    /// sharing moves) is dropped; clearData must run before currentIndex is
    /// reassigned because gameRecord.currentIndex IS the divergence point
    /// while a branch is active (branch navigation moves branchIndex only).
    func commitBranch(gameRecord: GameRecord) {
        guard isBranchActive else { return }

        gameRecord.clearData(after: gameRecord.currentIndex)
        gameRecord.sgf = branchSgf
        gameRecord.currentIndex = branchIndex
        gameRecord.lastModificationDate = Date.now
        deactivateBranch()
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Same command as Step 3. Expected: all 3 tests PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-ios-dev
git add "ios/KataGo iOS/KataGo iOS/GobanState.swift" \
        "ios/KataGo iOS/KataGo iOSTests/GobanStateBranchTests.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(goban): commitBranch replaces saved game with branch line

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Branch-exit dialog with Replace / Discard / Cancel

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/GameSplitView.swift:196-208`

- [ ] **Step 1: Replace the deactivation dialog**

In `GameSplitView.swift`, the `detailView` currently ends with this confirmation dialog (lines 196-208):

```swift
        .confirmationDialog(
            "Are you sure you want to restore the game position? This will discard the current branch.",
            isPresented: $gobanState.confirmingBranchDeactivation,
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive) {
                gobanState.deactivateBranch()
            }

            Button("Cancel", role: .cancel) {
                gobanState.confirmingBranchDeactivation = false
            }
        }
```

Replace it with:

```swift
        .confirmationDialog(
            "Branch moves are temporary. Replace the original game with this branch, or discard it?",
            isPresented: $gobanState.confirmingBranchDeactivation,
            titleVisibility: .visible
        ) {
            Button("Replace Original with Branch", role: .destructive) {
                if let gameRecord = navigationContext.selectedGameRecord {
                    gobanState.commitBranch(gameRecord: gameRecord)
                }
            }

            Button("Discard Branch", role: .destructive) {
                gobanState.deactivateBranch()
            }

            Button("Cancel", role: .cancel) {
                gobanState.confirmingBranchDeactivation = false
            }
        }
```

(`navigationContext` is already in scope — `GameSplitView` uses `navigationContext.selectedGameRecord` in the adjacent AI-overwrite dialog at line 150. If `selectedGameRecord` is nil — not reachable while a branch is active — the Replace button does nothing and the branch stays active, which is the safe non-destructive outcome.)

- [ ] **Step 2: Build to verify**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-ios-dev
git add "ios/KataGo iOS/KataGo iOS/GameSplitView.swift"
git commit -m "feat(goban): branch exit dialog offers replace or discard

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Red border indicator around the board

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/BoardView.swift` (ZStack, lines 47-73)

- [ ] **Step 1: Add the border to `BoardView`'s ZStack**

In `BoardView.swift`, the ZStack currently ends with (lines 64-72):

```swift
                    MoveNumberView(dimensions: dimensions,
                                   verticalFlip: gobanState.verticalFlip,
                                   style: gobanState.moveNumberStyleChoice,
                                   moveNumbers: gobanState.getMoveNumbers(gameRecord: gameRecord))

                    if shouldShowWinrateBar {
                        WinrateBarView(dimensions: dimensions)
                            .transition(.opacity)
                    }
```

Insert the border between the `MoveNumberView` and the `if shouldShowWinrateBar` block:

```swift
                    MoveNumberView(dimensions: dimensions,
                                   verticalFlip: gobanState.verticalFlip,
                                   style: gobanState.moveNumberStyleChoice,
                                   moveNumbers: gobanState.getMoveNumbers(gameRecord: gameRecord))

                    if gobanState.isBranchActive {
                        // Reminder that branch stones are temporary; geometry
                        // matches BoardLineView.drawBoardBackground's wood rect.
                        Rectangle()
                            .stroke(.red, lineWidth: max(2, dimensions.squareLength / 16))
                            .frame(width: dimensions.gobanWidth, height: dimensions.gobanHeight)
                            .position(x: dimensions.gobanStartX + (dimensions.gobanWidth / 2),
                                      y: dimensions.gobanStartY + (dimensions.gobanHeight / 2))
                    }

                    if shouldShowWinrateBar {
                        WinrateBarView(dimensions: dimensions)
                            .transition(.opacity)
                    }
```

(`Dimensions` exposes `gobanStartX`, `gobanStartY`, `gobanWidth`, `gobanHeight`, `squareLength` — the same properties `BoardLineView.drawBoardBackground` uses at BoardLineView.swift:66-76, so the stroke hugs the wood image exactly.)

- [ ] **Step 2: Build to verify**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-ios-dev
git add "ios/KataGo iOS/KataGo iOS/BoardView.swift"
git commit -m "feat(goban): red board border while branch mode is active

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Full verification

**Files:** none (verification only; fix-up commits if anything fails)

- [ ] **Step 1: Run the full unit-test suite**

```bash
xcodebuild test -project "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17'
```

Expected: `** TEST SUCCEEDED **` (all suites, including the 3 new `GobanStateBranchTests`).

- [ ] **Step 2: Build macOS**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=macOS' -configuration Debug
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Build visionOS**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit any verification fixes**

Only if Steps 1-3 required changes; use a `fix(goban): ...` message. Do **not** push — the user decides when to push (Xcode Cloud free tier).
