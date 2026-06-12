# Move Number Display Setting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a global setting that lets the user choose how move numbers are shown on the board: last-3 relative numbers (current behavior, default), absolute number on the last move, absolute numbers on all stones, or a triangle marker on the last move.

**Architecture:** Numbering is derived Swift-side from the active game's SGF (`SgfHelper.getMove(at:)` over `0..<currentIndex`), converted to `BoardPoint`s via the existing `BoardPoint(location:width:height:)` initializer, and cached in `GobanState` keyed by `(sgf, currentIndex)` like the existing `getNextMove` cache. The setting follows the `stoneStyle` pattern: static string constants on `Config` (the SwiftData `@Model` schema is frozen — statics only, no stored properties), an `Int` property on `GobanState`, an `@AppStorage("GlobalSettings.moveNumberStyle")` bridge in `GlobalPreferenceSync`, and a `ConfigTextPicker` in `GlobalSettingsView`'s Board section. `MoveNumberView` switches on the style; the existing showboard-driven 1-2-3 path is untouched.

**Tech Stack:** SwiftUI, Swift Testing (`import Testing`, `@Test`, `#expect`), `SgfHelper` (KataGoInterface framework), `xcodeproj` Ruby gem for pbxproj registration.

**Spec:** `docs/superpowers/specs/2026-06-12-move-number-display-design.md`

**Key background for a zero-context engineer:**

- The repo root is `/Users/chinchangyang/Code/KataGo-ios-dev`. All Swift app code is under `ios/KataGo iOS/KataGo iOS/`, unit tests under `ios/KataGo iOS/KataGo iOSTests/` (target name `KataGo AnytimeTests`, module `KataGo_Anytime`).
- The Xcode project does **not** use file-system-synchronized groups. A new `.swift` file will not compile until registered in `project.pbxproj` (use the Ruby snippet in Task 1; never hand-edit the pbxproj). Saving via the gem re-serializes the pbxproj — mechanical reordering of existing entries in the diff is normal.
- `Config` is a SwiftData `@Model` synced via CloudKit. Its stored-property schema is **frozen** — adding a stored property corrupts sync. Static constants and computed properties are safe.
- SGF coordinates from `SgfHelper.Move.location` are 0-indexed with y counted from the **top**. `BoardPoint` y is 0-indexed from the **bottom**. `BoardPoint(location:width:height:)` (KataGoModel.swift:66) performs the conversion — always use it, never convert by hand.
- `gameRecord.currentIndex` counts moves already played, so the played moves are SGF indices `0..<currentIndex`, and `getMove(at: currentIndex)` is the *next* (unplayed) move.
- Tests only run on the iOS Simulator.

---

### Task 1: `MoveNumbers` derivation helper (TDD)

**Files:**
- Create: `ios/KataGo iOS/KataGo iOS/MoveNumbers.swift`
- Create: `ios/KataGo iOS/KataGo iOSTests/MoveNumbersTests.swift`
- Modify: `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj` (via Ruby gem only)

- [ ] **Step 1: Register both new files in the Xcode project**

Run from `ios/KataGo iOS/` (create the empty files first so Xcode resolves them):

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
touch "KataGo iOS/MoveNumbers.swift" "KataGo iOSTests/MoveNumbersTests.swift"

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
' "KataGo Anytime" "ContentView.swift" "MoveNumbers.swift"

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
' "KataGo AnytimeTests" "NavigationContextTests.swift" "MoveNumbersTests.swift"
```

If `require "xcodeproj"` fails, use `/usr/local/opt/ruby/bin/ruby` instead of `ruby` (gem was installed with `--user-install` against the Homebrew Ruby).

- [ ] **Step 2: Write the failing tests**

Full content of `ios/KataGo iOS/KataGo iOSTests/MoveNumbersTests.swift`:

```swift
//
//  MoveNumbersTests.swift
//  KataGo AnytimeTests
//

import Testing
import KataGoInterface
@testable import KataGo_Anytime

struct MoveNumbersTests {
    // 5x5 board, three moves: B top-left, W b-b, B c-c.
    static let threeMoveSgf = "(;FF[4]GM[1]SZ[5];B[aa];W[bb];B[cc])"

    // Move 2 (W at the top-left corner) is captured by B move 3 and the corner
    // is refilled by B as move 5 — one board point hosts two move numbers.
    static let recaptureSgf = "(;FF[4]GM[1]SZ[5];B[ab];W[aa];B[ba];W[cc];B[aa])"

    // Move 2 (W) is a pass.
    static let passSgf = "(;FF[4]GM[1]SZ[5];B[aa];W[];B[cc])"

    // Build expected points through the same Location->BoardPoint converter
    // the implementation uses, so tests don't re-encode the y-flip convention.
    private func point(_ x: Int, _ y: Int) -> BoardPoint {
        BoardPoint(location: Location(x: x, y: y), width: 5, height: 5)
    }

    @Test func allMovesAreNumbered() {
        let result = MoveNumbers.derive(sgf: Self.threeMoveSgf, currentIndex: 3)
        #expect(result.numbers == [point(0, 0): 1, point(1, 1): 2, point(2, 2): 3])
        #expect(result.lastPoint == point(2, 2))
        #expect(result.lastNumber == 3)
    }

    @Test func indexLimitsNumbering() {
        let result = MoveNumbers.derive(sgf: Self.threeMoveSgf, currentIndex: 2)
        #expect(result.numbers == [point(0, 0): 1, point(1, 1): 2])
        #expect(result.lastPoint == point(1, 1))
        #expect(result.lastNumber == 2)
    }

    @Test func indexPastMoveListStopsAtLastMove() {
        let result = MoveNumbers.derive(sgf: Self.threeMoveSgf, currentIndex: 99)
        #expect(result.numbers.count == 3)
        #expect(result.lastNumber == 3)
    }

    @Test func zeroIndexYieldsEmptyResult() {
        let result = MoveNumbers.derive(sgf: Self.threeMoveSgf, currentIndex: 0)
        #expect(result == .empty)
    }

    @Test func invalidSgfYieldsEmptyResult() {
        let result = MoveNumbers.derive(sgf: "not an sgf", currentIndex: 5)
        #expect(result == .empty)
    }

    @Test func replayedPointShowsLatestNumber() {
        let result = MoveNumbers.derive(sgf: Self.recaptureSgf, currentIndex: 5)
        #expect(result.numbers[point(0, 0)] == 5)
        #expect(result.numbers.count == 4)
        #expect(result.lastPoint == point(0, 0))
        #expect(result.lastNumber == 5)
    }

    @Test func passMovesAreSkipped() {
        let result = MoveNumbers.derive(sgf: Self.passSgf, currentIndex: 3)
        #expect(result.numbers == [point(0, 0): 1, point(2, 2): 3])
        #expect(result.lastNumber == 3)
    }

    @Test func passAsLastMoveClearsLastPoint() {
        let result = MoveNumbers.derive(sgf: Self.passSgf, currentIndex: 2)
        #expect(result.numbers == [point(0, 0): 1])
        #expect(result.lastPoint == nil)
        #expect(result.lastNumber == nil)
    }
}
```

Note: if KataGo's SGF parser rejects the empty-property pass `W[]` (both pass tests fail on parsing, not on logic), substitute `W[tt]` — on boards ≤ 19x19 `tt` is the SGF pass convention.

- [ ] **Step 3: Run the tests to verify they fail**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/MoveNumbersTests"
```

Expected: **build failure** — `cannot find 'MoveNumbers' in scope` (the compile error is the failing state; `MoveNumbers.swift` is still empty).

- [ ] **Step 4: Write the implementation**

Full content of `ios/KataGo iOS/KataGo iOS/MoveNumbers.swift`:

```swift
//
//  MoveNumbers.swift
//  KataGo iOS
//

import Foundation
import KataGoInterface

/// How the board annotates move numbers. Raw values index
/// `Config.moveNumberStyles` (the picker's display strings) — keep the two in
/// the same order.
enum MoveNumberStyle: Int {
    case lastThreeMoves = 0
    case lastMove = 1
    case allMoves = 2
    case lastMoveMarker = 3
}

/// Absolute move numbers derived from the active game's SGF, independent of
/// the engine's showboard markers. When the same point is played more than
/// once (ko, recapture), the latest move number wins. `lastPoint`/`lastNumber`
/// are nil when no move was played or the last move was a pass.
struct MoveNumbers: Equatable {
    let numbers: [BoardPoint: Int]
    let lastPoint: BoardPoint?
    let lastNumber: Int?

    static let empty = MoveNumbers(numbers: [:], lastPoint: nil, lastNumber: nil)

    static func derive(sgf: String, currentIndex: Int) -> MoveNumbers {
        let sgfHelper = SgfHelper(sgf: sgf)
        let width = sgfHelper.xSize
        let height = sgfHelper.ySize
        var numbers: [BoardPoint: Int] = [:]
        var lastPoint: BoardPoint?
        var lastNumber: Int?
        var index = 0

        while index < currentIndex, let move = sgfHelper.getMove(at: index) {
            let number = index + 1
            if move.location.pass {
                lastPoint = nil
                lastNumber = nil
            } else {
                let point = BoardPoint(location: move.location, width: width, height: height)
                numbers[point] = number
                lastPoint = point
                lastNumber = number
            }
            index += 1
        }

        return MoveNumbers(numbers: numbers, lastPoint: lastPoint, lastNumber: lastNumber)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Same command as Step 3. Expected: `Test Suite 'MoveNumbersTests' passed` — all 8 tests PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-ios-dev
git add "ios/KataGo iOS/KataGo iOS/MoveNumbers.swift" \
        "ios/KataGo iOS/KataGo iOSTests/MoveNumbersTests.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(goban): derive absolute move numbers from SGF"
```

---

### Task 2: Setting constants and `GobanState` accessors

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/ConfigModel.swift` (append a new extension after the stone-style extension that ends at line 314)
- Modify: `ios/KataGo iOS/KataGo iOS/GobanState.swift` (property block at lines 41-53, helper extension at lines 631-671)

- [ ] **Step 1: Add static constants to `Config`**

In `ConfigModel.swift`, insert after the stone-style extension (after line 314, before `extension Config { static let defaultShowCoordinate = true }`):

```swift
extension Config {
    // Display strings for the move-number picker. Order must match the
    // MoveNumberStyle raw values.
    static let lastThreeMovesNumberStyle = "Last 3 moves"
    static let lastMoveNumberStyle = "Last move"
    static let allMovesNumberStyle = "All moves"
    static let lastMoveMarkerNumberStyle = "Marker"
    static let moveNumberStyles = [lastThreeMovesNumberStyle,
                                   lastMoveNumberStyle,
                                   allMovesNumberStyle,
                                   lastMoveMarkerNumberStyle]
    static let defaultMoveNumberStyle = 0
    static let defaultMoveNumberStyleText = moveNumberStyles[defaultMoveNumberStyle]
}
```

Do **not** add any stored property to the `Config` `@Model` — the SwiftData schema is frozen (CloudKit).

- [ ] **Step 2: Add the `GobanState` property and cache fields**

In `GobanState.swift`, the app-wide display-preference block currently ends at line 50 (`var analysisInformation: Int = Config.defaultAnalysisInformation`) followed by the next-move cache fields. Add the new property and a second cache pair:

```swift
    var analysisInformation: Int = Config.defaultAnalysisInformation
    var moveNumberStyle: Int = Config.defaultMoveNumberStyle

    @ObservationIgnored private var nextMoveCacheKey: (String, Int)? = nil
    @ObservationIgnored private var nextMoveCacheResult: Move? = nil
    @ObservationIgnored private var moveNumbersCacheKey: (String, Int)? = nil
    @ObservationIgnored private var moveNumbersCacheResult: MoveNumbers = .empty
```

(`@ObservationIgnored` matters: `getMoveNumbers` writes the cache during view-body evaluation; observable cache fields would re-invalidate the view.)

- [ ] **Step 3: Add the style accessors and the cached derivation entry point**

In the `// MARK: - Global display-preference helpers` extension of `GobanState` (after `analysisStyleText`, around line 670), add:

```swift
    var moveNumberStyleText: String {
        guard moveNumberStyle < Config.moveNumberStyles.count else { return Config.defaultMoveNumberStyleText }
        return Config.moveNumberStyles[moveNumberStyle]
    }

    var moveNumberStyleChoice: MoveNumberStyle {
        MoveNumberStyle(rawValue: moveNumberStyle) ?? .lastThreeMoves
    }
```

In the main `GobanState` class body, directly after `getNextMove(gameRecord:)` (ends at line 510), add the cached entry point (same single-entry cache pattern):

```swift
    func getMoveNumbers(gameRecord: GameRecord?) -> MoveNumbers {
        guard moveNumberStyleChoice != .lastThreeMoves,
              let sgf = getSgf(gameRecord: gameRecord),
              let currentIndex = getCurrentIndex(gameRecord: gameRecord) else {
            return .empty
        }

        if let key = moveNumbersCacheKey, key == (sgf, currentIndex) {
            return moveNumbersCacheResult
        }

        let result = MoveNumbers.derive(sgf: sgf, currentIndex: currentIndex)

        moveNumbersCacheKey = (sgf, currentIndex)
        moveNumbersCacheResult = result

        return result
    }
```

The `.lastThreeMoves` early-out keeps the default mode free of any SGF parsing.

- [ ] **Step 4: Build to verify**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-ios-dev
git add "ios/KataGo iOS/KataGo iOS/ConfigModel.swift" "ios/KataGo iOS/KataGo iOS/GobanState.swift"
git commit -m "feat(goban): move-number style state and cached SGF derivation"
```

---

### Task 3: Global settings picker and persistence

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/ConfigView.swift` (`GlobalSettingsView`, lines 648-709)
- Modify: `ios/KataGo iOS/KataGo iOS/GameSplitView.swift` (`GlobalPreferenceSync`, lines 598-646)

- [ ] **Step 1: Add the picker to `GlobalSettingsView`**

In `ConfigView.swift`, add the state variable next to the existing ones (after line 652 `@State private var stoneStyleText = Config.defaultStoneStyleText`):

```swift
    @State private var moveNumberStyleText = Config.defaultMoveNumberStyleText
```

In the `Section("Board")`, after the Stone style picker's `.onChange` closure (line 676) and before the "Show coordinate" item, add:

```swift
                ConfigTextPicker(
                    title: "Move numbers",
                    texts: Config.moveNumberStyles,
                    selectedText: $moveNumberStyleText
                )
                .onAppear {
                    moveNumberStyleText = gobanState.moveNumberStyleText
                }
                .onChange(of: moveNumberStyleText) { _, newValue in
                    gobanState.moveNumberStyle = Config.moveNumberStyles.firstIndex(of: newValue) ?? Config.defaultMoveNumberStyle
                }
```

- [ ] **Step 2: Bridge the value to UserDefaults in `GlobalPreferenceSync`**

In `GameSplitView.swift`, three one-line additions following the `stoneStyle` precedent exactly:

After line 611 (`@AppStorage("GlobalSettings.stoneStyle") ...`):

```swift
    @AppStorage("GlobalSettings.moveNumberStyle") private var moveNumberStyle = Config.defaultMoveNumberStyle
```

In `onAppear` (after line 628 `gobanState.stoneStyle = stoneStyle`):

```swift
                gobanState.moveNumberStyle = moveNumberStyle
```

In the `onChange` chain (after line 642, the `gobanState.stoneStyle` onChange):

```swift
            .onChange(of: gobanState.moveNumberStyle) { _, newValue in moveNumberStyle = newValue }
```

- [ ] **Step 3: Build to verify**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-ios-dev
git add "ios/KataGo iOS/KataGo iOS/ConfigView.swift" "ios/KataGo iOS/KataGo iOS/GameSplitView.swift"
git commit -m "feat(settings): move-number display picker in global settings"
```

---

### Task 4: Rendering in `MoveNumberView`

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/MoveNumberView.swift` (full rewrite below)
- Modify: `ios/KataGo iOS/KataGo iOS/BoardView.swift:64` (call site)

- [ ] **Step 1: Rewrite `MoveNumberView`**

Replace the entire content of `MoveNumberView.swift` with:

```swift
//
//  MoveNumberView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/6/15.
//

import SwiftUI

struct MoveNumberView: View {
    @Environment(Stones.self) var stones
    let dimensions: Dimensions
    let verticalFlip: Bool
    let style: MoveNumberStyle
    let moveNumbers: MoveNumbers

    var body: some View {
        switch style {
        case .lastThreeMoves:
            lastThreeMoveOrder
        case .lastMove:
            lastMoveNumber
        case .allMoves:
            allMoveNumbers
        case .lastMoveMarker:
            lastMoveMarker
        }
    }

    /// Relative 1-2-3 markers parsed from the engine's showboard output.
    private var lastThreeMoveOrder: some View {
        Group {
            ForEach(stones.moveOrder.keys.sorted(), id: \.self) { point in
                if let order = stones.moveOrder[point] {
                    label(String(order), at: point)
                }
            }
        }
    }

    @ViewBuilder
    private var lastMoveNumber: some View {
        if let point = moveNumbers.lastPoint,
           let number = moveNumbers.lastNumber,
           hasStone(at: point) {
            label(String(number), at: point)
        }
    }

    private var allMoveNumbers: some View {
        Group {
            ForEach(moveNumbers.numbers.keys.sorted(), id: \.self) { point in
                // Skip points whose stone was captured; on replayed points the
                // derivation already kept the latest number.
                if let number = moveNumbers.numbers[point], hasStone(at: point) {
                    label(String(number), at: point)
                }
            }
        }
    }

    @ViewBuilder
    private var lastMoveMarker: some View {
        if let point = moveNumbers.lastPoint, hasStone(at: point) {
            TriangleShape()
                .stroke(contrastColor(at: point), lineWidth: max(1, dimensions.squareLength / 24))
                .frame(width: dimensions.squareLength * 0.4, height: dimensions.squareLength * 0.35)
                .position(position(of: point))
        }
    }

    private func hasStone(at point: BoardPoint) -> Bool {
        stones.blackPoints.contains(point) || stones.whitePoints.contains(point)
    }

    private func contrastColor(at point: BoardPoint) -> Color {
        stones.blackPoints.contains(point) ? .white : .black
    }

    private func position(of point: BoardPoint) -> CGPoint {
        CGPoint(x: dimensions.boardLineStartX + CGFloat(point.x) * dimensions.squareLength,
                y: dimensions.boardLineStartY + point.getPositionY(height: dimensions.height, verticalFlip: verticalFlip) * dimensions.squareLength)
    }

    private func label(_ text: String, at point: BoardPoint) -> some View {
        Text(text)
            .contentTransition(.numericText())
            .foregroundStyle(contrastColor(at: point))
            .font(.system(size: 500, design: .monospaced))
            .minimumScaleFactor(0.01)
            .bold()
            .frame(width: dimensions.squareLength, height: dimensions.squareLength)
            .position(position(of: point))
    }
}

/// Upward-pointing triangle outline — the classic kifu last-move markup.
struct TriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

#Preview {
    let stones = Stones()

    return ZStack {
        Rectangle()
            .foregroundStyle(.brown)

        GeometryReader { geometry in
            let dimensions = Dimensions(size: geometry.size,
                                        width: 2,
                                        height: 2)
            MoveNumberView(dimensions: dimensions,
                           verticalFlip: false,
                           style: .lastThreeMoves,
                           moveNumbers: .empty)
        }
        .environment(stones)
        .onAppear() {
            stones.blackPoints = [BoardPoint(x: 0, y: 0), BoardPoint(x: 1, y: 1)]
            stones.whitePoints = [BoardPoint(x: 0, y: 1), BoardPoint(x: 1, y: 0)]
            stones.moveOrder = [BoardPoint(x: 0, y: 0): "1",
                                BoardPoint(x: 0, y: 1): "2",
                                BoardPoint(x: 1, y: 1): "3",
                                BoardPoint(x: 1, y: 0): "4"]
        }
    }
}
```

Notes: the `lastThreeMoveOrder` branch reproduces the previous body exactly (same text styling and positioning, now via the shared `label`/`position` helpers). The existing 1-2-3 data path (`stones.moveOrder` from showboard) is unchanged.

- [ ] **Step 2: Update the call site in `BoardView`**

In `BoardView.swift` line 64, replace:

```swift
                    MoveNumberView(dimensions: dimensions, verticalFlip: gobanState.verticalFlip)
```

with:

```swift
                    MoveNumberView(dimensions: dimensions,
                                   verticalFlip: gobanState.verticalFlip,
                                   style: gobanState.moveNumberStyleChoice,
                                   moveNumbers: gobanState.getMoveNumbers(gameRecord: gameRecord))
```

(`BoardView` already has `var gameRecord: GameRecord` and `@Environment(GobanState.self)`.)

- [ ] **Step 3: Build to verify**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-ios-dev
git add "ios/KataGo iOS/KataGo iOS/MoveNumberView.swift" "ios/KataGo iOS/KataGo iOS/BoardView.swift"
git commit -m "feat(goban): render move numbers per selected display style"
```

---

### Task 5: Full verification

**Files:** none (verification only; fix-up commits if anything fails)

- [ ] **Step 1: Run the full unit-test suite**

```bash
xcodebuild test -project "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17'
```

Expected: `** TEST SUCCEEDED **` (all suites including `MoveNumbersTests`).

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

Only if Steps 1-3 required changes; use a `fix(goban): ...` message describing the actual fix. Do **not** push — Xcode Cloud free tier; the user decides when to push.
