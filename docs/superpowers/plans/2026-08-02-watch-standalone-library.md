# KataGo Anytime Watch — Standalone Game Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the Apple Watch list saved games, open one, and scrub its moves with no iPhone in range, using its own CloudKit-synced SwiftData store.

**Architecture:** The watch already links `KataGoGameStore` (which contains `GameRecord`, `Config`, and `SharedModelContainer`) but never opens a `ModelContainer`. We give it one, over the same private CloudKit database the other platforms use, reusing the tvOS never-crash open ladder. Board positions come from replaying `GameRecord.sgf` through an extended `SgfHeaderScan` plus a new `GoRulesKit` replayer — **not** from the per-move `blackStones`/`whiteStones` dictionaries, which only cover indices the phone actually visited. Cached winrate / score lead / best move / comment fill in where the record has them. The watch never writes to the store, and the phone side gains no new wire messages.

**Tech Stack:** Swift 6, SwiftUI, SwiftData + CloudKit, Swift Testing, watchOS 26, xcodeproj Ruby gem 1.27.0.

**Spec:** `docs/superpowers/specs/2026-08-02-watch-standalone-library-design.md`

## Global Constraints

- The watch target may link **only** bridge-free products: `KataGoGameStore` and (new) `GoRulesKit`. Never `KataGoUICore`, `CKataGoBridge`, `GobanRecogKit`, or MLX.
- The `@Model` schema (`GameRecord`, `Config`) is **frozen** — CloudKit. Never add, rename, remove, or retype a stored property. Orphan fields instead of deleting them.
- The watch is **read-only**. No *shipping* code in this plan may call `modelContext.save()`, insert, or delete. Test fixtures seeding an in-memory container are exempt — that is how the suites build their data.
- All committed content is **English-only**. No CJK anywhere, including comments.
- Test framework is **Swift Testing** (`import Testing`, `@Test`, `#expect`, `#require`) in both the iOS test target and the SwiftPM package tests. Never XCTest.
- The SwiftPM tests under `KataGoUICore/Tests/` are compiled but **never executed** by `xcodebuild test`. `swift test` is a separate, mandatory gate.
- Piped `xcodebuild` exit codes lie. Judge every build/test by grepping for `BUILD SUCCEEDED` / `TEST SUCCEEDED` / `TEST FAILED`.
- Any closure handed from a `@MainActor` type to an un-annotated ObjC callback API (WCSession, CloudKit) must be written `{ @Sendable ... in }`, or Swift 6 wraps it in a main-queue assertion that traps.
- iOS test target name: `KataGo AnytimeTests` (its folder is `KataGo iOSTests/`).
- New Swift files in an **app target** must be registered in the pbxproj via `ruby scripts_add_swift_files.rb "<target>" <path…>`. New files in a **SwiftPM target** are auto-discovered — never register those.
- Working directory for every build/test command: `/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS`.
- Commit after every task. Do not push (`ios-dev` pushes are spaced by roughly a day).

---

### Task 1: SGF mainline moves and setup stones

`SgfHeaderScan` currently extracts board size, komi, rules, and the mainline move **colors** using a regex. It needs the move **coordinates** and the `AB`/`AW` setup stones so the board can be replayed. The regex is replaced by an explicit property-token scanner, because a regex cannot reliably tell the property `AB` from a Black move `B` without lookbehind.

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoAnalysisKit/SgfHeaderScan.swift`
- Test: `ios/KataGo iOS/KataGoUICore/Tests/KataGoAnalysisKitTests/SgfHeaderScanTests.swift`

**Interfaces:**
- Consumes: `PlayerColor` (`KataGoAnalysisKit/PlayerColor.swift`, cases `.black`, `.white`, `.unknown`, with `.other`).
- Produces:
  - `public struct SgfPoint: Sendable, Equatable, Hashable { public var x: Int; public var y: Int; public init(x: Int, y: Int) }` — 0-based, origin top-left.
  - `public struct SgfMove: Sendable, Equatable { public var color: PlayerColor; public var point: SgfPoint?; public init(color: PlayerColor, point: SgfPoint?) }` — `point == nil` means pass.
  - On `SgfHeaderScan`: `public var moves: [SgfMove]`, `public var setupBlack: [SgfPoint]`, `public var setupWhite: [SgfPoint]`, and `public var moveColors: [PlayerColor]` **changed from a stored to a computed property** (`moves.map(\.color)`).

- [ ] **Step 1: Write the failing tests**

Append these to `ios/KataGo iOS/KataGoUICore/Tests/KataGoAnalysisKitTests/SgfHeaderScanTests.swift`, inside the existing `struct SgfHeaderScanTests { … }` body (do not create a new file, do not touch the existing tests):

```swift
    @Test func readsMoveCoordinates() throws {
        let scan = try #require(SgfHeaderScan(
            sgf: "(;GM[1]FF[4]SZ[19];B[pd];W[dp];B[qp])"))
        #expect(scan.moves == [
            SgfMove(color: .black, point: SgfPoint(x: 15, y: 3)),
            SgfMove(color: .white, point: SgfPoint(x: 3, y: 15)),
            SgfMove(color: .black, point: SgfPoint(x: 16, y: 15)),
        ])
    }

    @Test func emptyValueIsAPass() throws {
        let scan = try #require(SgfHeaderScan(sgf: "(;GM[1]SZ[9];B[aa];W[])"))
        #expect(scan.moves[1].point == nil)
        #expect(scan.moves[1].color == .white)
    }

    @Test func offBoardValueIsAPass() throws {
        // "tt" is the legacy pass on boards up to 19x19; it decodes to (19,19),
        // which is off a 9x9 board, so the generic off-board rule covers it.
        let scan = try #require(SgfHeaderScan(sgf: "(;GM[1]SZ[9];B[aa];W[tt])"))
        #expect(scan.moves[1].point == nil)
        #expect(scan.moveCount == 2)
    }

    @Test func readsSetupStones() throws {
        let scan = try #require(SgfHeaderScan(
            sgf: "(;GM[1]SZ[19]HA[2]AB[pd][dp]AW[dd];W[qq])"))
        #expect(scan.setupBlack == [SgfPoint(x: 15, y: 3), SgfPoint(x: 3, y: 15)])
        #expect(scan.setupWhite == [SgfPoint(x: 3, y: 3)])
        // Setup stones are NOT moves.
        #expect(scan.moves == [SgfMove(color: .white, point: SgfPoint(x: 16, y: 16))])
    }

    @Test func setupPropertyIsNeverMistakenForABlackMove() throws {
        // The whole reason for a token scanner: "AB" is one property
        // identifier, not "A" followed by a "B" move.
        let scan = try #require(SgfHeaderScan(sgf: "(;GM[1]SZ[19]AB[dd][pp])"))
        #expect(scan.moves.isEmpty)
        #expect(scan.setupBlack.count == 2)
    }

    @Test func uppercaseCoordinateLettersDecodePastZ() throws {
        // SGF coordinates continue "A"..."Z" = 26...51 for boards over 26.
        let scan = try #require(SgfHeaderScan(sgf: "(;GM[1]SZ[37];B[aA];W[Ab])"))
        #expect(scan.moves[0].point == SgfPoint(x: 0, y: 26))
        #expect(scan.moves[1].point == SgfPoint(x: 26, y: 1))
    }

    @Test func moveColorsStillMirrorsTheMoveList() throws {
        let scan = try #require(SgfHeaderScan(sgf: "(;GM[1]SZ[9];B[aa];W[bb];B[cc])"))
        #expect(scan.moveColors == scan.moves.map(\.color))
        #expect(scan.moveColors == [.black, .white, .black])
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS/KataGoUICore" && swift test --filter KataGoAnalysisKitTests 2>&1 | tail -30
```

Expected: compile failure — `cannot find 'SgfMove' in scope`, `cannot find 'SgfPoint' in scope`, `value of type 'SgfHeaderScan' has no member 'moves'`.

- [ ] **Step 3: Add the value types**

Insert into `ios/KataGo iOS/KataGoUICore/Sources/KataGoAnalysisKit/SgfHeaderScan.swift`, immediately after `import Foundation` (line 16) and before `public struct SgfHeaderScan`:

```swift
/// A point in SGF coordinates, decoded to 0-based indices with the origin at
/// the TOP-LEFT (x right, y down) — the same convention as GoRulesKit's
/// GoPoint, so the two need no translation.
public struct SgfPoint: Sendable, Equatable, Hashable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

/// One mainline move. A nil `point` is a pass — either an explicit empty
/// value (`B[]`) or a value that lands outside the board, which is how the
/// legacy "tt" pass encodes on boards up to 19x19.
public struct SgfMove: Sendable, Equatable {
    public var color: PlayerColor
    public var point: SgfPoint?

    public init(color: PlayerColor, point: SgfPoint?) {
        self.color = color
        self.point = point
    }
}
```

- [ ] **Step 4: Replace the stored `moveColors` with the move list**

In the same file, replace this declaration:

```swift
    /// Colors of the mainline moves in order (move 1 first). Handicap games
    /// start with .white here because the scan reads actual B[]/W[] nodes,
    /// not an assumed alternation.
    public var moveColors: [PlayerColor]
```

with:

```swift
    /// The mainline moves in order (move 1 first). Handicap games start with
    /// .white here because the scan reads actual B[]/W[] nodes, not an
    /// assumed alternation.
    public var moves: [SgfMove]
    /// AB[] setup stones (handicap placement and free setup), in document
    /// order. These are positions, not moves.
    public var setupBlack: [SgfPoint]
    /// AW[] setup stones, in document order.
    public var setupWhite: [SgfPoint]

    /// Colors of the mainline moves in order. Kept as the scan's original
    /// surface so existing callers (the Safari extension) are unaffected.
    public var moveColors: [PlayerColor] { moves.map(\.color) }
```

- [ ] **Step 5: Replace the move regex with a property-token scan**

In the same file, replace this block:

```swift
        // Move nodes are ";B[...]" / ";W[...]" — the node separator prefix
        // distinguishes them from setup AB[]/AW[]. The sanitized walk blanks
        // long property values, so comment text can only forge a move node in
        // the pathological ≤8-char case — acceptable for a header scan whose
        // ground truth is loadsgf.
        moveColors = Self.mainlineForMoveScan(text).matches(of: /;\s*([BW])\[[^\]]*\]/).map {
            $0.1 == "B" ? PlayerColor.black : .white
        }
```

with:

```swift
        // Walk the sanitized mainline into (identifier, values) properties.
        // A token scan rather than a regex because SGF property identifiers
        // are runs of uppercase letters: "AB" is ONE identifier and must never
        // be read as a Black move. The sanitized walk blanks long property
        // values, so comment text can only forge a node in the pathological
        // <=8-char case — acceptable for a scan whose ground truth is loadsgf.
        var moves: [SgfMove] = []
        var setupBlack: [SgfPoint] = []
        var setupWhite: [SgfPoint] = []
        for property in Self.properties(in: Self.mainlineForMoveScan(text)) {
            switch property.identifier {
            case "B", "W":
                let color: PlayerColor = property.identifier == "B" ? .black : .white
                let raw = property.values.first ?? ""
                moves.append(SgfMove(color: color,
                                     point: Self.point(raw, width: width, height: height)))
            case "AB":
                setupBlack += property.values.compactMap {
                    Self.point($0, width: width, height: height)
                }
            case "AW":
                setupWhite += property.values.compactMap {
                    Self.point($0, width: width, height: height)
                }
            default:
                break
            }
        }
        self.moves = moves
        self.setupBlack = setupBlack
        self.setupWhite = setupWhite
```

- [ ] **Step 6: Add the scanner and coordinate helpers**

In the same file, insert after `mainlineForMoveScan(_:)` (before the closing brace of `SgfHeaderScan`):

```swift
    /// One SGF property: an identifier and its bracketed values.
    struct Property {
        var identifier: String
        var values: [String]
    }

    /// Splits a sanitized mainline string into properties. Values are read
    /// verbatim between brackets, so nothing inside a value can be mistaken
    /// for an identifier; identifiers accumulate uppercase letters until a
    /// value block ends, so "AB" never splits into "A" and "B".
    static func properties(in text: String) -> [Property] {
        var result: [Property] = []
        var identifier = ""
        var values: [String] = []
        var value = ""
        var inValue = false

        func flush() {
            if !identifier.isEmpty {
                result.append(Property(identifier: identifier, values: values))
            }
            identifier = ""
            values = []
        }

        for character in text {
            if inValue {
                if character == "]" {
                    inValue = false
                    values.append(value)
                    value = ""
                } else {
                    value.append(character)
                }
                continue
            }
            if character == "[" {
                inValue = true
            } else if character.isLetter && character.isUppercase {
                // An uppercase letter after a completed value block starts the
                // NEXT property; before one it extends the current identifier.
                if !values.isEmpty { flush() }
                identifier.append(character)
            } else if character == ";" || character == "(" || character == ")" {
                flush()
            }
        }
        flush()
        return result
    }

    /// Decodes an SGF point value. Returns nil for an empty value (an explicit
    /// pass) or for any point outside the board — which is exactly how the
    /// legacy "tt" pass decodes on boards up to 19x19.
    static func point(_ raw: String, width: Int, height: Int) -> SgfPoint? {
        let letters = Array(raw)
        guard letters.count == 2,
              let x = coordinate(letters[0]),
              let y = coordinate(letters[1]),
              x < width, y < height
        else { return nil }
        return SgfPoint(x: x, y: y)
    }

    /// SGF coordinate letter: "a"..."z" = 0...25, "A"..."Z" = 26...51.
    static func coordinate(_ character: Character) -> Int? {
        guard let ascii = character.asciiValue else { return nil }
        switch ascii {
        case UInt8(ascii: "a")...UInt8(ascii: "z"):
            return Int(ascii - UInt8(ascii: "a"))
        case UInt8(ascii: "A")...UInt8(ascii: "Z"):
            return Int(ascii - UInt8(ascii: "A")) + 26
        default:
            return nil
        }
    }
```

- [ ] **Step 7: Run the tests to verify they pass**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS/KataGoUICore" && swift test --filter KataGoAnalysisKitTests 2>&1 | tail -20
```

Expected: all tests pass, including the pre-existing ones (`handicapSetupStonesAreNotMoves`, `mainlineFollowsFirstBranchAtEachFork`, `commentsWithParensAndMoveLikeTextDoNotBreakTheScan`, `passMovesCount`, `nonSgfTextIsRejected`). If `mainlineFollowsFirstBranchAtEachFork` fails, the `(` / `)` flush in `properties(in:)` is wrong — those characters must end the current property, not be ignored.

- [ ] **Step 8: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-ios-dev
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoAnalysisKit/SgfHeaderScan.swift" \
        "ios/KataGo iOS/KataGoUICore/Tests/KataGoAnalysisKitTests/SgfHeaderScanTests.swift"
git commit -m "feat(sgf): scan mainline move coordinates and setup stones

The scan reported move colors only, which is all the Safari extension
needed. Replaying a board on the watch needs the coordinates too, plus
the AB/AW setup stones. Swaps the move regex for a property-token scan,
because a regex cannot tell the property AB from a Black move B without
lookbehind. moveColors becomes a computed view over the move list, so
existing callers are untouched.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF"
```

---

### Task 2: The pure-Swift SGF replayer

Produces the board position at any mainline index with real captures, engine-free. Replay is **permissive**: a recorded game may contain a position the configured ruleset would forbid, and rejecting a move mid-replay would corrupt every later index.

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/GoRulesKit/SgfReplay.swift`
- Create: `ios/KataGo iOS/KataGoUICore/Tests/GoRulesKitTests/SgfReplayTests.swift`

**Interfaces:**
- Consumes: `SgfHeaderScan`, `SgfMove`, `SgfPoint` (Task 1); `GoBoard.init(width:height:)`, `GoBoard.placeSetupStone(at:color:)`, `GoBoard.play(at:color:multiStoneSuicideLegal:) throws`, `GoBoard.playPass()`, `GoBoard.gtpVertices(of:)`, `GoBoard.color(at:)`, `GoPoint.gtpVertex(boardHeight:)`, `GoColor`.
- Produces:
  - `public struct SgfReplay: Sendable` with `public init(scan: SgfHeaderScan)`, `public let width: Int`, `public let height: Int`, `public let moveCount: Int`, `public private(set) var anomalyIndex: Int?`, `public static let checkpointStride = 25`, and `public mutating func position(at index: Int) -> Position`.
  - `public struct SgfReplay.Position: Sendable, Equatable` with `public let blackVertices: [String]`, `public let whiteVertices: [String]`, `public let lastMoveVertex: String?`, `public let toMove: PlayerColor`.

- [ ] **Step 1: Write the failing tests**

Create `ios/KataGo iOS/KataGoUICore/Tests/GoRulesKitTests/SgfReplayTests.swift`:

```swift
//
//  SgfReplayTests.swift
//  GoRulesKitTests
//
//  Locks in the engine-free replay the watch uses to draw any position of a
//  saved game without the phone or the C++ engine.
//

import Foundation
import Testing
@testable import GoRulesKit
import KataGoAnalysisKit

struct SgfReplayTests {
    private func replay(_ sgf: String) throws -> SgfReplay {
        SgfReplay(scan: try #require(SgfHeaderScan(sgf: sgf)))
    }

    @Test func emptyPositionAtIndexZero() throws {
        var r = try replay("(;GM[1]SZ[9];B[cc];W[gg])")
        let p = r.position(at: 0)
        #expect(p.blackVertices.isEmpty)
        #expect(p.whiteVertices.isEmpty)
        #expect(p.lastMoveVertex == nil)
        #expect(p.toMove == .black)
    }

    @Test func playsMovesInOrder() throws {
        var r = try replay("(;GM[1]SZ[9];B[cc];W[gg])")
        #expect(r.moveCount == 2)
        let one = r.position(at: 1)
        #expect(one.blackVertices == ["C7"])
        #expect(one.whiteVertices.isEmpty)
        #expect(one.lastMoveVertex == "C7")
        #expect(one.toMove == .white)

        let two = r.position(at: 2)
        #expect(two.blackVertices == ["C7"])
        #expect(two.whiteVertices == ["G3"])
        #expect(two.lastMoveVertex == "G3")
        #expect(two.toMove == .black)
    }

    @Test func indexIsClampedToTheMoveRange() throws {
        var r = try replay("(;GM[1]SZ[9];B[cc];W[gg])")
        #expect(r.position(at: -5) == r.position(at: 0))
        #expect(r.position(at: 99) == r.position(at: 2))
    }

    @Test func capturesAreApplied() throws {
        // Black surrounds a lone White stone in the corner (a1) and takes it.
        // W a1 = "ai" on a 9x9 (y = 8). Black plays b1 ("bi") and a2 ("ah").
        var r = try replay("(;GM[1]SZ[9];B[bi];W[ai];B[ah])")
        let p = r.position(at: 3)
        #expect(p.whiteVertices.isEmpty)
        #expect(Set(p.blackVertices) == Set(["B1", "A2"]))
    }

    @Test func passesAdvanceTheIndexWithoutChangingTheBoard() throws {
        var r = try replay("(;GM[1]SZ[9];B[cc];W[];B[gg])")
        #expect(r.moveCount == 3)
        let afterPass = r.position(at: 2)
        #expect(afterPass.blackVertices == ["C7"])
        #expect(afterPass.whiteVertices.isEmpty)
        #expect(afterPass.lastMoveVertex == nil)
        #expect(afterPass.toMove == .black)
    }

    @Test func setupStonesSeedThePosition() throws {
        var r = try replay("(;GM[1]SZ[19]HA[2]AB[pd][dp];W[dd])")
        let start = r.position(at: 0)
        #expect(Set(start.blackVertices) == Set(["Q16", "D4"]))
        #expect(start.toMove == .white)
        let one = r.position(at: 1)
        #expect(one.whiteVertices == ["D16"])
    }

    @Test func replayingFromACheckpointMatchesReplayingFromZero() throws {
        // 60 moves on every other intersection, so no stone ever touches
        // another: no captures, no suicide, and every move stays on a 19x19
        // board. That isolates what this test is about — the stride-25
        // checkpoints — from rules behaviour covered elsewhere.
        var sgf = "(;GM[1]SZ[19]"
        for index in 0..<60 {
            let color = index.isMultiple(of: 2) ? "B" : "W"
            let column = Character(UnicodeScalar(UInt8(ascii: "a") + UInt8(2 * (index % 8))))
            let row = Character(UnicodeScalar(UInt8(ascii: "a") + UInt8(2 * (index / 8))))
            sgf += ";\(color)[\(column)\(row)]"
        }
        sgf += ")"

        var forward = try replay(sgf)
        var backward = try replay(sgf)
        var expected: [SgfReplay.Position] = []
        for index in 0...60 { expected.append(forward.position(at: index)) }
        for index in stride(from: 60, through: 0, by: -1) {
            #expect(backward.position(at: index) == expected[index])
        }
        #expect(forward.anomalyIndex == nil)
    }

    @Test func aRefusedMoveIsSkippedAndRecorded() throws {
        // The second Black move repeats an occupied point; replay must skip it
        // and keep going rather than corrupting every later index.
        var r = try replay("(;GM[1]SZ[9];B[cc];W[gg];B[cc];W[dd])")
        let p = r.position(at: 4)
        #expect(Set(p.blackVertices) == Set(["C7"]))
        #expect(Set(p.whiteVertices) == Set(["G3", "D6"]))
        #expect(r.anomalyIndex == 2)
    }

    @Test func rectangularBoardsReplay() throws {
        var r = try replay("(;GM[1]SZ[19:9];B[aa];W[si])")
        #expect(r.width == 19)
        #expect(r.height == 9)
        let p = r.position(at: 2)
        #expect(p.blackVertices == ["A9"])
        #expect(p.whiteVertices == ["T1"])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS/KataGoUICore" && \
swift test --filter SgfReplayTests 2>&1 | tail -20
```

Expected: compile failure — `cannot find 'SgfReplay' in scope`.

- [ ] **Step 3: Write the replayer**

Create `ios/KataGo iOS/KataGoUICore/Sources/GoRulesKit/SgfReplay.swift`:

```swift
//
//  SgfReplay.swift
//  GoRulesKit
//
//  Engine-free replay of an SGF's mainline to any move index. Exists so a
//  process that cannot link the C++ engine — the watch app — can draw the
//  board at an arbitrary position of a saved game. The record's cached
//  blackStones/whiteStones dictionaries are NOT a substitute: they only cover
//  indices the phone actually visited, so an imported game has nothing but
//  its final position.
//

import Foundation
import KataGoAnalysisKit

public struct SgfReplay: Sendable {
    /// A drawn position: stones as GTP vertices, plus what to highlight.
    public struct Position: Sendable, Equatable {
        public let blackVertices: [String]
        public let whiteVertices: [String]
        /// The move that produced this position; nil at index 0 and after a pass.
        public let lastMoveVertex: String?
        public let toMove: PlayerColor

        public init(blackVertices: [String], whiteVertices: [String],
                    lastMoveVertex: String?, toMove: PlayerColor) {
            self.blackVertices = blackVertices
            self.whiteVertices = whiteVertices
            self.lastMoveVertex = lastMoveVertex
            self.toMove = toMove
        }
    }

    /// Boards are memoized every this many moves so scrubbing backwards in a
    /// long game does not replay from zero on watch hardware.
    public static let checkpointStride = 25

    public let width: Int
    public let height: Int
    public let moveCount: Int

    /// The first mainline move the board refused, if any. Diagnostic only —
    /// a refused move is skipped, never fatal.
    public private(set) var anomalyIndex: Int?

    private let scan: SgfHeaderScan
    private var checkpoints: [Int: GoBoard]

    public init(scan: SgfHeaderScan) {
        self.scan = scan
        width = max(scan.boardWidth, 1)
        height = max(scan.boardHeight, 1)
        moveCount = scan.moves.count

        var board = GoBoard(width: width, height: height)
        for point in scan.setupBlack {
            let target = GoPoint(x: point.x, y: point.y)
            guard board.color(at: target) == .empty else { continue }
            board.placeSetupStone(at: target, color: .black)
        }
        for point in scan.setupWhite {
            let target = GoPoint(x: point.x, y: point.y)
            guard board.color(at: target) == .empty else { continue }
            board.placeSetupStone(at: target, color: .white)
        }
        checkpoints = [0: board]
    }

    /// The position after `index` moves. Out-of-range values clamp.
    public mutating func position(at index: Int) -> Position {
        let target = min(max(index, 0), moveCount)
        let board = board(at: target)
        var last: String?
        if target > 0, let point = scan.moves[target - 1].point {
            last = GoPoint(x: point.x, y: point.y).gtpVertex(boardHeight: height)
        }
        return Position(blackVertices: board.gtpVertices(of: .black),
                        whiteVertices: board.gtpVertices(of: .white),
                        lastMoveVertex: last,
                        toMove: scan.toMove(atMoveIndex: target))
    }

    private mutating func board(at target: Int) -> GoBoard {
        if let cached = checkpoints[target] { return cached }

        // Nearest memoized board at or below the target; index 0 always exists.
        var from = 0
        for key in checkpoints.keys where key <= target && key > from { from = key }
        var board = checkpoints[from] ?? GoBoard(width: width, height: height)

        var index = from
        while index < target {
            board = Self.apply(scan.moves[index], to: board,
                               index: index, anomaly: &anomalyIndex)
            index += 1
            if index.isMultiple(of: Self.checkpointStride) {
                checkpoints[index] = board
            }
        }
        return board
    }

    /// Permissive application: the simple-ko ban is cleared before each move
    /// and suicide is allowed, because a recorded game may contain a position
    /// the configured ruleset would forbid, and refusing a move mid-replay
    /// would corrupt every later index. A move the board still refuses is
    /// skipped and its index recorded.
    private static func apply(_ move: SgfMove, to board: GoBoard,
                              index: Int, anomaly: inout Int?) -> GoBoard {
        var candidate = board
        // A pass legitimately clears ko, which is exactly the reset we want.
        candidate.playPass()
        guard let point = move.point else { return candidate }
        do {
            try candidate.play(at: GoPoint(x: point.x, y: point.y),
                               color: move.color == .black ? .black : .white,
                               multiStoneSuicideLegal: true)
            return candidate
        } catch {
            if anomaly == nil { anomaly = index }
            return board
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS/KataGoUICore" && swift test --filter SgfReplayTests 2>&1 | tail -20
```

Expected: all 9 tests pass.

- [ ] **Step 5: Run the whole package suite for regressions**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS/KataGoUICore" && swift test 2>&1 | tail -20
```

Expected: no failures across `GoRulesKitTests`, `KataGoAnalysisKitTests`, `GobanRecogNativeTests`.

- [ ] **Step 6: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-ios-dev
git add "ios/KataGo iOS/KataGoUICore/Sources/GoRulesKit/SgfReplay.swift" \
        "ios/KataGo iOS/KataGoUICore/Tests/GoRulesKitTests/SgfReplayTests.swift"
git commit -m "feat(rules): replay an SGF mainline to any move index

Engine-free, so a process that cannot link the C++ engine can draw the
board at an arbitrary position. The record's cached per-move stone
dictionaries are not a substitute — they cover only indices the phone
visited, so an imported game has nothing but its final position.

Replay is permissive: ko is cleared before each move and suicide is
allowed, because a recorded game may hold a position the configured
ruleset would forbid and a refusal mid-replay would corrupt every later
index. Boards memoize every 25 moves so scrubbing backwards stays cheap.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF"
```

---

### Task 3: Differential test against the C++ SGF parser

The pure-Swift replay must agree with the engine's own parser. The iOS test target links the C++ bridge (`-bundle_loader`), so it can compare the two.

**Files:**
- Create: `ios/KataGo iOS/KataGo iOSTests/SgfReplayDifferentialTests.swift`

**Interfaces:**
- Consumes: `SgfReplay` (Task 2); `SgfOperations(sgf:)` with `public func finalStones() -> (black: [String], white: [String])` and `public var moveSize: Int?` from `KataGoUICore`.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Write the test file**

Create `ios/KataGo iOS/KataGo iOSTests/SgfReplayDifferentialTests.swift`:

```swift
//
//  SgfReplayDifferentialTests.swift
//  KataGo AnytimeTests
//
//  The watch draws saved games by replaying their SGF in pure Swift, with no
//  engine. This pins that replay to the C++ parser the app itself uses, so a
//  divergence shows up here rather than as a wrong board on someone's wrist.
//

import Testing
import Foundation
import GoRulesKit
import KataGoAnalysisKit
import KataGoGameStore
@testable import KataGoUICore

struct SgfReplayDifferentialTests {
    /// Replay's final position must equal the C++ parser's final position.
    private func expectAgreement(_ sgf: String, _ label: String) throws {
        let scan = try #require(SgfHeaderScan(sgf: sgf), "scan failed for \(label)")
        var replay = SgfReplay(scan: scan)
        let mine = replay.position(at: replay.moveCount)

        let operations = SgfOperations(sgf: sgf)
        let theirs = operations.finalStones()

        #expect(Set(mine.blackVertices) == Set(theirs.black), "black mismatch: \(label)")
        #expect(Set(mine.whiteVertices) == Set(theirs.white), "white mismatch: \(label)")
        #expect(replay.moveCount == operations.moveSize, "move count mismatch: \(label)")
        #expect(replay.anomalyIndex == nil, "replay refused a move: \(label)")
    }

    @Test func plainGameAgrees() throws {
        try expectAgreement(
            "(;FF[4]GM[1]SZ[19]KM[7];B[pd];W[dp];B[dd];W[pp];B[qn];W[nq])",
            "plain 19x19")
    }

    @Test func captureAgrees() throws {
        // White's corner stone dies; both parsers must remove it.
        try expectAgreement(
            "(;FF[4]GM[1]SZ[9]KM[7];B[bi];W[ai];B[ah])",
            "corner capture")
    }

    @Test func passesAgree() throws {
        try expectAgreement(
            "(;FF[4]GM[1]SZ[9]KM[7];B[cc];W[];B[gg];W[tt])",
            "passes")
    }

    @Test func handicapSetupAgrees() throws {
        try expectAgreement(
            "(;FF[4]GM[1]SZ[19]HA[2]KM[0]AB[pd][dp];W[dd];B[pp])",
            "two-stone handicap")
    }

    @Test func rectangularBoardAgrees() throws {
        try expectAgreement(
            "(;FF[4]GM[1]SZ[19:9]KM[7];B[aa];W[si];B[jd])",
            "19x9 rectangle")
    }

    @Test func ladderCaptureAgrees() throws {
        // A multi-stone capture: White's two-stone chain on the first line is
        // enclosed and taken.
        try expectAgreement(
            "(;FF[4]GM[1]SZ[9]KM[7];B[ah];W[ai];B[bh];W[bi];B[ci])",
            "two-stone capture")
    }

    @Test func defaultRecordSgfAgrees() throws {
        try expectAgreement(GameRecord.defaultSgf, "GameRecord.defaultSgf")
    }
}
```

- [ ] **Step 2: Register the file in the test target**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS" && \
ruby scripts_add_swift_files.rb "KataGo AnytimeTests" "KataGo iOSTests/SgfReplayDifferentialTests.swift"
```

Expected: a line confirming the file was added. If the script reports it is already present, that is fine.

- [ ] **Step 3: Run the suite to verify it passes**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS" && \
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/SgfReplayDifferentialTests" \
  2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|error:|✘"
```

Expected: `** TEST SUCCEEDED **`.

If a case disagrees, the replay is wrong — fix `SgfReplay`/`SgfHeaderScan`, not the test. The one legitimate exception is a mismatch caused by the C++ parser applying a *rule* the permissive replay deliberately ignores; if you believe that is the case, prove it by naming the exact rule and the exact move index in the commit message before changing any expectation.

- [ ] **Step 4: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-ios-dev
git add "ios/KataGo iOS/KataGo iOSTests/SgfReplayDifferentialTests.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "test(rules): pin SgfReplay to the C++ SGF parser

The watch will draw saved games from the pure-Swift replay, so a
divergence from the engine's own parser must surface in CI rather than
as a wrong board on someone's wrist. Covers captures, passes, handicap
setup, rectangular boards, and the default record SGF.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF"
```

---

### Task 4: A CloudKit-only store for watchOS

tvOS already opens a plain (non-App-Group) CloudKit store through a never-crash ladder. The watch needs the same shape. Generalize the tvOS branch rather than copying it.

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/SharedModelContainer.swift`

**Interfaces:**
- Consumes: `LibraryStoreMode` (`.cloudKit` / `.localOnly` / `.inMemory`) from `LibrarySyncState.swift`.
- Produces:
  - `SharedModelContainer.cloudOnlyStoreMode: LibraryStoreMode` (available on tvOS and watchOS).
  - `SharedModelContainer.watchStoreMode: LibraryStoreMode` (watchOS only) — used by Task 9's empty-state logic.
  - `SharedModelContainer.tvStoreMode` keeps working unchanged for the tvOS target.

**No new unit test in this task, deliberately.** A store-open ladder is three branches each assigning a constant; the existing tvOS one was never unit-tested because there is nothing to test that the code does not already state outright. A pure decision function here could only ever be called with literal `true`/`false`, so it would pin nothing. This task is verified by the existing iOS suite still passing, the tvOS scheme still building, and Task 9's simulator run reaching the library instead of crashing.

- [ ] **Step 1: Generalize the tvOS branch to cover watchOS**

In `SharedModelContainer.swift`, replace the entire `#if os(tvOS) … #endif` region (currently lines 94-148) with:

```swift
    #if os(tvOS) || os(watchOS)
    /// Which rung of the CloudKit-only open ladder produced `shared`. Written
    /// exactly once, inside the `shared` static-let initializer (swift_once —
    /// happens-before every reader); `nonisolated(unsafe)` mirrors the
    /// LibraryStore write-once observer-token pattern.
    nonisolated(unsafe) private static var _cloudOnlyStoreMode: LibraryStoreMode = .cloudKit

    /// The rung of the open ladder that won, for the library's empty-state UI
    /// ("iCloud is unavailable" when sync cannot happen this launch). The
    /// getter touches `shared` first so no caller can observe the default
    /// before the ladder has run.
    public static var cloudOnlyStoreMode: LibraryStoreMode {
        _ = shared
        return _cloudOnlyStoreMode
    }

    /// A PLAIN SwiftData store (no `groupContainer`) mirrored to the private
    /// CloudKit database. Apple TV has no second process to share with and its
    /// group `containerURL` can be nil, which would silently disable CloudKit;
    /// the watch's only second process is the complication, which reads
    /// UserDefaults rather than the store. So on both, the App Group buys
    /// nothing and carries that risk. CloudKit is the sole inbound path for
    /// games on both devices.
    static func cloudOnlyCloudKitConfig() -> ModelConfiguration {
        ModelConfiguration(schema: schema,
                           cloudKitDatabase: .private(cloudKitContainerID))
    }

    /// Degraded config: the same plain local store with CloudKit disabled.
    /// The store is reconstructible from iCloud anyway, so this is an
    /// acceptable fallback that a later launch retries against CloudKit.
    static func cloudOnlyLocalConfig() -> ModelConfiguration {
        ModelConfiguration(schema: schema, cloudKitDatabase: .none)
    }

    /// CloudKit-only open path — NEVER crashes: CloudKit → local-only →
    /// in-memory. Unlike the iOS app's `retryThenLocalOnlyThenCrash`, a
    /// memory-pressured TV or watch must degrade to a retryable "storage
    /// unavailable" state, never `fatalError`.
    private static func openCloudOnlyStore() -> ModelContainer {
        do {
            let container = try ModelContainer(for: schema,
                                               configurations: cloudOnlyCloudKitConfig())
            _cloudOnlyStoreMode = .cloudKit
            return container
        } catch {
            NSLog("SharedModelContainer: CloudKit store open failed, degrading local-only: \(error)")
            do {
                let container = try ModelContainer(for: schema,
                                                   configurations: cloudOnlyLocalConfig())
                _cloudOnlyStoreMode = .localOnly
                return container
            } catch {
                NSLog("SharedModelContainer: local store open failed, using in-memory: \(error)")
                _cloudOnlyStoreMode = .inMemory
                return makeInMemoryContainer()
            }
        }
    }
    #endif

    #if os(tvOS)
    /// The tvOS name for `cloudOnlyStoreMode`, kept so the TV target's call
    /// sites are untouched.
    public static var tvStoreMode: LibraryStoreMode { cloudOnlyStoreMode }
    #endif

    #if os(watchOS)
    /// The watch's rung of the open ladder, for the library's empty state.
    public static var watchStoreMode: LibraryStoreMode { cloudOnlyStoreMode }
    #endif
```

- [ ] **Step 2: Route the watch through the ladder**

In the `shared` initializer, replace:

```swift
        #if os(tvOS)
        // Apple TV: no App Group (no widget/second process to share with), no
        // migration ladder (no pre-App-Group store to bring forward), and it must
        // NEVER fatalError. CloudKit is the only inbound path for games, and the
        // local store is purgeable — so a local-only degradation on CloudKit
        // failure is acceptable (next launch retries CloudKit).
        return openTVOSStore()
        #else
```

with:

```swift
        #if os(tvOS) || os(watchOS)
        // Apple TV and Apple Watch: no App-Group store (no second process that
        // reads it), no migration ladder (no pre-App-Group store to bring
        // forward), and neither may EVER fatalError. CloudKit is the only
        // inbound path for games on both, and the local store is
        // reconstructible — so a local-only degradation on CloudKit failure is
        // acceptable (next launch retries CloudKit).
        return openCloudOnlyStore()
        #else
```

- [ ] **Step 3: Run the existing store suite for regressions**

This task adds no tests; it must not break the 32 that already cover the store.

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS" && \
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/SharedModelContainerTests" \
  2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|error:"
```

Expected: `** TEST SUCCEEDED **`, all 32 pre-existing tests still passing.

- [ ] **Step 4: Verify the tvOS scheme still builds**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS" && \
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime TV" \
  -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)|error:"
```

Expected: `** BUILD SUCCEEDED **`. `tvStoreMode` must still resolve for `TVLibraryView` and `TVSettingsScreen`.

- [ ] **Step 5: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-ios-dev
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/SharedModelContainer.swift"
git commit -m "feat(store): open a CloudKit-only store on watchOS

The watch links KataGoGameStore already but never opened a container, so
with no phone in range it had no games to show. Apple TV had already
solved the same problem — a plain non-App-Group store over the private
CloudKit database, opened through a ladder that degrades rather than
crashing — so generalize that branch instead of copying it. tvStoreMode
survives as a tvOS-only alias.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF"
```

---

### Task 5: Watch entitlements and the GoRulesKit link

Without the iCloud entitlement the container from Task 4 falls straight to its local-only rung and the library is permanently empty.

**Files:**
- Modify: `ios/KataGo iOS/KataGo Anytime Watch/KataGo Anytime Watch.entitlements`
- Create: `ios/KataGo iOS/add_gorules_to_watch.rb`
- Modify: `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj` (by script)

**Interfaces:**
- Consumes: nothing.
- Produces: `import GoRulesKit` becomes legal in the watch target; the watch app can open a CloudKit store.

- [ ] **Step 1: Add the iCloud entitlements**

Replace the whole of `ios/KataGo iOS/KataGo Anytime Watch/KataGo Anytime Watch.entitlements` with:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>aps-environment</key>
	<string>development</string>
	<key>com.apple.developer.icloud-container-identifiers</key>
	<array>
		<string>iCloud.chinchangyang.KataGo-iOS.tw</string>
	</array>
	<key>com.apple.developer.icloud-services</key>
	<array>
		<string>CloudKit</string>
	</array>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.chinchangyang.KataGo-iOS.tw</string>
	</array>
</dict>
</plist>
```

The App Group stays: the ScoreLeadWidget complication still reads `watchScoreLeadBlack` / `watchScoreUpdatedAt` from it. `aps-environment` is what lets silent CloudKit pushes drive import while the app is foregrounded.

Leave `KataGoAnytimeWatchWidget/KataGoAnytimeWatchWidget.entitlements` untouched — the complication never reads the store.

- [ ] **Step 2: Write the link script**

Create `ios/KataGo iOS/add_gorules_to_watch.rb`:

```ruby
#!/usr/bin/env ruby
# Links the bridge-free GoRulesKit product into the "KataGo Anytime Watch"
# target (SGF replay for the standalone library browser). The watch must NEVER
# link KataGoUICore. Idempotent.
require 'xcodeproj'

PROJECT = File.join(__dir__, 'KataGo Anytime.xcodeproj')
WATCH   = 'KataGo Anytime Watch'
PRODUCT = 'GoRulesKit'

project = Xcodeproj::Project.open(PROJECT)
watch = project.targets.find { |t| t.name == WATCH } or abort("missing #{WATCH}")

pkg = project.root_object.package_references.find do |r|
  r.respond_to?(:relative_path) && r.relative_path == 'KataGoUICore'
end or abort('missing KataGoUICore package reference')

if watch.package_product_dependencies.any? { |d| d.product_name == PRODUCT }
  puts "#{PRODUCT} already linked into #{WATCH} — nothing to do."
  exit 0
end

dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
dep.package = pkg
dep.product_name = PRODUCT
watch.package_product_dependencies << dep

bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
bf.product_ref = dep
watch.frameworks_build_phase.files << bf

project.save
puts "Linked #{PRODUCT} into #{WATCH}."
```

- [ ] **Step 3: Run the script**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS" && ruby add_gorules_to_watch.rb
```

Expected: `Linked GoRulesKit into KataGo Anytime Watch.`

- [ ] **Step 4: Prove the link works**

Temporarily add `import GoRulesKit` to the top of `ios/KataGo iOS/KataGo Anytime Watch/WatchLiveModel.swift`, then:

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS" && \
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Watch" \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' \
  2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)|error:|warning:"
```

Expected: `** BUILD SUCCEEDED **` with no warnings. Then **remove** the temporary import again (Task 8 adds the real one) and re-run the build to confirm it is still green.

- [ ] **Step 5: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-ios-dev
git add "ios/KataGo iOS/KataGo Anytime Watch/KataGo Anytime Watch.entitlements" \
        "ios/KataGo iOS/add_gorules_to_watch.rb" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "build(watch): grant iCloud and link GoRulesKit

The watch container opens against the private CloudKit database, which
needs the iCloud entitlement the watch app never had; aps-environment
lets silent pushes drive the import. The App Group stays — the
complication still reads its two UserDefaults keys from it.

GoRulesKit is bridge-free (it depends only on KataGoGameStore, which the
watch already links), so it is legal here where KataGoUICore is not.

NOTE: this adds the iCloud capability to the App ID
chinchangyang.KataGo-iOS.tw.watchkitapp. Run a local device build with
-allowProvisioningUpdates to register it BEFORE the next Xcode Cloud
archive, or export will fail the way the first watch archive did.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF"
```

---

### Task 6: WatchBoardFrame, and the live pages moved onto it

One value type both the live mirror and the offline browser render, so neither page has to know which world it is in. This task must change **no live behaviour** — it only introduces the seam.

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchBoardFrame.swift`
- Create: `ios/KataGo iOS/KataGo Anytime Watch/WatchFrameBoard.swift`
- Modify: `ios/KataGo iOS/KataGo Anytime Watch/WatchBoardPage.swift`
- Create: `ios/KataGo iOS/KataGo iOSTests/WatchBoardFrameTests.swift`

`WatchMovesPage` is deliberately untouched here — its rows already take `WatchSnapshot.Candidate`, which is exactly what `WatchBoardFrame.candidates` holds. Task 9 gives it the stored branch.

**Interfaces:**
- Consumes: `WatchSnapshot`, `WatchSnapshot.Candidate`, `PlayerColor`.
- Produces: `WatchBoardFrame` (below). Task 8 builds the `.stored` variant; Task 9 renders both.

- [ ] **Step 1: Write the failing tests**

Create `ios/KataGo iOS/KataGo iOSTests/WatchBoardFrameTests.swift`:

```swift
//
//  WatchBoardFrameTests.swift
//  KataGo AnytimeTests
//
//  The one frame both watch worlds render: the iPhone mirror and the watch's
//  own replay of a saved game.
//

import Testing
import Foundation
@testable import KataGoGameStore

struct WatchBoardFrameTests {
    private func snapshot() -> WatchSnapshot {
        var s = WatchSnapshot(boardWidth: 19, boardHeight: 19,
                              blackStones: ["Q16"], whiteStones: ["D4"],
                              toMove: "B", moveNumber: 2,
                              analysisRunning: true,
                              rootWinrateBlack: 0.55, rootScoreLeadBlack: 1.5,
                              candidates: [
                                .init(vertex: "Q4", winrate: 0.56, scoreLead: 1.8,
                                      visits: 100, pv: ["Q4", "D16"]),
                                .init(vertex: "D16", winrate: 0.54, scoreLead: 1.2,
                                      visits: 80, pv: ["D16"]),
                                .init(vertex: "K10", winrate: 0.53, scoreLead: 1.0,
                                      visits: 60, pv: ["K10"]),
                                .init(vertex: "C3", winrate: 0.52, scoreLead: 0.9,
                                      visits: 40, pv: ["C3"]),
                              ],
                              hostTimestamp: Date(timeIntervalSince1970: 1_780_000_000))
        s.hostMoveIndex = 2
        s.hostMoveCount = 7
        return s
    }

    @Test func liveFrameCarriesTheSnapshot() {
        let frame = WatchBoardFrame.live(snapshot: snapshot(), stale: false,
                                         showCandidates: true,
                                         lastMoveVertex: "D4", title: "Game 1")
        #expect(frame.source == .live(stale: false))
        #expect(frame.title == "Game 1")
        #expect(frame.boardWidth == 19)
        #expect(frame.blackStones == ["Q16"])
        #expect(frame.whiteStones == ["D4"])
        #expect(frame.lastMoveVertex == "D4")
        #expect(frame.moveIndex == 2)
        #expect(frame.moveCount == 7)
        #expect(frame.winrateBlack == 0.55)
        #expect(frame.scoreLeadBlack == 1.5)
        #expect(frame.bestMove == nil)
        #expect(frame.comment == nil)
    }

    @Test func liveFrameCapsCandidateDotsAtThree() {
        let frame = WatchBoardFrame.live(snapshot: snapshot(), stale: false,
                                         showCandidates: true,
                                         lastMoveVertex: nil, title: nil)
        // The board draws at most three dots; the moves page keeps the list.
        #expect(frame.candidateVertices == ["Q4", "D16", "K10"])
        #expect(frame.candidates.count == 4)
    }

    @Test func liveFrameHidesCandidatesWhenAsked() {
        let frame = WatchBoardFrame.live(snapshot: snapshot(), stale: true,
                                         showCandidates: false,
                                         lastMoveVertex: nil, title: nil)
        #expect(frame.candidateVertices.isEmpty)
        #expect(frame.source == .live(stale: true))
    }

    @Test func storedFrameCarriesCachedReviewData() {
        let frame = WatchBoardFrame.stored(title: "Kobayashi",
                                           boardWidth: 13, boardHeight: 13,
                                           blackStones: ["D4"], whiteStones: [],
                                           lastMoveVertex: "D4",
                                           moveIndex: 1, moveCount: 40,
                                           winrateBlack: 0.61, scoreLeadBlack: -2.5,
                                           bestMove: "K10", comment: "Solid opening.")
        #expect(frame.source == .stored)
        #expect(frame.title == "Kobayashi")
        #expect(frame.boardWidth == 13)
        #expect(frame.moveIndex == 1)
        #expect(frame.moveCount == 40)
        #expect(frame.winrateBlack == 0.61)
        #expect(frame.scoreLeadBlack == -2.5)
        #expect(frame.bestMove == "K10")
        #expect(frame.comment == "Solid opening.")
        // Nothing analyzes on the watch, so there is never a candidate list.
        #expect(frame.candidates.isEmpty)
        #expect(frame.candidateVertices.isEmpty)
    }

    @Test func storedFrameOmitsNumbersTheRecordNeverCached() {
        let frame = WatchBoardFrame.stored(title: "Study", boardWidth: 9, boardHeight: 9,
                                           blackStones: [], whiteStones: [],
                                           lastMoveVertex: nil,
                                           moveIndex: 0, moveCount: 0,
                                           winrateBlack: nil, scoreLeadBlack: nil,
                                           bestMove: nil, comment: nil)
        // Hidden, never zeroed — the watch must not invent a number.
        #expect(frame.winrateBlack == nil)
        #expect(frame.scoreLeadBlack == nil)
    }

    @Test func scoreTextReadsFromWhicheverSideLeads() {
        #expect(WatchBoardFrame.scoreText(3.5) == "B+3.5")
        #expect(WatchBoardFrame.scoreText(-3.5) == "W+3.5")
        #expect(WatchBoardFrame.scoreText(0) == "B+0.0")
    }
}
```

- [ ] **Step 2: Register the test file and run it to verify it fails**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS" && \
ruby scripts_add_swift_files.rb "KataGo AnytimeTests" "KataGo iOSTests/WatchBoardFrameTests.swift" && \
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchBoardFrameTests" \
  2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|error:"
```

Expected: compile error — `cannot find 'WatchBoardFrame' in scope`.

- [ ] **Step 3: Write WatchBoardFrame**

Create `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchBoardFrame.swift`:

```swift
//
//  WatchBoardFrame.swift
//  KataGoGameStore
//
//  What the watch draws, from either of its two worlds: a position mirrored
//  from the iPhone over WCSession, or one the watch replayed itself from its
//  own copy of a saved game. The board and moves pages render a frame and
//  never ask which world produced it.
//
//  Lives here rather than in the watch target because the watch has no test
//  bundle — this is the same reason the visionOS logic lives in the package.
//

import Foundation

public struct WatchBoardFrame: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// Mirrored from the iPhone. `stale` once frames stop arriving.
        case live(stale: Bool)
        /// Replayed from the watch's own SwiftData copy of the game.
        case stored
    }

    public var title: String?
    public var boardWidth: Int
    public var boardHeight: Int
    public var blackStones: [String]
    public var whiteStones: [String]
    public var lastMoveVertex: String?
    /// Vertices to dot on the board, already capped for legibility.
    public var candidateVertices: [String]
    /// The full candidate list for the moves page. Always empty when stored —
    /// nothing analyzes on the watch.
    public var candidates: [WatchSnapshot.Candidate]
    public var moveIndex: Int?
    public var moveCount: Int?
    /// Black's win rate, 0...1. Nil where nothing has been analyzed — hidden,
    /// never zeroed, so the watch does not invent a number.
    public var winrateBlack: Float?
    /// Black's score lead in points. Nil where nothing has been analyzed.
    public var scoreLeadBlack: Float?
    /// The engine's best move at this index, as the record cached it.
    public var bestMove: String?
    /// The commentary the record cached at this index.
    public var comment: String?
    public var source: Source

    public init(title: String?, boardWidth: Int, boardHeight: Int,
                blackStones: [String], whiteStones: [String],
                lastMoveVertex: String?, candidateVertices: [String],
                candidates: [WatchSnapshot.Candidate],
                moveIndex: Int?, moveCount: Int?,
                winrateBlack: Float?, scoreLeadBlack: Float?,
                bestMove: String?, comment: String?,
                source: Source) {
        self.title = title
        self.boardWidth = boardWidth
        self.boardHeight = boardHeight
        self.blackStones = blackStones
        self.whiteStones = whiteStones
        self.lastMoveVertex = lastMoveVertex
        self.candidateVertices = candidateVertices
        self.candidates = candidates
        self.moveIndex = moveIndex
        self.moveCount = moveCount
        self.winrateBlack = winrateBlack
        self.scoreLeadBlack = scoreLeadBlack
        self.bestMove = bestMove
        self.comment = comment
        self.source = source
    }

    /// How many candidate dots the board draws at watch size.
    public static let candidateDotLimit = 3

    /// A frame from an iPhone snapshot. The caller has already chosen WHICH
    /// snapshot (cursor target, ring entry, or live head) and whether its
    /// candidates are current — that mode logic stays in the board page.
    public static func live(snapshot: WatchSnapshot,
                            stale: Bool,
                            showCandidates: Bool,
                            lastMoveVertex: String?,
                            title: String?) -> WatchBoardFrame {
        WatchBoardFrame(
            title: title,
            boardWidth: snapshot.boardWidth,
            boardHeight: snapshot.boardHeight,
            blackStones: snapshot.blackStones,
            whiteStones: snapshot.whiteStones,
            lastMoveVertex: lastMoveVertex,
            candidateVertices: showCandidates
                ? snapshot.candidates.prefix(candidateDotLimit).map(\.vertex) : [],
            candidates: snapshot.candidates,
            moveIndex: snapshot.hostMoveIndex,
            moveCount: snapshot.hostMoveCount,
            winrateBlack: snapshot.rootWinrateBlack,
            scoreLeadBlack: snapshot.rootScoreLeadBlack,
            bestMove: nil,
            comment: nil,
            source: .live(stale: stale))
    }

    /// A frame the watch replayed from its own copy of a saved game. Analysis
    /// fields come from whatever the record cached at this index; the watch
    /// never computes them.
    public static func stored(title: String?,
                              boardWidth: Int, boardHeight: Int,
                              blackStones: [String], whiteStones: [String],
                              lastMoveVertex: String?,
                              moveIndex: Int, moveCount: Int,
                              winrateBlack: Float?, scoreLeadBlack: Float?,
                              bestMove: String?, comment: String?) -> WatchBoardFrame {
        WatchBoardFrame(
            title: title,
            boardWidth: boardWidth,
            boardHeight: boardHeight,
            blackStones: blackStones,
            whiteStones: whiteStones,
            lastMoveVertex: lastMoveVertex,
            candidateVertices: [],
            candidates: [],
            moveIndex: moveIndex,
            moveCount: moveCount,
            winrateBlack: winrateBlack,
            scoreLeadBlack: scoreLeadBlack,
            bestMove: bestMove,
            comment: comment,
            source: .stored)
    }

    /// "B+3.2" / "W+3.2" from Black's signed score lead.
    public static func scoreText(_ scoreLeadBlack: Float) -> String {
        scoreLeadBlack >= 0 ? String(format: "B+%.1f", scoreLeadBlack)
                            : String(format: "W+%.1f", -scoreLeadBlack)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS" && \
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchBoardFrameTests" \
  2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|error:"
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Render the live board page from a frame**

In `ios/KataGo iOS/KataGo Anytime Watch/WatchBoardPage.swift`, replace the `body`'s opening `let` block and the `VStack` contents so the page builds a frame and renders it. Replace this:

```swift
        let peek = model.peek
        let cursorMode = model.sharedCursorAvailable
        let shown = cursorMode ? cursorFrame : peek.current
        let previous = (!cursorMode && peek.entries.indices.contains(peek.viewIndex - 1))
            ? peek.entries[peek.viewIndex - 1] : nil

        VStack(spacing: 2) {
            if let s = shown {
                WidgetBoardView(
                    width: s.boardWidth, height: s.boardHeight,
                    blackVertices: s.blackStones, whiteVertices: s.whiteStones,
                    // Cursor mode: the host analyzes the shown position, so
                    // candidates are always current. Ring mode keeps v0's
                    // live-only rule.
                    candidateVertices: (cursorMode || peek.isLive)
                        ? s.candidates.prefix(3).map(\.vertex) : [],
                    lastMoveVertex: cursorMode ? nil
                        : WatchPeekBuffer.lastMoveVertex(previous: previous, current: s))
                .aspectRatio(CGFloat(s.boardWidth) / CGFloat(s.boardHeight), contentMode: .fit)

                // Two-tone winrate bar (Black share from the left) + score lead.
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        Rectangle().fill(.black)
                            .frame(width: geo.size.width * CGFloat(s.rootWinrateBlack))
                        Rectangle().fill(.white)
                    }
                }
                .frame(height: 4)
                .clipShape(Capsule())

                HStack(spacing: 4) {
                    if model.isStale {
                        Image(systemName: "wifi.slash")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .accessibilityLabel(staleAccessibilityLabel)
                    }
                    Text(scoreText(s.rootScoreLeadBlack))
                        .font(.system(.headline, design: .monospaced))
                }
            }
        }
```

with:

```swift
        let peek = model.peek

        VStack(spacing: 2) {
            if let frame = liveFrame {
                WatchFrameBoard(frame: frame,
                                staleAccessibilityLabel: staleAccessibilityLabel)
            }
        }
```

Then replace the private `scoreText(_:)` method at the bottom of the file with a `liveFrame` builder that keeps every mode rule intact:

```swift
    /// The frame to draw: same cursor/ring selection as before, expressed once.
    private var liveFrame: WatchBoardFrame? {
        let peek = model.peek
        let cursorMode = model.sharedCursorAvailable
        guard let shown = cursorMode ? cursorFrame : peek.current else { return nil }
        let previous = (!cursorMode && peek.entries.indices.contains(peek.viewIndex - 1))
            ? peek.entries[peek.viewIndex - 1] : nil
        return WatchBoardFrame.live(
            snapshot: shown,
            stale: model.isStale,
            // Cursor mode: the host analyzes the shown position, so candidates
            // are always current. Ring mode keeps v0's live-only rule.
            showCandidates: cursorMode || peek.isLive,
            lastMoveVertex: cursorMode ? nil
                : WatchPeekBuffer.lastMoveVertex(previous: previous, current: shown),
            title: nil)
    }
```

- [ ] **Step 6: Add the shared board subview**

Create `ios/KataGo iOS/KataGo Anytime Watch/WatchFrameBoard.swift`:

```swift
import SwiftUI
import KataGoGameStore

/// Draws a WatchBoardFrame: board, winrate bar, score line. Shared by the
/// live mirror and the offline browser so the two can never drift apart.
struct WatchFrameBoard: View {
    let frame: WatchBoardFrame
    /// Spoken text for the stale indicator; nil hides the indicator. Stored
    /// games never mirror anything, so they pass nothing.
    var staleAccessibilityLabel: Text? = nil

    private var isStale: Bool {
        frame.source == .live(stale: true)
    }

    var body: some View {
        WidgetBoardView(width: frame.boardWidth, height: frame.boardHeight,
                        blackVertices: frame.blackStones,
                        whiteVertices: frame.whiteStones,
                        candidateVertices: frame.candidateVertices,
                        lastMoveVertex: frame.lastMoveVertex)
            .aspectRatio(CGFloat(frame.boardWidth) / CGFloat(frame.boardHeight),
                         contentMode: .fit)

        if let winrate = frame.winrateBlack {
            // Two-tone winrate bar (Black share from the left).
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle().fill(.black)
                        .frame(width: geo.size.width * CGFloat(winrate))
                    Rectangle().fill(.white)
                }
            }
            .frame(height: 4)
            .clipShape(Capsule())
        }

        HStack(spacing: 4) {
            if isStale, let staleAccessibilityLabel {
                Image(systemName: "wifi.slash")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .accessibilityLabel(staleAccessibilityLabel)
            }
            // Browsing shows where you are in the game; the live mirror
            // already has that in its status pill.
            if frame.source == .stored,
               let index = frame.moveIndex, let count = frame.moveCount {
                Text("\(index) / \(count)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let score = frame.scoreLeadBlack {
                Text(WatchBoardFrame.scoreText(score))
                    .font(.system(.headline, design: .monospaced))
            }
        }
    }
}
```

- [ ] **Step 7: Register the new watch file and build**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS" && \
ruby scripts_add_swift_files.rb "KataGo Anytime Watch" "KataGo Anytime Watch/WatchFrameBoard.swift" && \
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Watch" \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' \
  2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)|error:|warning:"
```

Expected: `** BUILD SUCCEEDED **`, zero warnings.

- [ ] **Step 8: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-ios-dev
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchBoardFrame.swift" \
        "ios/KataGo iOS/KataGo Anytime Watch/WatchFrameBoard.swift" \
        "ios/KataGo iOS/KataGo Anytime Watch/WatchBoardPage.swift" \
        "ios/KataGo iOS/KataGo iOSTests/WatchBoardFrameTests.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "refactor(watch): draw the board from one frame type

The watch is about to gain a second source of positions — its own replay
of a saved game — and two pages that each reach into WatchLiveModel
would drift apart immediately. WatchBoardFrame is what both worlds
produce and the pages render.

Live behaviour is unchanged: the cursor/ring selection rules move into
liveFrame verbatim, including the ring's live-only candidate rule.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF"
```

---

### Task 7: The watch library store

Bounded, newest-first rows plus live refresh as CloudKit imports land.

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchLibraryStore.swift`
- Create: `ios/KataGo iOS/KataGo iOSTests/WatchLibraryStoreTests.swift`

**Interfaces:**
- Consumes: `GameRecord`, `SharedModelContainer`, `SgfHeaderScan`, `LibrarySyncPolicy`, `EmptyLibraryState`, `LibraryStoreMode`, `ICloudAccountState`.
- Produces:
  - `public struct WatchLibraryRow: Identifiable, Equatable, Sendable` — `id: String`, `name: String`, `boardWidth: Int`, `boardHeight: Int`, `sgf: String`, `lastModified: Date?`, `var sizeText: String`.
  - `@Observable @MainActor public final class WatchLibraryStore` — `public init(container: ModelContainer, storeMode: LibraryStoreMode)`, `public private(set) var rows: [WatchLibraryRow]`, `public var accountState: ICloudAccountState`, `public func refresh()`, `public func startObservingRemoteChanges()`, `public func moveCount(for row: WatchLibraryRow) -> Int`, `public func emptyState(now: Date) -> EmptyLibraryState`, `public func row(id: String) -> WatchLibraryRow?`.
  - `public static let fetchLimit = 100`.

- [ ] **Step 1: Write the failing tests**

Create `ios/KataGo iOS/KataGo iOSTests/WatchLibraryStoreTests.swift`:

```swift
//
//  WatchLibraryStoreTests.swift
//  KataGo AnytimeTests
//
//  The watch's own read-only view of the library. Bounded so a wrist-sized
//  process never faults in a game's heavy per-move analysis dictionaries.
//

import Testing
import Foundation
import SwiftData
@testable import KataGoGameStore

@MainActor
struct WatchLibraryStoreTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: SharedModelContainer.schema,
                           configurations: SharedModelContainer.inMemoryConfig())
    }

    @discardableResult
    private func insert(_ container: ModelContainer, name: String, sgf: String,
                        width: Int, height: Int, modified: Date) -> GameRecord {
        // GameRecord.createGameRecord lives in KataGoUICore's bridge
        // extension, which this KataGoGameStore-only suite must not import;
        // the synthesized @Model init is what GameEntityQueryTests uses too.
        let record = GameRecord(config: Config())
        record.name = name
        record.sgf = sgf
        record.width = width
        record.height = height
        record.lastModificationDate = modified
        container.mainContext.insert(record)
        return record
    }

    private let epoch = Date(timeIntervalSince1970: 1_780_000_000)

    @Test func rowsAreNewestFirst() throws {
        let container = try makeContainer()
        insert(container, name: "Older", sgf: "(;GM[1]SZ[19])", width: 19, height: 19,
               modified: epoch)
        insert(container, name: "Newer", sgf: "(;GM[1]SZ[19])", width: 19, height: 19,
               modified: epoch.addingTimeInterval(60))

        let store = WatchLibraryStore(container: container, storeMode: .cloudKit)
        store.refresh()
        #expect(store.rows.map(\.name) == ["Newer", "Older"])
    }

    @Test func rowsCarryBoardSizeAndSgf() throws {
        let container = try makeContainer()
        insert(container, name: "Rect", sgf: "(;GM[1]SZ[19:9];B[aa])", width: 19,
               height: 9, modified: epoch)

        let store = WatchLibraryStore(container: container, storeMode: .cloudKit)
        store.refresh()
        let row = try #require(store.rows.first)
        #expect(row.boardWidth == 19)
        #expect(row.boardHeight == 9)
        #expect(row.sizeText == "19x9")
        #expect(row.sgf.contains("SZ[19:9]"))
    }

    @Test func missingBoardSizeDefaultsToNineteen() throws {
        let container = try makeContainer()
        let record = insert(container, name: "NoSize", sgf: "(;GM[1]SZ[19])",
                            width: 19, height: 19, modified: epoch)
        record.width = nil
        record.height = nil

        let store = WatchLibraryStore(container: container, storeMode: .cloudKit)
        store.refresh()
        let row = try #require(store.rows.first)
        #expect(row.boardWidth == 19)
        #expect(row.boardHeight == 19)
    }

    @Test func moveCountIsScannedAndMemoized() throws {
        let container = try makeContainer()
        insert(container, name: "Three", sgf: "(;GM[1]SZ[9];B[aa];W[bb];B[cc])",
               width: 9, height: 9, modified: epoch)

        let store = WatchLibraryStore(container: container, storeMode: .cloudKit)
        store.refresh()
        let row = try #require(store.rows.first)
        #expect(store.moveCount(for: row) == 3)
        // A second read must return the same answer from the memo.
        #expect(store.moveCount(for: row) == 3)
    }

    @Test func unreadableSgfCountsAsZeroMoves() throws {
        let container = try makeContainer()
        insert(container, name: "Broken", sgf: "not an sgf at all",
               width: 19, height: 19, modified: epoch)

        let store = WatchLibraryStore(container: container, storeMode: .cloudKit)
        store.refresh()
        let row = try #require(store.rows.first)
        #expect(store.moveCount(for: row) == 0)
    }

    @Test func rowLookupByIDFindsTheGame() throws {
        let container = try makeContainer()
        insert(container, name: "Findable", sgf: "(;GM[1]SZ[19])", width: 19,
               height: 19, modified: epoch)

        let store = WatchLibraryStore(container: container, storeMode: .cloudKit)
        store.refresh()
        let row = try #require(store.rows.first)
        #expect(store.row(id: row.id)?.name == "Findable")
        #expect(store.row(id: "not-a-real-id") == nil)
    }

    @Test func emptyStateIsUnavailableOnADegradedStore() throws {
        let container = try makeContainer()
        let store = WatchLibraryStore(container: container, storeMode: .localOnly)
        store.refresh()
        #expect(store.emptyState(now: epoch) == .unavailable)
    }

    @Test func emptyStateIsSignedOutWithoutAnAccount() throws {
        let container = try makeContainer()
        let store = WatchLibraryStore(container: container, storeMode: .cloudKit)
        store.accountState = .unavailable
        store.refresh()
        #expect(store.emptyState(now: epoch) == .signedOut)
    }

    @Test func emptyStateStaysSyncingInsideTheLaunchGrace() throws {
        let container = try makeContainer()
        let store = WatchLibraryStore(container: container, storeMode: .cloudKit,
                                      openedAt: epoch)
        store.refresh()
        #expect(store.emptyState(now: epoch.addingTimeInterval(1)) == .syncing)
    }

    @Test func emptyStateSettlesToEmptyAfterTheGrace() throws {
        let container = try makeContainer()
        let store = WatchLibraryStore(container: container, storeMode: .cloudKit,
                                      openedAt: epoch)
        store.refresh()
        let after = epoch.addingTimeInterval(WatchLibraryStore.launchGrace + 1)
        #expect(store.emptyState(now: after) == .empty)
    }
}
```

- [ ] **Step 2: Register the test file and run it to verify it fails**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS" && \
ruby scripts_add_swift_files.rb "KataGo AnytimeTests" "KataGo iOSTests/WatchLibraryStoreTests.swift" && \
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchLibraryStoreTests" \
  2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|error:"
```

Expected: compile error — `cannot find 'WatchLibraryStore' in scope`.

- [ ] **Step 3: Write the store**

Create `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchLibraryStore.swift`:

```swift
//
//  WatchLibraryStore.swift
//  KataGoGameStore
//
//  The watch's read-only view of the game library. Read-only is structural,
//  not a convention: nothing here inserts, deletes, or saves, so the watch can
//  never conflict with the phone through CloudKit.
//
//  Lives here rather than in the watch target because the watch has no test
//  bundle. Never imports CloudKit — the account signal is passed in by the
//  view layer so this module stays appex-safe.
//

import Foundation
import SwiftData
import CoreData
import Observation
import KataGoAnalysisKit

/// One game as the watch library lists it.
public struct WatchLibraryRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let boardWidth: Int
    public let boardHeight: Int
    /// The game record, the only source the watch replays positions from.
    public let sgf: String
    public let lastModified: Date?

    public init(id: String, name: String, boardWidth: Int, boardHeight: Int,
                sgf: String, lastModified: Date?) {
        self.id = id
        self.name = name
        self.boardWidth = boardWidth
        self.boardHeight = boardHeight
        self.sgf = sgf
        self.lastModified = lastModified
    }

    /// "19x9". ASCII only — the multiplication sign is not worth the encoding
    /// risk in a string this small.
    public var sizeText: String { "\(boardWidth)x\(boardHeight)" }
}

@Observable
@MainActor
public final class WatchLibraryStore {
    /// Newest-first cap. A wrist-sized process has no business materializing
    /// an unbounded library, and nobody scrolls past a hundred games on a watch.
    public static let fetchLimit = 100
    /// How long after opening the store an empty library still reads as
    /// "syncing" rather than "no games".
    public static let launchGrace: TimeInterval = 10
    /// How long a remote-change burst keeps the library reading as "syncing".
    public static let remoteActivityWindow: TimeInterval = 5

    public private(set) var rows: [WatchLibraryRow] = []
    /// Set by the view layer, which owns the CloudKit account check.
    public var accountState: ICloudAccountState = .unknown

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let storeMode: LibraryStoreMode
    @ObservationIgnored private let openedAt: Date
    @ObservationIgnored private var lastRemoteChange: Date?
    @ObservationIgnored private var observer: (any NSObjectProtocol)?
    /// Memoized move counts. Observation-ignored on purpose: the library rows
    /// read this during body evaluation, and mutating observed state there
    /// would re-invalidate the view forever.
    @ObservationIgnored private var moveCounts: [String: Int] = [:]

    public init(container: ModelContainer,
                storeMode: LibraryStoreMode,
                openedAt: Date = Date()) {
        self.container = container
        self.storeMode = storeMode
        self.openedAt = openedAt
    }

    // No deinit: the store is owned by the App scene and lives as long as the
    // process, and a nonisolated deinit cannot touch this @MainActor state in
    // Swift 6 anyway.

    /// Newest-first, property-bounded fetch. `propertiesToFetch` keeps a
    /// game's heavy per-move dictionaries (ownership, win rates, best moves,
    /// board snapshots) out of the watch's memory; SwiftData faults anything
    /// unlisted in on demand, so this is a footprint bound, never a
    /// correctness change.
    public func refresh() {
        var descriptor = FetchDescriptor<GameRecord>(
            sortBy: [.init(\.lastModificationDate, order: .reverse)])
        descriptor.fetchLimit = Self.fetchLimit
        descriptor.propertiesToFetch = [
            \.uuid, \.name, \.width, \.height, \.sgf, \.lastModificationDate
        ]
        let fetched = (try? container.mainContext.fetch(descriptor)) ?? []
        rows = fetched.compactMap { record in
            guard let uuid = record.uuid else { return nil }
            return WatchLibraryRow(id: uuid.uuidString,
                                   name: record.name,
                                   boardWidth: record.width ?? 19,
                                   boardHeight: record.height ?? 19,
                                   sgf: record.sgf,
                                   lastModified: record.lastModificationDate)
        }
        // A game may have been edited on another device; drop stale counts.
        moveCounts = moveCounts.filter { key, _ in rows.contains { $0.id == key } }
    }

    /// Refetch whenever CloudKit lands an import, so games appear without a
    /// relaunch. Same pattern as the Mac's iCloud list.
    public func startObservingRemoteChanges() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lastRemoteChange = Date()
                self.refresh()
            }
        }
    }

    /// The game's mainline length, scanned on demand and memoized so opening
    /// the library never scans a hundred SGFs up front.
    public func moveCount(for row: WatchLibraryRow) -> Int {
        if let cached = moveCounts[row.id] { return cached }
        let count = SgfHeaderScan(sgf: row.sgf)?.moveCount ?? 0
        moveCounts[row.id] = count
        return count
    }

    public func row(id: String) -> WatchLibraryRow? {
        rows.first { $0.id == id }
    }

    /// What to show while `rows` is empty. Delegates to the same policy the
    /// Apple TV library uses.
    public func emptyState(now: Date) -> EmptyLibraryState {
        let recentActivity = lastRemoteChange.map {
            now.timeIntervalSince($0) < Self.remoteActivityWindow
        } ?? false
        return LibrarySyncPolicy.emptyLibraryState(
            storeMode: storeMode,
            accountState: accountState,
            importInFlight: false,
            recentRemoteActivity: recentActivity,
            graceExpired: now.timeIntervalSince(openedAt) >= Self.launchGrace)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS" && \
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchLibraryStoreTests" \
  2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|error:"
```

Expected: `** TEST SUCCEEDED **`, 10 tests.

- [ ] **Step 5: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-ios-dev
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchLibraryStore.swift" \
        "ios/KataGo iOS/KataGo iOSTests/WatchLibraryStoreTests.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(watch): a bounded read-only library over the watch's store

Rows carry only what the list and the replay need — id, name, size, SGF,
date — so a wrist-sized process never faults in a game's per-move
ownership or analysis dictionaries. Move counts are scanned lazily and
memoized, and the memo is observation-ignored because the rows read it
during body evaluation.

Refetches on NSPersistentStoreRemoteChange so games appear as CloudKit
imports land, and reuses the Apple TV empty-state policy verbatim.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF"
```

---

### Task 8: The browse model — a stored frame from a game

Turns a row plus a scrub index into a `WatchBoardFrame`, pulling the board from `SgfReplay` and the numbers from the record's cached dictionaries.

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchStoredAnalysis.swift`
- Create: `ios/KataGo iOS/KataGo Anytime Watch/WatchBrowseModel.swift`
- Create: `ios/KataGo iOS/KataGo iOSTests/WatchStoredAnalysisTests.swift`

**Interfaces:**
- Consumes: `WatchLibraryRow` (Task 7), `WatchBoardFrame` (Task 6), `SgfReplay` (Task 2), `GameRecord`.
- Produces:
  - `public struct WatchStoredAnalysis: Equatable, Sendable` — `winrateBlack: Float?`, `scoreLeadBlack: Float?`, `bestMove: String?`, `comment: String?`, plus `public static func at(index:winRates:scoreLeads:bestMoves:comments:) -> WatchStoredAnalysis`.
  - `@Observable @MainActor final class WatchBrowseModel` in the watch target — `init(row:container:)`, `var index: Int`, `var frame: WatchBoardFrame?`, `var moveCount: Int`, `var isReadable: Bool`.

- [ ] **Step 1: Write the failing tests**

Create `ios/KataGo iOS/KataGo iOSTests/WatchStoredAnalysisTests.swift`:

```swift
//
//  WatchStoredAnalysisTests.swift
//  KataGo AnytimeTests
//
//  Offline, the watch shows only the review data the phone already cached at
//  that exact index — hidden, never zeroed, where it cached nothing.
//

import Testing
import Foundation
@testable import KataGoGameStore

struct WatchStoredAnalysisTests {
    @Test func readsEveryFieldAtTheIndex() {
        let analysis = WatchStoredAnalysis.at(index: 3,
                                              winRates: [3: 0.62],
                                              scoreLeads: [3: 2.5],
                                              bestMoves: [3: "Q16"],
                                              comments: [3: "Territory-first."])
        #expect(analysis.winrateBlack == 0.62)
        #expect(analysis.scoreLeadBlack == 2.5)
        #expect(analysis.bestMove == "Q16")
        #expect(analysis.comment == "Territory-first.")
    }

    @Test func anUnanalyzedIndexYieldsNothing() {
        let analysis = WatchStoredAnalysis.at(index: 9,
                                              winRates: [3: 0.62],
                                              scoreLeads: [3: 2.5],
                                              bestMoves: [3: "Q16"],
                                              comments: [3: "Territory-first."])
        #expect(analysis == WatchStoredAnalysis(winrateBlack: nil, scoreLeadBlack: nil,
                                                bestMove: nil, comment: nil))
    }

    @Test func nilDictionariesYieldNothing() {
        let analysis = WatchStoredAnalysis.at(index: 0, winRates: nil, scoreLeads: nil,
                                              bestMoves: nil, comments: nil)
        #expect(analysis.winrateBlack == nil)
        #expect(analysis.scoreLeadBlack == nil)
        #expect(analysis.bestMove == nil)
        #expect(analysis.comment == nil)
    }

    @Test func partialCoverageFillsOnlyWhatExists() {
        // The phone caches these dictionaries independently; a comment can
        // exist at an index with no win rate.
        let analysis = WatchStoredAnalysis.at(index: 5, winRates: nil, scoreLeads: nil,
                                              bestMoves: nil, comments: [5: "Ko fight."])
        #expect(analysis.comment == "Ko fight.")
        #expect(analysis.winrateBlack == nil)
    }

    @Test func anEmptyCommentIsTreatedAsAbsent() {
        let analysis = WatchStoredAnalysis.at(index: 1, winRates: nil, scoreLeads: nil,
                                              bestMoves: nil, comments: [1: "   "])
        #expect(analysis.comment == nil)
    }
}
```

- [ ] **Step 2: Register the test file and run it to verify it fails**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS" && \
ruby scripts_add_swift_files.rb "KataGo AnytimeTests" "KataGo iOSTests/WatchStoredAnalysisTests.swift" && \
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchStoredAnalysisTests" \
  2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|error:"
```

Expected: compile error — `cannot find 'WatchStoredAnalysis' in scope`.

- [ ] **Step 3: Write the analysis lookup**

Create `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchStoredAnalysis.swift`:

```swift
//
//  WatchStoredAnalysis.swift
//  KataGoGameStore
//
//  What a saved game already knows about one position. The phone fills these
//  per-move dictionaries as it analyzes, so coverage is whatever the user
//  actually looked at — every field is independently optional and an absent
//  one must be HIDDEN, not zeroed. The watch computes nothing.
//

import Foundation

public struct WatchStoredAnalysis: Equatable, Sendable {
    public var winrateBlack: Float?
    public var scoreLeadBlack: Float?
    public var bestMove: String?
    public var comment: String?

    public init(winrateBlack: Float?, scoreLeadBlack: Float?,
                bestMove: String?, comment: String?) {
        self.winrateBlack = winrateBlack
        self.scoreLeadBlack = scoreLeadBlack
        self.bestMove = bestMove
        self.comment = comment
    }

    public static func at(index: Int,
                          winRates: [Int: Float]?,
                          scoreLeads: [Int: Float]?,
                          bestMoves: [Int: String]?,
                          comments: [Int: String]?) -> WatchStoredAnalysis {
        WatchStoredAnalysis(
            winrateBlack: winRates?[index],
            scoreLeadBlack: scoreLeads?[index],
            bestMove: bestMoves?[index].flatMap(nonBlank),
            comment: comments?[index].flatMap(nonBlank))
    }

    private static func nonBlank(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS" && \
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchStoredAnalysisTests" \
  2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|error:"
```

Expected: `** TEST SUCCEEDED **`, 5 tests.

- [ ] **Step 5: Write the browse model**

Create `ios/KataGo iOS/KataGo Anytime Watch/WatchBrowseModel.swift`:

```swift
import Foundation
import Observation
import SwiftData
import GoRulesKit
import KataGoAnalysisKit
import KataGoGameStore

/// Drives one game the watch is browsing offline: replay for the board,
/// the record's cached dictionaries for the numbers. Read-only throughout —
/// nothing here inserts, deletes, or saves.
@Observable
@MainActor
final class WatchBrowseModel {
    let row: WatchLibraryRow
    /// The scrub position, 0...moveCount.
    var index: Int = 0

    @ObservationIgnored private var replay: SgfReplay?
    // The record's cached review data, read ONCE when the game opens. Scrubbing
    // must not hit SwiftData: `frame` is recomputed on every Crown detent and
    // every body evaluation, and a predicate fetch at that rate is what makes
    // scrubbing feel bad on watch hardware. One game's four dictionaries are a
    // small, bounded cost — the footprint rule that keeps them out of the
    // library list is about a hundred rows, not one open game.
    @ObservationIgnored private let winRates: [Int: Float]?
    @ObservationIgnored private let scoreLeads: [Int: Float]?
    @ObservationIgnored private let bestMoves: [Int: String]?
    @ObservationIgnored private let comments: [Int: String]?

    init(row: WatchLibraryRow, container: ModelContainer) {
        self.row = row
        if let scan = SgfHeaderScan(sgf: row.sgf) {
            replay = SgfReplay(scan: scan)
        }

        let record = Self.record(for: row, container: container)
        winRates = record?.winRates
        scoreLeads = record?.scoreLeads
        bestMoves = record?.bestMoves
        comments = record?.comments

        // Open where the game itself sits, so the watch lands on the same
        // position the phone last showed.
        index = min(max(record?.currentIndex ?? 0, 0), moveCount)
    }

    /// False when the SGF could not be scanned at all.
    var isReadable: Bool { replay != nil }

    var moveCount: Int { replay?.moveCount ?? 0 }

    var frame: WatchBoardFrame? {
        guard var replay = self.replay else { return nil }
        let position = replay.position(at: index)
        self.replay = replay   // keep the memoized checkpoints
        let analysis = storedAnalysis()
        return WatchBoardFrame.stored(
            title: row.name,
            boardWidth: replay.width, boardHeight: replay.height,
            blackStones: position.blackVertices,
            whiteStones: position.whiteVertices,
            lastMoveVertex: position.lastMoveVertex,
            moveIndex: index, moveCount: replay.moveCount,
            winrateBlack: analysis.winrateBlack,
            scoreLeadBlack: analysis.scoreLeadBlack,
            bestMove: analysis.bestMove,
            comment: analysis.comment)
    }

    /// The review data the record cached at the scrubbed index. Pure lookup —
    /// the dictionaries were read once in `init`.
    private func storedAnalysis() -> WatchStoredAnalysis {
        WatchStoredAnalysis.at(index: index,
                               winRates: winRates,
                               scoreLeads: scoreLeads,
                               bestMoves: bestMoves,
                               comments: comments)
    }

    private static func record(for row: WatchLibraryRow,
                               container: ModelContainer) -> GameRecord? {
        guard let uuid = UUID(uuidString: row.id) else { return nil }
        return try? GameRecord.fetchGameRecord(uuid: uuid, container: container)
    }
}
```

- [ ] **Step 6: Register the file and build the watch**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS" && \
ruby scripts_add_swift_files.rb "KataGo Anytime Watch" "KataGo Anytime Watch/WatchBrowseModel.swift" && \
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Watch" \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' \
  2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)|error:|warning:"
```

Expected: `** BUILD SUCCEEDED **`, zero warnings.

Note: `GameRecord.fetchGameRecord(uuid:container:)` restricts `propertiesToFetch`, and `winRates`/`scoreLeads`/`bestMoves` are not in that list — SwiftData faults them in on demand when `init` reads them. That is exactly right here (one game, once, at open) and exactly wrong in the list, which is why Task 7 bounds its own fetch instead of reusing this one.

- [ ] **Step 7: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-ios-dev
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchStoredAnalysis.swift" \
        "ios/KataGo iOS/KataGo Anytime Watch/WatchBrowseModel.swift" \
        "ios/KataGo iOS/KataGo iOSTests/WatchStoredAnalysisTests.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(watch): browse one saved game offline

Board from the replay, numbers from whatever the record cached at that
index. Coverage of those dictionaries is whatever the user actually
analyzed on the phone, so each field is independently optional and an
absent one is hidden rather than shown as zero.

Opens at the game's own currentIndex so the watch lands where the phone
left off. Read-only: nothing inserts, deletes, or saves.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF"
```

---

### Task 9: The watch UI — library root, game view, auto-push

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchNavigationPolicy.swift`
- Create: `ios/KataGo iOS/KataGo Anytime Watch/WatchLibraryPage.swift`
- Create: `ios/KataGo iOS/KataGo Anytime Watch/WatchStoredGameView.swift`
- Modify: `ios/KataGo iOS/KataGo Anytime Watch/WatchRootView.swift`
- Modify: `ios/KataGo iOS/KataGo Anytime Watch/KataGoAnytimeWatchApp.swift`
- Create: `ios/KataGo iOS/KataGo iOSTests/WatchNavigationPolicyTests.swift`

`WatchBoardPage` and `WatchMovesPage` are unchanged here — they move wholesale into the pushed live-mirror destination and keep reading `WatchLiveModel` from the environment.

**Interfaces:**
- Consumes: `WatchLibraryStore`, `WatchBrowseModel`, `WatchBoardFrame`, `WatchFrameBoard`, `WatchLiveModel`, `SharedModelContainer.shared`, `SharedModelContainer.watchStoreMode`.
- Produces:
  - `public enum WatchLaunchRoute: Equatable, Sendable { case library, liveGame }`
  - `public enum WatchNavigationPolicy` with `public static func launchRoute(hasSnapshot:latchConsumed:) -> WatchLaunchRoute` and `public static func opensLiveMirror(rowID:hostGameID:hasSnapshot:) -> Bool`.

- [ ] **Step 1: Write the failing tests**

Create `ios/KataGo iOS/KataGo iOSTests/WatchNavigationPolicyTests.swift`:

```swift
//
//  WatchNavigationPolicyTests.swift
//  KataGo AnytimeTests
//
//  Where the watch lands on launch, and when a library row is really the
//  live game under another name.
//

import Testing
@testable import KataGoGameStore

struct WatchNavigationPolicyTests {
    @Test func aSnapshotSendsYouStraightToTheBoard() {
        // The glance case must stay zero-tap: the watch has always opened on
        // the mirrored board, including from WCSession's replayed context.
        #expect(WatchNavigationPolicy.launchRoute(hasSnapshot: true,
                                                  latchConsumed: false) == .liveGame)
    }

    @Test func noSnapshotLandsOnTheLibrary() {
        #expect(WatchNavigationPolicy.launchRoute(hasSnapshot: false,
                                                  latchConsumed: false) == .library)
    }

    @Test func theLatchStopsItPushingAgainThisSession() {
        // Without the latch, swiping back to the library would immediately
        // bounce you into the board again and the list would be unreachable.
        #expect(WatchNavigationPolicy.launchRoute(hasSnapshot: true,
                                                  latchConsumed: true) == .library)
    }

    @Test func theLiveGamesRowOpensTheMirrorNotAReplay() {
        #expect(WatchNavigationPolicy.opensLiveMirror(rowID: "abc",
                                                      hostGameID: "abc",
                                                      hasSnapshot: true))
    }

    @Test func anotherGamesRowOpensTheReplay() {
        #expect(!WatchNavigationPolicy.opensLiveMirror(rowID: "abc",
                                                       hostGameID: "xyz",
                                                       hasSnapshot: true))
    }

    @Test func withoutASnapshotEveryRowIsAReplay() {
        #expect(!WatchNavigationPolicy.opensLiveMirror(rowID: "abc",
                                                       hostGameID: "abc",
                                                       hasSnapshot: false))
        #expect(!WatchNavigationPolicy.opensLiveMirror(rowID: "abc",
                                                       hostGameID: nil,
                                                       hasSnapshot: true))
    }
}
```

- [ ] **Step 2: Register the test file and run it to verify it fails**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS" && \
ruby scripts_add_swift_files.rb "KataGo AnytimeTests" "KataGo iOSTests/WatchNavigationPolicyTests.swift" && \
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchNavigationPolicyTests" \
  2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|error:"
```

Expected: compile error — `cannot find 'WatchNavigationPolicy' in scope`.

- [ ] **Step 3: Write the policy**

Create `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchNavigationPolicy.swift`:

```swift
//
//  WatchNavigationPolicy.swift
//  KataGoGameStore
//
//  Where the watch lands, decided in one testable place because the watch
//  target has no test bundle.
//

import Foundation

public enum WatchLaunchRoute: Equatable, Sendable {
    case library
    case liveGame
}

public enum WatchNavigationPolicy {
    /// A snapshot — live or replayed from WCSession's persisted context —
    /// means the phone has something to show, so the watch opens on the board
    /// exactly as it always has. `latchConsumed` is set once the user has
    /// swiped back, so the library stays reachable for the rest of the session.
    public static func launchRoute(hasSnapshot: Bool,
                                   latchConsumed: Bool) -> WatchLaunchRoute {
        (hasSnapshot && !latchConsumed) ? .liveGame : .library
    }

    /// Whether tapping a library row should open the live mirror rather than
    /// the watch's own replay. There is never a stale second view of the game
    /// the phone is actually playing.
    public static func opensLiveMirror(rowID: String,
                                       hostGameID: String?,
                                       hasSnapshot: Bool) -> Bool {
        guard hasSnapshot, let hostGameID else { return false }
        return rowID == hostGameID
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS" && \
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchNavigationPolicyTests" \
  2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|error:"
```

Expected: `** TEST SUCCEEDED **`, 6 tests.

- [ ] **Step 5: Write the library page**

Create `ios/KataGo iOS/KataGo Anytime Watch/WatchLibraryPage.swift`:

```swift
import SwiftUI
import CloudKit
import KataGoGameStore

/// The watch's root: every saved game, with the phone's current game pinned
/// on top when there is one.
struct WatchLibraryPage: View {
    @Environment(WatchLiveModel.self) private var live
    @Environment(WatchLibraryStore.self) private var library
    @Binding var path: [WatchRoute]

    @State private var now = Date()

    var body: some View {
        List {
            if live.latest != nil {
                Section {
                    Button {
                        path.append(.live)
                    } label: {
                        liveRow
                    }
                }
            }

            if library.rows.isEmpty {
                emptyState
            } else {
                Section("Games") {
                    ForEach(library.rows) { row in
                        Button {
                            open(row)
                        } label: {
                            gameRow(row)
                        }
                    }
                }
            }
        }
        .navigationTitle("KataGo")
        .task {
            library.refresh()
            library.startObservingRemoteChanges()
            library.accountState = await Self.accountState()
            // Re-evaluate the empty state as the launch grace expires.
            try? await Task.sleep(for: .seconds(WatchLibraryStore.launchGrace))
            now = Date()
        }
    }

    private var liveRow: some View {
        HStack {
            Image(systemName: live.isStale ? "wifi.slash" : "dot.radiowaves.left.and.right")
                .foregroundStyle(live.isStale ? .red : .green)
            VStack(alignment: .leading) {
                Text(liveTitle).lineLimit(1)
                Text(liveSubtitle).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var liveTitle: String {
        if let id = live.latest?.hostGameID, let row = library.row(id: id) {
            return row.name
        }
        return "Live on iPhone"
    }

    private var liveSubtitle: String {
        guard let snapshot = live.latest else { return "" }
        if let index = snapshot.hostMoveIndex, let count = snapshot.hostMoveCount {
            return "Move \(index) of \(count)"
        }
        return "\(snapshot.boardWidth)x\(snapshot.boardHeight)"
    }

    private func gameRow(_ row: WatchLibraryRow) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(row.name).lineLimit(1)
            Text("\(row.sizeText) - \(library.moveCount(for: row)) moves")
                .font(.caption2).foregroundStyle(.secondary)
            if let date = row.lastModified {
                Text(date, style: .relative)
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch library.emptyState(now: now) {
        case .syncing:
            HStack {
                ProgressView()
                Text("Syncing from iCloud").font(.caption)
            }
        case .signedOut:
            Label("Sign in to iCloud on iPhone to see your games",
                  systemImage: "icloud.slash")
                .font(.caption)
        case .unavailable:
            Label("iCloud is unavailable. Games will appear once it reconnects.",
                  systemImage: "exclamationmark.icloud")
                .font(.caption)
        case .empty:
            Label("No games yet. Games sync from your iPhone.",
                  systemImage: "circle.grid.cross")
                .font(.caption)
        }
    }

    private func open(_ row: WatchLibraryRow) {
        if WatchNavigationPolicy.opensLiveMirror(rowID: row.id,
                                                 hostGameID: live.latest?.hostGameID,
                                                 hasSnapshot: live.latest != nil) {
            path.append(.live)
        } else {
            path.append(.stored(row.id))
        }
    }

    /// The account signal the empty-state policy needs. Kept in the view so
    /// KataGoGameStore never has to import CloudKit.
    private static func accountState() async -> ICloudAccountState {
        do {
            switch try await CKContainer(identifier: SharedModelContainer.cloudKitContainerID)
                .accountStatus() {
            case .available: return .available
            case .noAccount, .restricted: return .unavailable
            default: return .unknown
            }
        } catch {
            return .unknown
        }
    }
}
```

- [ ] **Step 6: Write the stored game view**

Create `ios/KataGo iOS/KataGo Anytime Watch/WatchStoredGameView.swift`:

```swift
import SwiftUI
import SwiftData
import KataGoGameStore

/// A saved game the watch replays itself: board page plus a review page,
/// the same two-page shape as the live mirror.
struct WatchStoredGameView: View {
    @State private var model: WatchBrowseModel
    @State private var crownIndex: Double = 0

    init(row: WatchLibraryRow, container: ModelContainer) {
        _model = State(initialValue: WatchBrowseModel(row: row, container: container))
    }

    var body: some View {
        Group {
            if model.isReadable, let frame = model.frame {
                TabView {
                    boardPage(frame)
                    reviewPage(frame)
                }
                .tabViewStyle(.verticalPage)
            } else {
                ContentUnavailableView("Can't read this game",
                                       systemImage: "doc.questionmark",
                                       description: Text("Its record could not be parsed."))
            }
        }
        .navigationTitle(model.row.name)
        .onAppear { crownIndex = Double(model.index) }
    }

    private func boardPage(_ frame: WatchBoardFrame) -> some View {
        VStack(spacing: 2) {
            WatchFrameBoard(frame: frame)
        }
        .focusable()
        .digitalCrownRotation($crownIndex,
                              from: 0, through: Double(model.moveCount),
                              by: 1, sensitivity: .medium,
                              isContinuous: false, isHapticFeedbackEnabled: true)
        .onChange(of: crownIndex) { _, newValue in
            // A local index over the watch's own replay: nothing to confirm
            // with the phone, so no debounce and no shared cursor here.
            model.index = min(max(Int(newValue.rounded()), 0), model.moveCount)
        }
    }

    private func reviewPage(_ frame: WatchBoardFrame) -> some View {
        List {
            if let best = frame.bestMove {
                LabeledContent("Best") {
                    Text(best).font(.system(.body, design: .monospaced)).bold()
                }
            }
            if let comment = frame.comment {
                Text(comment).font(.caption)
            }
            if frame.bestMove == nil, frame.comment == nil {
                Text("No analysis saved for this move").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Review")
    }
}
```

- [ ] **Step 7: Rewrite the root view**

Replace the whole of `ios/KataGo iOS/KataGo Anytime Watch/WatchRootView.swift` with:

```swift
import SwiftUI
import SwiftData
import KataGoGameStore

/// Where the watch can navigate. The library is the root; the live mirror and
/// any saved game are pushes from it.
enum WatchRoute: Hashable {
    case live
    case stored(String)
}

struct WatchRootView: View {
    @Environment(WatchLiveModel.self) private var model
    @Environment(WatchLibraryStore.self) private var library
    let container: ModelContainer

    @State private var path: [WatchRoute] = []
    /// Set once the user has left the auto-pushed board, so the library stays
    /// reachable for the rest of this session.
    @State private var latchConsumed = false

    var body: some View {
        NavigationStack(path: $path) {
            WatchLibraryPage(path: $path)
                .navigationDestination(for: WatchRoute.self) { route in
                    switch route {
                    case .live:
                        liveMirror
                    case .stored(let id):
                        if let row = library.row(id: id) {
                            WatchStoredGameView(row: row, container: container)
                        } else {
                            ContentUnavailableView("Game not found",
                                                   systemImage: "questionmark.folder",
                                                   description: Text("It may have been deleted."))
                        }
                    }
                }
        }
        .onAppear(perform: routeOnLaunch)
        .onChange(of: path) { _, newPath in
            // Leaving the auto-pushed board consumes the latch.
            if newPath.isEmpty { latchConsumed = true }
        }
    }

    private var liveMirror: some View {
        TabView {
            WatchBoardPage()
            WatchMovesPage()
        }
        .tabViewStyle(.verticalPage)
        .navigationTitle("Live")
        .overlay(alignment: .bottom) {
            if let message = model.rejectionMessage {
                Label { Text(message) } icon: { Image(systemName: "xmark.circle.fill") }
                    .font(.caption2).padding(4)
                    .background(.red.opacity(0.9), in: Capsule())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.rejectionMessage)
    }

    private func routeOnLaunch() {
        guard path.isEmpty else { return }
        let route = WatchNavigationPolicy.launchRoute(hasSnapshot: model.latest != nil,
                                                      latchConsumed: latchConsumed)
        if route == .liveGame { path = [.live] }
    }
}
```

- [ ] **Step 8: Wire the container into the app entry point**

Replace the whole of `ios/KataGo iOS/KataGo Anytime Watch/KataGoAnytimeWatchApp.swift` with:

```swift
import SwiftUI
import SwiftData
import KataGoGameStore

@main
struct KataGoAnytimeWatchApp: App {
    @State private var model = WatchLiveModel()
    @State private var library: WatchLibraryStore

    init() {
        // `shared` is a static let, so touching it here and below is one
        // container, opened once through the CloudKit-only ladder.
        _library = State(initialValue: WatchLibraryStore(
            container: SharedModelContainer.shared,
            storeMode: SharedModelContainer.watchStoreMode))
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView(container: SharedModelContainer.shared)
                .environment(model)
                .environment(library)
                .onAppear { model.activate() }
        }
    }
}
```

- [ ] **Step 9: Register the new files and build**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS" && \
ruby scripts_add_swift_files.rb "KataGo Anytime Watch" \
  "KataGo Anytime Watch/WatchLibraryPage.swift" \
  "KataGo Anytime Watch/WatchStoredGameView.swift" && \
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Watch" \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' \
  2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)|error:|warning:"
```

Expected: `** BUILD SUCCEEDED **`, zero warnings.

- [ ] **Step 10: Run the watch app in the simulator and confirm the library renders**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"

# 1. Find the watch simulator and boot it.
WATCH_UDID=$(xcrun simctl list devices available \
  | grep "Apple Watch Series 11 (46mm)" | head -1 \
  | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
echo "watch: $WATCH_UDID"
xcrun simctl boot "$WATCH_UDID" 2>/dev/null || true

# 2. Locate the freshly built app.
APP=$(find ~/Library/Developer/Xcode/DerivedData -type d \
  -path "*Debug-watchsimulator*" -name "KataGo Anytime Watch.app" \
  -exec stat -f "%m %N" {} \; 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
echo "app: $APP"

# 3. Install and launch.
xcrun simctl install "$WATCH_UDID" "$APP"
xcrun simctl launch --console-pty "$WATCH_UDID" chinchangyang.KataGo-iOS.tw.watchkitapp
```

Then screenshot it:

```bash
xcrun simctl io "$WATCH_UDID" screenshot /tmp/watch-library.png && open /tmp/watch-library.png
```

With no paired phone and no iCloud account, the expected screen is the library root showing either "Syncing from iCloud" (for the first 10 s) or "Sign in to iCloud on iPhone to see your games" — **not** a crash and **not** a blank screen. That is the whole point of Task 4's never-crash ladder. If the process dies at launch, read the console output for a `SharedModelContainer` line: it names which rung failed.

- [ ] **Step 11: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-ios-dev
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchNavigationPolicy.swift" \
        "ios/KataGo iOS/KataGo Anytime Watch/WatchLibraryPage.swift" \
        "ios/KataGo iOS/KataGo Anytime Watch/WatchStoredGameView.swift" \
        "ios/KataGo iOS/KataGo Anytime Watch/WatchRootView.swift" \
        "ios/KataGo iOS/KataGo Anytime Watch/KataGoAnytimeWatchApp.swift" \
        "ios/KataGo iOS/KataGo iOSTests/WatchNavigationPolicyTests.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(watch): browse the game library without the iPhone

The watch's only screen without a phone in range was a dead end reading
'No live session'. It now opens on its own library, with the phone's
current game pinned on top when there is one, and any saved game opens
into the same two-page board/review shape.

Launch still lands on the board whenever a snapshot exists, so the
glance case stays zero-tap; a one-shot latch keeps swiping back from
bouncing you straight into it again. A row matching the phone's current
game opens the live mirror, never a stale replay of it.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF"
```

---

### Task 10: Full verification sweep

**Files:**
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Run the SwiftPM package suite**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS/KataGoUICore" && swift test 2>&1 | tail -25
```

Expected: zero failures. This gate never runs under `xcodebuild test`, so a green Xcode run proves nothing about `SgfHeaderScanTests` or `SgfReplayTests`.

- [ ] **Step 2: Run the full iOS unit suite**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS" && \
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests" \
  2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|error:|✘"
```

Expected: `** TEST SUCCEEDED **`, zero failures.

- [ ] **Step 3: Build all five schemes**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
for spec in \
  "KataGo Anytime|platform=iOS Simulator,name=iPhone 17" \
  "KataGo Anytime Mac|platform=macOS" \
  "KataGo Anytime Vision|platform=visionOS Simulator,name=Apple Vision Pro" \
  "KataGo Anytime TV|platform=tvOS Simulator,name=Apple TV" \
  "KataGo Anytime Watch|platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)"
do
  scheme="${spec%%|*}"; dest="${spec##*|}"
  echo "=== $scheme ==="
  xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "$scheme" \
    -destination "$dest" 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)|error:|warning:"
done
```

Expected: five `** BUILD SUCCEEDED **`, no `error:`, no `warning:`.

- [ ] **Step 4: Register the iCloud capability on the watch App ID**

This must happen before the next `ios-dev` push, or Xcode Cloud's archive fails at export exactly as the first watch archive did.

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS" && \
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates \
  2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)|error:"
```

Expected: `** BUILD SUCCEEDED **`. If it fails with a provisioning error naming `chinchangyang.KataGo-iOS.tw.watchkitapp`, the App ID needs the iCloud capability added in the developer portal before retrying. Do not push until this step is green.

- [ ] **Step 5: Update CLAUDE.md**

Two exact edits.

**(a)** In the "Platform Support" section, replace this line:

```
- watchOS 26+ (companion live mirror + remote play, paired iPhone only)
```

with:

```
- watchOS 26+ (companion live mirror + remote play with a paired iPhone; standalone read-only game library when the phone is away)
```

**(b)** In the "Building for All Platforms" paragraph, replace this sentence:

```
There are **five app targets/schemes**: `KataGo Anytime` (iOS only), `KataGo Anytime Mac` (macOS, native AppKit), `KataGo Anytime Vision` (visionOS, volumetric RealityKit), `KataGo Anytime TV` (tvOS), and `KataGo Anytime Watch` (watchOS, companion live mirror + remote play).
```

with:

```
There are **five app targets/schemes**: `KataGo Anytime` (iOS only), `KataGo Anytime Mac` (macOS, native AppKit), `KataGo Anytime Vision` (visionOS, volumetric RealityKit), `KataGo Anytime TV` (tvOS), and `KataGo Anytime Watch` (watchOS, companion live mirror + remote play, plus a standalone read-only game library). The watch links `KataGoGameStore` **and** `GoRulesKit` (both bridge-free) and opens `SharedModelContainer.shared` through the CloudKit-only ladder it shares with tvOS — a plain non-App-Group store over the private CloudKit database that degrades to local-only, then in-memory, and never crashes. Board positions on the watch come from replaying `GameRecord.sgf` via `SgfHeaderScan` + `GoRulesKit.SgfReplay`, never from the per-move `blackStones`/`whiteStones` dictionaries, which only cover indices the phone visited.
```

If the exact sentence in (b) differs from what is in the file, match on the "five app targets/schemes" phrase and preserve whatever the surrounding text actually says while adding the same two facts.

- [ ] **Step 6: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-ios-dev
git add CLAUDE.md
git commit -m "docs: record the watch's standalone library

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01An63LYQDTk7aX8jjtmxVrF"
```

- [ ] **Step 7: Hand off the on-wrist QA checklist**

Neither CloudKit-on-watch nor WCSession has a CI story, so report these as the outstanding gate rather than claiming the feature is verified:

1. Fresh install, phone in range: launch lands on the live board, exactly as before.
2. Swipe back: the library appears, with the phone's game pinned on top and marked live.
3. Tap another game: it opens and the Crown scrubs its moves, with no phone involvement.
4. Scrub to a move the phone never analyzed: the winrate bar and score line disappear rather than reading zero.
5. Review page on an analyzed move shows the cached best move and comment; on an unanalyzed one, "No analysis saved for this move".
6. Turn the phone off (or put it out of range) and relaunch the watch app: the library still lists games and they still open.
7. Create a game on the Mac; confirm it appears on the watch without relaunching, once CloudKit syncs.
8. Sign out of iCloud on the watch: the library shows the signed-out state, not a crash and not an infinite spinner.
9. Confirm the live mirror's Crown scrubbing, tap-to-play, and rejection banners still behave as they did in v1.1.
10. Confirm the ScoreLeadWidget complication still updates.

---

## Notes for the implementer

**Do not** replace `SgfReplay` with the record's `blackStones`/`whiteStones` dictionaries, however tempting the shortcut looks. Those dictionaries only hold indices the phone actually visited: a game imported from an SGF has nothing but its final position, and scrubbing it would show blank boards.

**Do not** make the watch write anything. Every fetch in this plan is read-only by design, and that is the entire reason the watch cannot conflict with the phone through CloudKit.

**Do not** relax the permissive replay into strict rules enforcement. A recorded game may legitimately contain a position the configured ruleset would forbid; refusing a move mid-replay corrupts every later index.

If the differential test in Task 3 fails, the replay is wrong. Fix the replay.
