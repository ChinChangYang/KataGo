# KataGo Anytime Watch v0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A watchOS 26 companion app that live-mirrors an analysis session on the paired iPhone (board, top candidates, winrate/score lead), with Crown scrubbing over a local peek buffer, a staleness-badged cache, and a score-lead complication. Read-only: the watch never mutates the host.

**Architecture:** iPhone side, a `WatchSessionRelay` (iOS app target) polls `GameSession`'s `@Observable` state every 500 ms and pushes a ~2 KB JSON `WatchSnapshot` via `WCSession.updateApplicationContext` (latest-wins). Watch side, a new "KataGo Anytime Watch" app target links only the bridge-free `KataGoGameStore` product, renders via the existing `WidgetBoardView` (extended with candidate-dot/last-move annotations), and keeps a 50-entry peek ring buffer for Crown scrubbing. A watch WidgetKit extension shows the score lead, fed through the watch-local App Group.

**Tech Stack:** Swift 6 / SwiftUI / `@Observable`, WatchConnectivity, WidgetKit (watchOS), SwiftPM (`KataGoUICore` package), `xcodeproj` Ruby gem for pbxproj wiring, Swift Testing (`@Test` / `#expect`).

**Spec:** `docs/superpowers/specs/2026-07-04-watchos-companion-design.md` (approved).

## Global Constraints

- Platforms: iOS 26+, watchOS 26.0; Swift 6; team `6F82AZ9Z52`; App Group `group.chinchangyang.KataGo-iOS.tw`.
- The watch app and watch widget must **never** link `KataGoUICore` or `CKataGoBridge` (C++ engine) — only the `KataGoGameStore` product.
- **Never modify any SwiftData `@Model` schema** (CloudKit-frozen). No new fields on `GameRecord`/`Config`.
- New targets set `MARKETING_VERSION = 7.0`, `CURRENT_PROJECT_VERSION = 293` (must match host app at distribution).
- pbxproj edits go through the `xcodeproj` Ruby gem (`gem install --user-install xcodeproj` if missing); the project has NO file-system-synchronized groups. SwiftPM package sources under `KataGoUICore/Sources` are auto-discovered — never register those in pbxproj.
- `xcodebuild … | tail/grep` lies about exit codes — always check for `BUILD SUCCEEDED` / `TEST SUCCEEDED` in output, or `set -o pipefail`.
- Use `trash` instead of `rm` for any deletion. Commit after each task; do NOT push (CI push spacing).
- Working directory for all commands: `/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS` (quote all paths — they contain spaces).
- Existing behavior must not change: the iOS/macOS widget (`WidgetBoardView` call sites), all four existing app targets, and the test suite must keep building/passing.

---

### Task 1: watchOS platform flag + `WatchSnapshot` payload

**Files:**
- Modify: `KataGoUICore/Package.swift:48`
- Create: `KataGoUICore/Sources/KataGoGameStore/WatchSnapshot.swift`
- Test: `KataGo iOSTests/WatchSnapshotTests.swift`

**Interfaces:**
- Consumes: nothing (leaf type).
- Produces: `WatchSnapshot` (`Codable, Equatable, Sendable`) with `WatchSnapshot.Candidate`, `positionKey: String`, `encodedData() throws -> Data`, `static func decode(_ data: Data) throws -> WatchSnapshot`. Later tasks (builder, relay, watch app, peek buffer) all depend on these exact names.

- [ ] **Step 1: Add watchOS to the package platforms**

In `KataGoUICore/Package.swift` change line 48:

```swift
    platforms: [.iOS(.v26), .macOS(.v26), .visionOS(.v26), .tvOS(.v26), .watchOS(.v26)],
```

- [ ] **Step 2: Write the failing test**

Create `KataGo iOSTests/WatchSnapshotTests.swift`:

```swift
import Testing
import Foundation
@testable import KataGoGameStore

struct WatchSnapshotTests {
    static func makeSnapshot() -> WatchSnapshot {
        WatchSnapshot(
            boardWidth: 19, boardHeight: 19,
            blackStones: ["Q16", "D4"], whiteStones: ["D16"],
            toMove: "W", moveNumber: 3, analysisRunning: true,
            rootWinrateBlack: 0.62, rootScoreLeadBlack: 3.5,
            candidates: [
                .init(vertex: "Q3", winrate: 0.55, scoreLead: 2.1, visits: 312,
                      pv: ["Q3", "R4", "R3"]),
                .init(vertex: "C16", winrate: 0.52, scoreLead: 1.4, visits: 120, pv: []),
            ],
            hostTimestamp: Date(timeIntervalSince1970: 1_780_000_000))
    }

    @Test func roundTripPreservesAllFields() throws {
        let original = Self.makeSnapshot()
        let decoded = try WatchSnapshot.decode(original.encodedData())
        #expect(decoded == original)
    }

    @Test func positionKeyTracksStonesOnly() {
        var a = Self.makeSnapshot()
        var b = Self.makeSnapshot()
        b.rootWinrateBlack = 0.10          // analysis churn must NOT change the key
        b.candidates = []
        #expect(a.positionKey == b.positionKey)
        b.blackStones.append("K10")        // a new stone MUST change the key
        #expect(a.positionKey != b.positionKey)
        // Stone ORDER must not matter (GTP replay order can differ after undo/redo).
        a.blackStones = ["D4", "Q16"]
        #expect(a.positionKey == Self.makeSnapshot().positionKey)
    }

    @Test func fullBoardPayloadStaysSmall() throws {
        // Worst realistic case: 19x19 midgame, 10 candidates with 6-deep PVs.
        var s = Self.makeSnapshot()
        s.blackStones = (1...19).flatMap { r in ["A\(r)", "B\(r)"] }        // 38 stones
        s.whiteStones = (1...19).flatMap { r in ["C\(r)", "D\(r)"] }        // 38 stones
        s.candidates = (0..<10).map { i in
            .init(vertex: "Q\(i + 1)", winrate: 0.5, scoreLead: 0.1, visits: 1_000,
                  pv: ["Q16", "D4", "D16", "Q4", "K10", "C3"])
        }
        let bytes = try s.encodedData().count
        #expect(bytes < 16_384, "payload was \(bytes) bytes")
    }

    @Test func stalenessRule() {
        let t0 = Date(timeIntervalSince1970: 1_780_000_000)
        #expect(WatchSnapshot.isStale(receivedAt: nil, now: t0, threshold: 10))
        #expect(!WatchSnapshot.isStale(receivedAt: t0, now: t0 + 9, threshold: 10))
        #expect(WatchSnapshot.isStale(receivedAt: t0, now: t0 + 11, threshold: 10))
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
ruby scripts_add_swift_files.rb "KataGo iOSTests" "KataGo iOSTests/WatchSnapshotTests.swift"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo iOSTests/WatchSnapshotTests" 2>&1 | tail -20
```

Expected: build FAILS with "cannot find 'WatchSnapshot' in scope". (Note: `-only-testing` works at suite level, not per-test.)

- [ ] **Step 4: Implement `WatchSnapshot`**

Create `KataGoUICore/Sources/KataGoGameStore/WatchSnapshot.swift`:

```swift
import Foundation

/// Wire payload for the watch live mirror: one self-contained frame of the
/// host's current position + analysis, small enough (~2 KB typical, hard test
/// bound 16 KB) to ride `WCSession.updateApplicationContext` at ~2 Hz.
/// Lives in KataGoGameStore so both the iOS app (sender) and the watch app
/// (receiver) share one definition without touching the engine-linked
/// KataGoUICore product. Version the schema — application contexts persist
/// across app updates, so a watch build may decode a frame written by an
/// older/newer phone build.
public struct WatchSnapshot: Codable, Equatable, Sendable {
    public struct Candidate: Codable, Equatable, Sendable {
        public var vertex: String        // GTP vertex, e.g. "Q16" / "pass"
        public var winrate: Float        // side-to-move perspective (same as host's list UI)
        public var scoreLead: Float      // side-to-move perspective
        public var visits: Int
        public var pv: [String]          // principal variation, capped at 6 plies

        public init(vertex: String, winrate: Float, scoreLead: Float,
                    visits: Int, pv: [String]) {
            self.vertex = vertex; self.winrate = winrate; self.scoreLead = scoreLead
            self.visits = visits; self.pv = pv
        }
    }

    public var version: Int = 1
    public var boardWidth: Int
    public var boardHeight: Int
    public var blackStones: [String]     // GTP vertices
    public var whiteStones: [String]
    public var toMove: String            // "B" / "W"
    /// Stones placed so far (on-board + captured). A display/peek key, not an
    /// SGF index — passes don't advance it.
    public var moveNumber: Int
    public var analysisRunning: Bool
    public var rootWinrateBlack: Float   // Black perspective, 0…1
    public var rootScoreLeadBlack: Float // Black perspective, points
    public var candidates: [Candidate]   // strongest first, ≤ 10
    public var hostTimestamp: Date

    public init(boardWidth: Int, boardHeight: Int,
                blackStones: [String], whiteStones: [String],
                toMove: String, moveNumber: Int, analysisRunning: Bool,
                rootWinrateBlack: Float, rootScoreLeadBlack: Float,
                candidates: [Candidate], hostTimestamp: Date) {
        self.boardWidth = boardWidth; self.boardHeight = boardHeight
        self.blackStones = blackStones; self.whiteStones = whiteStones
        self.toMove = toMove; self.moveNumber = moveNumber
        self.analysisRunning = analysisRunning
        self.rootWinrateBlack = rootWinrateBlack
        self.rootScoreLeadBlack = rootScoreLeadBlack
        self.candidates = candidates; self.hostTimestamp = hostTimestamp
    }

    /// Identity of the board POSITION alone (not analysis churn), independent
    /// of stone-array order. The peek buffer appends a frame only when this
    /// changes.
    public var positionKey: String {
        "\(boardWidth)x\(boardHeight)|"
            + blackStones.sorted().joined(separator: ",")
            + "|" + whiteStones.sorted().joined(separator: ",")
    }

    public func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> WatchSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(WatchSnapshot.self, from: data)
    }

    /// Shared staleness rule so the app (10 s threshold) and the complication
    /// (600 s) agree on semantics: nil receipt time is always stale.
    public static func isStale(receivedAt: Date?, now: Date,
                               threshold: TimeInterval) -> Bool {
        guard let receivedAt else { return true }
        return now.timeIntervalSince(receivedAt) > threshold
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Same command as Step 3. Expected: `TEST SUCCEEDED`, 4 tests pass.

- [ ] **Step 6: Verify KataGoGameStore builds for watchOS**

```bash
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGoGameStore" \
  -destination 'generic/platform=watchOS Simulator' 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`. (The target has only `#if os(macOS)` / `#if os(tvOS)` gates, whose else-branches are watch-safe; if a watchOS-unavailable API surfaces, gate it `#if !os(watchOS)` and note it in the commit.)

- [ ] **Step 7: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Package.swift" \
        "ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchSnapshot.swift" \
        "ios/KataGo iOS/KataGo iOSTests/WatchSnapshotTests.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(watch): WatchSnapshot payload + watchOS platform in KataGoGameStore"
```

---

### Task 2: Board annotations — candidate dots + last-move ring

**Files:**
- Modify: `KataGoUICore/Sources/KataGoGameStore/WidgetBoardView.swift`
- Test: `KataGo iOSTests/WidgetBoardAnnotationTests.swift`

**Interfaces:**
- Consumes: `parseVertex(_:width:height:)` (already public in the same file).
- Produces: `WidgetBoardView.init(width:height:blackVertices:whiteVertices:candidateVertices:lastMoveVertex:)` where the two new params default to `[]`/`nil` (all existing widget call sites compile unchanged), and `WidgetBoardView.annotationPoints(candidates:lastMove:width:height:) -> (dots: [(x: Int, y: Int, rank: Int)], last: (x: Int, y: Int)?)` (nonisolated static, pure — the testable seam). Rank colors: 0 = green, 1 = yellow, 2 = orange.

- [ ] **Step 1: Write the failing test**

Create `KataGo iOSTests/WidgetBoardAnnotationTests.swift`:

```swift
import Testing
@testable import KataGoGameStore

struct WidgetBoardAnnotationTests {
    @Test func candidateDotsMapRankAndDropOffBoardAndPass() {
        let (dots, last) = WidgetBoardView.annotationPoints(
            candidates: ["Q16", "pass", "Z99", "D4"],   // pass + off-board dropped
            lastMove: "Q16", width: 19, height: 19)
        #expect(dots.count == 2)
        #expect(dots[0].x == 15 && dots[0].y == 3 && dots[0].rank == 0)  // Q16
        #expect(dots[1].x == 3 && dots[1].y == 15 && dots[1].rank == 1)  // D4 keeps ORIGINAL rank order after drops? No: rank is the index in the KEPT list
        #expect(last != nil && last! == (x: 15, y: 3))
    }

    @Test func nilLastMoveAndEmptyCandidatesYieldNothing() {
        let (dots, last) = WidgetBoardView.annotationPoints(
            candidates: [], lastMove: nil, width: 9, height: 9)
        #expect(dots.isEmpty)
        #expect(last == nil)
    }
}
```

Rank semantics (make the first test's comment true in code): rank = index in the surviving (renderable) list — the strongest *renderable* candidate is always green.

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
ruby scripts_add_swift_files.rb "KataGo iOSTests" "KataGo iOSTests/WidgetBoardAnnotationTests.swift"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo iOSTests/WidgetBoardAnnotationTests" 2>&1 | tail -20
```

Expected: FAIL — `annotationPoints` not found.

- [ ] **Step 3: Implement annotations in `WidgetBoardView`**

In `WidgetBoardView.swift`, add stored properties + widen the init (keep the existing init signature working via defaults) and the pure helper:

```swift
    let candidateDots: [(x: Int, y: Int, rank: Int)]
    let lastMovePoint: (x: Int, y: Int)?

    public init(width: Int, height: Int, blackVertices: [String], whiteVertices: [String],
                candidateVertices: [String] = [], lastMoveVertex: String? = nil) {
        let w = max(width, 1)
        let h = max(height, 1)
        self.width = w
        self.height = h
        self.black = blackVertices.compactMap { parseVertex($0, width: w, height: h) }
        self.white = whiteVertices.compactMap { parseVertex($0, width: w, height: h) }
        let annotations = WidgetBoardView.annotationPoints(
            candidates: candidateVertices, lastMove: lastMoveVertex, width: w, height: h)
        self.candidateDots = annotations.dots
        self.lastMovePoint = annotations.last
    }

    /// Pure geometry for the watch/widget overlays: candidate vertices → grid
    /// dots ranked by surviving order (0 strongest), last move → grid point.
    /// "pass" and off-board vertices are dropped (parseVertex returns nil).
    /// nonisolated for the same reason as `hoshiPoints`.
    nonisolated public static func annotationPoints(
        candidates: [String], lastMove: String?, width: Int, height: Int
    ) -> (dots: [(x: Int, y: Int, rank: Int)], last: (x: Int, y: Int)?) {
        let dots = candidates
            .compactMap { parseVertex($0, width: width, height: height) }
            .enumerated()
            .map { (x: $0.element.x, y: $0.element.y, rank: $0.offset) }
        let last = lastMove.flatMap { parseVertex($0, width: width, height: height) }
        return (dots, last)
    }
```

In `body`, after the black-stones `ForEach`, draw the overlays (rank colors green/yellow/orange, ring for last move):

```swift
                let rankColors: [Color] = [.green, .yellow, .orange]
                ForEach(Array(candidateDots.enumerated()), id: \.offset) { _, d in
                    Circle().fill(rankColors[min(d.rank, rankColors.count - 1)])
                        .frame(width: max(cell * 0.36, 3), height: max(cell * 0.36, 3))
                        .position(CGPoint(x: originX + CGFloat(d.x) * cell, y: originY + CGFloat(d.y) * cell))
                }
                if let lm = lastMovePoint {
                    Circle().stroke(Color.red, lineWidth: max(cell * 0.08, 1))
                        .frame(width: cell * 0.6, height: cell * 0.6)
                        .position(CGPoint(x: originX + CGFloat(lm.x) * cell, y: originY + CGFloat(lm.y) * cell))
                }
```

(`parseVertex` is a top-level function in this file, callable from the nonisolated static.)

- [ ] **Step 4: Run the tests to verify they pass**

Same command as Step 2. Expected: `TEST SUCCEEDED`. Also run the FULL widget-related suites to prove no regression:

```bash
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -5
```

Expected: `TEST SUCCEEDED` (the pre-existing flaky PlayerName thinking-time UI test is a known non-regression if it's the only failure).

- [ ] **Step 5: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WidgetBoardView.swift" \
        "ios/KataGo iOS/KataGo iOSTests/WidgetBoardAnnotationTests.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(watch): candidate-dot + last-move-ring overlays on WidgetBoardView"
```

---

### Task 3: `WatchPeekBuffer` — Crown-scrub history

**Files:**
- Create: `KataGoUICore/Sources/KataGoGameStore/WatchPeekBuffer.swift`
- Test: `KataGo iOSTests/WatchPeekBufferTests.swift`

**Interfaces:**
- Consumes: `WatchSnapshot` (`positionKey`, `moveNumber`, `blackStones`, `whiteStones`).
- Produces: `WatchPeekBuffer` with `ingest(_ snapshot: WatchSnapshot)`, `entries: [WatchSnapshot]`, `viewIndex: Int`, `current: WatchSnapshot?`, `isLive: Bool`, `movesBehindLive: Int`, `static func lastMoveVertex(previous: WatchSnapshot?, current: WatchSnapshot) -> String?`, `static let capacity = 50`. Task 5's watch UI uses exactly these.

- [ ] **Step 1: Write the failing test**

Create `KataGo iOSTests/WatchPeekBufferTests.swift`:

```swift
import Testing
import Foundation
@testable import KataGoGameStore

// @MainActor because WatchPeekBuffer is @MainActor (it feeds SwiftUI directly).
@MainActor
struct WatchPeekBufferTests {
    static func snap(black: [String], white: [String], move: Int) -> WatchSnapshot {
        WatchSnapshot(boardWidth: 9, boardHeight: 9, blackStones: black, whiteStones: white,
                      toMove: "B", moveNumber: move, analysisRunning: true,
                      rootWinrateBlack: 0.5, rootScoreLeadBlack: 0, candidates: [],
                      hostTimestamp: Date(timeIntervalSince1970: 1_780_000_000))
    }

    @Test func ingestAppendsOnlyDistinctPositionsAndTracksLive() {
        let buffer = WatchPeekBuffer()
        buffer.ingest(Self.snap(black: ["C3"], white: [], move: 1))
        buffer.ingest(Self.snap(black: ["C3"], white: [], move: 1))      // analysis churn, same position
        buffer.ingest(Self.snap(black: ["C3"], white: ["G7"], move: 2))
        #expect(buffer.entries.count == 2)
        #expect(buffer.isLive)
        #expect(buffer.viewIndex == 1)

        buffer.viewIndex = 0                                             // scrub back
        #expect(!buffer.isLive)
        #expect(buffer.movesBehindLive == 1)
        #expect(buffer.current?.moveNumber == 1)

        // A NEW live frame while scrubbed back must append without yanking the view.
        buffer.ingest(Self.snap(black: ["C3", "E5"], white: ["G7"], move: 3))
        #expect(buffer.entries.count == 3)
        #expect(buffer.viewIndex == 0)
        // Returning to live re-pins: subsequent ingests follow again.
        buffer.viewIndex = buffer.entries.count - 1
        buffer.ingest(Self.snap(black: ["C3", "E5", "E3"], white: ["G7"], move: 4))
        #expect(buffer.isLive && buffer.current?.moveNumber == 4)
    }

    @Test func capacityDropsOldest() {
        let buffer = WatchPeekBuffer()
        for i in 1...(WatchPeekBuffer.capacity + 10) {
            buffer.ingest(Self.snap(black: (1...i).map { "A\(($0 % 9) + 1)" + "\($0)" },
                                    white: [], move: i))
        }
        #expect(buffer.entries.count == WatchPeekBuffer.capacity)
        #expect(buffer.entries.first?.moveNumber == 11)
    }

    @Test func lastMoveVertexIsTheSingleAddedStone() {
        let a = Self.snap(black: ["C3"], white: [], move: 1)
        let b = Self.snap(black: ["C3"], white: ["G7"], move: 2)
        #expect(WatchPeekBuffer.lastMoveVertex(previous: a, current: b) == "G7")
        #expect(WatchPeekBuffer.lastMoveVertex(previous: nil, current: a) == nil)
        // Capture (stone count change ≠ +1) yields nil rather than a wrong ring.
        let c = Self.snap(black: [], white: ["G7", "C4"], move: 3)
        #expect(WatchPeekBuffer.lastMoveVertex(previous: b, current: c) == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
ruby scripts_add_swift_files.rb "KataGo iOSTests" "KataGo iOSTests/WatchPeekBufferTests.swift"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo iOSTests/WatchPeekBufferTests" 2>&1 | tail -20
```

Expected: FAIL — `WatchPeekBuffer` not found.

- [ ] **Step 3: Implement `WatchPeekBuffer`**

Create `KataGoUICore/Sources/KataGoGameStore/WatchPeekBuffer.swift`:

```swift
import Foundation
import Observation

/// Watch-local ring buffer of recent positions for Crown scrubbing ("local
/// peek"): zero host mutation, per the v0 spec. Frames are appended only when
/// the POSITION changes (`positionKey`), so analysis-churn frames just refresh
/// the live entry's numbers in place. When the user is pinned to live
/// (`viewIndex` at the end) new frames follow; while scrubbed back, new frames
/// append without yanking the view.
@Observable
@MainActor
public final class WatchPeekBuffer {
    public static let capacity = 50

    public private(set) var entries: [WatchSnapshot] = []
    public var viewIndex: Int = 0

    public init() {}

    public var current: WatchSnapshot? {
        entries.indices.contains(viewIndex) ? entries[viewIndex] : nil
    }

    public var isLive: Bool { viewIndex >= entries.count - 1 }

    public var movesBehindLive: Int { max(entries.count - 1 - viewIndex, 0) }

    public func ingest(_ snapshot: WatchSnapshot) {
        let wasLive = isLive
        if let last = entries.last, last.positionKey == snapshot.positionKey {
            entries[entries.count - 1] = snapshot   // same position: refresh analysis numbers
        } else {
            entries.append(snapshot)
            if entries.count > Self.capacity {
                entries.removeFirst(entries.count - Self.capacity)
                viewIndex = max(viewIndex - 1, 0)   // account for the dropped head
            }
        }
        if wasLive { viewIndex = entries.count - 1 }
    }

    /// The last move is the single stone present in `current` but not in
    /// `previous`. Captures/undos change counts by ≠ +1 → nil (no ring) rather
    /// than guessing wrong.
    nonisolated public static func lastMoveVertex(previous: WatchSnapshot?,
                                                  current: WatchSnapshot) -> String? {
        guard let previous else { return nil }
        let prev = Set(previous.blackStones + previous.whiteStones)
        let cur = Set(current.blackStones + current.whiteStones)
        let added = cur.subtracting(prev)
        guard added.count == 1, cur.count == prev.count + 1 else { return nil }
        return added.first
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Same command as Step 2. Expected: `TEST SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchPeekBuffer.swift" \
        "ios/KataGo iOS/KataGo iOSTests/WatchPeekBufferTests.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(watch): WatchPeekBuffer for Crown local-peek scrubbing"
```

---

### Task 4: Snapshot builder + `WatchSessionRelay` on the iPhone

**Files:**
- Create: `KataGoUICore/Sources/KataGoUICore/Session/WatchSnapshotBuilder.swift` (package — auto-discovered, no pbxproj step)
- Create: `KataGo iOS/Watch/WatchSessionRelay.swift` (iOS app target — needs pbxproj registration)
- Modify: `KataGo iOS/App/ContentView.swift` (wire the relay; see Step 5)
- Test: `KataGo iOSTests/WatchSnapshotBuilderTests.swift`

**Interfaces:**
- Consumes: `GameSession` observables — `stones: Stones` (`blackPoints/whitePoints: [BoardPoint]`, `blackStonesCaptured/whiteStonesCaptured: Int`), `board: BoardSize` (`width/height: CGFloat`), `player: Turn` (`nextColorForPlayCommand: PlayerColor`), `analysis: Analysis` (`candidateMoves(width:height:limit:)`, `info[point]?.pv`), `gobanState.analysisStatus`, `rootWinrate.black`, `rootScore.black`; `Stones.toString(_:width:height:)` for vertex strings; `WatchSnapshot` from Task 1.
- Produces: `WatchSnapshotBuilder.makeSnapshot(session:now:) -> WatchSnapshot` (`@MainActor` static) and `WatchSessionRelay` (`@MainActor` final class, `func start(session: GameSession)`).

- [ ] **Step 1: Write the failing test**

Create `KataGo iOSTests/WatchSnapshotBuilderTests.swift`:

```swift
import Testing
import Foundation
@testable import KataGoUICore
import KataGoGameStore

@MainActor
struct WatchSnapshotBuilderTests {
    @Test func buildsSnapshotFromSessionState() {
        let session = GameSession()
        session.board.width = 19
        session.board.height = 19
        session.stones.blackPoints = [BoardPoint(x: 15, y: 3)]     // Q16 (y is 0-based row from top per Coordinate)
        session.stones.whitePoints = []
        session.player.nextColorForPlayCommand = .white
        session.gobanState.analysisStatus = .run
        session.rootWinrate.black = 0.61
        session.rootScore.black = 2.5
        session.analysis.nextColorForAnalysis = .white
        session.analysis.info = [
            BoardPoint(x: 2, y: 3): AnalysisInfo(visits: 500, winrate: 0.48,
                                                 scoreLead: -1.2, utilityLcb: 0.1,
                                                 pv: ["C16", "D4", "Q3", "R4", "C3", "D3", "E3", "F3"]),
            BoardPoint(x: 3, y: 15): AnalysisInfo(visits: 100, winrate: 0.44,
                                                  scoreLead: -2.0, utilityLcb: 0.0),
        ]

        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let snapshot = WatchSnapshotBuilder.makeSnapshot(session: session, now: now)

        #expect(snapshot.boardWidth == 19 && snapshot.boardHeight == 19)
        #expect(snapshot.blackStones == ["Q16"])
        #expect(snapshot.whiteStones.isEmpty)
        #expect(snapshot.toMove == "W")
        #expect(snapshot.moveNumber == 1)
        #expect(snapshot.analysisRunning)
        #expect(snapshot.rootWinrateBlack == 0.61)
        #expect(snapshot.rootScoreLeadBlack == 2.5)
        #expect(snapshot.candidates.count == 2)
        #expect(snapshot.candidates[0].visits == 500)      // strongest first
        #expect(snapshot.candidates[0].pv.count == 6)      // PV capped at 6
        #expect(snapshot.hostTimestamp == now)
    }

    @Test func pausedAnalysisAndPassesAreRepresented() {
        let session = GameSession()
        session.board.width = 9; session.board.height = 9
        session.gobanState.analysisStatus = .pause
        session.stones.blackStonesCaptured = 2
        let snapshot = WatchSnapshotBuilder.makeSnapshot(session: session, now: .now)
        #expect(!snapshot.analysisRunning)
        #expect(snapshot.candidates.isEmpty)
        #expect(snapshot.moveNumber == 2)                  // captured stones still count as played
    }
}
```

(If `BoardPoint(x:y:)`'s memberwise init isn't public, use `BoardPoint(move: "Q16", width: 19, height: 19)!` instead — that initializer is public in `KataGoModel.swift:124`. Adjust the expected `blackStones` accordingly; the assertion stays `== ["Q16"]`.)

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
ruby scripts_add_swift_files.rb "KataGo iOSTests" "KataGo iOSTests/WatchSnapshotBuilderTests.swift"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo iOSTests/WatchSnapshotBuilderTests" 2>&1 | tail -20
```

Expected: FAIL — `WatchSnapshotBuilder` not found.

- [ ] **Step 3: Implement the builder**

Create `KataGoUICore/Sources/KataGoUICore/Session/WatchSnapshotBuilder.swift`:

```swift
import Foundation
import KataGoGameStore

/// Projects the live GameSession observables into one WatchSnapshot frame.
/// Pure read — never mutates session state. Candidate winrate/scoreLead stay
/// in side-to-move perspective (matching the host's candidate list UI); root
/// values are Black-perspective straight from rootWinrate/rootScore.
public enum WatchSnapshotBuilder {
    @MainActor
    public static func makeSnapshot(session: GameSession, now: Date = .now) -> WatchSnapshot {
        let width = Int(session.board.width)
        let height = Int(session.board.height)
        let running = session.gobanState.analysisStatus == .run

        let candidates: [WatchSnapshot.Candidate]
        if running {
            candidates = session.analysis
                .candidateMoves(width: width, height: height, limit: 10)
                .map { c in
                    WatchSnapshot.Candidate(
                        vertex: c.vertex, winrate: c.winrate, scoreLead: c.scoreLead,
                        visits: c.visits,
                        pv: Array((session.analysis.info[c.point]?.pv ?? []).prefix(6)))
                }
        } else {
            candidates = []
        }

        func vertices(_ points: [BoardPoint]) -> [String] {
            (Stones.toString(points, width: width, height: height) ?? "")
                .split(separator: " ").map(String.init)
        }

        let stones = session.stones
        return WatchSnapshot(
            boardWidth: width, boardHeight: height,
            blackStones: vertices(stones.blackPoints),
            whiteStones: vertices(stones.whitePoints),
            toMove: session.player.nextColorForPlayCommand == .black ? "B" : "W",
            moveNumber: stones.blackPoints.count + stones.whitePoints.count
                + stones.blackStonesCaptured + stones.whiteStonesCaptured,
            analysisRunning: running,
            rootWinrateBlack: session.rootWinrate.black,
            rootScoreLeadBlack: session.rootScore.black,
            candidates: candidates,
            hostTimestamp: now)
    }
}
```

(Verify `Stones.toString(_:width:height:)` is `static`; it is used as `Stones.refillString` at `KataGoModel.swift:118`. If it's an instance method, use `Stones.refillString(points, width: width, height: height)` — same file, public static.)

- [ ] **Step 4: Run the test to verify it passes**

Same command as Step 2. Expected: `TEST SUCCEEDED`.

- [ ] **Step 5: Implement the relay and wire it into ContentView**

Create `KataGo iOS/Watch/WatchSessionRelay.swift` (create the `Watch/` folder):

```swift
import Foundation
import WatchConnectivity
import KataGoUICore
import KataGoGameStore

/// iPhone→watch push: every 500 ms build a WatchSnapshot from the live
/// GameSession and, when it differs from the last sent frame, push it via
/// updateApplicationContext (latest-wins, no reachability needed — WCSession
/// delivers the newest context when the watch wakes). Equality gating means
/// an idle board sends nothing after the first frame.
@MainActor
final class WatchSessionRelay: NSObject, WCSessionDelegate {
    static let contextKey = "watchSnapshot"

    private var lastSent: WatchSnapshot?
    private var loopTask: Task<Void, Never>?

    func start(session gameSession: GameSession) {
        guard WCSession.isSupported() else { return }   // iPad: no-op
        let wcSession = WCSession.default
        wcSession.delegate = self
        wcSession.activate()

        loopTask?.cancel()
        loopTask = Task { [weak self, weak gameSession] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, let gameSession else { return }
                self.pushIfChanged(from: gameSession)
            }
        }
    }

    private func pushIfChanged(from gameSession: GameSession) {
        let wcSession = WCSession.default
        guard wcSession.activationState == .activated,
              wcSession.isPaired, wcSession.isWatchAppInstalled else { return }
        let snapshot = WatchSnapshotBuilder.makeSnapshot(session: gameSession)
        // Equality must ignore the timestamp, or every tick "changes".
        if var previous = lastSent {
            previous.hostTimestamp = snapshot.hostTimestamp
            if previous == snapshot { return }
        }
        guard let data = try? snapshot.encodedData() else { return }
        do {
            try wcSession.updateApplicationContext([Self.contextKey: data])
            lastSent = snapshot
        } catch {
            // Transient WCSession errors (e.g. not activated yet): drop the
            // frame; the next changed tick retries. Latest-wins semantics make
            // skipped frames harmless.
        }
    }

    // MARK: WCSessionDelegate (iOS side requires all three)
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: (any Error)?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()   // re-activate after watch switch, per Apple docs
    }
}
```

Wire into `KataGo iOS/App/ContentView.swift`: add the state property below `@State var aiMove` (line ~29):

```swift
    @State private var watchRelay = WatchSessionRelay()
```

and start it inside the existing `.task` (line ~64), immediately before `await session.run(...)`:

```swift
                watchRelay.start(session: session)
```

Register the new app-target file:

```bash
ruby scripts_add_swift_files.rb "KataGo Anytime" "KataGo iOS/Watch/WatchSessionRelay.swift"
```

- [ ] **Step 6: Build the iOS app to verify the wiring compiles**

```bash
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`. Also rebuild macOS + visionOS to prove no cross-platform leak (the relay file is iOS-target-only, but `WatchSnapshotBuilder` is in the shared package):

```bash
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS' 2>&1 | tail -3
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' 2>&1 | tail -3
```

Expected: `BUILD SUCCEEDED` twice.

- [ ] **Step 7: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Session/WatchSnapshotBuilder.swift" \
        "ios/KataGo iOS/KataGo iOS/Watch/WatchSessionRelay.swift" \
        "ios/KataGo iOS/KataGo iOS/App/ContentView.swift" \
        "ios/KataGo iOS/KataGo iOSTests/WatchSnapshotBuilderTests.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(watch): WatchSnapshotBuilder + WCSession relay in the iOS app"
```

---

### Task 5: Watch app target + UI

**Files:**
- Create: `add_watch_app_target.rb` (in `ios/KataGo iOS/`)
- Create: `KataGo Anytime Watch/KataGoAnytimeWatchApp.swift`
- Create: `KataGo Anytime Watch/WatchLiveModel.swift`
- Create: `KataGo Anytime Watch/WatchRootView.swift`
- Create: `KataGo Anytime Watch/WatchBoardPage.swift`
- Create: `KataGo Anytime Watch/WatchMovesPage.swift`
- Create: `KataGo Anytime Watch/KataGo Anytime Watch.entitlements`

**Interfaces:**
- Consumes: `WatchSnapshot` (decode), `WatchPeekBuffer` (ingest/viewIndex/isLive/movesBehindLive/lastMoveVertex), `WidgetBoardView(width:height:blackVertices:whiteVertices:candidateVertices:lastMoveVertex:)` — all from `KataGoGameStore`.
- Produces: the `KataGo Anytime Watch` target (bundle id `chinchangyang.KataGo-iOS.tw.watchkitapp`), embedded in the iOS app; `WatchLiveModel` with `latest: WatchSnapshot?`, `peek: WatchPeekBuffer`, `isStale: Bool`, `receivedAt: Date?` (Task 6's complication write hook lands in `WatchLiveModel.ingest`).

- [ ] **Step 1: Write the target-creation script**

Create `add_watch_app_target.rb` (modeled on `add_widget_extension_target.rb`):

```ruby
#!/usr/bin/env ruby
# Adds the "KataGo Anytime Watch" watchOS app target (modern single-target
# watch app), links the bridge-free KataGoGameStore product, embeds it into
# the iOS app's Watch directory, and writes a shared scheme. Idempotent.
require 'xcodeproj'

PROJECT = File.join(__dir__, 'KataGo Anytime.xcodeproj')
WATCH   = 'KataGo Anytime Watch'
TEAM    = '6F82AZ9Z52'
IOS_APP = 'KataGo Anytime'

project = Xcodeproj::Project.open(PROJECT)
if project.targets.any? { |t| t.name == WATCH }
  puts "Target '#{WATCH}' already exists — nothing to do."
  exit 0
end

ios_app = project.targets.find { |t| t.name == IOS_APP } or abort("missing #{IOS_APP}")
pkg = project.root_object.package_references.find do |r|
  r.respond_to?(:relative_path) && r.relative_path == 'KataGoUICore'
end or abort('missing KataGoUICore package reference')

# 1. Watch app target. new_target(:application, …, :watchos) sets SDKROOT and
#    the plain com.apple.product-type.application; WKApplication=YES in the
#    generated Info.plist is what makes it a single-target watch app.
watch = project.new_target(:application, WATCH, :watchos, '26.0')

watch.build_configurations.each do |c|
  s = c.build_settings
  s['PRODUCT_NAME']                                   = WATCH
  s['PRODUCT_BUNDLE_IDENTIFIER']                      = 'chinchangyang.KataGo-iOS.tw.watchkitapp'
  s['GENERATE_INFOPLIST_FILE']                        = 'YES'
  s['INFOPLIST_KEY_WKApplication']                    = 'YES'
  s['INFOPLIST_KEY_WKCompanionAppBundleIdentifier']   = 'chinchangyang.KataGo-iOS.tw'
  s['INFOPLIST_KEY_CFBundleDisplayName']              = 'KataGo Anytime'
  s['INFOPLIST_KEY_UISupportedInterfaceOrientations'] = 'UIInterfaceOrientationPortrait'
  s['CODE_SIGN_ENTITLEMENTS']                         = "#{WATCH}/#{WATCH}.entitlements"
  s['CODE_SIGN_STYLE']                                = 'Automatic'
  s['DEVELOPMENT_TEAM']                               = TEAM
  s['SDKROOT']                                        = 'watchos'
  s['TARGETED_DEVICE_FAMILY']                         = '4'
  s['WATCHOS_DEPLOYMENT_TARGET']                      = '26.0'
  s['SWIFT_VERSION']                                  = '6.0'
  s['SKIP_INSTALL']                                   = 'YES'
  s['LD_RUNPATH_SEARCH_PATHS']                        = ['$(inherited)', '@executable_path/Frameworks']
  s['MARKETING_VERSION']                              = '7.0'
  s['CURRENT_PROJECT_VERSION']                        = '293'
end

# 2. Link KataGoGameStore (bridge-free — the watch must NEVER link KataGoUICore).
dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
dep.package = pkg
dep.product_name = 'KataGoGameStore'
watch.package_product_dependencies << dep
bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
bf.product_ref = dep
watch.frameworks_build_phase.files << bf

# 3. Register sources + entitlements.
group = project.main_group.find_subpath(WATCH, true)
group.set_source_tree('SOURCE_ROOT')
%w[
  KataGoAnytimeWatchApp.swift WatchLiveModel.swift WatchRootView.swift
  WatchBoardPage.swift WatchMovesPage.swift
].each do |f|
  ref = group.new_reference("#{WATCH}/#{f}")
  watch.source_build_phase.add_file_reference(ref)
end
group.new_reference("#{WATCH}/#{WATCH}.entitlements")

# 4. Embed into the iOS app: modern watch apps copy into
#    $(CONTENTS_FOLDER_PATH)/Watch via a products-directory copy phase.
ios_app.add_dependency(watch)
phase = ios_app.copy_files_build_phases.find { |p| p.name == 'Embed Watch Content' }
unless phase
  phase = ios_app.new_copy_files_build_phase('Embed Watch Content')
  phase.symbol_dst_subfolder_spec = :products_directory
  phase.dst_path = '$(CONTENTS_FOLDER_PATH)/Watch'
end
ebf = phase.add_file_reference(watch.product_reference)
ebf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

# 5. Shared scheme so xcodebuild -scheme works headlessly.
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(watch)
scheme.set_launch_target(watch)
scheme.save_as(PROJECT, WATCH, true)

project.save
puts "Added #{WATCH}, linked KataGoGameStore, embedded into #{IOS_APP}, shared scheme written."
```

- [ ] **Step 2: Write the entitlements + watch app sources**

`KataGo Anytime Watch/KataGo Anytime Watch.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.chinchangyang.KataGo-iOS.tw</string>
	</array>
</dict>
</plist>
```

`KataGo Anytime Watch/KataGoAnytimeWatchApp.swift`:

```swift
import SwiftUI

@main
struct KataGoAnytimeWatchApp: App {
    @State private var model = WatchLiveModel()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(model)
                .onAppear { model.activate() }
        }
    }
}
```

`KataGo Anytime Watch/WatchLiveModel.swift`:

```swift
import Foundation
import Observation
import WatchConnectivity
import WatchKit
import WidgetKit
import KataGoGameStore

/// Watch-side receiver: decodes WatchSnapshot frames from the application
/// context, feeds the peek buffer, tracks staleness, and mirrors the score
/// lead into the App Group for the complication. WCSession persists the most
/// recent application context across launches (`receivedApplicationContext`),
/// which IS the spec's "cache the last snapshot" — no extra storage needed.
@Observable
@MainActor
final class WatchLiveModel: NSObject, WCSessionDelegate {
    static let staleAfter: TimeInterval = 10
    static let appGroupID = "group.chinchangyang.KataGo-iOS.tw"
    static let complicationKind = "ScoreLeadWidget"

    private(set) var latest: WatchSnapshot?
    private(set) var receivedAt: Date?
    let peek = WatchPeekBuffer()
    /// Ticks every 5 s so `isStale` re-evaluates without new frames.
    private(set) var now = Date()
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var lastComplicationReload: Date?
    @ObservationIgnored private var lastComplicationScore: Float?

    var isStale: Bool {
        WatchSnapshot.isStale(receivedAt: receivedAt, now: now, threshold: Self.staleAfter)
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        // Replay the persisted last context so a cold launch shows the cached
        // position (stale-badged) instead of a blank screen.
        if let data = session.receivedApplicationContext[WatchSessionRelayKeys.snapshot] as? Data {
            ingest(data, receivedAt: nil)
        }
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.now = Date()
            }
        }
    }

    func ingest(_ data: Data, receivedAt: Date?) {
        guard let snapshot = try? WatchSnapshot.decode(data) else { return }
        // Spec: haptic on live-move arrival — only for a real position change
        // on a live (not cold-replay) frame while the user is pinned to live.
        let positionChanged = latest.map { $0.positionKey != snapshot.positionKey } ?? false
        if positionChanged, receivedAt != nil, peek.isLive {
            WKInterfaceDevice.current().play(.click)
        }
        latest = snapshot
        self.receivedAt = receivedAt
        now = Date()
        peek.ingest(snapshot)
        mirrorComplication(snapshot)
    }

    /// Budget-friendly: reload the complication only on a ≥0.5-point change
    /// and at most every 30 s.
    private func mirrorComplication(_ snapshot: WatchSnapshot) {
        let defaults = UserDefaults(suiteName: Self.appGroupID)
        defaults?.set(Double(snapshot.rootScoreLeadBlack), forKey: "watchScoreLeadBlack")
        defaults?.set(snapshot.hostTimestamp, forKey: "watchScoreUpdatedAt")
        let scoreDelta = abs((lastComplicationScore ?? .infinity) - snapshot.rootScoreLeadBlack)
        let elapsed = now.timeIntervalSince(lastComplicationReload ?? .distantPast)
        guard scoreDelta >= 0.5, elapsed >= 30 else { return }
        lastComplicationScore = snapshot.rootScoreLeadBlack
        lastComplicationReload = now
        WidgetCenter.shared.reloadTimelines(ofKind: Self.complicationKind)
    }

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: (any Error)?) {}

    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[WatchSessionRelayKeys.snapshot] as? Data else { return }
        Task { @MainActor in self.ingest(data, receivedAt: Date()) }
    }
}

/// Wire keys shared by convention with the iPhone's WatchSessionRelay
/// (the two targets share no compiled code beyond KataGoGameStore, so keep
/// this string in sync with WatchSessionRelay.contextKey).
enum WatchSessionRelayKeys {
    static let snapshot = "watchSnapshot"
}
```

`KataGo Anytime Watch/WatchRootView.swift`:

```swift
import SwiftUI
import KataGoGameStore

struct WatchRootView: View {
    @Environment(WatchLiveModel.self) private var model

    var body: some View {
        if model.peek.entries.isEmpty {
            ContentUnavailableView("No live session",
                                   systemImage: "circle.grid.cross",
                                   description: Text("Start analysis on your iPhone."))
        } else {
            TabView {
                WatchBoardPage()
                WatchMovesPage()
            }
            .tabViewStyle(.verticalPage)
        }
    }
}
```

`KataGo Anytime Watch/WatchBoardPage.swift`:

```swift
import SwiftUI
import KataGoGameStore

struct WatchBoardPage: View {
    @Environment(WatchLiveModel.self) private var model
    @State private var crownIndex: Double = 0

    var body: some View {
        let peek = model.peek
        let shown = peek.current
        let previous = peek.viewIndex > 0 ? peek.entries[peek.viewIndex - 1] : nil

        VStack(spacing: 2) {
            if let s = shown {
                WidgetBoardView(
                    width: s.boardWidth, height: s.boardHeight,
                    blackVertices: s.blackStones, whiteVertices: s.whiteStones,
                    candidateVertices: peek.isLive ? s.candidates.prefix(3).map(\.vertex) : [],
                    lastMoveVertex: WatchPeekBuffer.lastMoveVertex(previous: previous, current: s))
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

                Text(scoreText(s.rootScoreLeadBlack))
                    .font(.system(.headline, design: .monospaced))
            }
        }
        .overlay(alignment: .top) {
            if model.isStale, let at = model.receivedAt ?? shown.map(\.hostTimestamp) {
                // Date interpolation with a style only exists on Text, so
                // compose the Label from Text parts (a plain string can't do it).
                Label { Text("Stale ") + Text(at, style: .relative) }
                    icon: { Image(systemName: "wifi.slash") }
                    .font(.caption2).padding(3)
                    .background(.red.opacity(0.85), in: Capsule())
            } else if !peek.isLive {
                Text("\(peek.movesBehindLive) behind live")
                    .font(.caption2).padding(3)
                    .background(.orange.opacity(0.85), in: Capsule())
                    .onTapGesture { peek.viewIndex = peek.entries.count - 1 }
            }
        }
        .focusable()
        .digitalCrownRotation($crownIndex,
                              from: 0, through: Double(max(peek.entries.count - 1, 0)),
                              by: 1, sensitivity: .medium,
                              isContinuous: false, isHapticFeedbackEnabled: true)
        .onChange(of: crownIndex) { _, newValue in
            peek.viewIndex = Int(newValue.rounded())
        }
        .onChange(of: peek.viewIndex) { _, newValue in
            // Keep the crown in sync when ingest re-pins the live index.
            if Int(crownIndex.rounded()) != newValue { crownIndex = Double(newValue) }
        }
    }

    private func scoreText(_ scoreLeadBlack: Float) -> String {
        scoreLeadBlack >= 0 ? String(format: "B+%.1f", scoreLeadBlack)
                            : String(format: "W+%.1f", -scoreLeadBlack)
    }
}
```

`KataGo Anytime Watch/WatchMovesPage.swift`:

```swift
import SwiftUI
import KataGoGameStore

struct WatchMovesPage: View {
    @Environment(WatchLiveModel.self) private var model
    private let rankColors: [Color] = [.green, .yellow, .orange]

    var body: some View {
        let live = model.peek.entries.last
        List {
            if let live, live.analysisRunning, !live.candidates.isEmpty {
                ForEach(Array(live.candidates.prefix(3).enumerated()), id: \.element.vertex) { rank, c in
                    HStack {
                        Circle().fill(rankColors[min(rank, rankColors.count - 1)])
                            .frame(width: 8, height: 8)
                        Text(c.vertex).font(.system(.body, design: .monospaced)).bold()
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text(String(format: "%.0f%%", c.winrate * 100)).font(.caption)
                            Text(String(format: "%+.1f", c.scoreLead)).font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("Analysis off").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Top Moves")
    }
}
```

- [ ] **Step 3: Run the target script and build the watch app**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
ruby add_watch_app_target.rb
xcrun simctl list devices | grep -i "apple watch" | head -3   # pick an available watch simulator name
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Watch" \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`. (Substitute the simulator name from `simctl list` if Series 11 isn't present. If `.verticalPage` or another API differs under the watchOS 26 SDK, fix forward at the call site — do not downgrade the deployment target.)

- [ ] **Step 4: Verify the iOS app still builds and embeds the watch app**

```bash
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`, and the build log contains a copy step into `…/KataGo Anytime.app/Watch/`. Also confirm visionOS still builds (the watch embed phase must not break it):

```bash
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' 2>&1 | tail -3
```

Expected: `BUILD SUCCEEDED`. If the visionOS build chokes on the watch embed, condition the copy phase: in Xcode set the Embed Watch Content phase's platform filter to iOS only (`platform_filters = ['ios']` on the build phase in the Ruby script) and re-run.

- [ ] **Step 5: Commit**

```bash
git add "ios/KataGo iOS/add_watch_app_target.rb" "ios/KataGo iOS/KataGo Anytime Watch/" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj"
git commit -m "feat(watch): KataGo Anytime Watch app target — live mirror UI with Crown peek"
```

---

### Task 6: Score-lead complication (watch widget extension)

**Files:**
- Create: `add_watch_widget_target.rb` (in `ios/KataGo iOS/`)
- Create: `KataGoAnytimeWatchWidget/KataGoAnytimeWatchWidgetBundle.swift`
- Create: `KataGoAnytimeWatchWidget/ScoreLeadWidget.swift`
- Create: `KataGoAnytimeWatchWidget/Info.plist`
- Create: `KataGoAnytimeWatchWidget/KataGoAnytimeWatchWidget.entitlements`

**Interfaces:**
- Consumes: App Group defaults keys `watchScoreLeadBlack` (Double) + `watchScoreUpdatedAt` (Date) written by `WatchLiveModel.mirrorComplication` (Task 5); widget kind string `"ScoreLeadWidget"` must equal `WatchLiveModel.complicationKind`.
- Produces: the `KataGoAnytimeWatchWidget` extension target embedded in the watch app.

- [ ] **Step 1: Write the extension sources**

`KataGoAnytimeWatchWidget/Info.plist` (same shape as the iOS widget's):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>$(DEVELOPMENT_LANGUAGE)</string>
	<key>CFBundleDisplayName</key>
	<string>KataGo Score</string>
	<key>CFBundleExecutable</key>
	<string>$(EXECUTABLE_NAME)</string>
	<key>CFBundleIdentifier</key>
	<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>CFBundleName</key>
	<string>$(PRODUCT_NAME)</string>
	<key>CFBundlePackageType</key>
	<string>$(PRODUCT_BUNDLE_PACKAGE_TYPE)</string>
	<key>CFBundleShortVersionString</key>
	<string>$(MARKETING_VERSION)</string>
	<key>CFBundleVersion</key>
	<string>$(CURRENT_PROJECT_VERSION)</string>
	<key>NSExtension</key>
	<dict>
		<key>NSExtensionPointIdentifier</key>
		<string>com.apple.widgetkit-extension</string>
	</dict>
</dict>
</plist>
```

`KataGoAnytimeWatchWidget/KataGoAnytimeWatchWidget.entitlements`: same App Group-only entitlements as the watch app (copy the file from Task 5 Step 2, identical content).

`KataGoAnytimeWatchWidget/KataGoAnytimeWatchWidgetBundle.swift`:

```swift
import WidgetKit
import SwiftUI

@main
struct KataGoAnytimeWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        ScoreLeadWidget()
    }
}
```

`KataGoAnytimeWatchWidget/ScoreLeadWidget.swift`:

```swift
import WidgetKit
import SwiftUI

/// Smart Stack / complication tile: the live analysis score lead, colored by
/// leader, marked stale after 10 minutes without an update. Data arrives via
/// the watch-local App Group, written by WatchLiveModel; timeline reloads are
/// pushed by the watch app (WidgetCenter), so the provider itself is trivial.
struct ScoreLeadEntry: TimelineEntry {
    let date: Date
    let scoreLeadBlack: Double?
    let updatedAt: Date?
}

struct ScoreLeadProvider: TimelineProvider {
    static let appGroupID = "group.chinchangyang.KataGo-iOS.tw"

    func read(at date: Date) -> ScoreLeadEntry {
        let defaults = UserDefaults(suiteName: Self.appGroupID)
        let score = defaults?.object(forKey: "watchScoreLeadBlack") as? Double
        let updated = defaults?.object(forKey: "watchScoreUpdatedAt") as? Date
        return ScoreLeadEntry(date: date, scoreLeadBlack: score, updatedAt: updated)
    }

    func placeholder(in context: Context) -> ScoreLeadEntry {
        ScoreLeadEntry(date: .now, scoreLeadBlack: 4.5, updatedAt: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (ScoreLeadEntry) -> Void) {
        completion(read(at: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ScoreLeadEntry>) -> Void) {
        completion(Timeline(entries: [read(at: .now)], policy: .never))
    }
}

struct ScoreLeadWidgetView: View {
    let entry: ScoreLeadEntry

    private var isStale: Bool {
        guard let updatedAt = entry.updatedAt else { return true }
        return entry.date.timeIntervalSince(updatedAt) > 600
    }

    var body: some View {
        if let score = entry.scoreLeadBlack {
            let text = score >= 0 ? String(format: "B+%.1f", score)
                                  : String(format: "W+%.1f", -score)
            Text(text)
                .font(.system(.headline, design: .monospaced))
                .foregroundStyle(isStale ? .secondary : (score >= 0 ? .primary : .secondary))
                .containerBackground(.fill.tertiary, for: .widget)
        } else {
            Text("—").containerBackground(.fill.tertiary, for: .widget)
        }
    }
}

struct ScoreLeadWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ScoreLeadWidget", provider: ScoreLeadProvider()) {
            ScoreLeadWidgetView(entry: $0)
        }
        .configurationDisplayName("Score Lead")
        .description("Live score lead while analysis runs on your iPhone.")
        .supportedFamilies([.accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}
```

- [ ] **Step 2: Write the target script**

Create `add_watch_widget_target.rb`:

```ruby
#!/usr/bin/env ruby
# Adds the "KataGoAnytimeWatchWidget" WidgetKit extension (the score-lead
# complication) and embeds it into the watch app's PlugIns. Dependency-free:
# it reads only App Group UserDefaults, so it links NO package products.
# Idempotent.
require 'xcodeproj'

PROJECT   = File.join(__dir__, 'KataGo Anytime.xcodeproj')
WIDGET    = 'KataGoAnytimeWatchWidget'
TEAM      = '6F82AZ9Z52'
WATCH_APP = 'KataGo Anytime Watch'

project = Xcodeproj::Project.open(PROJECT)
if project.targets.any? { |t| t.name == WIDGET }
  puts "Target '#{WIDGET}' already exists — nothing to do."
  exit 0
end

watch_app = project.targets.find { |t| t.name == WATCH_APP } or abort("missing #{WATCH_APP}")

# 1. Extension target on the watchOS platform.
widget = project.new_target(:app_extension, WIDGET, :watchos, '26.0')

widget.build_configurations.each do |c|
  s = c.build_settings
  s['PRODUCT_NAME']              = WIDGET
  s['PRODUCT_BUNDLE_IDENTIFIER'] = 'chinchangyang.KataGo-iOS.tw.watchkitapp.widget'
  s['INFOPLIST_FILE']            = "#{WIDGET}/Info.plist"
  s['GENERATE_INFOPLIST_FILE']   = 'NO'
  s['CODE_SIGN_ENTITLEMENTS']    = "#{WIDGET}/#{WIDGET}.entitlements"
  s['CODE_SIGN_STYLE']           = 'Automatic'
  s['DEVELOPMENT_TEAM']          = TEAM
  s['SDKROOT']                   = 'watchos'
  s['TARGETED_DEVICE_FAMILY']    = '4'
  s['WATCHOS_DEPLOYMENT_TARGET'] = '26.0'
  s['SWIFT_VERSION']             = '6.0'
  s['SKIP_INSTALL']              = 'YES'
  s['LD_RUNPATH_SEARCH_PATHS']   = ['$(inherited)', '@executable_path/Frameworks',
                                    '@executable_path/../../Frameworks']
  s['MARKETING_VERSION']         = '7.0'
  s['CURRENT_PROJECT_VERSION']   = '293'
end

# 2. Register sources + Info.plist/entitlements.
group = project.main_group.find_subpath(WIDGET, true)
group.set_source_tree('SOURCE_ROOT')
%w[KataGoAnytimeWatchWidgetBundle.swift ScoreLeadWidget.swift].each do |f|
  ref = group.new_reference("#{WIDGET}/#{f}")
  widget.source_build_phase.add_file_reference(ref)
end
group.new_reference("#{WIDGET}/Info.plist")
group.new_reference("#{WIDGET}/#{WIDGET}.entitlements")

# 3. Embed into the WATCH app's PlugIns + build dependency.
watch_app.add_dependency(widget)
phase = watch_app.copy_files_build_phases.find { |p| p.name == 'Embed Foundation Extensions' }
unless phase
  phase = watch_app.new_copy_files_build_phase('Embed Foundation Extensions')
  phase.symbol_dst_subfolder_spec = :plug_ins   # PlugIns/
  phase.dst_path = ''
end
ebf = phase.add_file_reference(widget.product_reference)
ebf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

project.save
puts "Added #{WIDGET}, embedded into #{WATCH_APP}."
```

- [ ] **Step 3: Run the script and rebuild**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
ruby add_watch_widget_target.rb
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Watch" \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' 2>&1 | tail -5
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED` twice, watch app now contains `PlugIns/KataGoAnytimeWatchWidget.appex`.

- [ ] **Step 4: Commit**

```bash
git add "ios/KataGo iOS/add_watch_widget_target.rb" "ios/KataGo iOS/KataGoAnytimeWatchWidget/" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj"
git commit -m "feat(watch): score-lead complication via watch WidgetKit extension"
```

---

### Task 7: Full regression run, docs, and hardware checklist

**Files:**
- Modify: `CLAUDE.md` (build commands + platform notes)
- Modify: `docs/superpowers/specs/2026-07-04-watchos-companion-design.md` (mark resolved open items)

- [ ] **Step 1: Full test + all-platform build sweep**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -5
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS' 2>&1 | tail -3
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime TV" -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | tail -3
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' 2>&1 | tail -3
```

Expected: `TEST SUCCEEDED` + three `BUILD SUCCEEDED` (known flaky PlayerName thinking-time UI test excepted).

- [ ] **Step 2: Update CLAUDE.md**

Add to the Build Commands section (after the macOS build command):

```bash
# Build for watchOS Simulator (scheme: KataGo Anytime Watch; watch app links ONLY KataGoGameStore — never the engine)
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Watch" -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)'
```

and note in Platform Support: `watchOS 26+ (companion live mirror, paired iPhone only)`.

- [ ] **Step 3: Resolve the spec's open items**

In the spec's "Open items for the implementation plan" section, replace the four bullets with their resolutions: bundle ids `…tw.watchkitapp` / `…tw.watchkitapp.widget`, scheme `KataGo Anytime Watch`; complication families accessoryInline/Circular/Rectangular with app-pushed reloads (≥0.5 pt and ≥30 s); peek buffer stores full snapshots (50 × ~2 KB ≈ 100 KB); pbxproj wiring via `add_watch_app_target.rb` / `add_watch_widget_target.rb`.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md docs/superpowers/specs/2026-07-04-watchos-companion-design.md
git commit -m "docs(watch): watch build command + resolved spec open items"
```

- [ ] **Step 5: Hardware pair-test checklist (user-run, real devices)**

Not automatable — hand to the user with the build installed on phone + watch:

1. Start analysis on iPhone → watch shows board/candidates/score within ~2 s.
2. Play moves on iPhone → watch board follows; last-move ring appears; candidate dots move.
3. Crown scrub back → "N behind live" pill, host iPhone board does NOT move; scrub to end → pill clears, live resumes.
4. Lock the iPhone → stale badge within ~15 s; unlock + foreground → recovers.
5. Force-quit the watch app → relaunch shows the cached position with stale badge (from `receivedApplicationContext`).
6. Add the Score Lead complication to the Smart Stack → shows current lead; goes stale-styled ~10 min after analysis stops.
7. 19×19 legibility judgment call on-wrist (dots only) — spec accepts coarse.

---

## Verification (plan-level)

- Unit: `WatchSnapshotTests`, `WidgetBoardAnnotationTests`, `WatchPeekBufferTests`, `WatchSnapshotBuilderTests` all green in the iOS-sim test run.
- Build: all five schemes (`KataGo Anytime` iOS + visionOS, `KataGo Anytime Mac`, `KataGo Anytime TV`, `KataGo Anytime Watch`) succeed.
- Behavioral: Task 7 Step 5 hardware checklist.
- Non-regression: existing iOS/macOS widget renders unchanged (new `WidgetBoardView` params default to empty).
