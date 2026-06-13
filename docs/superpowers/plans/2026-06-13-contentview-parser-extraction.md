# ContentView Parser Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the pure `showboard`/`kata-analyze` parsing out of `ContentView.swift` into two unit-tested value types, leaving `ContentView` a thin wrapper — behavior-preserving.

**Architecture:** Two new pure types in the app target — `BoardTextParser` (board ASCII → stones/moveOrder/dims) and `AnalysisLineParser` (analysis lines → `AnalysisInfo` map + `OwnershipUnit`s). Both are added first (standalone, app keeps building), with unit tests in `KataGo AnytimeTests` (which CI runs). Then `ContentView`'s `parseBoardPoints`/`maybeCollectAnalysis` are rewired to call them and the moved methods deleted; all `@State`/`withAnimation` mutation stays in `ContentView`.

**Tech Stack:** SwiftUI, Swift Testing (`import Testing`, `@Test`, `#expect`), Swift `Regex` literals, `xcodeproj` Ruby gem for pbxproj registration.

**Spec:** `docs/superpowers/specs/2026-06-13-contentview-parser-extraction-design.md`

**Key background for a zero-context engineer:**

- Repo root `/Users/chinchangyang/Code/KataGo-ios-dev`, branch `ios-dev` (work on it; commit but NEVER push). App sources: `ios/KataGo iOS/KataGo iOS/`; unit tests: `ios/KataGo iOS/KataGo iOSTests/` (target `KataGo AnytimeTests`, module `KataGo_Anytime`, Swift Testing).
- New `.swift` files must be registered in `project.pbxproj` via the `xcodeproj` Ruby gem (no synchronized groups). Snippet in Task 1. If `require "xcodeproj"` fails, use `/usr/local/opt/ruby/bin/ruby`.
- Unit tests run under the **default** test plan (FastTestPlan → `KataGo AnytimeTests`), so a plain `xcodebuild test` runs them — and CI runs them. No `-testPlan` needed.
- Model types already exist in `KataGoModel.swift`: `BoardPoint(x:Int,y:Int)` (Hashable/Equatable/Comparable), `BoardPoint.pass(width:height:)`, `AnalysisInfo(visits:Int, winrate:Float, scoreLead:Float, utilityLcb:Float)`, `OwnershipUnit(point:BoardPoint, whiteness:Float, scale:Float, opacity:Float)`, `Coordinate(xLabel:String, yLabel:String, width:Int, height:Int)` (xMap: A=0,B=1,…H=7,J=8,…Q=15; y is 1-indexed), and `PlayerColor` (`.black`/`.white`). `Analysis.parseRootVisits(from:)` stays in `ContentView`'s flow.
- This is a **behavior-preserving** refactor: copy the logic verbatim. Builds must succeed on iOS, macOS, visionOS.

---

### Task 1: `BoardTextParser` + tests (TDD)

**Files:**
- Create: `ios/KataGo iOS/KataGo iOS/BoardTextParser.swift`
- Create: `ios/KataGo iOS/KataGo iOSTests/BoardTextParserTests.swift`
- Modify: `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj` (gem only)

- [ ] **Step 1: Register both files in the Xcode project**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
touch "KataGo iOS/BoardTextParser.swift" "KataGo iOSTests/BoardTextParserTests.swift"

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
' "KataGo Anytime" "ContentView.swift" "BoardTextParser.swift"

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
' "KataGo AnytimeTests" "NavigationContextTests.swift" "BoardTextParserTests.swift"
```

- [ ] **Step 2: Write the failing tests**

Full content of `ios/KataGo iOS/KataGo iOSTests/BoardTextParserTests.swift`:

```swift
//
//  BoardTextParserTests.swift
//  KataGo AnytimeTests
//

import Testing
@testable import KataGo_Anytime

struct BoardTextParserTests {
    // A 3x3 showboard sample. First line is the column header (skipped for
    // parsing). Row numbers are right-aligned to 2 chars; each cell is one
    // glyph + one space, so x = charIndex / 2 over line.dropFirst(3).
    //   row 3: white at column B (x=1)
    //   row 2: black at column A (x=0), move marker "1" at column B (x=1)
    //   row 1: empty
    static let board = [
        "   A B C",
        " 3 . O .",
        " 2 X 1 .",
        " 1 . . .",
    ]

    @Test func parsesStonesDimensionsAndMoveOrder() {
        let r = BoardTextParser.parse(Self.board)
        #expect(r.width == 3)
        #expect(r.height == 3)
        #expect(r.blackStones == [BoardPoint(x: 0, y: 1)])
        #expect(r.whiteStones == [BoardPoint(x: 1, y: 2)])
        #expect(r.moveOrder == [BoardPoint(x: 1, y: 1): "1"])
    }

    @Test func headerOnlyYieldsNoStones() {
        // dropFirst() leaves no rows, so no stones/moves; height = count-1 = 0;
        // width derives from the last line ("   A B C").
        let r = BoardTextParser.parse(["   A B C"])
        #expect(r.height == 0)
        #expect(r.width == 3)
        #expect(r.blackStones.isEmpty)
        #expect(r.whiteStones.isEmpty)
        #expect(r.moveOrder.isEmpty)
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/BoardTextParserTests" 2>&1 | tail -40
```

Expected: **build failure** — `cannot find 'BoardTextParser' in scope` (the file is empty). Large build; use a 600000 ms timeout.

- [ ] **Step 4: Write the implementation**

Full content of `ios/KataGo iOS/KataGo iOS/BoardTextParser.swift`:

```swift
//
//  BoardTextParser.swift
//  KataGo iOS
//

import Foundation

/// The board state parsed from KataGo's `showboard` ASCII output.
struct ParsedBoard: Equatable {
    let width: CGFloat
    let height: CGFloat
    let blackStones: [BoardPoint]
    let whiteStones: [BoardPoint]
    let moveOrder: [BoardPoint: Character]
}

/// Pure parser for `showboard` text. Behavior matches the previous
/// ContentView.parseStones/calculateBoardDimensions/calculateYCoordinate/parseLine.
enum BoardTextParser {
    static func parse(_ boardText: [String]) -> ParsedBoard {
        let height = CGFloat(boardText.count - 1)
        let width = CGFloat((boardText.last?.dropFirst(2).count ?? 0) / 2)
        var blackStones: [BoardPoint] = []
        var whiteStones: [BoardPoint] = []
        var moveOrder: [BoardPoint: Character] = [:]

        for line in boardText.dropFirst() {
            let y = (Int(line.prefix(2).trimmingCharacters(in: .whitespaces)) ?? 1) - 1
            for (charIndex, char) in line.dropFirst(3).enumerated() {
                let xCoord = charIndex / 2
                let point = BoardPoint(x: xCoord, y: y)
                if char == "X" {
                    blackStones.append(point)
                } else if char == "O" {
                    whiteStones.append(point)
                } else if char.isNumber {
                    moveOrder[point] = char
                }
            }
        }

        return ParsedBoard(width: width,
                           height: height,
                           blackStones: blackStones,
                           whiteStones: whiteStones,
                           moveOrder: moveOrder)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Same command as Step 3. Expected: 2/2 `BoardTextParserTests` PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-ios-dev
git add "ios/KataGo iOS/KataGo iOS/BoardTextParser.swift" \
        "ios/KataGo iOS/KataGo iOSTests/BoardTextParserTests.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "refactor(parse): add tested BoardTextParser

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `AnalysisLineParser` + tests (TDD)

**Files:**
- Create: `ios/KataGo iOS/KataGo iOS/AnalysisLineParser.swift`
- Create: `ios/KataGo iOS/KataGo iOSTests/AnalysisLineParserTests.swift`
- Modify: `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj` (gem only)

- [ ] **Step 1: Register both files in the Xcode project**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
touch "KataGo iOS/AnalysisLineParser.swift" "KataGo iOSTests/AnalysisLineParserTests.swift"

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
' "KataGo Anytime" "ContentView.swift" "AnalysisLineParser.swift"

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
' "KataGo AnytimeTests" "NavigationContextTests.swift" "AnalysisLineParserTests.swift"
```

- [ ] **Step 2: Write the failing tests**

Full content of `ios/KataGo iOS/KataGo iOSTests/AnalysisLineParserTests.swift`:

```swift
//
//  AnalysisLineParserTests.swift
//  KataGo AnytimeTests
//

import Testing
@testable import KataGo_Anytime

struct AnalysisLineParserTests {
    // Q16 on a 19x19 board: x = Q = 15, y = 16 -> BoardPoint(x: 15, y: 15).
    private let q16 = BoardPoint(x: 15, y: 15)
    // D4: x = D = 3, y = 4 -> BoardPoint(x: 3, y: 3).
    private let d4 = BoardPoint(x: 3, y: 3)

    @Test func whiteKeepsSignsAndParsesFields() {
        let parser = AnalysisLineParser(boardWidth: 19, boardHeight: 19, nextColor: .white)
        let msg = "info move Q16 visits 10 winrate 0.55 scoreLead 2.5 utilityLcb 0.3 order 0 pv Q16"
        let r = parser.parse(message: msg)
        let info = r.info[q16]
        #expect(info?.visits == 10)
        #expect(abs((info?.winrate ?? 0) - 0.55) < 1e-4)
        #expect(abs((info?.scoreLead ?? 0) - 2.5) < 1e-4)
        #expect(abs((info?.utilityLcb ?? 0) - 0.3) < 1e-4)
    }

    @Test func blackFlipsSigns() {
        let parser = AnalysisLineParser(boardWidth: 19, boardHeight: 19, nextColor: .black)
        let msg = "info move Q16 visits 10 winrate 0.55 scoreLead 2.5 utilityLcb 0.3 order 0 pv Q16"
        let info = parser.parse(message: msg).info[q16]
        #expect(abs((info?.winrate ?? 0) - 0.45) < 1e-4)   // 1 - 0.55
        #expect(abs((info?.scoreLead ?? 0) - (-2.5)) < 1e-4)
        #expect(abs((info?.utilityLcb ?? 0) - (-0.3)) < 1e-4)
    }

    @Test func dropsZeroVisitHalfWinrateButKeepsOtherZeroVisit() {
        let parser = AnalysisLineParser(boardWidth: 19, boardHeight: 19, nextColor: .white)
        let msg = "info move Q16 visits 0 winrate 0.5 scoreLead 0 utilityLcb 0 "
                + "info move D4 visits 0 winrate 0.6 scoreLead 1 utilityLcb 1"
        let r = parser.parse(message: msg)
        #expect(r.info[q16] == nil)        // visits 0 && winrate 0.5 -> dropped
        #expect(r.info[d4] != nil)         // visits 0 but winrate 0.6 -> kept
    }

    @Test func parsesPassMove() {
        let parser = AnalysisLineParser(boardWidth: 19, boardHeight: 19, nextColor: .white)
        let msg = "info move pass visits 10 winrate 0.5 scoreLead 0 utilityLcb 0"
        let r = parser.parse(message: msg)
        #expect(r.info[BoardPoint.pass(width: 19, height: 19)] != nil)
    }

    @Test func ownershipDigitizesAndOrders() {
        // 2x2 board: 4 ownership values, iterated y from 1..0, x 0..1.
        // mean -> whiteness = (mean+1)/2, digitized to nearest 1/5.
        // mean +1 -> whiteness 1.0 ; mean -1 -> whiteness 0.0.
        let parser = AnalysisLineParser(boardWidth: 2, boardHeight: 2, nextColor: .white)
        let msg = "info move A1 visits 1 winrate 0.6 scoreLead 0 utilityLcb 0 "
                + "ownership 1.0 -1.0 1.0 -1.0 ownershipStdev 0.0 0.0 0.0 0.0"
        let units = parser.parse(message: msg).ownershipUnits
        #expect(units.count == 4)
        #expect(units[0].point == BoardPoint(x: 0, y: 1))   // first cell: y = height-1, x = 0
        #expect(abs(units[0].whiteness - 1.0) < 1e-4)
        #expect(abs(units[1].whiteness - 0.0) < 1e-4)
    }

    @Test func ownershipCountMismatchYieldsEmpty() {
        let parser = AnalysisLineParser(boardWidth: 2, boardHeight: 2, nextColor: .white)
        // 3 values for a 4-cell board -> rejected.
        let msg = "info move A1 visits 1 winrate 0.6 scoreLead 0 utilityLcb 0 "
                + "ownership 1.0 -1.0 1.0 ownershipStdev 0.0 0.0 0.0"
        #expect(parser.parse(message: msg).ownershipUnits.isEmpty)
    }

    @Test func garbageYieldsEmpty() {
        let parser = AnalysisLineParser(boardWidth: 19, boardHeight: 19, nextColor: .white)
        let r = parser.parse(message: "not an analysis line")
        #expect(r.info.isEmpty)
        #expect(r.ownershipUnits.isEmpty)
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/AnalysisLineParserTests" 2>&1 | tail -40
```

Expected: **build failure** — `cannot find 'AnalysisLineParser' in scope`.

- [ ] **Step 4: Write the implementation**

Full content of `ios/KataGo iOS/KataGo iOS/AnalysisLineParser.swift`:

```swift
//
//  AnalysisLineParser.swift
//  KataGo iOS
//

import Foundation

/// The analysis state parsed from one `kata-analyze` output message.
struct ParsedAnalysis {
    let info: [BoardPoint: AnalysisInfo]
    let ownershipUnits: [OwnershipUnit]
}

/// Pure parser for `kata-analyze` lines. Behavior matches the previous
/// ContentView analysis helpers. `nextColor` is `player.nextColorFromShowBoard`;
/// winrate/scoreLead/utilityLcb are flipped to Black's perspective when it is
/// Black to move.
struct AnalysisLineParser {
    let boardWidth: Int
    let boardHeight: Int
    let nextColor: PlayerColor

    func parse(message: String) -> ParsedAnalysis {
        let splitData = message.split(separator: "info")
        let infoDicts = splitData.compactMap { extractAnalysisInfo(dataLine: String($0)) }
        let info = infoDicts.reduce(into: [BoardPoint: AnalysisInfo]()) { acc, dict in
            acc.merge(dict) { current, _ in current }   // first wins on collision
        }
        let ownershipUnits = extractOwnershipUnits(lastData: splitData.last)
        return ParsedAnalysis(info: info, ownershipUnits: ownershipUnits)
    }

    // MARK: - Analysis info

    private func extractAnalysisInfo(dataLine: String) -> [BoardPoint: AnalysisInfo]? {
        let point = matchMovePattern(dataLine: dataLine)
        let visits = matchVisitsPattern(dataLine: dataLine)
        let winrate = matchWinratePattern(dataLine: dataLine)
        let scoreLead = matchScoreLeadPattern(dataLine: dataLine)
        let utilityLcb = matchUtilityLcbPattern(dataLine: dataLine)

        if let point, let visits, let winrate, let scoreLead, let utilityLcb {
            // Winrate is 0.5 when visits = 0; skip those to keep the win-rate bar stable.
            guard visits > 0 || winrate != 0.5 else { return nil }
            return [point: AnalysisInfo(visits: visits, winrate: winrate, scoreLead: scoreLead, utilityLcb: utilityLcb)]
        }
        return nil
    }

    private func moveToPoint(move: String) -> BoardPoint? {
        let pattern = /([^\d\W]+)(\d+)/
        if let match = move.firstMatch(of: pattern),
           let coordinate = Coordinate(xLabel: String(match.1),
                                       yLabel: String(match.2),
                                       width: boardWidth,
                                       height: boardHeight) {
            return BoardPoint(x: coordinate.x, y: coordinate.y - 1)
        }
        return nil
    }

    private func matchMovePattern(dataLine: String) -> BoardPoint? {
        if let match = dataLine.firstMatch(of: /move (\w+\d+)/) {
            if let point = moveToPoint(move: String(match.1)) { return point }
        } else if dataLine.firstMatch(of: /move pass/) != nil {
            return BoardPoint.pass(width: boardWidth, height: boardHeight)
        }
        return nil
    }

    private func matchVisitsPattern(dataLine: String) -> Int? {
        if let match = dataLine.firstMatch(of: /visits (\d+)/) { return Int(match.1) }
        return nil
    }

    /// Extract a Float capture and flip it to Black's perspective when Black moves.
    private func signedFloat<R: RegexComponent>(in dataLine: String,
                                                pattern: R,
                                                whenBlack: (Float) -> Float) -> Float?
    where R.RegexOutput == (Substring, Substring) {
        guard let match = dataLine.firstMatch(of: pattern),
              let value = Float(match.output.1) else { return nil }
        return nextColor == .black ? whenBlack(value) : value
    }

    private func matchWinratePattern(dataLine: String) -> Float? {
        signedFloat(in: dataLine, pattern: /winrate ([-\d.eE]+)/) { 1.0 - $0 }
    }

    private func matchScoreLeadPattern(dataLine: String) -> Float? {
        signedFloat(in: dataLine, pattern: /scoreLead ([-\d.eE]+)/) { -$0 }
    }

    private func matchUtilityLcbPattern(dataLine: String) -> Float? {
        signedFloat(in: dataLine, pattern: /utilityLcb ([-\d.eE]+)/) { -$0 }
    }

    // MARK: - Ownership

    private func floats<R: RegexComponent>(in message: String, pattern: R) -> [Float]
    where R.RegexOutput == (Substring, Substring) {
        guard let match = message.firstMatch(of: pattern) else { return [] }
        let values = match.output.1.split(separator: " ").compactMap { Float($0) }
        return values.count == boardWidth * boardHeight ? values : []
    }

    private func extractOwnershipMean(message: String) -> [Float] {
        floats(in: message, pattern: /ownership ([-\d\s.eE]+)/)
    }

    private func extractOwnershipStdev(message: String) -> [Float] {
        floats(in: message, pattern: /ownershipStdev ([-\d\s.eE]+)/)
    }

    private func computeDefiniteness(_ whiteness: Float) -> Float {
        Swift.abs(whiteness - 0.5) * 2
    }

    private func computeOpacity(scale x: Float) -> Float {
        let a = 100.0
        let b = 0.25
        return Float(0.8 / (1.0 + exp(-a * (Double(x) - b))))
    }

    private func extractOwnershipUnits(lastData: Substring?) -> [OwnershipUnit] {
        guard let lastData else { return [] }
        let message = String(lastData)
        let mean = extractOwnershipMean(message: message)
        let stdev = extractOwnershipStdev(message: message)
        guard !mean.isEmpty && !stdev.isEmpty else { return [] }

        var ownershipUnits: [OwnershipUnit] = []
        var i = 0
        for y in stride(from: (boardHeight - 1), through: 0, by: -1) {
            for x in 0..<boardWidth {
                let point = BoardPoint(x: x, y: y)
                let whiteness = (mean[i] + 1) / 2
                let digit: Float = 5
                let digitizedWhiteness = (whiteness * digit).rounded() / digit
                let digitizedStdev = (stdev[i] * digit).rounded() / digit
                let definiteness = computeDefiniteness(digitizedWhiteness)
                let scale = max(definiteness, digitizedStdev) * 0.65
                let opacity = computeOpacity(scale: scale)
                ownershipUnits.append(OwnershipUnit(point: point,
                                                    whiteness: digitizedWhiteness,
                                                    scale: scale,
                                                    opacity: opacity))
                i += 1
            }
        }
        return ownershipUnits
    }
}
```

Note: if the generic `signedFloat`/`floats` signatures give the Swift compiler trouble (regex-literal generics can be finicky), fall back to keeping the three winrate/scoreLead/utilityLcb methods and the two ownership-extract methods as separate non-generic copies of the original bodies — the de-dup is optional polish; **behavior preservation and the passing tests are what matter.**

- [ ] **Step 5: Run the tests to verify they pass**

Same command as Step 3. Expected: 7/7 `AnalysisLineParserTests` PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-ios-dev
git add "ios/KataGo iOS/KataGo iOS/AnalysisLineParser.swift" \
        "ios/KataGo iOS/KataGo iOSTests/AnalysisLineParserTests.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "refactor(parse): add tested AnalysisLineParser

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Rewire `ContentView` to use the parsers

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/ContentView.swift`

- [ ] **Step 1: Replace `parseBoardPoints` and delete the board-parsing helpers**

In `ContentView.swift`, replace the current `parseStones` (lines ~229-242) and `parseBoardPoints` (lines ~244-257) with a single non-async `parseBoardPoints`, and **delete** `calculateBoardDimensions` (~259-264), `calculateYCoordinate` (~266-269), and `parseLine` (~271-286). Keep `adjustBoardDimensionsIfNeeded` (it mutates `analysis`/`board`). The new method:

```swift
    // Parses the board text to extract and classify positions of stones and moves
    func parseBoardPoints(boardText: [String]) {
        let parsed = BoardTextParser.parse(boardText)

        withAnimation(.none) {
            stones.blackPoints = parsed.blackStones
            stones.whitePoints = parsed.whiteStones
            adjustBoardDimensionsIfNeeded(width: parsed.width, height: parsed.height)
        } completion: {
            withAnimation(.spring) {
                stones.moveOrder = parsed.moveOrder
            }
        }
    }
```

- [ ] **Step 2: Update the `parseBoardPoints` call site in `maybeCollectBoard`**

In `maybeCollectBoard` (the `if message.hasPrefix("Next player")` block, ~line 190), drop the `await` now that `parseBoardPoints` is synchronous:

```swift
            // Parse the current board state
            parseBoardPoints(boardText: boardText)
```

(`maybeCollectBoard` stays `async` — it is awaited from `messaging()` — and is otherwise unchanged.)

- [ ] **Step 3: Replace the body of `maybeCollectAnalysis` and delete the analysis helpers**

Replace `maybeCollectAnalysis` (lines ~358-394) with the version below, and **delete** these now-unused methods: `collectAnalysisInfo`, `computeDefiniteness`, `computeOpacity`, `extractOwnershipUnits`, `moveToPoint`, `matchMovePattern`, `matchVisitsPattern`, `matchWinratePattern`, `matchScoreLeadPattern`, `matchUtilityLcbPattern`, `extractAnalysisInfo`, `extractOwnershipMean`, `extractOwnershipStdev` (lines ~298-356 and ~396-525). Do NOT delete `moveToPoint`'s lookalike `BoardPoint(move:width:height:)` usage in `postProcessAIMove`/`maybeCollectCheckMove` — that is a different `BoardPoint` initializer and stays.

```swift
    func maybeCollectAnalysis(message: String) async {
        guard gobanState.showBoardCount == 0 else { return }
        if message.starts(with: /info/) {
            let sampleTime = ProcessInfo.processInfo.systemUptime

            let parser = AnalysisLineParser(boardWidth: Int(board.width),
                                            boardHeight: Int(board.height),
                                            nextColor: player.nextColorFromShowBoard)
            let parsed = parser.parse(message: message)
            let rootVisits = Analysis.parseRootVisits(from: message)

            withAnimation {
                analysis.info = parsed.info
                analysis.ownershipUnits = parsed.ownershipUnits
                analysis.nextColorForAnalysis = player.nextColorFromShowBoard

                if let rootVisits {
                    analysis.updateVisitsPerSecond(rootVisits: rootVisits, at: sampleTime)
                }

                if gobanState.eyeStatus != .book {
                    if let blackWinrate = analysis.blackWinrate {
                        rootWinrate.black = blackWinrate
                    }
                    rootScore.black = analysis.blackScore ?? 0
                }
            }

            gobanState.waitingForAnalysis = parsed.info.isEmpty
        }
    }
```

(`maybeCollectAnalysis` stays `async` — awaited from `messaging()`. The `await`s it previously used internally are gone because the parser is synchronous.)

- [ ] **Step 4: Build to verify (iOS Simulator)**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`. If the compiler reports an unused/leftover reference, ensure every method listed in Steps 1 and 3 was actually deleted and that no other code calls them (grep: `grep -n "parseStones\|extractAnalysisInfo\|matchWinratePattern\|extractOwnershipUnits\|collectAnalysisInfo" "ios/KataGo iOS/KataGo iOS/ContentView.swift"` should return nothing).

- [ ] **Step 5: Run the full unit suite (confirms parsers still green after wiring)**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/BoardTextParserTests" \
  -only-testing:"KataGo AnytimeTests/AnalysisLineParserTests" 2>&1 | tail -20
```

Expected: `TEST SUCCEEDED` (9 tests total).

- [ ] **Step 6: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-ios-dev
git add "ios/KataGo iOS/KataGo iOS/ContentView.swift"
git commit -m "refactor(ContentView): use BoardTextParser/AnalysisLineParser

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

Expected: `** TEST SUCCEEDED **`, including the new `BoardTextParserTests` (2) and `AnalysisLineParserTests` (7).

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

Only if Steps 1-3 required changes; use a `fix(parse): ...` message. Do **not** push.
