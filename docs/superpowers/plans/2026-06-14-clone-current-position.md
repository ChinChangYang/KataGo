# Clone Current Position Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Clone menu item offer "Clone Whole Game" (today's behavior) and "Clone Current Position" (a copy truncated to the move the user is viewing).

**Architecture:** A pure, unit-tested Swift SGF-truncation helper (`SgfTruncation`) cuts the stored SGF to N move nodes; `GameRecord.clone(upToMove:)` reuses it plus the existing `clearData(after:)` to produce a trimmed copy; `PlusMenuView`'s Clone button presents a `confirmationDialog` choosing between the two clones.

**Tech Stack:** SwiftUI, Swift Testing (`import Testing`, `@Test`, `#expect`), `SgfHelper` (KataGoInterface) for test assertions, `xcodeproj` Ruby gem for pbxproj registration.

**Spec:** `docs/superpowers/specs/2026-06-14-clone-current-position-design.md`

**Key background for a zero-context engineer:**

- Repo root `/Users/chinchangyang/Code/KataGo-ios-dev`, branch `ios-dev` (work on it; commit but NEVER push). App sources: `ios/KataGo iOS/KataGo iOS/`; unit tests: `ios/KataGo iOS/KataGo iOSTests/` (target `KataGo AnytimeTests`, module `KataGo_Anytime`, Swift Testing).
- New `.swift` files must be registered in `project.pbxproj` via the `xcodeproj` Ruby gem (no synchronized groups). Snippet in Task 1. If `require "xcodeproj"` fails, use `/usr/local/opt/ruby/bin/ruby`.
- Unit tests run under the default test plan and in CI. Run a single suite with `-only-testing:"KataGo AnytimeTests/<SuiteName>"`.
- `GameRecord` is a SwiftData `@Model` — do NOT change its stored-property schema. We only add methods. `GameRecord.clone()` (GameRecord.swift:248) deep-copies the record; `GameRecord.clearData(after: index)` (GameRecord.swift:285) filters every per-index dictionary to keys `<= index`. `GameRecord.createGameRecord(...)` builds a standalone record without a ModelContainer (used by existing tests).
- The `GameRecord` init parameter order is: `sgf, currentIndex, config, name, lastModificationDate, comments, thumbnail, scoreLeads, bestMoves, winRates, deadBlackStones, deadWhiteStones, blackSchrodingerStones, whiteSchrodingerStones, moves, blackStones, whiteStones, ownershipWhiteness, ownershipScales, width, height`.
- Stored SGFs are linear `printsgf` mainlines: `(;<root props>;B[..];W[..];…)`. `currentIndex` = number of moves played; SGF indices `0..<currentIndex` are the played moves. `SgfHelper(sgf:).moveSize` returns the move count.
- Behavior-preserving for the existing "whole game" path; the new path is additive. Builds must succeed on iOS, macOS, visionOS.

---

### Task 1: `SgfTruncation` helper + tests (TDD)

**Files:**
- Create: `ios/KataGo iOS/KataGo iOS/SgfTruncation.swift`
- Create: `ios/KataGo iOS/KataGo iOSTests/SgfTruncationTests.swift`
- Modify: `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj` (gem only)

- [ ] **Step 1: Register both files in the Xcode project**

(Anchoring the source file on `GameRecord.swift` places it in the `Model` group.)

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
touch "KataGo iOS/SgfTruncation.swift" "KataGo iOSTests/SgfTruncationTests.swift"

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
' "KataGo Anytime" "GameRecord.swift" "SgfTruncation.swift"

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
' "KataGo AnytimeTests" "NavigationContextTests.swift" "SgfTruncationTests.swift"
```

- [ ] **Step 2: Write the failing tests**

Full content of `ios/KataGo iOS/KataGo iOSTests/SgfTruncationTests.swift`:

```swift
//
//  SgfTruncationTests.swift
//  KataGo AnytimeTests
//

import Testing
import KataGoInterface
@testable import KataGo_Anytime

struct SgfTruncationTests {
    static let fourMoves = "(;FF[4]GM[1]SZ[9];B[aa];W[bb];B[cc];W[dd])"

    @Test func truncatesToTwoMoves() {
        let r = SgfTruncation.truncate(Self.fourMoves, toMoveCount: 2)
        #expect(r == "(;FF[4]GM[1]SZ[9];B[aa];W[bb])")
        #expect(SgfHelper(sgf: r).moveSize == 2)
    }

    @Test func truncatesToZeroKeepsOnlyRoot() {
        let r = SgfTruncation.truncate(Self.fourMoves, toMoveCount: 0)
        #expect(r == "(;FF[4]GM[1]SZ[9])")
        #expect(SgfHelper(sgf: r).moveSize == 0)
    }

    @Test func fullCountReturnsUnchanged() {
        #expect(SgfTruncation.truncate(Self.fourMoves, toMoveCount: 4) == Self.fourMoves)
    }

    @Test func countBeyondMovesReturnsUnchanged() {
        #expect(SgfTruncation.truncate(Self.fourMoves, toMoveCount: 10) == Self.fourMoves)
    }

    @Test func semicolonInsideCommentDoesNotShiftCut() {
        // The ';' inside C[...] must not be counted as a node delimiter.
        let sgf = "(;FF[4]GM[1]SZ[9];B[aa]C[hi; there];W[bb];B[cc])"
        let r = SgfTruncation.truncate(sgf, toMoveCount: 1)
        #expect(r == "(;FF[4]GM[1]SZ[9];B[aa]C[hi; there])")
        #expect(SgfHelper(sgf: r).moveSize == 1)
    }

    @Test func passMoveIsCounted() {
        // W[] is a pass; truncate-to-2 keeps B[aa] and the pass.
        let sgf = "(;FF[4]GM[1]SZ[9];B[aa];W[];B[cc])"
        let r = SgfTruncation.truncate(sgf, toMoveCount: 2)
        #expect(r == "(;FF[4]GM[1]SZ[9];B[aa];W[])")
        #expect(SgfHelper(sgf: r).moveSize == 2)
    }
}
```

Note: if KataGo's parser rejects the empty-property pass `W[]` in `passMoveIsCounted` (the assertion on `r ==` still holds regardless; only the `moveSize` line would differ), keep the string assertion and adjust the move-count expectation to what `SgfHelper` reports — the truncation behavior is what this test pins.

- [ ] **Step 3: Run the tests to verify they fail**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/SgfTruncationTests" 2>&1 | tail -40
```

Expected: **build failure** — `cannot find 'SgfTruncation' in scope`. Large build; 600000 ms timeout.

- [ ] **Step 4: Write the implementation**

Full content of `ios/KataGo iOS/KataGo iOS/SgfTruncation.swift`:

```swift
//
//  SgfTruncation.swift
//  KataGo iOS
//

import Foundation

/// Truncates a linear SGF to its first N move nodes. Pure and bracket-aware:
/// a comment value containing ';' or an escaped ']' cannot shift the cut.
/// Assumes a linear SGF with no variations, which is what the app saves
/// (printsgf mainline output).
enum SgfTruncation {
    /// Returns `sgf` containing only the root node plus the first `n` move
    /// nodes, closed with ")". If `sgf` has `n` or fewer moves (or `n < 0`),
    /// returns `sgf` unchanged.
    static func truncate(_ sgf: String, toMoveCount n: Int) -> String {
        guard n >= 0 else { return sgf }

        let chars = Array(sgf)
        var inBracket = false
        var escaped = false
        var topLevelSemicolons = 0   // 1st = root node; (k+1)-th = move node k

        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inBracket {
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "]" {
                    inBracket = false
                }
            } else if c == "[" {
                inBracket = true
            } else if c == ";" {
                topLevelSemicolons += 1
                // The (n+2)-th top-level ';' starts move node n+1: cut here.
                if topLevelSemicolons == n + 2 {
                    return String(chars[0..<i]) + ")"
                }
            }
            i += 1
        }

        // Fewer than n+1 moves were present — nothing to truncate.
        return sgf
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Same command as Step 3. Expected: 6/6 `SgfTruncationTests` PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-ios-dev
git add "ios/KataGo iOS/KataGo iOS/SgfTruncation.swift" \
        "ios/KataGo iOS/KataGo iOSTests/SgfTruncationTests.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(clone): add SgfTruncation helper

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `GameRecord.clone(upToMove:)` + test (TDD)

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/GameRecord.swift` (add a method after `clone()`, which ends around line 278)
- Modify: `ios/KataGo iOS/KataGo iOSTests/GameRecordTests.swift` (append a test; file already registered)

- [ ] **Step 1: Write the failing test**

Append this method inside the existing `struct GameRecordTests { … }` in `ios/KataGo iOS/KataGo iOSTests/GameRecordTests.swift` (before its closing brace):

```swift
    @Test func cloneUpToMoveTruncatesSgfAndData() async throws {
        let sgf = "(;FF[4]GM[1]SZ[9];B[aa];W[bb];B[cc];W[dd])"
        let record = GameRecord.createGameRecord(
            sgf: sgf,
            currentIndex: 4,
            name: "Game",
            comments: [0: "z", 1: "a", 2: "b", 3: "c", 4: "d"],
            winRates: [1: 0.5, 2: 0.6, 3: 0.7, 4: 0.8]
        )

        let copy = record.clone(upToMove: 2)

        #expect(copy.sgf == "(;FF[4]GM[1]SZ[9];B[aa];W[bb])")
        #expect(copy.currentIndex == 2)
        #expect(copy.comments == [0: "z", 1: "a", 2: "b"])
        #expect(copy.winRates == [1: 0.5, 2: 0.6])
        #expect(copy.name == "Game (copy)")
        #expect(record.config !== copy.config)
        // Original is untouched.
        #expect(record.sgf == sgf)
        #expect(record.currentIndex == 4)
    }
```

(`createGameRecord` is a class func with defaulted, labeled parameters; the call skips the ones it does not set.)

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/GameRecordTests/cloneUpToMoveTruncatesSgfAndData" 2>&1 | tail -30
```

Expected: **build failure** — `value of type 'GameRecord' has no member 'clone(upToMove:)'`.

- [ ] **Step 3: Write the implementation**

In `ios/KataGo iOS/KataGo iOS/GameRecord.swift`, immediately after the existing `clone()` method (which ends with `return newGameRecord` then `}` around line 278), add:

```swift
    /// Like `clone()`, but the copy contains only the moves up to `index`:
    /// the SGF is truncated to `index` move nodes, `currentIndex` is set to
    /// `index`, and per-index data after `index` is dropped.
    func clone(upToMove index: Int) -> GameRecord {
        let newConfig = Config(config: self.config)
        let truncatedSgf = SgfTruncation.truncate(self.sgf, toMoveCount: index)

        let newGameRecord = GameRecord(
            sgf: truncatedSgf,
            currentIndex: index,
            config: newConfig,
            name: self.name + " (copy)",
            lastModificationDate: Date.now,
            comments: self.comments,
            thumbnail: self.thumbnail,
            scoreLeads: self.scoreLeads,
            bestMoves: self.bestMoves,
            winRates: self.winRates,
            deadBlackStones: self.deadBlackStones,
            deadWhiteStones: self.deadWhiteStones,
            blackSchrodingerStones: self.blackSchrodingerStones,
            whiteSchrodingerStones: self.whiteSchrodingerStones,
            moves: self.moves,
            blackStones: self.blackStones,
            whiteStones: self.whiteStones,
            ownershipWhiteness: self.ownershipWhiteness,
            ownershipScales: self.ownershipScales,
            width: self.width,
            height: self.height
        )

        newGameRecord.clearData(after: index)
        newConfig.gameRecord = newGameRecord
        return newGameRecord
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Same command as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-ios-dev
git add "ios/KataGo iOS/KataGo iOS/GameRecord.swift" "ios/KataGo iOS/KataGo iOSTests/GameRecordTests.swift"
git commit -m "feat(clone): GameRecord.clone(upToMove:) for current-position copy

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Clone dialog in `PlusMenuView`

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/PlusMenuView.swift`

- [ ] **Step 1: Add the dialog state flag**

In `PlusMenuView`, after `@State private var showingDeveloper = false` (line ~19), add:

```swift
    @State private var confirmingClone = false
```

- [ ] **Step 2: Change the Clone button to open the dialog**

Replace the existing Clone button (inside the `if let gameRecord { … }` block) — currently:

```swift
                Button {
                    withAnimation {
                        let newGameRecord = gameRecord.clone()
                        modelContext.insert(newGameRecord)
                        navigationContext.selectedGameRecord = newGameRecord
                    }
                } label: {
                    Label("Clone", systemImage: "doc.on.doc")
                }
```

with:

```swift
                Button {
                    confirmingClone = true
                } label: {
                    Label("Clone", systemImage: "doc.on.doc")
                }
```

- [ ] **Step 3: Attach the confirmation dialog**

In `PlusMenuView`'s `body`, find the existing `.sheet(isPresented: $showingDeveloper) { … }` modifier on the `Menu` and add the `confirmationDialog` immediately after it (same modifier chain on the `Menu`):

```swift
        .confirmationDialog(
            "Clone this game",
            isPresented: $confirmingClone,
            titleVisibility: .visible
        ) {
            if let gameRecord {
                Button("Clone Whole Game") {
                    withAnimation {
                        let newGameRecord = gameRecord.clone()
                        modelContext.insert(newGameRecord)
                        navigationContext.selectedGameRecord = newGameRecord
                    }
                }

                Button("Clone Current Position") {
                    withAnimation {
                        let newGameRecord = gameRecord.clone(upToMove: gameRecord.currentIndex)
                        modelContext.insert(newGameRecord)
                        navigationContext.selectedGameRecord = newGameRecord
                    }
                }
            }

            Button("Cancel", role: .cancel) { }
        }
```

(Presenting a dialog from a `Menu` button works here — the existing `.sheet`s open the same way. If the dialog ever fails to appear on device, defer the flag: `Button { Task { @MainActor in confirmingClone = true } }`.)

- [ ] **Step 4: Build to verify (iOS Simulator)**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | tail -10
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-ios-dev
git add "ios/KataGo iOS/KataGo iOS/PlusMenuView.swift"
git commit -m "feat(clone): Clone menu offers whole game vs current position

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Full verification

**Files:** none (verification only; fix-up commits if anything fails)

- [ ] **Step 1: Full unit-test suite (iOS Simulator)**

```bash
xcodebuild test -project "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`, including `SgfTruncationTests` (6) and the new `GameRecordTests/cloneUpToMoveTruncatesSgfAndData`.

- [ ] **Step 2: Build macOS**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=macOS' -configuration Debug 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Build visionOS**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit any verification fixes**

Only if Steps 1-3 required changes; use a `fix(clone): ...` message. Do **not** push.
