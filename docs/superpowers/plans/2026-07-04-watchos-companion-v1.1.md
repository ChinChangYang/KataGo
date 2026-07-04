# KataGo Anytime Watch v1.1 — Write Path Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> At execution start, save this plan verbatim to `docs/superpowers/plans/2026-07-04-watchos-companion-v1.1.md` and commit it (the v0 precedent).

**Goal:** The Apple Watch upgrades from read-only mirror to write path: the Digital Crown drives the iPhone's board position (shared cursor), and a tap on a top-3 candidate plays it on the iPhone — both under a hard-block gate that can never corrupt a game. Prerequisite: the sticky-maxVisits reset becomes structural (impossible to miss at a new re-arm site) before watch scrubbing multiplies re-arms.

**Context:** v0 (commits ef4bf3cd..fd8b50dc) shipped the read-only live mirror and passed full hardware QA on 2026-07-04. Spec: `docs/superpowers/specs/2026-07-04-watchos-companion-design.md` (v1.1 section, approved). The user explicitly chose **shared single cursor** (Crown drives the host board, not permanent local-peek) in the design grill.

**Architecture:** Watch→iPhone commands ride `WCSession.sendMessage` (reachable-only, reply handler) as a new `WatchCommand` Codable in the bridge-free `KataGoGameStore` package. The iPhone's existing `WatchSessionRelay` gains the receive side and dispatches into the SAME seams the phone UI uses: `GobanState.go(to:)` for navigation and `GobanState.sendCheckMoveCommand` (the board-tap path) for play. `WatchSnapshot` gains optional gate fields so the watch knows when affordances are live; the host re-validates authoritatively on receipt. Every command is bound to game + position so a stale command is rejected visibly, never played silently.

**Tech Stack:** Swift 6 (strict concurrency), WatchConnectivity, SwiftUI (watchOS 26), Swift Testing (`@Test`/`#expect`), xcodeproj-gem-registered targets (no project changes needed this time — all files land in existing targets/packages).

## Global Constraints

- **Never modify SwiftData `@Model` schemas** (`GameRecord`, `Config`) — CloudKit corruption risk. All new state is transient or in wire payloads.
- **The watch app links ONLY `KataGoGameStore`** — never `KataGoUICore` (pulls the C++ bridge). New watch-shared types go in `KataGoGameStore`.
- All new `WatchSnapshot` fields must be **Optional** — synthesized Codable fails on missing non-optional keys, and v0 payloads persist in `receivedApplicationContext` across app updates.
- Swift 6 strict concurrency: never capture non-Sendable values (WCSession, `[String: Any]`, `Error`) into a `Task { @MainActor in }` — extract Sendable `Data`/`String` first (v0 house pattern).
- Tests live in the `KataGo iOSTests/` **folder** but the target is **"KataGo AnytimeTests"**. New test files must be registered in the pbxproj (xcodeproj Ruby gem — see `ios/KataGo iOS/add_watch_app_target.rb` for the recipe; simple file-adds can reuse `add_test_file.rb` pattern if present, else a small one-off script).
- Piped `xcodebuild` exit codes lie — always grep output for the literal `BUILD SUCCEEDED` / `** TEST SUCCEEDED **` strings.
- Use `trash`, never `rm`, for deletions.
- Build/test working directory: `ios/KataGo iOS/`. Test command:
  `xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/<SuiteName>"`
- Watch build gate: `xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Watch" -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)'`
- Commit after every task. Do NOT push (Xcode Cloud spacing — the user decides).

## File Structure

| File | Task | Change |
|---|---|---|
| `KataGoUICore/Sources/KataGoUICore/Session/GtpCommandBuilder.swift` | 1 | Add `continuousAnalyzeCommands`/`fastContinuousAnalyzeCommands`; demote bare `analyzeCommand`/`fastAnalyzeCommand` to `internal` |
| `KataGoUICore/Sources/KataGoUICore/Model/GobanState.swift` | 1 | `getRequestAnalysisCommands` uses the bundle |
| `KataGo iOS/Game/GameSplitView.swift` (~line 572) | 1 | Re-arm site uses the bundle |
| `KataGo Anytime Mac/MainWindowController.swift` (~line 1273) | 1 | Re-arm site uses the bundle |
| `KataGoUICore/Sources/KataGoGameStore/WatchSnapshot.swift` | 2 | Six optional v1.1 fields |
| `KataGoUICore/Sources/KataGoGameStore/WatchCommand.swift` (new) | 2 | `WatchCommand` + `WatchCommandReply` |
| `KataGoUICore/Sources/KataGoUICore/Session/WatchHostGate.swift` (new) | 3 | Gate truth (`isHumanTurn`/`canScrub`/`canPlay`) |
| `KataGoUICore/Sources/KataGoUICore/Session/WatchSnapshotBuilder.swift` | 3 | `gameRecord:`/`moveCount:` params, fills new fields |
| `KataGo iOS/Watch/WatchSessionRelay.swift` | 3, 4 | Task 3: `start` signature + moveCount memo; Task 4: `didReceiveMessage` |
| `KataGo iOS/App/ContentView.swift` (line 65) | 3 | Pass `navigationContext`/`audioModel` to relay |
| `KataGoUICore/Sources/KataGoUICore/Session/WatchCommandHandler.swift` (new) | 4 | Validate + dispatch commands (UIKit-free, testable) |
| `KataGoUICore/Sources/KataGoGameStore/WatchSharedCursor.swift` (new) | 5 | Cursor state machine (debounce/confirm/timeout) |
| `KataGoUICore/Sources/KataGoGameStore/WatchPeekBuffer.swift` | 5 | `entry(forHostIndex:)` render cache lookup |
| `KataGo Anytime Watch/WatchLiveModel.swift` | 5 | Reachability, send channel, cursor driving, rejection state |
| `KataGo Anytime Watch/WatchBoardPage.swift` | 5 | Crown cursor mode (host-index) with ring fallback |
| `KataGo Anytime Watch/WatchMovesPage.swift` | 6 | Tap-to-play buttons, "AI is playing" state |
| `KataGo Anytime Watch/WatchRootView.swift` | 6 | Global rejection banner overlay |
| Tests: `KataGo iOSTests/GtpCommandBuilderTests.swift` (mod), `WatchSnapshotTests.swift` (mod), `WatchCommandTests.swift` (new), `WatchHostGateTests.swift` (new), `WatchSnapshotBuilderTests.swift` (mod), `WatchCommandHandlerTests.swift` (new), `WatchSharedCursorTests.swift` (new) | 1–5 | |

Dependency order: Task 1 independent; 2 → 3 → 4 (host side complete); 5 → 6 (watch side); 7 gates.

---

### Task 1: Structural sticky-maxVisits fix

The three re-arm sites each hand-roll `["kata-set-param maxVisits <unbounded>", <kata-analyze>]` today — the invariant is a per-call-site convention, and watch-driven navigation (Task 4's `go(to:)` → `sendPostExecutionCommands` → re-arm) multiplies re-arm traffic. Fix: the reset becomes part of one blessed builder bundle, and the bare analyze builders become `internal` so **app targets cannot compile a bare `kata-analyze` re-arm at all**. (`DeepReportGenerator`'s probes are bespoke raw strings with different flags and already reset explicitly at `DeepReportGenerator.swift:125` — leave them.)

**Files:**
- Modify: `KataGoUICore/Sources/KataGoUICore/Session/GtpCommandBuilder.swift:46-52`
- Modify: `KataGoUICore/Sources/KataGoUICore/Model/GobanState.swift:116-121`
- Modify: `KataGo iOS/Game/GameSplitView.swift:572-577`
- Modify: `KataGo Anytime Mac/MainWindowController.swift:1273-1278`
- Test: `KataGo iOSTests/GtpCommandBuilderTests.swift`

**Interfaces:**
- Produces: `public static func continuousAnalyzeCommands(interval: Int, maxMoves: Int) -> [String]` and `public static func fastContinuousAnalyzeCommands(maxMoves: Int) -> [String]` on `GtpCommandBuilder`. `analyzeCommand`/`fastAnalyzeCommand` become `internal` (still visible to `@testable` tests and same-module code).

- [ ] **Step 1: Write the failing test** — append to `GtpCommandBuilderTests.swift`:

```swift
@Test func continuousAnalyzeBundlesAlwaysResetMaxVisits() {
    // The reset is structural: every continuous-analysis re-arm goes through
    // these bundles, so a prior human-profile gen-move's sticky maxVisits=400
    // can never silently cap analysis (the load-bearing invariant behind the
    // rank-is-strength feature — and behind watch-driven navigation, which
    // multiplies re-arms).
    let cmds = GtpCommandBuilder.continuousAnalyzeCommands(interval: 25, maxMoves: 30)
    #expect(cmds.first == "kata-set-param maxVisits \(GtpCommandBuilder.unboundedMaxVisits)")
    #expect(cmds.last == "kata-analyze interval 25 maxmoves 30 ownership true ownershipStdev true rootInfo true")

    let fast = GtpCommandBuilder.fastContinuousAnalyzeCommands(maxMoves: 50)
    #expect(fast.first == "kata-set-param maxVisits \(GtpCommandBuilder.unboundedMaxVisits)")
    #expect(fast.last == "kata-analyze interval 10 maxmoves 50 ownership true ownershipStdev true rootInfo true")
}
```

If `GtpCommandBuilderTests.swift` uses plain `import KataGoUICore`, change it to `@testable import KataGoUICore` now (the demotion in Step 3 requires it for the existing assertions that reference `analyzeCommand`/`fastAnalyzeCommand`).

- [ ] **Step 2: Run to verify it fails** — `xcodebuild test ... -only-testing:"KataGo AnytimeTests/GtpCommandBuilderTests"` → expected: compile FAIL, `continuousAnalyzeCommands` not found.

- [ ] **Step 3: Implement** — in `GtpCommandBuilder.swift`, replace the two builders (lines 46-52) with:

```swift
    /// One continuous-analysis line. INTERNAL on purpose: a bare kata-analyze
    /// re-arm silently inherits a prior human-profile gen-move's sticky
    /// maxVisits=400 — app targets must use the bundles below, which embed the
    /// reset structurally instead of leaving it as a per-call-site convention.
    static func analyzeCommand(interval: Int, maxMoves: Int) -> String {
        return "kata-analyze interval \(interval) maxmoves \(maxMoves) ownership true ownershipStdev true rootInfo true"
    }

    static func fastAnalyzeCommand(maxMoves: Int) -> String {
        return analyzeCommand(interval: 10, maxMoves: maxMoves)
    }

    /// Continuous-analysis re-arm bundle: ALWAYS precedes kata-analyze with a
    /// maxVisits reset. Every re-arm site (shared getRequestAnalysisCommands,
    /// iOS GameSplitView, macOS MainWindowController, and any future
    /// watch-driven re-arm) must use this or fastContinuousAnalyzeCommands.
    public static func continuousAnalyzeCommands(interval: Int, maxMoves: Int) -> [String] {
        return ["kata-set-param maxVisits \(unboundedMaxVisits)",
                analyzeCommand(interval: interval, maxMoves: maxMoves)]
    }

    /// The fast (0.1 s first report) variant of the bundle, for the initial
    /// arm after a position change on iOS/macOS.
    public static func fastContinuousAnalyzeCommands(maxMoves: Int) -> [String] {
        return ["kata-set-param maxVisits \(unboundedMaxVisits)",
                fastAnalyzeCommand(maxMoves: maxMoves)]
    }
```

In `GobanState.swift` replace lines 116-121 with:

```swift
        // Continuous analysis: the bundle embeds the maxVisits reset so a
        // prior human gen-move's maxVisits=400 never leaks into (and caps)
        // analysis — structural, not a per-site convention.
        return continuousAnalysisUsesConfigInterval
            ? GtpCommandBuilder.continuousAnalyzeCommands(interval: config.analysisInterval, maxMoves: config.maxAnalysisMoves)
            : GtpCommandBuilder.fastContinuousAnalyzeCommands(maxMoves: config.maxAnalysisMoves)
```

In `GameSplitView.swift` replace lines 572-577 (the `else` branch body) with:

```swift
                } else {
                    // The bundle embeds the maxVisits reset (structural fix for
                    // the sticky human-profile gen-move cap).
                    messageList.appendAndSend(commands: GtpCommandBuilder.continuousAnalyzeCommands(
                        interval: config.analysisInterval, maxMoves: config.maxAnalysisMoves))
                }
```

In `MainWindowController.swift` replace the equivalent re-arm (lines ~1273-1278) with:

```swift
                    // The bundle embeds the maxVisits reset (structural fix for
                    // the sticky human-profile gen-move cap).
                    session.messageList.appendAndSend(commands: GtpCommandBuilder.continuousAnalyzeCommands(
                        interval: gameRecord.concreteConfig.analysisInterval,
                        maxMoves: gameRecord.concreteConfig.maxAnalysisMoves))
```

(Match the receiver the existing code uses — read the surrounding lines first; the macOS site may use `messageList` directly.)

- [ ] **Step 4: Run the focused suites** — `-only-testing:"KataGo AnytimeTests/GtpCommandBuilderTests"` and `-only-testing:"KataGo AnytimeTests/GobanStateContinuousAnalysisIntervalTests"` → PASS. (The latter references the now-internal builders; it already uses `@testable import KataGoUICore` — fix assertions only if compilation says otherwise.)

- [ ] **Step 5: Build iOS + macOS** (the two app targets whose call sites changed); grep both for `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit** — `fix(engine): make the continuous-analysis maxVisits reset structural`

---

### Task 2: Wire types — WatchSnapshot v1.1 fields + WatchCommand/Reply

**Files:**
- Modify: `KataGoUICore/Sources/KataGoGameStore/WatchSnapshot.swift`
- Create: `KataGoUICore/Sources/KataGoGameStore/WatchCommand.swift`
- Test: modify `KataGo iOSTests/WatchSnapshotTests.swift`, create `KataGo iOSTests/WatchCommandTests.swift` (register in pbxproj, target "KataGo AnytimeTests")

**Interfaces:**
- Produces on `WatchSnapshot` (all Optional, `nil` = v0 phone): `hostGameID: String?`, `hostMoveIndex: Int?`, `hostMoveCount: Int?`, `isHumanTurn: Bool?`, `canScrub: Bool?`, `canPlay: Bool?`. Existing init keeps its exact signature (new fields default nil via trailing defaulted params).
- Produces: `WatchCommand` (`kind: .goTo/.play`, `gameID: String`, `targetIndex: Int?`, `vertex: String?`, `toMove: String?`, `boundIndex: Int?`, `static let messageKey = "watchCommand"`, `encodedData()/decode(_:)`) and `WatchCommandReply` (`accepted: Bool`, `reason: String?`, `static let messageKey = "watchReply"`, `encodedData()/decode(_:)`).

- [ ] **Step 1: Write the failing tests.** Append to `WatchSnapshotTests.swift`:

```swift
@Test func writePathFieldsRoundTripAndDefaultNil() throws {
    var s = Self.makeSnapshot()
    #expect(s.hostGameID == nil && s.hostMoveIndex == nil && s.canPlay == nil)
    s.hostGameID = "ABC"; s.hostMoveIndex = 42; s.hostMoveCount = 50
    s.isHumanTurn = true; s.canScrub = true; s.canPlay = false
    let decoded = try WatchSnapshot.decode(s.encodedData())
    #expect(decoded == s)
}

@Test func v0PayloadWithoutWritePathFieldsStillDecodes() throws {
    // A v0 phone's frame persists in receivedApplicationContext across the
    // app update — it must decode with the new fields nil.
    var s = Self.makeSnapshot()
    s.hostGameID = "ABC"; s.hostMoveIndex = 42; s.hostMoveCount = 50
    s.isHumanTurn = true; s.canScrub = true; s.canPlay = true
    var json = try JSONSerialization.jsonObject(with: s.encodedData()) as! [String: Any]
    for key in ["hostGameID", "hostMoveIndex", "hostMoveCount",
                "isHumanTurn", "canScrub", "canPlay"] { json.removeValue(forKey: key) }
    let decoded = try WatchSnapshot.decode(JSONSerialization.data(withJSONObject: json))
    #expect(decoded.hostGameID == nil && decoded.hostMoveIndex == nil
            && decoded.canScrub == nil && decoded.canPlay == nil)
    #expect(decoded.blackStones == s.blackStones)
}
```

Create `WatchCommandTests.swift`:

```swift
import Testing
import Foundation
@testable import KataGoGameStore

struct WatchCommandTests {
    @Test func goToRoundTrip() throws {
        let cmd = WatchCommand(kind: .goTo, gameID: "G1", targetIndex: 17)
        let decoded = try WatchCommand.decode(cmd.encodedData())
        #expect(decoded == cmd)
        #expect(decoded.vertex == nil && decoded.boundIndex == nil)
    }

    @Test func playRoundTripCarriesFullBinding() throws {
        // Spec: the gate carries the bound position — a play command must be
        // rejectable when the board moved after it was computed.
        let cmd = WatchCommand(kind: .play, gameID: "G1", vertex: "Q16",
                               toMove: "B", boundIndex: 42)
        let decoded = try WatchCommand.decode(cmd.encodedData())
        #expect(decoded == cmd)
    }

    @Test func replyRoundTrip() throws {
        let ok = try WatchCommandReply.decode(WatchCommandReply(accepted: true).encodedData())
        #expect(ok.accepted && ok.reason == nil)
        let no = try WatchCommandReply.decode(
            WatchCommandReply(accepted: false, reason: "Position changed").encodedData())
        #expect(!no.accepted && no.reason == "Position changed")
    }
}
```

- [ ] **Step 2: Register the new test file in the pbxproj** (xcodeproj gem one-off, target "KataGo AnytimeTests"), run both suites → expected FAIL (fields/types missing).

- [ ] **Step 3: Implement.** In `WatchSnapshot.swift`, after `public var hostTimestamp: Date` add:

```swift
    // v1.1 write path — ALL optional so a v0 payload (persisted in
    // receivedApplicationContext across app updates) still decodes; nil means
    // "v0 phone", which the watch treats as read-only mirror mode.
    /// GameRecord.uuid.uuidString of the game on screen; commands bind to it.
    public var hostGameID: String?
    /// Host's current mainline SGF index (GobanState.getCurrentIndex).
    public var hostMoveIndex: Int?
    /// Mainline move count (SgfOperations.moveSize) — the crown's upper bound.
    public var hostMoveCount: Int?
    /// Side to move is human-played (its maxTime == 0); nil when unknown.
    public var isHumanTurn: Bool?
    /// Host would accept a goTo command right now.
    public var canScrub: Bool?
    /// Host would accept a play command right now (hard-block gate result).
    public var canPlay: Bool?
```

(Leave the memberwise `init` exactly as-is — the new vars carry `nil` defaults, and Task 3 fills them by mutation. Do NOT add them to the init; that keeps every existing call site source-compatible.)

Create `WatchCommand.swift`:

```swift
import Foundation

/// Watch→iPhone command envelope (v1.1 write path), sent via
/// WCSession.sendMessage (reachable-only, reply expected) under `messageKey`.
/// Every command binds to the game it was computed against; play additionally
/// binds the exact position and side, so a command that raced a host change is
/// rejected visibly, never played silently (spec: hard-block gate).
public struct WatchCommand: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case goTo   // navigate the host mainline to `targetIndex`
        case play   // play `vertex` for `toMove`, valid only at `boundIndex`
    }

    /// sendMessage dictionary key holding the encoded command.
    public static let messageKey = "watchCommand"

    public var kind: Kind
    public var gameID: String
    public var targetIndex: Int?
    public var vertex: String?
    /// "B"/"W" — same convention as WatchSnapshot.toMove.
    public var toMove: String?
    public var boundIndex: Int?

    public init(kind: Kind, gameID: String, targetIndex: Int? = nil,
                vertex: String? = nil, toMove: String? = nil, boundIndex: Int? = nil) {
        self.kind = kind; self.gameID = gameID; self.targetIndex = targetIndex
        self.vertex = vertex; self.toMove = toMove; self.boundIndex = boundIndex
    }

    public func encodedData() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> WatchCommand {
        try JSONDecoder().decode(WatchCommand.self, from: data)
    }
}

/// iPhone→watch reply. `accepted` means the command entered the same engine
/// seam the phone's own UI uses (goTo → GobanState.go(to:); play → the
/// kata-check-move → play path a board tap takes). Engine-side legality of an
/// analysis candidate holds by construction — kata-analyze only reports legal
/// moves — so acceptance is the real "it will happen" signal.
public struct WatchCommandReply: Codable, Equatable, Sendable {
    public static let messageKey = "watchReply"
    public var accepted: Bool
    /// User-facing rejection reason, shown on the watch.
    public var reason: String?

    public init(accepted: Bool, reason: String? = nil) {
        self.accepted = accepted; self.reason = reason
    }

    public func encodedData() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> WatchCommandReply {
        try JSONDecoder().decode(WatchCommandReply.self, from: data)
    }
}
```

- [ ] **Step 4: Run** `-only-testing:"KataGo AnytimeTests/WatchSnapshotTests"` and `WatchCommandTests` → PASS.
- [ ] **Step 5: Commit** — `feat(watch): v1.1 wire types — snapshot gate fields + WatchCommand/Reply`

---

### Task 3: Host gate truth + snapshot enrichment

**Files:**
- Create: `KataGoUICore/Sources/KataGoUICore/Session/WatchHostGate.swift`
- Modify: `KataGoUICore/Sources/KataGoUICore/Session/WatchSnapshotBuilder.swift`
- Modify: `KataGo iOS/Watch/WatchSessionRelay.swift` (start signature, memo, builder call)
- Modify: `KataGo iOS/App/ContentView.swift:65`
- Test: create `KataGo iOSTests/WatchHostGateTests.swift` (register in pbxproj), modify `WatchSnapshotBuilderTests.swift`

**Interfaces:**
- Consumes: `GameRecord.createGameRecord(sgf:currentIndex:...)` (test fixture), `gobanState.shouldGenMove/isBranchActive/pendingMoveTurn/reportGenerationActive/isAutoPlaying/showBoardCount/isEditing/analysisStatus/getNextMove/getCurrentIndex`, `config.blackMaxTime/whiteMaxTime`, `SgfOperations(sgf:).moveSize`.
- Produces: `WatchHostGateState { isHumanTurn: Bool?, canScrub: Bool, canPlay: Bool }` and `WatchHostGate.evaluate(session:gameRecord:) -> WatchHostGateState` (@MainActor). `WatchSnapshotBuilder.makeSnapshot(session:gameRecord:moveCount:now:)` — new params defaulted (`nil`) so existing call sites/tests compile.

- [ ] **Step 1: Write the failing tests.** Create `WatchHostGateTests.swift`:

```swift
import Testing
import Foundation
@testable import KataGoUICore
import KataGoGameStore

@MainActor
struct WatchHostGateTests {
    // 4 mainline moves; currentIndex 4 = at the head.
    private static let sgf = "(;FF[4]GM[1]SZ[9];B[aa];W[bb];B[cc];W[dd])"

    private func makeHost(currentIndex: Int = 4, editing: Bool = true)
        -> (session: GameSession, gameRecord: GameRecord) {
        let session = GameSession()
        let gameRecord = GameRecord.createGameRecord(sgf: Self.sgf, currentIndex: currentIndex)
        // Human-vs-human, black to move, analysis running: the all-green case.
        gameRecord.concreteConfig.blackMaxTime = 0
        gameRecord.concreteConfig.whiteMaxTime = 0
        session.player.nextColorForPlayCommand = .black
        session.gobanState.analysisStatus = .run
        session.gobanState.isEditing = editing
        return (session, gameRecord)
    }

    @Test func allGreenAllowsScrubAndPlay() {
        let (session, gameRecord) = makeHost()
        let gate = WatchHostGate.evaluate(session: session, gameRecord: gameRecord)
        #expect(gate.isHumanTurn == true && gate.canScrub && gate.canPlay)
    }

    @Test func noGameBlocksEverything() {
        let gate = WatchHostGate.evaluate(session: GameSession(), gameRecord: nil)
        #expect(gate.isHumanTurn == nil && !gate.canScrub && !gate.canPlay)
    }

    @Test func lockedGameBlocksPlayOnly() {
        // Play on a locked game would start a branch — not mainline append.
        let (session, gameRecord) = makeHost(editing: false)
        let gate = WatchHostGate.evaluate(session: session, gameRecord: gameRecord)
        #expect(gate.canScrub && !gate.canPlay)
    }

    @Test func behindHeadBlocksPlayOnly() {
        // Playing behind the head truncates the record (overwrite) — the phone
        // confirms that destructive path with a dialog; the watch must never
        // reach it.
        let (session, gameRecord) = makeHost(currentIndex: 2)
        let gate = WatchHostGate.evaluate(session: session, gameRecord: gameRecord)
        #expect(gate.canScrub && !gate.canPlay)
    }

    @Test func activeBranchBlocksBoth() {
        let (session, gameRecord) = makeHost()
        session.gobanState.branchSgf = Self.sgf
        session.gobanState.branchIndex = 2
        let gate = WatchHostGate.evaluate(session: session, gameRecord: gameRecord)
        #expect(!gate.canScrub && !gate.canPlay)
    }

    @Test func aiTurnBlocksBoth() {
        // shouldGenMove true (gen-move may be streaming; a goTo's undo would
        // cancel it and its best-so-far "play" reply could land on the wrong
        // board — the tvOS lesson).
        let (session, gameRecord) = makeHost()
        gameRecord.concreteConfig.blackMaxTime = 10
        let gate = WatchHostGate.evaluate(session: session, gameRecord: gameRecord)
        #expect(gate.isHumanTurn == false && !gate.canScrub && !gate.canPlay)
    }

    @Test func pendingMoveBlocksBoth() {
        let (session, gameRecord) = makeHost()
        session.gobanState.pendingMoveTurn = "b"
        let gate = WatchHostGate.evaluate(session: session, gameRecord: gameRecord)
        #expect(!gate.canScrub && !gate.canPlay)
    }

    @Test func pausedAnalysisBlocksPlayButNotScrub() {
        let (session, gameRecord) = makeHost()
        session.gobanState.analysisStatus = .pause
        let gate = WatchHostGate.evaluate(session: session, gameRecord: gameRecord)
        #expect(gate.canScrub && !gate.canPlay)
    }

    @Test func unknownTurnBlocksPlay() {
        let (session, gameRecord) = makeHost()
        session.player.nextColorForPlayCommand = .unknown
        let gate = WatchHostGate.evaluate(session: session, gameRecord: gameRecord)
        #expect(gate.isHumanTurn == nil && !gate.canPlay)
    }
}
```

Append to `WatchSnapshotBuilderTests.swift`:

```swift
    @Test func gameRecordEnrichesWritePathFields() {
        let session = GameSession()
        session.board.width = 9; session.board.height = 9
        session.player.nextColorForPlayCommand = .black
        session.gobanState.analysisStatus = .run
        session.gobanState.isEditing = true
        let gameRecord = GameRecord.createGameRecord(
            sgf: "(;FF[4]GM[1]SZ[9];B[aa];W[bb];B[cc];W[dd])", currentIndex: 4)
        gameRecord.concreteConfig.blackMaxTime = 0
        gameRecord.concreteConfig.whiteMaxTime = 0

        let snapshot = WatchSnapshotBuilder.makeSnapshot(
            session: session, gameRecord: gameRecord, moveCount: 4, now: .now)

        #expect(snapshot.hostGameID == gameRecord.uuid?.uuidString)
        #expect(snapshot.hostMoveIndex == 4)
        #expect(snapshot.hostMoveCount == 4)
        #expect(snapshot.isHumanTurn == true)
        #expect(snapshot.canScrub == true && snapshot.canPlay == true)
    }

    @Test func nilGameRecordLeavesWritePathFieldsNil() {
        let session = GameSession()
        session.board.width = 9; session.board.height = 9
        let snapshot = WatchSnapshotBuilder.makeSnapshot(session: session)
        #expect(snapshot.hostGameID == nil && snapshot.hostMoveIndex == nil
                && snapshot.canScrub == nil && snapshot.canPlay == nil)
    }
```

- [ ] **Step 2: Register `WatchHostGateTests.swift` in pbxproj; run both suites** → expected FAIL (type missing / param missing).

- [ ] **Step 3: Implement.** Create `WatchHostGate.swift`:

```swift
import Foundation
import KataGoGameStore

/// Gate truth for the v1.1 watch write path, computed host-side from live
/// session state. The snapshot carries the result so the watch can show/hide
/// affordances; WatchCommandHandler re-evaluates on receipt (authoritative —
/// the watch's copy can be one relay tick stale).
public struct WatchHostGateState: Equatable, Sendable {
    /// Side to move is human-played (its per-move maxTime == 0); nil when the
    /// next color is unknown (board still loading) or there is no game.
    public var isHumanTurn: Bool?
    public var canScrub: Bool
    public var canPlay: Bool

    public init(isHumanTurn: Bool?, canScrub: Bool, canPlay: Bool) {
        self.isHumanTurn = isHumanTurn; self.canScrub = canScrub; self.canPlay = canPlay
    }
}

public enum WatchHostGate {
    /// Scrub parity with the phone's own toolbar gate
    /// (StatusToolbarItems.isFunctional: no gen-move in flight, not
    /// auto-playing, no showboard in flight) plus mainline-only (no active
    /// branch), no pending human move, and no report probing.
    /// Play additionally requires the spec's hard-block gate: analysis
    /// running, game unlocked (isEditing), at the mainline head (nothing to
    /// overwrite — playing behind the head truncates the record), and the
    /// human's turn.
    @MainActor
    public static func evaluate(session: GameSession, gameRecord: GameRecord?) -> WatchHostGateState {
        guard let gameRecord else {
            return WatchHostGateState(isHumanTurn: nil, canScrub: false, canPlay: false)
        }
        let config = gameRecord.concreteConfig
        let gobanState = session.gobanState

        let isHumanTurn: Bool?
        switch session.player.nextColorForPlayCommand {
        case .black: isHumanTurn = config.blackMaxTime == 0
        case .white: isHumanTurn = config.whiteMaxTime == 0
        case .unknown: isHumanTurn = nil
        }

        let canScrub = !gobanState.shouldGenMove(config: config, player: session.player)
            && !gobanState.isAutoPlaying
            && gobanState.showBoardCount == 0
            && !gobanState.isBranchActive
            && gobanState.pendingMoveTurn == nil
            && !gobanState.reportGenerationActive

        let atMainlineHead = gobanState.getNextMove(gameRecord: gameRecord) == nil
        let canPlay = canScrub
            && gobanState.analysisStatus == .run
            && gobanState.isEditing
            && atMainlineHead
            && isHumanTurn == true

        return WatchHostGateState(isHumanTurn: isHumanTurn, canScrub: canScrub, canPlay: canPlay)
    }
}
```

In `WatchSnapshotBuilder.swift`, change the signature and the return:

```swift
    @MainActor
    public static func makeSnapshot(session: GameSession,
                                    gameRecord: GameRecord? = nil,
                                    moveCount: Int? = nil,
                                    now: Date = .now) -> WatchSnapshot {
```

and just before `return`, build into a `var snapshot = WatchSnapshot(...)` then:

```swift
        if let gameRecord {
            let gate = WatchHostGate.evaluate(session: session, gameRecord: gameRecord)
            snapshot.hostGameID = gameRecord.uuid?.uuidString
            snapshot.hostMoveIndex = session.gobanState.getCurrentIndex(gameRecord: gameRecord)
            snapshot.hostMoveCount = moveCount
            snapshot.isHumanTurn = gate.isHumanTurn
            snapshot.canScrub = gate.canScrub
            snapshot.canPlay = gate.canPlay
        }
        return snapshot
```

In `WatchSessionRelay.swift`: store weak refs and a moveCount memo, thread them into the builder:

```swift
    private weak var gameSession: GameSession?
    private weak var navigationContext: NavigationContext?
    private weak var audioModel: AudioModel?
    /// SgfOperations parses the whole SGF — memoize moveSize per SGF string so
    /// the 500 ms tick doesn't re-parse a long game.
    private var moveCountMemo: (sgf: String, count: Int?)?

    func start(session gameSession: GameSession,
               navigationContext: NavigationContext,
               audioModel: AudioModel) {
        guard WCSession.isSupported() else { return }   // iPad: no-op
        self.gameSession = gameSession
        self.navigationContext = navigationContext
        self.audioModel = audioModel
        // ... existing activation + loop, unchanged ...
    }

    private func currentMoveCount(for gameRecord: GameRecord?) -> Int? {
        guard let sgf = gameRecord?.sgf else { return nil }
        if moveCountMemo?.sgf != sgf {
            moveCountMemo = (sgf, SgfOperations(sgf: sgf).moveSize)
        }
        return moveCountMemo?.count
    }
```

and in `pushIfChanged`:

```swift
        let gameRecord = navigationContext?.selectedGameRecord
        let snapshot = WatchSnapshotBuilder.makeSnapshot(
            session: gameSession, gameRecord: gameRecord,
            moveCount: currentMoveCount(for: gameRecord))
```

In `ContentView.swift:65`: `watchRelay.start(session: session, navigationContext: navigationContext, audioModel: audioModel)`.

- [ ] **Step 4: Run** `WatchHostGateTests` + `WatchSnapshotBuilderTests` → PASS. Build iOS scheme → `BUILD SUCCEEDED`.
- [ ] **Step 5: Commit** — `feat(watch): host gate truth + write-path snapshot fields`

---

### Task 4: Host command execution (relay receive side)

**Files:**
- Create: `KataGoUICore/Sources/KataGoUICore/Session/WatchCommandHandler.swift`
- Modify: `KataGo iOS/Watch/WatchSessionRelay.swift` (add `didReceiveMessage`)
- Test: create `KataGo iOSTests/WatchCommandHandlerTests.swift` (register in pbxproj)

**Interfaces:**
- Consumes: `WatchCommand`/`WatchCommandReply` (Task 2), `WatchHostGate.evaluate` (Task 3), `GobanState.go(to:gameRecord:board:messageList:player:audioModel:stones:)` (GobanState.swift:732), `GobanState.sendCheckMoveCommand(turn:move:messageList:)` (GobanState.swift:360), `Turn.nextColorSymbolForPlayCommand` (KataGoModel.swift:193, returns "b"/"w").
- Produces: `WatchCommandHandler.handle(data:session:gameRecord:moveCount:audioModel:hostIsActive:) -> WatchCommandReply` (@MainActor, UIKit-free — the iOS relay supplies `hostIsActive`).

The play path needs NO new engine plumbing: `sendCheckMoveCommand` sets the pending move, and the existing `GameSession.maybeCollectCheckMove` (GameSession.swift:476) consumes the engine's `isLegal` reply and calls `playPendingHumanMove` — identical to a board tap.

- [ ] **Step 1: Write the failing tests.** Create `WatchCommandHandlerTests.swift`:

```swift
import Testing
import Foundation
@testable import KataGoUICore
import KataGoGameStore

@MainActor
struct WatchCommandHandlerTests {
    private static let sgf = "(;FF[4]GM[1]SZ[9];B[aa];W[bb];B[cc];W[dd])"

    private func makeHost(currentIndex: Int = 4)
        -> (session: GameSession, gameRecord: GameRecord) {
        let session = GameSession()
        session.board.width = 9; session.board.height = 9
        let gameRecord = GameRecord.createGameRecord(sgf: Self.sgf, currentIndex: currentIndex)
        gameRecord.concreteConfig.blackMaxTime = 0
        gameRecord.concreteConfig.whiteMaxTime = 0
        session.player.nextColorForPlayCommand = .black
        session.gobanState.analysisStatus = .run
        session.gobanState.isEditing = true
        return (session, gameRecord)
    }

    private func encoded(_ cmd: WatchCommand) -> Data { try! cmd.encodedData() }

    @Test func inactiveHostRejects() {
        let (session, gameRecord) = makeHost()
        let cmd = WatchCommand(kind: .goTo, gameID: gameRecord.uuid!.uuidString, targetIndex: 2)
        let reply = WatchCommandHandler.handle(data: encoded(cmd), session: session,
                                               gameRecord: gameRecord, moveCount: 4,
                                               audioModel: nil, hostIsActive: false)
        #expect(!reply.accepted)
    }

    @Test func wrongGameIDRejects() {
        let (session, gameRecord) = makeHost()
        let cmd = WatchCommand(kind: .goTo, gameID: "not-the-game", targetIndex: 2)
        let reply = WatchCommandHandler.handle(data: encoded(cmd), session: session,
                                               gameRecord: gameRecord, moveCount: 4,
                                               audioModel: nil, hostIsActive: true)
        #expect(!reply.accepted)
    }

    @Test func goToNavigatesTheMainline() {
        let (session, gameRecord) = makeHost()
        let cmd = WatchCommand(kind: .goTo, gameID: gameRecord.uuid!.uuidString, targetIndex: 2)
        let reply = WatchCommandHandler.handle(data: encoded(cmd), session: session,
                                               gameRecord: gameRecord, moveCount: 4,
                                               audioModel: nil, hostIsActive: true)
        #expect(reply.accepted)
        #expect(gameRecord.currentIndex == 2)
        // go(to:) backward path sends real GTP undos through the message list.
        #expect(session.messageList.messages.contains { $0.text == "> undo" })
    }

    @Test func goToOutOfRangeRejects() {
        let (session, gameRecord) = makeHost()
        let cmd = WatchCommand(kind: .goTo, gameID: gameRecord.uuid!.uuidString, targetIndex: 99)
        let reply = WatchCommandHandler.handle(data: encoded(cmd), session: session,
                                               gameRecord: gameRecord, moveCount: 4,
                                               audioModel: nil, hostIsActive: true)
        #expect(!reply.accepted)
        #expect(gameRecord.currentIndex == 4)
    }

    @Test func playDispatchesCheckMove() {
        let (session, gameRecord) = makeHost()
        let cmd = WatchCommand(kind: .play, gameID: gameRecord.uuid!.uuidString,
                               vertex: "E5", toMove: "B", boundIndex: 4)
        let reply = WatchCommandHandler.handle(data: encoded(cmd), session: session,
                                               gameRecord: gameRecord, moveCount: 4,
                                               audioModel: nil, hostIsActive: true)
        #expect(reply.accepted)
        // Same seam as a board tap: pending move set + kata-check-move sent;
        // GameSession.maybeCollectCheckMove finishes the play when the engine
        // confirms legality.
        #expect(session.gobanState.pendingMoveVertex == "E5")
        #expect(session.gobanState.pendingMoveTurn == "b")
        #expect(session.messageList.messages.contains { $0.text == "> kata-check-move b E5" })
    }

    @Test func playWithStaleBindingRejects() {
        let (session, gameRecord) = makeHost()
        // Computed against index 3, but the host is at 4 → position changed.
        let cmd = WatchCommand(kind: .play, gameID: gameRecord.uuid!.uuidString,
                               vertex: "E5", toMove: "B", boundIndex: 3)
        let reply = WatchCommandHandler.handle(data: encoded(cmd), session: session,
                                               gameRecord: gameRecord, moveCount: 4,
                                               audioModel: nil, hostIsActive: true)
        #expect(!reply.accepted)
        #expect(session.gobanState.pendingMoveTurn == nil)
    }

    @Test func playWithWrongSideRejects() {
        let (session, gameRecord) = makeHost()
        let cmd = WatchCommand(kind: .play, gameID: gameRecord.uuid!.uuidString,
                               vertex: "E5", toMove: "W", boundIndex: 4)
        let reply = WatchCommandHandler.handle(data: encoded(cmd), session: session,
                                               gameRecord: gameRecord, moveCount: 4,
                                               audioModel: nil, hostIsActive: true)
        #expect(!reply.accepted)
    }

    @Test func playOnLockedGameRejects() {
        let (session, gameRecord) = makeHost()
        session.gobanState.isEditing = false
        let cmd = WatchCommand(kind: .play, gameID: gameRecord.uuid!.uuidString,
                               vertex: "E5", toMove: "B", boundIndex: 4)
        let reply = WatchCommandHandler.handle(data: encoded(cmd), session: session,
                                               gameRecord: gameRecord, moveCount: 4,
                                               audioModel: nil, hostIsActive: true)
        #expect(!reply.accepted)
    }

    @Test func garbageDataRejects() {
        let (session, gameRecord) = makeHost()
        let reply = WatchCommandHandler.handle(data: Data([0xFF]), session: session,
                                               gameRecord: gameRecord, moveCount: 4,
                                               audioModel: nil, hostIsActive: true)
        #expect(!reply.accepted)
    }
}
```

- [ ] **Step 2: Register in pbxproj; run** → expected FAIL (type missing).

- [ ] **Step 3: Implement.** Create `WatchCommandHandler.swift`:

```swift
import Foundation
import KataGoGameStore

/// Executes a decoded WatchCommand against the live session, re-validating
/// the gate authoritatively (the watch's snapshot-derived gate can be a relay
/// tick stale). Dispatches into the SAME seams the phone UI uses — goTo →
/// GobanState.go(to:), play → GobanState.sendCheckMoveCommand (the board-tap
/// path; GameSession.maybeCollectCheckMove consumes the engine's reply and
/// completes the play). UIKit-free so it compiles on every platform and stays
/// unit-testable; the iOS relay supplies `hostIsActive`.
public enum WatchCommandHandler {
    @MainActor
    public static func handle(data: Data?,
                              session: GameSession,
                              gameRecord: GameRecord?,
                              moveCount: Int?,
                              audioModel: AudioModel?,
                              hostIsActive: Bool) -> WatchCommandReply {
        // sendMessage can background-wake the app; the engine's timing there
        // is unreliable (about to suspend), so refuse rather than half-run.
        guard hostIsActive else {
            return WatchCommandReply(accepted: false, reason: "Open the app on iPhone")
        }
        guard let data, let command = try? WatchCommand.decode(data) else {
            return WatchCommandReply(accepted: false, reason: "Unrecognized command")
        }
        guard let gameRecord, gameRecord.uuid?.uuidString == command.gameID else {
            return WatchCommandReply(accepted: false, reason: "Game changed on iPhone")
        }
        let gate = WatchHostGate.evaluate(session: session, gameRecord: gameRecord)

        switch command.kind {
        case .goTo:
            guard gate.canScrub else {
                return WatchCommandReply(accepted: false, reason: "iPhone is busy")
            }
            guard let target = command.targetIndex, target >= 0,
                  let moveCount, target <= moveCount else {
                return WatchCommandReply(accepted: false, reason: "Position out of range")
            }
            session.gobanState.go(to: target, gameRecord: gameRecord,
                                  board: session.board,
                                  messageList: session.messageList,
                                  player: session.player,
                                  audioModel: audioModel,
                                  stones: session.stones)
            return WatchCommandReply(accepted: true)

        case .play:
            guard gate.canPlay else {
                return WatchCommandReply(accepted: false, reason: "Play not available")
            }
            // Position binding: the candidate was computed against boundIndex
            // for toMove — reject if either moved (spec: the gate carries the
            // bound move number; never play onto a changed board).
            guard let vertex = command.vertex,
                  command.boundIndex == session.gobanState.getCurrentIndex(gameRecord: gameRecord),
                  let turn = session.player.nextColorSymbolForPlayCommand,
                  command.toMove?.lowercased() == turn else {
                return WatchCommandReply(accepted: false, reason: "Position changed")
            }
            session.gobanState.sendCheckMoveCommand(turn: turn, move: vertex,
                                                    messageList: session.messageList)
            return WatchCommandReply(accepted: true)
        }
    }
}
```

In `WatchSessionRelay.swift`, add (plus `import UIKit` if not transitively available):

```swift
    // MARK: Watch→phone commands (v1.1 write path)

    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        // Extract the Sendable Data before hopping (house Swift 6 pattern);
        // box the reply closure — WCSession documents it callable from any
        // queue, but the SDK import may lack @Sendable.
        let data = message[WatchCommand.messageKey] as? Data
        let reply = UncheckedSendableBox(replyHandler)
        Task { @MainActor in
            let result: WatchCommandReply
            if let gameSession = self.gameSession {
                result = WatchCommandHandler.handle(
                    data: data,
                    session: gameSession,
                    gameRecord: self.navigationContext?.selectedGameRecord,
                    moveCount: self.currentMoveCount(for: self.navigationContext?.selectedGameRecord),
                    audioModel: self.audioModel,
                    hostIsActive: UIApplication.shared.applicationState != .background)
            } else {
                result = WatchCommandReply(accepted: false, reason: "No active game")
            }
            let payload = (try? result.encodedData()) ?? Data()
            reply.value([WatchCommandReply.messageKey: payload])
        }
    }
```

At file scope:

```swift
/// WCSession's replyHandler is documented callable from any queue; box it for
/// the MainActor hop in case the SDK import lacks @Sendable. Harmless if the
/// signature is already @Sendable.
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
```

(If the Xcode 26 SDK already marks the replyHandler `@Sendable`, the box still compiles — keep it for clarity either way. If the compiler instead complains the box is redundant, drop it and call `replyHandler` directly.)

- [ ] **Step 4: Run** `WatchCommandHandlerTests` → PASS. Build iOS scheme → `BUILD SUCCEEDED`.
- [ ] **Step 5: Commit** — `feat(watch): host executes watch goTo/play commands under the hard-block gate`

---

### Task 5: Watch shared cursor (Crown drives the iPhone)

Crown semantics change **only when the write path is available** (`sharedCursorAvailable`): the crown then indexes the host mainline `0...hostMoveCount` (not the ring), renders optimistically from cached frames, and sends a debounced `goTo`. In every other case (v0 phone payload, stale, unreachable, branch/AI-turn/busy) the page behaves exactly like v0 local peek — that degrade path is already hardware-verified.

**Files:**
- Create: `KataGoUICore/Sources/KataGoGameStore/WatchSharedCursor.swift`
- Modify: `KataGoUICore/Sources/KataGoGameStore/WatchPeekBuffer.swift` (one lookup method)
- Modify: `KataGo Anytime Watch/WatchLiveModel.swift`
- Modify: `KataGo Anytime Watch/WatchBoardPage.swift`
- Test: create `KataGo iOSTests/WatchSharedCursorTests.swift` (register in pbxproj)

**Interfaces:**
- Produces: `WatchSharedCursor` (@MainActor @Observable, KataGoGameStore): `propose(target:) -> Bool`, `takeDue(now:) -> Int?`, `observe(hostIndex:now:) -> Observation?` (`.confirmed/.waiting/.timedOut`), `abandon()`, `pendingTarget: Int?`; constants `debounce = 0.3`, `confirmTimeout = 5.0`.
- Produces: `WatchPeekBuffer.entry(forHostIndex:) -> WatchSnapshot?`.
- Produces on `WatchLiveModel`: `isReachable`, `sharedCursorAvailable`, `cursorPendingTarget`, `rejectionMessage`, `playPending`, `scrub(to:)`, `playCandidate(vertex:)`.

- [ ] **Step 1: Write the failing tests.** Create `WatchSharedCursorTests.swift`:

```swift
import Testing
import Foundation
@testable import KataGoGameStore

@MainActor
struct WatchSharedCursorTests {
    let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    @Test func proposeDebouncesAndSendsOnce() {
        let cursor = WatchSharedCursor()
        #expect(cursor.propose(target: 40))          // schedule
        #expect(cursor.propose(target: 39))          // retarget → reschedule
        #expect(!cursor.propose(target: 39))         // same target → no reschedule
        #expect(cursor.pendingTarget == 39)
        #expect(cursor.takeDue(now: t0) == 39)       // debounce fired → send 39
        #expect(cursor.takeDue(now: t0) == nil)      // nothing else due
        #expect(cursor.pendingTarget == 39)          // still pending (awaiting confirm)
    }

    @Test func frameWithTargetIndexConfirms() {
        let cursor = WatchSharedCursor()
        _ = cursor.propose(target: 12)
        _ = cursor.takeDue(now: t0)
        #expect(cursor.observe(hostIndex: 11, now: t0 + 1) == .waiting)
        #expect(cursor.observe(hostIndex: 12, now: t0 + 2) == .confirmed)
        #expect(cursor.pendingTarget == nil)
        #expect(cursor.observe(hostIndex: 12, now: t0 + 3) == nil)   // idle: nothing pending
    }

    @Test func silenceTimesOut() {
        let cursor = WatchSharedCursor()
        _ = cursor.propose(target: 12)
        _ = cursor.takeDue(now: t0)
        #expect(cursor.observe(hostIndex: 3, now: t0 + WatchSharedCursor.confirmTimeout + 1) == .timedOut)
        #expect(cursor.pendingTarget == nil)
    }

    @Test func abandonClearsPendingState() {
        let cursor = WatchSharedCursor()
        _ = cursor.propose(target: 12)
        cursor.abandon()
        #expect(cursor.pendingTarget == nil)
        #expect(cursor.takeDue(now: t0) == nil)
    }

    @Test func retargetWhileAwaitingConfirmSupersedes() {
        let cursor = WatchSharedCursor()
        _ = cursor.propose(target: 12)
        _ = cursor.takeDue(now: t0)
        #expect(cursor.propose(target: 8))           // crown kept turning
        #expect(cursor.takeDue(now: t0 + 1) == 8)
        // The old target's confirmation no longer matters:
        #expect(cursor.observe(hostIndex: 12, now: t0 + 2) == .waiting)
        #expect(cursor.observe(hostIndex: 8, now: t0 + 2) == .confirmed)
    }

    @Test func peekBufferLooksUpByHostIndex() {
        let buffer = WatchPeekBuffer()
        var a = WatchSnapshotTests.makeSnapshot()
        a.hostMoveIndex = 3
        var b = WatchSnapshotTests.makeSnapshot()
        b.blackStones.append("K10")
        b.hostMoveIndex = 4
        buffer.ingest(a); buffer.ingest(b)
        #expect(buffer.entry(forHostIndex: 3)?.hostMoveIndex == 3)
        #expect(buffer.entry(forHostIndex: 4)?.hostMoveIndex == 4)
        #expect(buffer.entry(forHostIndex: 9) == nil)
    }
}
```

(`WatchSnapshotTests.makeSnapshot()` is `static` in the same module’s test target — reuse it; if access proves awkward, inline a local fixture.)

- [ ] **Step 2: Register in pbxproj; run** → expected FAIL.

- [ ] **Step 3: Implement the state machine.** Create `WatchSharedCursor.swift`:

```swift
import Foundation
import Observation

/// State machine for the v1.1 shared cursor: the Crown proposes a host
/// mainline index; after a debounce the target is sent to the iPhone; the
/// cursor then waits for a snapshot whose hostMoveIndex confirms it (or a
/// timeout). Pure transitions — the watch app owns the actual timers and
/// WCSession traffic — so this is unit-testable off-device.
@Observable
@MainActor
public final class WatchSharedCursor {
    /// Crown settle time before a goTo is sent.
    public static let debounce: TimeInterval = 0.3
    /// How long a sent goTo may wait for its confirming frame.
    public static let confirmTimeout: TimeInterval = 5.0

    public enum Observation: Equatable, Sendable {
        case confirmed, waiting, timedOut
    }

    private enum Phase: Equatable {
        case idle
        case debouncing(target: Int)
        case awaitingConfirm(target: Int, sentAt: Date)
    }
    private var phase: Phase = .idle

    public init() {}

    public var pendingTarget: Int? {
        switch phase {
        case .idle: return nil
        case .debouncing(let t), .awaitingConfirm(let t, _): return t
        }
    }

    /// Crown moved. Returns true when the caller should (re)start its
    /// debounce timer (a repeat of the same debouncing target does not).
    public func propose(target: Int) -> Bool {
        if case .debouncing(let t) = phase, t == target { return false }
        phase = .debouncing(target: target)
        return true
    }

    /// Debounce fired: the target to send now, or nil if superseded/absent.
    /// Moves to awaitingConfirm.
    public func takeDue(now: Date) -> Int? {
        guard case .debouncing(let target) = phase else { return nil }
        phase = .awaitingConfirm(target: target, sentAt: now)
        return target
    }

    /// A snapshot frame arrived (or the clock ticked). nil = nothing pending.
    public func observe(hostIndex: Int?, now: Date) -> Observation? {
        guard case .awaitingConfirm(let target, let sentAt) = phase else {
            if case .debouncing = phase { return .waiting }
            return nil
        }
        if hostIndex == target { phase = .idle; return .confirmed }
        if now.timeIntervalSince(sentAt) > Self.confirmTimeout { phase = .idle; return .timedOut }
        return .waiting
    }

    /// Rejection or transport failure: forget the pending target.
    public func abandon() { phase = .idle }
}
```

Add to `WatchPeekBuffer`:

```swift
    /// Latest cached frame for a host mainline index — the shared-cursor
    /// render cache (instant optimistic board while the iPhone catches up).
    public func entry(forHostIndex index: Int) -> WatchSnapshot? {
        entries.last(where: { $0.hostMoveIndex == index })
    }
```

- [ ] **Step 4: Run** `WatchSharedCursorTests` → PASS.

- [ ] **Step 5: Wire the model.** In `WatchLiveModel.swift` add state + the command channel:

```swift
    let cursor = WatchSharedCursor()
    private(set) var isReachable = false
    /// Transient user-facing rejection/failure banner text (auto-clears).
    private(set) var rejectionMessage: String?
    /// True while a play command awaits its reply (debounces double-taps).
    private(set) var playPending = false
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var rejectionClearTask: Task<Void, Never>?

    /// The write path is usable: fresh frames, phone reachable for
    /// sendMessage, and a v1.1 host that currently allows navigation.
    var sharedCursorAvailable: Bool {
        !isStale && isReachable
            && latest?.canScrub == true
            && latest?.hostMoveIndex != nil
            && latest?.hostGameID != nil
    }

    var canPlayNow: Bool {
        !isStale && isReachable && latest?.canPlay == true && latest?.hostGameID != nil
    }

    var cursorPendingTarget: Int? { cursor.pendingTarget }

    /// Crown moved to `target` (host mainline index). Debounced goTo.
    func scrub(to target: Int) {
        guard sharedCursorAvailable else { return }
        // Already there and nothing in flight → no-op (also swallows the
        // programmatic crown resyncs the page performs).
        if target == latest?.hostMoveIndex, cursor.pendingTarget == nil { return }
        guard cursor.propose(target: target) else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(WatchSharedCursor.debounce))
            guard !Task.isCancelled else { return }
            self?.sendPendingGoTo()
        }
    }

    private func sendPendingGoTo() {
        guard let gameID = latest?.hostGameID,
              let target = cursor.takeDue(now: Date()) else { return }
        send(WatchCommand(kind: .goTo, gameID: gameID, targetIndex: target))
    }

    func playCandidate(vertex: String) {
        guard canPlayNow, let s = latest, let gameID = s.hostGameID, !playPending else { return }
        playPending = true
        send(WatchCommand(kind: .play, gameID: gameID, vertex: vertex,
                          toMove: s.toMove, boundIndex: s.hostMoveIndex))
    }

    private func send(_ command: WatchCommand) {
        guard let data = try? command.encodedData() else { return }
        WCSession.default.sendMessage(
            [WatchCommand.messageKey: data],
            replyHandler: { reply in
                // Extract Sendable Data before hopping (house pattern).
                let replyData = reply[WatchCommandReply.messageKey] as? Data
                Task { @MainActor in self.handleReply(replyData, for: command.kind) }
            },
            errorHandler: { error in
                let message = error.localizedDescription
                Task { @MainActor in self.handleTransportFailure(message, for: command.kind) }
            })
    }

    private func handleReply(_ data: Data?, for kind: WatchCommand.Kind) {
        if kind == .play { playPending = false }
        guard let data, let reply = try? WatchCommandReply.decode(data) else {
            handleTransportFailure("Bad reply from iPhone", for: kind)
            return
        }
        if reply.accepted {
            // goTo: confirmation arrives as the next frame (cursor.observe in
            // ingest). play: the move lands as a position-change frame.
            if kind == .play { WKInterfaceDevice.current().play(.success) }
        } else {
            if kind == .goTo { cursor.abandon() }
            WKInterfaceDevice.current().play(.failure)
            showRejection(reply.reason ?? "Rejected by iPhone")
        }
    }

    private func handleTransportFailure(_ message: String, for kind: WatchCommand.Kind) {
        if kind == .play { playPending = false }
        if kind == .goTo { cursor.abandon() }
        WKInterfaceDevice.current().play(.failure)
        showRejection(message)
    }

    private func showRejection(_ text: String) {
        rejectionMessage = text
        rejectionClearTask?.cancel()
        rejectionClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.rejectionMessage = nil
        }
    }
```

In `ingest(_:receivedAt:)`, after `peek.ingest(snapshot)` add:

```swift
        if cursor.observe(hostIndex: snapshot.hostMoveIndex, now: Date()) == .timedOut {
            showRejection("iPhone didn't respond")
        }
```

Reachability plumbing — in `activate()` nothing changes; add the delegate method and seed the flag in `activationDidCompleteWith` (read the Bool BEFORE hopping — WCSession is not Sendable):

```swift
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.isReachable = reachable }
    }
```

and inside the existing `activationDidCompleteWith`, alongside the data read:

```swift
        let reachable = session.isReachable
```

then inside its `Task { @MainActor in ... }` block: `self.isReachable = reachable` (before the existing `guard`, so it always runs).

- [ ] **Step 6: Rework `WatchBoardPage`** — full replacement:

```swift
import SwiftUI
import KataGoGameStore

struct WatchBoardPage: View {
    @Environment(WatchLiveModel.self) private var model
    @State private var crownIndex: Double = 0

    var body: some View {
        let peek = model.peek
        let cursorMode = model.sharedCursorAvailable
        let shown = cursorMode ? cursorFrame : peek.current
        let previous = (!cursorMode && peek.viewIndex > 0) ? peek.entries[peek.viewIndex - 1] : nil

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
        .overlay(alignment: .top) { statusPill }
        .focusable()
        .digitalCrownRotation($crownIndex,
                              from: 0, through: crownUpperBound,
                              by: 1, sensitivity: .medium,
                              isContinuous: false, isHapticFeedbackEnabled: true)
        .onChange(of: crownIndex) { _, newValue in
            let target = Int(newValue.rounded())
            if model.sharedCursorAvailable {
                model.scrub(to: target)
            } else {
                model.peek.viewIndex = target
            }
        }
        .onChange(of: peek.viewIndex, initial: true) { _, newValue in
            // Ring mode: keep the crown in sync when ingest re-pins live.
            guard !model.sharedCursorAvailable else { return }
            if Int(crownIndex.rounded()) != newValue { crownIndex = Double(newValue) }
        }
        .onChange(of: model.latest?.hostMoveIndex) { _, newIndex in
            // Cursor mode: follow host-side navigation (e.g. phone buttons)
            // while no watch-initiated target is pending.
            guard model.sharedCursorAvailable, model.cursorPendingTarget == nil,
                  let newIndex else { return }
            if Int(crownIndex.rounded()) != newIndex { crownIndex = Double(newIndex) }
        }
        .onChange(of: model.sharedCursorAvailable, initial: true) { _, available in
            // Mode flip: re-anchor the crown in the new coordinate space.
            crownIndex = available
                ? Double(model.latest?.hostMoveIndex ?? 0)
                : Double(model.peek.viewIndex)
        }
    }

    private var crownUpperBound: Double {
        model.sharedCursorAvailable
            ? Double(model.latest?.hostMoveCount ?? 0)
            : Double(max(model.peek.entries.count - 1, 0))
    }

    /// Optimistic render for the crown's target: the live frame when the
    /// crown is at the host position, else the freshest cached frame for that
    /// index, else the live frame while the iPhone catches up.
    private var cursorFrame: WatchSnapshot? {
        guard let latest = model.latest else { return nil }
        let target = Int(crownIndex.rounded())
        if target == latest.hostMoveIndex { return latest }
        return model.peek.entry(forHostIndex: target) ?? latest
    }

    @ViewBuilder private var statusPill: some View {
        let peek = model.peek
        if model.isStale, let at = model.receivedAt ?? model.latest.map(\.hostTimestamp) {
            Label { Text("Stale \(at, style: .relative)") }
                icon: { Image(systemName: "wifi.slash") }
                .font(.caption2).padding(3)
                .background(.red.opacity(0.85), in: Capsule())
        } else if model.sharedCursorAvailable {
            if let target = model.cursorPendingTarget {
                Text("→ \(target)/\(model.latest?.hostMoveCount ?? 0)")
                    .font(.caption2).padding(3)
                    .background(.orange.opacity(0.85), in: Capsule())
            } else if let index = model.latest?.hostMoveIndex,
                      let count = model.latest?.hostMoveCount, index < count {
                Text("\(index)/\(count)")
                    .font(.caption2).padding(3)
                    .background(.orange.opacity(0.85), in: Capsule())
                    .onTapGesture { model.scrub(to: count) }
            }
        } else if !peek.isLive {
            Text("\(peek.movesBehindLive) behind live")
                .font(.caption2).padding(3)
                .background(.orange.opacity(0.85), in: Capsule())
                .onTapGesture { peek.viewIndex = peek.entries.count - 1 }
        }
    }

    private func scoreText(_ scoreLeadBlack: Float) -> String {
        scoreLeadBlack >= 0 ? String(format: "B+%.1f", scoreLeadBlack)
                            : String(format: "W+%.1f", -scoreLeadBlack)
    }
}
```

- [ ] **Step 7: Build the watch scheme** → grep `BUILD SUCCEEDED`; confirm zero new warnings. Run full `WatchSharedCursorTests` + `WatchPeekBufferTests` again.
- [ ] **Step 8: Commit** — `feat(watch): shared cursor — Crown drives the iPhone board (v0 peek fallback)`

---

### Task 6: Watch Play UI

**Files:**
- Modify: `KataGo Anytime Watch/WatchMovesPage.swift`
- Modify: `KataGo Anytime Watch/WatchRootView.swift`

**Interfaces:**
- Consumes: `model.canPlayNow`, `model.playPending`, `model.playCandidate(vertex:)`, `model.rejectionMessage`, `latest.isHumanTurn` (Task 5), `WatchSnapshot.candidates`.

- [ ] **Step 1: Rework `WatchMovesPage`** — full replacement:

```swift
import SwiftUI
import KataGoGameStore

struct WatchMovesPage: View {
    @Environment(WatchLiveModel.self) private var model
    private let rankColors: [Color] = [.green, .yellow, .orange]

    var body: some View {
        let live = model.latest
        List {
            if let live, live.analysisRunning, live.isHumanTurn == false {
                // Spec: when the side to move is AI-controlled the carousel is
                // replaced — no Play affordance, no genmove race.
                Label("AI is playing", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            } else if let live, live.analysisRunning, !live.candidates.isEmpty {
                ForEach(Array(live.candidates.prefix(3).enumerated()),
                        id: \.element.vertex) { rank, candidate in
                    if model.canPlayNow {
                        Button {
                            model.playCandidate(vertex: candidate.vertex)
                        } label: {
                            row(rank: rank, candidate: candidate)
                        }
                        .disabled(model.playPending)
                    } else {
                        row(rank: rank, candidate: candidate)
                    }
                }
            } else {
                Text("Analysis off").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Top Moves")
    }

    private func row(rank: Int, candidate: WatchSnapshot.Candidate) -> some View {
        HStack {
            Circle().fill(rankColors[min(rank, rankColors.count - 1)])
                .frame(width: 8, height: 8)
            Text(candidate.vertex).font(.system(.body, design: .monospaced)).bold()
            if model.canPlayNow {
                Image(systemName: "hand.tap").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text(String(format: "%.0f%%", candidate.winrate * 100)).font(.caption)
                Text(String(format: "%+.1f", candidate.scoreLead)).font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
```

- [ ] **Step 2: Global rejection banner** in `WatchRootView` (visible from both pages):

```swift
        } else {
            TabView {
                WatchBoardPage()
                WatchMovesPage()
            }
            .tabViewStyle(.verticalPage)
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
```

- [ ] **Step 3: Build the watch scheme** → `BUILD SUCCEEDED`, zero new warnings.
- [ ] **Step 4: Commit** — `feat(watch): tap-to-play candidates under the hard-block gate + rejection banner`

---

### Task 7: Full gates, docs, ship checklist

- [ ] **Step 1: Full test suite** — `xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17'` → grep `** TEST SUCCEEDED **`. Expect all prior 589 + new suites.
- [ ] **Step 2: Build all five schemes** (iOS sim, visionOS sim, macOS, tvOS sim, watchOS sim — commands in CLAUDE.md) → grep each for `BUILD SUCCEEDED`.
- [ ] **Step 3: Docs.**
  - Spec `docs/superpowers/specs/2026-07-04-watchos-companion-design.md`: under "### v1.1 — Write path", add a status line: `**Status: implemented — see docs/superpowers/plans/2026-07-04-watchos-companion-v1.1.md.**`
  - CLAUDE.md: in the scheme list prose, update the watch parenthetical from "companion live mirror" to "companion live mirror + remote play" (both occurrences: Build Commands intro and Platform Support if worded there).
- [ ] **Step 4: Commit** — `docs(watch): v1.1 write path status + CLAUDE.md wording`
- [ ] **Step 5: Report the hardware QA checklist** (user-run — WCSession has no simulator story; do NOT push, Xcode Cloud spacing):
  1. Scrub the Crown on the watch board page with analysis running → the **iPhone board follows** (~0.3 s debounce + engine replay); pill shows `n/N` while behind, `→ n/N` while in flight.
  2. Navigate on the iPhone → watch crown/board follow without sending anything back (no feedback loop).
  3. Tap a candidate on the Moves page (unlocked game, at head, human turn) → move plays on iPhone, success haptic, board updates both sides.
  4. Rejection cases each show the red banner + failure haptic, and change nothing: locked game (Play hidden — check no button renders), scrubbed-back host (Play hidden), branch active on phone (crown falls back to local peek), phone app backgrounded (goTo rejected "Open the app on iPhone").
  5. AI-vs-human game, AI's turn → Moves page shows "AI is playing"; crown falls back to local peek during the AI turn.
  6. Human-profile game (e.g. 9d): after a watch-driven scrub + resume, confirm analysis is NOT capped at 400 visits (visits keep climbing on the phone overlay) — the Task 1 invariant, live.
  7. v0 regression sweep: stale badge on phone lock, cold-relaunch cached view, complication still updates.

## Verification (end-to-end)

- Unit: Tasks 1–5 suites (`GtpCommandBuilderTests`, `WatchSnapshotTests`, `WatchCommandTests`, `WatchHostGateTests`, `WatchSnapshotBuilderTests`, `WatchCommandHandlerTests`, `WatchSharedCursorTests`) + full suite in Task 7.
- Build: all five schemes, literal-string-verified.
- Hardware: Task 7 Step 5 checklist (user-run; the write path is WCSession-real-device-only).
- Execution: subagent-driven-development (fresh implementer + reviewer per task, fable final whole-branch review), ledger at `.superpowers/sdd/progress.md` — same machinery as v0.
