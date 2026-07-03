# Deep Analysis Report Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An on-demand, per-position "Deep Analysis Report" sheet (iOS/visionOS/macOS) that probes the engine (~5 s) for per-candidate ownership deltas, tenuki follow-ups, a pass comparison, and PVs, then streams a FoundationModels narrative over the deterministic facts.

**Architecture:** All feature logic lives in the `KataGoUICore` SwiftPM package: extended `AnalysisLineParser` (pv, movesOwnership, rootInfo, raw ownership), a `ReportCollector` that attributes engine reply lines to probe stages via a FIFO of sent commands, a `DeepReportGenerator` that serializes probes over the existing single GTP stream (installed as `GameSession.lineObserver`), and a shared `DeepReportView` sheet. Entry points are two small edits (iOS `PlusMenuView`, macOS Game menu + `MainWindowController`).

**Tech Stack:** Swift 6.2, SwiftUI, Swift Testing (`@Test`/`#expect`), FoundationModels (canImport-guarded), GTP over `KataGoEngineIO`.

**Design spec:** `docs/superpowers/specs/2026-07-03-deep-analysis-report-design.md` (approved).

## Global Constraints

- Platforms: iOS 26+, visionOS 26+, macOS 26+. tvOS is EXCLUDED: report UI is never presented there; all FoundationModels code stays behind `#if canImport(FoundationModels)`.
- SwiftData `@Model` schema (Config/GameRecord) is FROZEN (CloudKit). No new stored model fields. Report persistence only via the existing `gameRecord.comments: [Int: String]?` dictionary.
- New source files go in the `KataGoUICore` package (`ios/KataGo iOS/KataGoUICore/Sources/...`) — NO pbxproj registration needed. New TEST files go in `ios/KataGo iOS/KataGo iOSTests/` and MUST be registered in project.pbxproj under target `KataGo AnytimeTests` via the `xcodeproj` Ruby gem (no synchronized groups).
- Tests are Swift Testing style and run ONLY on iOS Simulator:
  `xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17'`
  Scope to one suite with `-only-testing:"KataGo AnytimeTests/<SuiteName>"` (suite level only; use the TARGET name `KataGo AnytimeTests`).
- Engine invariants: `GameSession.run()` is the ONLY reader; `lineObserver` is the ONLY out-of-band tap. ANY command cancels an in-flight analyze. `kata-set-param maxVisits` is sticky. Probes use `kata-analyze` ONLY (never the search-analyze family — no stray `play` lines). The shipped cfg sets `reportAnalysisWinratesAs = WHITE` (engine numbers are White-perspective; the parser flips to side-to-move only when constructed with `nextColor: .black`).
- GTP wire format (verified in cpp/command/gtp.cpp): normal ack = `"= <response>"` line then one empty line; analyze commands print a bare `"="` header line BEFORE streaming `info` lines (gtp.cpp:3488, 2215); a cancelled analyze prints ONE empty line (gtp.cpp:2145); errors are `"? <message>"`. `movesOwnership` (capital O) does NOT match the case-sensitive `/ownership /` regex — pinned by test, not "fixed".
- Report constants (from the spec): snapshot budget 2.0 s; pass probe 1.0 s; tenuki probes 1.0 s × 2 candidates; probe command options `interval 50 maxmoves 8`; noise thresholds = win-rate delta < 0.02, score delta < 1.0 when probe visits < 100; contested points = top 8 by |Δ|; `analysisPVLen = 15`.
- Build gates: iOS Simulator (scheme `KataGo Anytime`), visionOS Simulator (same scheme, destination `platform=visionOS Simulator,name=Apple Vision Pro`), macOS (scheme `KataGo Anytime Mac`). Working directory for builds: `ios/KataGo iOS/`.
- Every commit message ends with:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

---

### Task 1: Parser — raw ownership floats, rootInfo values, movesOwnership pin

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Session/AnalysisLineParser.swift`
- Create: `ios/KataGo iOS/KataGo iOSTests/AnalysisLineParserReportTests.swift`
- Modify: `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj` (via Ruby gem, test file registration)

**Interfaces:**
- Consumes: existing `AnalysisLineParser` (init `(boardWidth:boardHeight:nextColor:)`, method `parse(message:) -> ParsedAnalysis`), existing `ParsedAnalysis { info: [BoardPoint: AnalysisInfo], ownershipUnits: [OwnershipUnit] }`.
- Produces (later tasks rely on these exact names):
  - `public struct ParsedRootInfo { public let visits: Int; public let winrate: Float; public let scoreLead: Float }`
  - `ParsedAnalysis` gains `public let rawOwnership: [Float]` (undigitized mean grid, `[]` when absent) and `public let rootInfo: ParsedRootInfo?`.
  - Perspective: `winrate`/`scoreLead` in `ParsedRootInfo` are flipped to Black's perspective when `nextColor == .black`, exactly like the per-candidate fields. `rawOwnership` is NEVER flipped (always as-emitted, White-positive under the shipped cfg).

- [ ] **Step 1: Register the new test file in the Xcode project**

Create the (empty for now) test file and register it. From the repo root:

```bash
touch "ios/KataGo iOS/KataGo iOSTests/AnalysisLineParserReportTests.swift"
```

Then run this Ruby script (requires `gem install xcodeproj` if missing):

```ruby
# save as /tmp/add_test_file.rb and run: ruby /tmp/add_test_file.rb AnalysisLineParserReportTests.swift
require 'xcodeproj'
file_name = ARGV[0]
project = Xcodeproj::Project.open('ios/KataGo iOS/KataGo Anytime.xcodeproj')
target = project.targets.find { |t| t.name == 'KataGo AnytimeTests' }
group = project.main_group.find_subpath('KataGo iOSTests', false)
raise 'group not found' unless group
raise 'target not found' unless target
if group.files.none? { |f| f.path == file_name }
  ref = group.new_reference(file_name)
  target.add_file_references([ref])
end
project.save
puts "registered #{file_name}"
```

Expected: `registered AnalysisLineParserReportTests.swift`.

- [ ] **Step 2: Write the failing tests**

Full contents of `ios/KataGo iOS/KataGo iOSTests/AnalysisLineParserReportTests.swift`:

```swift
//
//  AnalysisLineParserReportTests.swift
//  KataGo AnytimeTests
//
//  Parser extensions for the Deep Analysis Report: raw ownership floats,
//  rootInfo winrate/scoreLead, and the movesOwnership no-collision pin.
//

import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

struct AnalysisLineParserReportTests {
    // 2x2 board fixtures. Ownership order: y from height-1 down, x 0..<width.
    private let base = "info move A1 visits 10 winrate 0.55 scoreLead 2.5 utilityLcb 0.3 order 0 pv A1"

    @Test func rawOwnershipIsUndigitized() {
        let parser = AnalysisLineParser(boardWidth: 2, boardHeight: 2, nextColor: .white)
        let msg = base + " ownership 0.13 -0.87 0.42 -0.11 ownershipStdev 0.0 0.0 0.0 0.0"
        let r = parser.parse(message: msg)
        #expect(r.rawOwnership.count == 4)
        #expect(abs(r.rawOwnership[0] - 0.13) < 1e-4)   // NOT rounded to 1/5 steps
        #expect(abs(r.rawOwnership[1] - (-0.87)) < 1e-4)
        // Digitized units still produced unchanged alongside.
        #expect(r.ownershipUnits.count == 4)
    }

    @Test func rawOwnershipEmptyWhenAbsent() {
        let parser = AnalysisLineParser(boardWidth: 2, boardHeight: 2, nextColor: .white)
        let r = parser.parse(message: base)
        #expect(r.rawOwnership.isEmpty)
    }

    @Test func rawOwnershipNotFlippedForBlack() {
        // Perspective contract: rawOwnership stays as-emitted even when Black moves.
        let parser = AnalysisLineParser(boardWidth: 2, boardHeight: 2, nextColor: .black)
        let msg = base + " ownership 0.13 -0.87 0.42 -0.11 ownershipStdev 0.0 0.0 0.0 0.0"
        let r = parser.parse(message: msg)
        #expect(abs(r.rawOwnership[0] - 0.13) < 1e-4)
    }

    @Test func rootInfoParsedWhitePerspective() {
        let parser = AnalysisLineParser(boardWidth: 2, boardHeight: 2, nextColor: .white)
        let msg = base + " rootInfo visits 512 utility 0.2 winrate 0.61 scoreMean 3.1 scoreStdev 10.0 scoreLead 3.1 scoreSelfplay 3.4 weight 500.0"
        let r = parser.parse(message: msg)
        #expect(r.rootInfo?.visits == 512)
        #expect(abs((r.rootInfo?.winrate ?? 0) - 0.61) < 1e-4)
        #expect(abs((r.rootInfo?.scoreLead ?? 0) - 3.1) < 1e-4)
    }

    @Test func rootInfoFlippedForBlack() {
        let parser = AnalysisLineParser(boardWidth: 2, boardHeight: 2, nextColor: .black)
        let msg = base + " rootInfo visits 512 utility 0.2 winrate 0.61 scoreMean 3.1 scoreStdev 10.0 scoreLead 3.1 scoreSelfplay 3.4 weight 500.0"
        let r = parser.parse(message: msg)
        #expect(abs((r.rootInfo?.winrate ?? 0) - 0.39) < 1e-4)   // 1 - 0.61
        #expect(abs((r.rootInfo?.scoreLead ?? 0) - (-3.1)) < 1e-4)
    }

    @Test func rootInfoNilWhenAbsent() {
        let parser = AnalysisLineParser(boardWidth: 2, boardHeight: 2, nextColor: .white)
        #expect(parser.parse(message: base).rootInfo == nil)
    }

    @Test func movesOwnershipDoesNotCorruptRootOwnership() {
        // PIN: 'movesOwnership' (capital O) must not satisfy the case-sensitive
        // /ownership / regex. The root grid must win, undigitized values intact.
        let parser = AnalysisLineParser(boardWidth: 2, boardHeight: 2, nextColor: .white)
        let msg = base + " movesOwnership 0.9 0.9 0.9 0.9"
                       + " rootInfo visits 512 utility 0.2 winrate 0.61 scoreMean 3.1 scoreStdev 10.0 scoreLead 3.1 scoreSelfplay 3.4 weight 500.0"
                       + " ownership 0.13 -0.87 0.42 -0.11 ownershipStdev 0.0 0.0 0.0 0.0"
        let r = parser.parse(message: msg)
        #expect(abs(r.rawOwnership[0] - 0.13) < 1e-4)   // root grid, not 0.9
        #expect(r.ownershipUnits.count == 4)
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/AnalysisLineParserReportTests"
```

Expected: BUILD FAILURE — `ParsedAnalysis` has no member `rawOwnership` / `rootInfo` (compile error is the failure mode here since the fields don't exist yet).

- [ ] **Step 4: Implement the parser extensions**

In `AnalysisLineParser.swift`, replace the `ParsedAnalysis` struct at the top:

```swift
/// The analysis state parsed from one `kata-analyze` output message.
public struct ParsedAnalysis {
    public let info: [BoardPoint: AnalysisInfo]
    public let ownershipUnits: [OwnershipUnit]
    /// Undigitized root ownership means as emitted by the engine (White-positive
    /// under the shipped `reportAnalysisWinratesAs = WHITE` cfg). NEVER flipped
    /// by `nextColor` — consumers needing another perspective convert themselves.
    /// Empty when the message carries no root ownership grid.
    public let rawOwnership: [Float]
    /// The `rootInfo` block's search totals, if present. `winrate`/`scoreLead`
    /// follow the same perspective flip as the per-candidate fields.
    public let rootInfo: ParsedRootInfo?
}

/// Root-level search values from a kata-analyze `rootInfo` block.
public struct ParsedRootInfo {
    public let visits: Int
    public let winrate: Float
    public let scoreLead: Float
}
```

Replace `parse(message:)`:

```swift
    public func parse(message: String) -> ParsedAnalysis {
        let splitData = message.split(separator: "info")
        let infoDicts = splitData.compactMap { extractAnalysisInfo(dataLine: String($0)) }
        let info = infoDicts.reduce(into: [BoardPoint: AnalysisInfo]()) { acc, dict in
            acc.merge(dict) { current, _ in current }   // first wins on collision
        }
        let lastMessage = splitData.last.map(String.init) ?? ""
        let rawOwnership = extractOwnershipMean(message: lastMessage)
        let ownershipUnits = extractOwnershipUnits(lastData: splitData.last)
        return ParsedAnalysis(info: info,
                              ownershipUnits: ownershipUnits,
                              rawOwnership: rawOwnership,
                              rootInfo: extractRootInfo(message: message))
    }
```

Add the rootInfo extractor (place after `matchUtilityLcbPattern`). `rootInfo` has a capital I, so the lowercase `"info"` split leaves it intact in the last segment; match on the WHOLE message like `Analysis.parseRootVisits` does:

```swift
    // MARK: - Root info

    /// Parses the `rootInfo` block's visits/winrate/scoreLead. Field order is
    /// fixed by the engine (gtp.cpp: visits, utility, winrate, scoreMean,
    /// scoreStdev, scoreLead, ...). Perspective-flipped like candidate fields.
    private func extractRootInfo(message: String) -> ParsedRootInfo? {
        let pattern = /rootInfo visits (\d+) utility [-\d.eE]+ winrate ([-\d.eE]+) scoreMean [-\d.eE]+ scoreStdev [-\d.eE]+ scoreLead ([-\d.eE]+)/
        guard let match = message.firstMatch(of: pattern),
              let visits = Int(match.1),
              let rawWinrate = Float(match.2),
              let rawScoreLead = Float(match.3) else { return nil }
        let winrate = nextColor == .black ? 1.0 - rawWinrate : rawWinrate
        let scoreLead = nextColor == .black ? -rawScoreLead : rawScoreLead
        return ParsedRootInfo(visits: visits, winrate: winrate, scoreLead: scoreLead)
    }
```

Note `extractOwnershipMean(message:)` and `extractOwnershipUnits(lastData:)` already exist unchanged — `parse` now calls `extractOwnershipMean` directly to surface the raw grid. No change to `extractOwnershipUnits`.

- [ ] **Step 5: Run the new suite and the pre-existing parser suite**

```bash
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/AnalysisLineParserReportTests" -only-testing:"KataGo AnytimeTests/AnalysisLineParserTests"
```

Expected: TEST SUCCEEDED, both suites pass (the old suite proves no regression).

- [ ] **Step 6: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Session/AnalysisLineParser.swift" "ios/KataGo iOS/KataGo iOSTests/AnalysisLineParserReportTests.swift" "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(report): parser surfaces raw ownership floats and rootInfo values"
```

---

### Task 2: Parser — per-candidate pv and movesOwnership

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Session/AnalysisLineParser.swift`
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/KataGoModel.swift` (AnalysisInfo, ~line 194)
- Modify: `ios/KataGo iOS/KataGo iOSTests/AnalysisLineParserReportTests.swift` (append tests)

**Interfaces:**
- Consumes: Task 1's `ParsedAnalysis`.
- Produces: `AnalysisInfo` gains `public let pv: [String]` (GTP vertex strings, `[]` default) and `public let movesOwnership: [Float]?` (`nil` default) with backward-compatible init defaults. Existing callers (`GobanState`, tests) compile unchanged.

- [ ] **Step 1: Append the failing tests**

Append inside `struct AnalysisLineParserReportTests`:

```swift
    @Test func pvParsedAsVertexList() {
        let parser = AnalysisLineParser(boardWidth: 19, boardHeight: 19, nextColor: .white)
        let msg = "info move Q16 visits 10 winrate 0.55 scoreLead 2.5 utilityLcb 0.3 order 0 pv Q16 D4 pass C3 movesOwnership 0.1"
        let info = parser.parse(message: msg).info[BoardPoint(x: 15, y: 15)]
        #expect(info?.pv == ["Q16", "D4", "pass", "C3"])   // stops at movesOwnership
    }

    @Test func pvEmptyWhenAbsent() {
        let parser = AnalysisLineParser(boardWidth: 19, boardHeight: 19, nextColor: .white)
        let msg = "info move Q16 visits 10 winrate 0.55 scoreLead 2.5 utilityLcb 0.3"
        #expect(parser.parse(message: msg).info[BoardPoint(x: 15, y: 15)]?.pv == [])
    }

    @Test func movesOwnershipParsedPerCandidate() {
        let parser = AnalysisLineParser(boardWidth: 2, boardHeight: 2, nextColor: .white)
        let msg = "info move A1 visits 10 winrate 0.55 scoreLead 2.5 utilityLcb 0.3 pv A1 movesOwnership 0.9 -0.5 0.25 -1.0 "
                + "info move B2 visits 5 winrate 0.5 scoreLead 1.0 utilityLcb 0.1 pv B2 movesOwnership 0.1 0.2 0.3 0.4"
        let r = parser.parse(message: msg)
        let a1 = r.info[BoardPoint(x: 0, y: 0)]
        let b2 = r.info[BoardPoint(x: 1, y: 1)]
        #expect(a1?.movesOwnership?.count == 4)
        #expect(abs((a1?.movesOwnership?[1] ?? 0) - (-0.5)) < 1e-4)
        #expect(abs((b2?.movesOwnership?[0] ?? 0) - 0.1) < 1e-4)
    }

    @Test func movesOwnershipNilWhenAbsentOrWrongCount() {
        let parser = AnalysisLineParser(boardWidth: 2, boardHeight: 2, nextColor: .white)
        let absent = "info move A1 visits 10 winrate 0.55 scoreLead 2.5 utilityLcb 0.3"
        #expect(parser.parse(message: absent).info[BoardPoint(x: 0, y: 0)]?.movesOwnership == nil)
        let short = "info move A1 visits 10 winrate 0.55 scoreLead 2.5 utilityLcb 0.3 movesOwnership 0.9 0.9"
        #expect(parser.parse(message: short).info[BoardPoint(x: 0, y: 0)]?.movesOwnership == nil)
    }
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/AnalysisLineParserReportTests"
```

Expected: BUILD FAILURE — `AnalysisInfo` has no member `pv`.

- [ ] **Step 3: Extend AnalysisInfo (KataGoModel.swift ~line 194)**

Replace the `AnalysisInfo` struct:

```swift
public struct AnalysisInfo {
    public let visits: Int
    public let winrate: Float
    public let scoreLead: Float
    public let utilityLcb: Float
    /// Principal variation as GTP vertex strings ("Q16", "pass"). Depth is
    /// capped by the cfg's `analysisPVLen`. Empty when not present in the line.
    public let pv: [String]
    /// Per-candidate ownership grid from this move's search subtree (same
    /// emission order and perspective as the root grid). Only present when the
    /// analyze command requested `movesOwnership true`; nil otherwise.
    public let movesOwnership: [Float]?

    public init(visits: Int, winrate: Float, scoreLead: Float, utilityLcb: Float,
                pv: [String] = [], movesOwnership: [Float]? = nil) {
        self.visits = visits
        self.winrate = winrate
        self.scoreLead = scoreLead
        self.utilityLcb = utilityLcb
        self.pv = pv
        self.movesOwnership = movesOwnership
    }
}
```

- [ ] **Step 4: Extend the parser's per-segment extraction**

In `AnalysisLineParser.swift`, replace the `if let point, ...` return inside `extractAnalysisInfo(dataLine:)`:

```swift
        if let point, let visits, let winrate, let scoreLead, let utilityLcb {
            // Winrate is 0.5 when visits = 0; skip those to keep the win-rate bar stable.
            guard visits > 0 || winrate != 0.5 else { return nil }
            return [point: AnalysisInfo(visits: visits,
                                        winrate: winrate,
                                        scoreLead: scoreLead,
                                        utilityLcb: utilityLcb,
                                        pv: extractPV(dataLine: dataLine),
                                        movesOwnership: extractMovesOwnership(dataLine: dataLine))]
        }
        return nil
```

Add the two extractors (place before `// MARK: - Ownership`):

```swift
    // MARK: - Per-candidate extras

    /// Vertices after the `pv` keyword, token-scanned until the first token
    /// that is neither "pass" nor a vertex ("Q16", "AB12" two-letter columns).
    /// Token scanning (not a greedy regex) so trailing keywords like
    /// `movesOwnership` or `rootInfo` terminate the list.
    private func extractPV(dataLine: String) -> [String] {
        let tokens = dataLine.split(separator: " ")
        guard let pvIndex = tokens.firstIndex(of: "pv") else { return [] }
        var pv: [String] = []
        for token in tokens[(pvIndex + 1)...] {
            let isVertex = token.wholeMatch(of: /[A-Za-z]{1,2}\d{1,2}/) != nil
            if token == "pass" || isVertex {
                pv.append(String(token))
            } else {
                break
            }
        }
        return pv
    }

    /// This candidate's subtree ownership grid, when `movesOwnership true` was
    /// requested. Count-validated like the root grid; nil when absent/mismatched.
    private func extractMovesOwnership(dataLine: String) -> [Float]? {
        let values = floats(in: dataLine, pattern: /movesOwnership ([-\d\s.eE]+)/)
        return values.isEmpty ? nil : values
    }
```

- [ ] **Step 5: Run the report suite + old parser suite + full unit sweep**

```bash
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17'
```

Expected: TEST SUCCEEDED (full unit run — `AnalysisInfo` is widely consumed; the default-argument init must not break `GobanState` persistence or other suites).

- [ ] **Step 6: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Session/AnalysisLineParser.swift" "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/KataGoModel.swift" "ios/KataGo iOS/KataGo iOSTests/AnalysisLineParserReportTests.swift"
git commit -m "feat(report): parse per-candidate pv and movesOwnership"
```

---

### Task 3: Config — analysisPVLen 15

**Files:**
- Modify: `ios/KataGo iOS/Resources/default_gtp.cfg` (line ~71)

**Interfaces:**
- Produces: every analyze response app-wide now carries up-to-15-move PVs. The parser tolerates them (Task 2); nothing else reads `pv`.

- [ ] **Step 1: Edit the cfg**

In `ios/KataGo iOS/Resources/default_gtp.cfg`, change:

```
analysisPVLen = 1
```

to:

```
analysisPVLen = 15
```

- [ ] **Step 2: Full unit sweep (the cfg affects every kata-analyze consumer)**

```bash
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17'
```

Expected: TEST SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add "ios/KataGo iOS/Resources/default_gtp.cfg"
git commit -m "feat(report): raise analysisPVLen to 15 for principal variations"
```

---

### Task 4: Report data model — types, perspective normalization, ownership delta, contested points

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/DeepReportModel.swift`
- Create: `ios/KataGo iOS/KataGo iOSTests/DeepReportModelTests.swift`
- Modify: `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj` (test file registration)

**Interfaces:**
- Consumes: `BoardPoint`, `PlayerColor` (existing), Task 1/2 parser outputs.
- Produces (exact names later tasks use):
  - `public enum ReportConstants` — `snapshotBudget: TimeInterval = 2.0`, `passBudget: TimeInterval = 1.0`, `tenukiBudget: TimeInterval = 1.0`, `candidateCount = 2`, `probeInterval = 50`, `probeMaxMoves = 8`, `winrateNoise: Float = 0.02`, `scoreNoise: Float = 1.0`, `lowVisitThreshold = 100`, `contestedPointCount = 8`.
  - `public enum ReportPerspective` — `static func winrate(_ whiteWinrate: Float, for side: PlayerColor) -> Float`, `static func score(_ whiteScoreLead: Float, for side: PlayerColor) -> Float`.
  - `public enum OwnershipDelta` — `static func grid(base: [Float], probe: [Float], width: Int, height: Int) -> [BoardPoint: Float]` (White-perspective probe−base per point; empty on count mismatch), `static func contestedPoints(in grid: [BoardPoint: Float], width: Int, height: Int) -> [ContestedPoint]` (top 8 by |Δ|, ties by vertex), `static func regionName(point: BoardPoint, width: Int, height: Int) -> String`.
  - Value types: `PositionSummary { winrate, scoreLead: Float, visits: Int }`, `TenukiFollowUp { vertex: String, winrate: Float, scoreLead: Float, visits: Int, pv: [String] }`, `CandidateReport { vertex: String, visits: Int, winrate: Float, scoreLead: Float, winrateDelta: Float, scoreLeadDelta: Float, pv: [String], ownershipDelta: [BoardPoint: Float], tenuki: TenukiFollowUp? }`, `ContestedPoint { point: BoardPoint, vertex: String, delta: Float, regionName: String }`, `PassComparison { punishmentVertex: String, winrate: Float, scoreLead: Float, winrateDeltaVsBest: Float, scoreLeadDeltaVsBest: Float, ownershipDelta: [BoardPoint: Float], contestedPoints: [ContestedPoint] }` — all `public struct`s with public memberwise inits, all values ALREADY normalized to the reported position's side-to-move.
  - `@Observable @MainActor public final class DeepReportModel` — `public enum Stage: Equatable { case idle, snapshot, passProbe, tenuki(Int), narrating, complete, failed(String), cancelled }`; vars `stage: Stage = .idle`, `moveNumber: Int = 0`, `sideToMove: PlayerColor = .black`, `boardWidth: Int = 19`, `boardHeight: Int = 19`, `blackVertices: [String] = []`, `whiteVertices: [String] = []`, `position: PositionSummary?`, `candidates: [CandidateReport] = []`, `passComparison: PassComparison?`, `narrative: String = ""`, `narrativeUnavailableReason: String?`, `visitsPerSecondText: String?`; computed `public var isGenerating: Bool` (true for snapshot/passProbe/tenuki/narrating).

- [ ] **Step 1: Register the test file** — `touch "ios/KataGo iOS/KataGo iOSTests/DeepReportModelTests.swift"` then `ruby /tmp/add_test_file.rb DeepReportModelTests.swift` (script from Task 1). Expected: `registered DeepReportModelTests.swift`.

- [ ] **Step 2: Write the failing tests**

Full contents of `DeepReportModelTests.swift`:

```swift
//
//  DeepReportModelTests.swift
//  KataGo AnytimeTests
//

import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

struct DeepReportModelTests {
    @Test func perspectiveConvertsWhiteValuesToSide() {
        #expect(abs(ReportPerspective.winrate(0.61, for: .white) - 0.61) < 1e-6)
        #expect(abs(ReportPerspective.winrate(0.61, for: .black) - 0.39) < 1e-6)
        #expect(abs(ReportPerspective.score(3.5, for: .white) - 3.5) < 1e-6)
        #expect(abs(ReportPerspective.score(3.5, for: .black) - (-3.5)) < 1e-6)
    }

    @Test func deltaGridSubtractsPerPoint() {
        // 2x2, emission order: (0,1),(1,1),(0,0),(1,0) — y from height-1 down.
        let base: [Float] = [0.0, 0.5, -0.5, 1.0]
        let probe: [Float] = [0.2, 0.5, -1.0, 1.0]
        let grid = OwnershipDelta.grid(base: base, probe: probe, width: 2, height: 2)
        #expect(abs((grid[BoardPoint(x: 0, y: 1)] ?? 0) - 0.2) < 1e-6)
        #expect(abs((grid[BoardPoint(x: 1, y: 1)] ?? 0) - 0.0) < 1e-6)
        #expect(abs((grid[BoardPoint(x: 0, y: 0)] ?? 0) - (-0.5)) < 1e-6)
    }

    @Test func deltaGridEmptyOnMismatch() {
        #expect(OwnershipDelta.grid(base: [0, 0], probe: [0, 0, 0, 0], width: 2, height: 2).isEmpty)
    }

    @Test func contestedPointsAreTop8ByMagnitude() {
        var grid: [BoardPoint: Float] = [:]
        for x in 0..<10 {
            grid[BoardPoint(x: x, y: 0)] = Float(x) * 0.1 - 0.5   // magnitudes 0.5 ... 0.4
        }
        let points = OwnershipDelta.contestedPoints(in: grid, width: 19, height: 19)
        #expect(points.count == 8)
        #expect(abs(points[0].delta.magnitude - 0.5) < 1e-6)      // biggest |Δ| first
        #expect(points.allSatisfy { !$0.regionName.isEmpty && !$0.vertex.isEmpty })
    }

    @Test func regionNamesFollowBoardThirds() {
        // BoardPoint y is 0 at the BOTTOM row; high y = upper side.
        #expect(OwnershipDelta.regionName(point: BoardPoint(x: 0, y: 18), width: 19, height: 19) == "upper left")
        #expect(OwnershipDelta.regionName(point: BoardPoint(x: 18, y: 0), width: 19, height: 19) == "lower right")
        #expect(OwnershipDelta.regionName(point: BoardPoint(x: 9, y: 9), width: 19, height: 19) == "center")
        #expect(OwnershipDelta.regionName(point: BoardPoint(x: 9, y: 18), width: 19, height: 19) == "upper center")
    }

    @Test @MainActor func modelStageDrivesIsGenerating() {
        let model = DeepReportModel()
        #expect(model.isGenerating == false)
        model.stage = .snapshot
        #expect(model.isGenerating == true)
        model.stage = .tenuki(1)
        #expect(model.isGenerating == true)
        model.stage = .complete
        #expect(model.isGenerating == false)
        model.stage = .failed("x")
        #expect(model.isGenerating == false)
    }
}
```

- [ ] **Step 3: Run to verify failure** — same `-only-testing:"KataGo AnytimeTests/DeepReportModelTests"` command shape as Task 1 Step 3. Expected: BUILD FAILURE (types don't exist).

- [ ] **Step 4: Implement**

Full contents of `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/DeepReportModel.swift`:

```swift
//
//  DeepReportModel.swift
//  KataGoUICore
//
//  Value types + observable progress model for the Deep Analysis Report.
//  All winrate/scoreLead values in these types are normalized to the reported
//  position's side-to-move; ownership grids/deltas stay White-perspective
//  (the engine's emission under reportAnalysisWinratesAs = WHITE) and are
//  converted at render time.
//

import Foundation
import Observation

/// Spec constants for the ~5 s "quick" report.
public enum ReportConstants {
    public static let snapshotBudget: TimeInterval = 2.0
    public static let passBudget: TimeInterval = 1.0
    public static let tenukiBudget: TimeInterval = 1.0
    public static let candidateCount = 2
    public static let probeInterval = 50      // centiseconds → 0.5 s reports
    public static let probeMaxMoves = 8
    public static let winrateNoise: Float = 0.02
    public static let scoreNoise: Float = 1.0
    public static let lowVisitThreshold = 100
    public static let contestedPointCount = 8
}

/// Converts the engine's White-perspective values to a side's perspective.
public enum ReportPerspective {
    public static func winrate(_ whiteWinrate: Float, for side: PlayerColor) -> Float {
        side == .white ? whiteWinrate : 1.0 - whiteWinrate
    }
    public static func score(_ whiteScoreLead: Float, for side: PlayerColor) -> Float {
        side == .white ? whiteScoreLead : -whiteScoreLead
    }
}

public struct PositionSummary: Sendable {
    public let winrate: Float
    public let scoreLead: Float
    public let visits: Int
    public init(winrate: Float, scoreLead: Float, visits: Int) {
        self.winrate = winrate
        self.scoreLead = scoreLead
        self.visits = visits
    }
}

public struct TenukiFollowUp: Sendable {
    public let vertex: String
    public let winrate: Float
    public let scoreLead: Float
    public let visits: Int
    public let pv: [String]
    public init(vertex: String, winrate: Float, scoreLead: Float, visits: Int, pv: [String]) {
        self.vertex = vertex
        self.winrate = winrate
        self.scoreLead = scoreLead
        self.visits = visits
        self.pv = pv
    }
}

public struct CandidateReport: Identifiable, Sendable {
    public let vertex: String
    public let visits: Int
    public let winrate: Float
    public let scoreLead: Float
    /// vs. the position summary (positive = better than the position value).
    public let winrateDelta: Float
    public let scoreLeadDelta: Float
    public let pv: [String]
    /// White-perspective subtree-vs-root ownership delta.
    public let ownershipDelta: [BoardPoint: Float]
    public var tenuki: TenukiFollowUp?
    public var id: String { vertex }
    public init(vertex: String, visits: Int, winrate: Float, scoreLead: Float,
                winrateDelta: Float, scoreLeadDelta: Float, pv: [String],
                ownershipDelta: [BoardPoint: Float], tenuki: TenukiFollowUp?) {
        self.vertex = vertex
        self.visits = visits
        self.winrate = winrate
        self.scoreLead = scoreLead
        self.winrateDelta = winrateDelta
        self.scoreLeadDelta = scoreLeadDelta
        self.pv = pv
        self.ownershipDelta = ownershipDelta
        self.tenuki = tenuki
    }
}

public struct ContestedPoint: Identifiable, Sendable {
    public let point: BoardPoint
    public let vertex: String
    public let delta: Float
    public let regionName: String
    public var id: Int { point.hashValue }
    public init(point: BoardPoint, vertex: String, delta: Float, regionName: String) {
        self.point = point
        self.vertex = vertex
        self.delta = delta
        self.regionName = regionName
    }
}

public struct PassComparison: Sendable {
    public let punishmentVertex: String
    public let winrate: Float
    public let scoreLead: Float
    /// Best candidate minus pass scenario (positive = passing costs this much).
    public let winrateDeltaVsBest: Float
    public let scoreLeadDeltaVsBest: Float
    public let ownershipDelta: [BoardPoint: Float]
    public let contestedPoints: [ContestedPoint]
    public init(punishmentVertex: String, winrate: Float, scoreLead: Float,
                winrateDeltaVsBest: Float, scoreLeadDeltaVsBest: Float,
                ownershipDelta: [BoardPoint: Float], contestedPoints: [ContestedPoint]) {
        self.punishmentVertex = punishmentVertex
        self.winrate = winrate
        self.scoreLead = scoreLead
        self.winrateDeltaVsBest = winrateDeltaVsBest
        self.scoreLeadDeltaVsBest = scoreLeadDeltaVsBest
        self.ownershipDelta = ownershipDelta
        self.contestedPoints = contestedPoints
    }
}

/// Ownership-delta math over the engine's flat grids (emission order:
/// y from height-1 down to 0, x from 0 to width-1 — matching
/// AnalysisLineParser.extractOwnershipUnits).
public enum OwnershipDelta {
    public static func grid(base: [Float], probe: [Float],
                            width: Int, height: Int) -> [BoardPoint: Float] {
        let count = width * height
        guard base.count == count, probe.count == count else { return [:] }
        var result: [BoardPoint: Float] = [:]
        var i = 0
        for y in stride(from: height - 1, through: 0, by: -1) {
            for x in 0..<width {
                result[BoardPoint(x: x, y: y)] = probe[i] - base[i]
                i += 1
            }
        }
        return result
    }

    public static func contestedPoints(in grid: [BoardPoint: Float],
                                       width: Int, height: Int) -> [ContestedPoint] {
        grid.sorted {
            if $0.value.magnitude != $1.value.magnitude {
                return $0.value.magnitude > $1.value.magnitude
            }
            return ($0.key.x, $0.key.y) < ($1.key.x, $1.key.y)
        }
        .prefix(ReportConstants.contestedPointCount)
        .compactMap { point, delta in
            guard let vertex = Coordinate(x: point.x, y: point.y + 1,
                                          width: width, height: height)?.move else { return nil }
            return ContestedPoint(point: point,
                                  vertex: vertex,
                                  delta: delta,
                                  regionName: regionName(point: point, width: width, height: height))
        }
    }

    /// Deterministic board-thirds region name. BoardPoint y = 0 is the BOTTOM
    /// row, so the upper third is high y. "center" for the middle-middle third.
    public static func regionName(point: BoardPoint, width: Int, height: Int) -> String {
        let col = min(point.x * 3 / max(width, 1), 2)
        let row = min(point.y * 3 / max(height, 1), 2)
        let vertical = ["lower", "middle", "upper"][row]
        let horizontal = ["left", "center", "right"][col]
        if vertical == "middle" && horizontal == "center" { return "center" }
        if vertical == "middle" { return "\(horizontal) side" }
        return "\(vertical) \(horizontal)"
    }
}

/// Progress + result state the report sheet observes. Sections fill in as
/// probe stages land; `narrative` grows token-wise while streaming.
@Observable
@MainActor
public final class DeepReportModel {
    public enum Stage: Equatable {
        case idle
        case snapshot
        case passProbe
        case tenuki(Int)
        case narrating
        case complete
        case failed(String)
        case cancelled
    }

    public var stage: Stage = .idle
    public var moveNumber: Int = 0
    public var sideToMove: PlayerColor = .black
    public var boardWidth: Int = 19
    public var boardHeight: Int = 19
    public var blackVertices: [String] = []
    public var whiteVertices: [String] = []
    public var position: PositionSummary?
    public var candidates: [CandidateReport] = []
    public var passComparison: PassComparison?
    public var narrative: String = ""
    public var narrativeUnavailableReason: String?
    /// Live search speed captured when the report started (nil when unknown).
    public var visitsPerSecondText: String?

    public var isGenerating: Bool {
        switch stage {
        case .snapshot, .passProbe, .tenuki, .narrating: return true
        case .idle, .complete, .failed, .cancelled: return false
        }
    }

    public init() {}
}
```

Note: `regionName` for the test expectation `BoardPoint(x: 9, y: 18)` → row 2 ("upper"), col 1 ("center") → "upper center" via the last return. `Coordinate` and `BoardPoint` are existing KataGoUICore types; tuple comparison `($0.key.x, $0.key.y) < (...)` needs no extra imports.

- [ ] **Step 5: Run the suite** — `-only-testing:"KataGo AnytimeTests/DeepReportModelTests"`. Expected: TEST SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/DeepReportModel.swift" "ios/KataGo iOS/KataGo iOSTests/DeepReportModelTests.swift" "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(report): report value types, perspective + ownership-delta math"
```

---

### Task 5: ReportCollector — exact stage attribution via a sent-command FIFO

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/ReportCollector.swift`
- Create: `ios/KataGo iOS/KataGo iOSTests/ReportCollectorTests.swift`
- Modify: `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj` (test file registration)

**Interfaces:**
- Consumes: raw engine reply lines (fed by `GameSession.lineObserver` in Task 7).
- Produces:
  - `public final class ReportCollector: @unchecked Sendable` (NSLock-protected, nonisolated methods — same pattern as the RecordingEngine test double).
  - `public enum ReportStage: Hashable { case snapshot, passProbe, tenuki(Int) }`
  - `func willSend(stage: ReportStage?)` — call once per command ABOUT to be sent; pass the stage for analyze commands, nil for everything else.
  - `func ingest(line: String)` — feed every reply line.
  - `func latestLine(for stage: ReportStage) -> String?` — most recent `info` line attributed to the stage.
  - `var sawError: Bool` — true once any `? ` line arrived.
  - `func reset()` — clears everything.

**Wire protocol this encodes (verified in gtp.cpp):** every command produces exactly one `=`-prefixed line — a normal ack (`"= ..."`) or an analyze response header (bare `"="`) — in FIFO order. When an `=` line arrives, pop the FIFO: the popped entry's stage (nil for non-analyze) becomes current. `info` lines belong to the current stage. Empty lines (cancelled-analyze terminators, ack trailers) are ignored. Stale `info` lines from the user's live analysis arrive BEFORE our first ack and are dropped because no stage is current yet.

- [ ] **Step 1: Register the test file** — `touch` + `ruby /tmp/add_test_file.rb ReportCollectorTests.swift`.

- [ ] **Step 2: Write the failing tests**

Full contents of `ReportCollectorTests.swift`:

```swift
//
//  ReportCollectorTests.swift
//  KataGo AnytimeTests
//

import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

struct ReportCollectorTests {
    @Test func staleLinesBeforeFirstAckAreDropped() {
        let c = ReportCollector()
        c.willSend(stage: nil)              // kata-set-param
        c.willSend(stage: .snapshot)        // kata-analyze
        c.ingest(line: "info move D4 visits 99 ...")   // stale live-analysis line
        c.ingest(line: "= ")                            // set-param ack
        c.ingest(line: "info move D4 visits 100 ...")  // still stale (analyze header not seen)
        #expect(c.latestLine(for: .snapshot) == nil)
        c.ingest(line: "=")                             // analyze response header
        c.ingest(line: "info move Q16 visits 7 ...")
        #expect(c.latestLine(for: .snapshot) == "info move Q16 visits 7 ...")
    }

    @Test func latestLineWinsWithinStage() {
        let c = ReportCollector()
        c.willSend(stage: .snapshot)
        c.ingest(line: "=")
        c.ingest(line: "info move Q16 visits 7 ...")
        c.ingest(line: "info move Q16 visits 30 ...")
        #expect(c.latestLine(for: .snapshot) == "info move Q16 visits 30 ...")
    }

    @Test func nonAnalyzeAckEndsTheStage() {
        let c = ReportCollector()
        c.willSend(stage: .snapshot)
        c.ingest(line: "=")
        c.ingest(line: "info move Q16 visits 7 ...")
        c.willSend(stage: nil)              // stop
        c.ingest(line: "")                  // cancelled-analyze terminator — ignored
        c.ingest(line: "info move Q16 visits 9 ...")   // in-flight before stop ack: still snapshot
        c.ingest(line: "= ")                // stop ack → stage ends
        c.ingest(line: "info move Z9 visits 1 ...")    // stray → dropped
        #expect(c.latestLine(for: .snapshot) == "info move Q16 visits 9 ...")
    }

    @Test func stagesAttributeIndependently() {
        let c = ReportCollector()
        c.willSend(stage: .snapshot)
        c.ingest(line: "=")
        c.ingest(line: "info snapshot-line")
        c.willSend(stage: nil)                       // stop
        c.ingest(line: "= ")
        c.willSend(stage: .tenuki(0))                // next analyze
        c.ingest(line: "=")
        c.ingest(line: "info tenuki-line")
        #expect(c.latestLine(for: .snapshot) == "info snapshot-line")
        #expect(c.latestLine(for: .tenuki(0)) == "info tenuki-line")
        #expect(c.latestLine(for: .tenuki(1)) == nil)
    }

    @Test func errorLineSetsSawError() {
        let c = ReportCollector()
        #expect(c.sawError == false)
        c.ingest(line: "? illegal move")
        #expect(c.sawError == true)
    }

    @Test func resetClearsState() {
        let c = ReportCollector()
        c.willSend(stage: .snapshot)
        c.ingest(line: "=")
        c.ingest(line: "info x")
        c.ingest(line: "? boom")
        c.reset()
        #expect(c.latestLine(for: .snapshot) == nil)
        #expect(c.sawError == false)
    }
}
```

- [ ] **Step 3: Run to verify failure** — `-only-testing:"KataGo AnytimeTests/ReportCollectorTests"`. Expected: BUILD FAILURE (type doesn't exist).

- [ ] **Step 4: Implement**

Full contents of `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/ReportCollector.swift`:

```swift
//
//  ReportCollector.swift
//  KataGoUICore
//
//  Attributes raw engine reply lines to Deep Report probe stages, exactly.
//
//  GTP wire facts this relies on (cpp/command/gtp.cpp): every command produces
//  exactly one "="-prefixed line, in FIFO order — a normal ack ("= ...") or a
//  bare "=" analyze response header printed BEFORE the info stream (gtp.cpp
//  printGTPResponseHeader); a cancelled analyze emits one EMPTY line, not an
//  ack. So a FIFO of our sent commands, popped per "=" line, tells us which
//  analyze stage (if any) the subsequent `info` lines belong to. Stale lines
//  from the user's live analysis arrive before our first ack, when no stage is
//  current, and are dropped.
//
//  NSLock-protected because lines arrive via GameSession.lineObserver while
//  the generator reads results from the main actor.
//

import Foundation

public enum ReportStage: Hashable, Sendable {
    case snapshot
    case passProbe
    case tenuki(Int)
}

public final class ReportCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingStages: [ReportStage?] = []
    private var currentStage: ReportStage?
    private var latestByStage: [ReportStage: String] = [:]
    private var _sawError = false

    public init() {}

    public var sawError: Bool {
        lock.withLock { _sawError }
    }

    /// Call once per command about to be sent, IN SEND ORDER: the stage for
    /// analyze commands, nil for everything else (set-param/play/undo/stop/...).
    public func willSend(stage: ReportStage?) {
        lock.withLock { pendingStages.append(stage) }
    }

    /// Feed every raw engine reply line (from GameSession.lineObserver).
    public func ingest(line: String) {
        lock.withLock {
            if line.hasPrefix("? ") {
                _sawError = true
            } else if line.hasPrefix("=") {
                // One "=" line per command, FIFO: ack or analyze header.
                currentStage = pendingStages.isEmpty ? nil : pendingStages.removeFirst()
            } else if line.hasPrefix("info"), let stage = currentStage {
                latestByStage[stage] = line
            }
            // Empty lines (analyze terminators, ack trailers) are ignored.
        }
    }

    public func latestLine(for stage: ReportStage) -> String? {
        lock.withLock { latestByStage[stage] }
    }

    public func reset() {
        lock.withLock {
            pendingStages = []
            currentStage = nil
            latestByStage = [:]
            _sawError = false
        }
    }
}
```

- [ ] **Step 5: Run the suite** — `-only-testing:"KataGo AnytimeTests/ReportCollectorTests"`. Expected: TEST SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/ReportCollector.swift" "ios/KataGo iOS/KataGo iOSTests/ReportCollectorTests.swift" "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(report): ReportCollector attributes reply lines to probe stages"
```

---

### Task 6: Report mode — GobanState flag + GameSession live-analysis bypass

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/GobanState.swift` (stored-property region, ~line 50)
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Session/GameSession.swift` (`maybeCollectAnalysis`, ~line 329)
- Create: `ios/KataGo iOS/KataGo iOSTests/GameSessionReportModeTests.swift`
- Modify: `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj` (test file registration)

**Interfaces:**
- Produces: `GobanState.reportGenerationActive: Bool` (default false). While true, `GameSession.maybeCollectAnalysis` returns early for `info` lines: live `Analysis`, `rootWinrate`/`rootScore`, and `waitingForAnalysis` are all untouched (no true→false edges can fire the per-platform re-arm observers mid-report). `lineObserver` still fires for every line (it runs in `messaging()` before the collectors).

- [ ] **Step 1: Register the test file** — `touch` + `ruby /tmp/add_test_file.rb GameSessionReportModeTests.swift`.

- [ ] **Step 2: Write the failing tests**

Full contents of `GameSessionReportModeTests.swift`:

```swift
//
//  GameSessionReportModeTests.swift
//  KataGo AnytimeTests
//

import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

@MainActor
struct GameSessionReportModeTests {
    private let infoLine = "info move Q16 visits 10 winrate 0.55 scoreLead 2.5 utilityLcb 0.3 order 0 pv Q16"

    @Test func reportModeBypassesLiveAnalysis() async {
        let session = GameSession()
        session.board.width = 19
        session.board.height = 19
        session.gobanState.reportGenerationActive = true
        session.gobanState.waitingForAnalysis = true   // must NOT be cleared mid-report

        await session.maybeCollectAnalysis(message: infoLine)

        #expect(session.analysis.info.isEmpty)
        #expect(session.gobanState.waitingForAnalysis == true)
    }

    @Test func normalModeStillCollects() async {
        let session = GameSession()
        session.board.width = 19
        session.board.height = 19
        session.gobanState.waitingForAnalysis = true

        await session.maybeCollectAnalysis(message: infoLine)

        #expect(!session.analysis.info.isEmpty)
        #expect(session.gobanState.waitingForAnalysis == false)
    }
}
```

- [ ] **Step 3: Run to verify failure** — `-only-testing:"KataGo AnytimeTests/GameSessionReportModeTests"`. Expected: BUILD FAILURE — `GobanState` has no member `reportGenerationActive`.

- [ ] **Step 4: Implement**

In `GobanState.swift`, add after the `forcesBranchOnPlay` declaration (~line 47, before `public var branchSgf`):

```swift
    /// True while a Deep Analysis Report is probing the engine. GameSession
    /// bypasses live-analysis collection for `info` lines (probe replies are
    /// consumed via `lineObserver` by the report's collector instead), so the
    /// board overlay, charts, and the `waitingForAnalysis` edge machinery stay
    /// frozen mid-report. Menu/board interaction gates on it belt-and-suspenders
    /// (the modal report sheet is the primary lock). Transient; never persisted.
    public var reportGenerationActive = false
```

In `GameSession.swift` `maybeCollectAnalysis`, add the bypass as the FIRST guard (before `guard gobanState.showBoardCount == 0`):

```swift
    func maybeCollectAnalysis(message: String) async {
        // Deep Report probes own the info stream: the report collector reads it
        // via lineObserver; the live Analysis/edge machinery must not see it.
        guard !gobanState.reportGenerationActive else { return }
        guard gobanState.showBoardCount == 0 else { return }
        ...existing body unchanged...
```

- [ ] **Step 5: Run the new suite + full unit sweep** (the guard touches every analysis line):

```bash
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17'
```

Expected: TEST SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/GobanState.swift" "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Session/GameSession.swift" "ios/KataGo iOS/KataGo iOSTests/GameSessionReportModeTests.swift" "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(report): report mode bypasses live analysis collection"
```

---

### Task 7: DeepReportGenerator — probe orchestration, happy path

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/DeepReportGenerator.swift`
- Create: `ios/KataGo iOS/KataGo iOSTests/DeepReportGeneratorTests.swift`
- Modify: `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj` (test file registration)

**Interfaces:**
- Consumes: `ReportCollector`/`ReportStage` (Task 5), `DeepReportModel` + value types + `ReportConstants`/`ReportPerspective`/`OwnershipDelta` (Task 4), parser extensions (Tasks 1–2), `GobanState.reportGenerationActive` (Task 6), existing `MessageList.appendAndSend`, `MessageList.session` (weak `GameSession?`), `GameSession.lineObserver`, `GobanState.sendPostExecutionCommands(config:messageList:player:)`, `GtpCommandBuilder.unboundedMaxVisits`, `Turn.nextColorFromShowBoard`, `Stones.blackPoints/whitePoints`, `GameRecord.concreteConfig/currentIndex`.
- Produces:
  - `public struct ReportBudgets { snapshot, pass, tenuki: TimeInterval; candidateCount: Int; static let standard: ReportBudgets }` (standard = ReportConstants values).
  - `public typealias ReportSleeper = @MainActor (TimeInterval) async throws -> Void`
  - `@MainActor public final class DeepReportGenerator` — `init(messageList: MessageList, budgets: ReportBudgets = .standard, sleeper: @escaping ReportSleeper = { try await Task.sleep(for: .seconds($0)) })`; `public func generate(model: DeepReportModel, gameRecord: GameRecord) async`. On any exit (success, `CancellationError`, `ReportError`) it restores: prior `lineObserver`, `reportGenerationActive = false`, outstanding `undo`s, `stop`, and `sendPostExecutionCommands` re-arm. Task 9 later inserts narration before `.complete`.
  - `struct ReportError: Error { let message: String }` (internal).

**Probe command strings (exact):**
1. `kata-set-param maxVisits 1000000000`
2. `kata-analyze interval 50 maxmoves 8 ownership true movesOwnership true rootInfo true` (snapshot)
3. `stop`
4. `kata-analyze <opp> interval 50 maxmoves 8 ownership true rootInfo true` (pass probe; `<opp>` = "w" when the reported side is Black)
5. `stop`
6. per candidate (skipping "pass"): `play <side> <vertex>` → `kata-analyze <side> interval 50 maxmoves 8 ownership true rootInfo true` → `stop` → `undo`
7. restore: `stop`, remaining `undo`s, then `sendPostExecutionCommands` (showboard + re-arm, which resets maxVisits — the existing 3-site pattern's 4th site).

- [ ] **Step 1: Register the test file** — `touch` + `ruby /tmp/add_test_file.rb DeepReportGeneratorTests.swift`.

- [ ] **Step 2: Write the failing happy-path test**

Full contents of `DeepReportGeneratorTests.swift` (Task 8 appends more):

```swift
//
//  DeepReportGeneratorTests.swift
//  KataGo AnytimeTests
//
//  The injectable sleeper makes these tests deterministic: each "sleep" feeds
//  the scripted engine replies for that stage synchronously, so no wall-clock
//  timing is involved.
//

import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

/// Records sent commands; replies are pushed by the test via lineObserver.
final class ReportProbeEngine: KataGoEngineIO, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [String] = []
    var sent: [String] { lock.withLock { _sent } }
    nonisolated func sendCommand(_ command: String) { lock.withLock { _sent.append(command) } }
    nonisolated func getMessageLine() -> String { "" }
    nonisolated func sendMessage(_ message: String) {}
    nonisolated var hasReachedEOF: Bool { false }
}

@MainActor
struct DeepReportGeneratorTests {
    // 2x2 board, Black to move. Engine values are White-perspective (cfg).
    static let snapshotLine = "info move A1 visits 100 winrate 0.60 scoreLead 5.0 utilityLcb 0.5 order 0 pv A1 B2 movesOwnership 0.9 0.9 0.9 0.9 "
        + "info move B2 visits 50 winrate 0.55 scoreLead 3.0 utilityLcb 0.4 order 1 pv B2 movesOwnership 0.1 0.1 0.1 0.1 "
        + "rootInfo visits 150 utility 0.2 winrate 0.58 scoreMean 4.0 scoreStdev 8.0 scoreLead 4.0 scoreSelfplay 4.2 weight 150.0 "
        + "ownership 0.5 0.5 0.5 0.5 ownershipStdev 0.1 0.1 0.1 0.1"
    static let passLine = "info move B2 visits 40 winrate 0.75 scoreLead 8.0 utilityLcb 0.6 order 0 pv B2 A1 "
        + "rootInfo visits 60 utility 0.4 winrate 0.72 scoreMean 7.0 scoreStdev 8.0 scoreLead 7.0 scoreSelfplay 7.1 weight 60.0 "
        + "ownership 0.8 0.8 0.8 0.8 ownershipStdev 0.1 0.1 0.1 0.1"
    static let tenukiLine = "info move B2 visits 30 winrate 0.45 scoreLead -1.0 utilityLcb 0.2 order 0 pv B2 A2 "
        + "rootInfo visits 45 utility 0.1 winrate 0.44 scoreMean -0.5 scoreStdev 8.0 scoreLead -0.5 scoreSelfplay -0.4 weight 45.0 "
        + "ownership 0.4 0.4 0.4 0.4 ownershipStdev 0.1 0.1 0.1 0.1"

    @MainActor
    final class Script {
        let session: GameSession
        var step = 0
        init(session: GameSession) { self.session = session }
        func feed(_ lines: [String]) { lines.forEach { session.lineObserver?($0) } }
        func sleeper(_ interval: TimeInterval) async throws {
            step += 1
            switch step {
            case 1:   // snapshot budget: set-param ack, analyze header, report line
                feed(["= ", "=", DeepReportGeneratorTests.snapshotLine])
            case 2:   // pass budget: stop ack, analyze header, report line
                feed(["= ", "=", DeepReportGeneratorTests.passLine])
            case 3:   // tenuki 0: stop ack, play ack, analyze header, report line
                feed(["= ", "= ", "=", DeepReportGeneratorTests.tenukiLine])
            case 4:   // tenuki 1: stop ack, undo ack, play ack, header, report line
                feed(["= ", "= ", "= ", "=", DeepReportGeneratorTests.tenukiLine])
            default: break
            }
        }
    }

    @MainActor
    struct Fixture {
        let session = GameSession()
        let engine = ReportProbeEngine()
        let record: GameRecord
        let model = DeepReportModel()
        let script: Script
        let generator: DeepReportGenerator

        init(sleeperOverride: ReportSleeper? = nil) {
            record = GameRecord.createGameRecord(name: "Report")
            session.useEngine(engine)
            session.board.width = 2
            session.board.height = 2
            session.player.nextColorFromShowBoard = .black
            let script = Script(session: session)
            self.script = script
            generator = DeepReportGenerator(
                messageList: session.messageList,
                budgets: ReportBudgets(snapshot: 0, pass: 0, tenuki: 0, candidateCount: 2),
                sleeper: sleeperOverride ?? { try await script.sleeper($0) }
            )
        }
    }

    @Test func happyPathBuildsFullReport() async {
        let f = Fixture()
        await f.generator.generate(model: f.model, gameRecord: f.record)

        #expect(f.model.stage == .complete)

        // Position summary: White-persp 0.58/4.0 → Black side-to-move 0.42/-4.0.
        #expect(abs((f.model.position?.winrate ?? 0) - 0.42) < 1e-4)
        #expect(abs((f.model.position?.scoreLead ?? 0) - (-4.0)) < 1e-4)
        #expect(f.model.position?.visits == 150)

        // Candidates: A1 (100 visits) then B2 (50), normalized to Black.
        #expect(f.model.candidates.count == 2)
        #expect(f.model.candidates[0].vertex == "A1")
        #expect(abs(f.model.candidates[0].winrate - 0.40) < 1e-4)
        #expect(f.model.candidates[0].pv == ["A1", "B2"])
        #expect(!f.model.candidates[0].ownershipDelta.isEmpty)
        // Tenuki attached: White-persp 0.44/-0.5 → Black 0.56/0.5, reply B2.
        #expect(f.model.candidates[0].tenuki?.vertex == "B2")
        #expect(abs((f.model.candidates[0].tenuki?.winrate ?? 0) - 0.56) < 1e-4)

        // Pass comparison: White-persp 0.72 → Black 0.28; best candidate 0.40.
        #expect(abs((f.model.passComparison?.winrate ?? 0) - 0.28) < 1e-4)
        #expect(abs((f.model.passComparison?.winrateDeltaVsBest ?? 0) - 0.12) < 1e-4)
        #expect(f.model.passComparison?.punishmentVertex == "B2")
        #expect(f.model.passComparison?.contestedPoints.isEmpty == false)

        // Exact probe command stream, in order.
        let sent = f.engine.sent
        let expectedPrefix = [
            "kata-set-param maxVisits 1000000000",
            "kata-analyze interval 50 maxmoves 8 ownership true movesOwnership true rootInfo true",
            "stop",
            "kata-analyze w interval 50 maxmoves 8 ownership true rootInfo true",
            "stop",
            "play b A1",
            "kata-analyze b interval 50 maxmoves 8 ownership true rootInfo true",
            "stop",
            "undo",
            "play b B2",
            "kata-analyze b interval 50 maxmoves 8 ownership true rootInfo true",
            "stop",
            "undo",
        ]
        #expect(Array(sent.prefix(expectedPrefix.count)) == expectedPrefix)
        // Restore: a final stop then the standard post-execution showboard.
        #expect(sent.dropFirst(expectedPrefix.count).contains("stop"))
        #expect(sent.dropFirst(expectedPrefix.count).contains("showboard"))

        // Cleanup: flags and observer restored.
        #expect(f.session.gobanState.reportGenerationActive == false)
        #expect(f.session.lineObserver == nil)
    }
}
```

- [ ] **Step 3: Run to verify failure** — `-only-testing:"KataGo AnytimeTests/DeepReportGeneratorTests"`. Expected: BUILD FAILURE (`DeepReportGenerator` doesn't exist).

- [ ] **Step 4: Implement the generator**

Full contents of `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/DeepReportGenerator.swift`:

```swift
//
//  DeepReportGenerator.swift
//  KataGoUICore
//
//  Serializes the Deep Report probe sequence over the app's single GTP stream.
//
//  Invariants honored here (see the design spec):
//  - Probes use kata-analyze ONLY (never search-analyze — no stray "play"
//    replies to guard against).
//  - The first probe command implicitly cancels the user's live kata-analyze;
//    live collection is bypassed via gobanState.reportGenerationActive (the
//    GameSession guard), so no waitingForAnalysis edges fire mid-report.
//  - Engine game state is mutated ONLY by the tenuki `play`s, tracked by
//    `outstandingPlays` (never exceeds 1) so every exit path can restore.
//  - All parsing uses nextColor .white so values stay White-perspective
//    (reportAnalysisWinratesAs = WHITE); normalization to the reported side
//    happens exactly once, here, via ReportPerspective.
//

import Foundation

/// Wall-clock budgets for the probe stages; injectable so tests substitute 0.
public struct ReportBudgets: Sendable {
    public let snapshot: TimeInterval
    public let pass: TimeInterval
    public let tenuki: TimeInterval
    public let candidateCount: Int

    public init(snapshot: TimeInterval, pass: TimeInterval,
                tenuki: TimeInterval, candidateCount: Int) {
        self.snapshot = snapshot
        self.pass = pass
        self.tenuki = tenuki
        self.candidateCount = candidateCount
    }

    public static let standard = ReportBudgets(snapshot: ReportConstants.snapshotBudget,
                                               pass: ReportConstants.passBudget,
                                               tenuki: ReportConstants.tenukiBudget,
                                               candidateCount: ReportConstants.candidateCount)
}

/// Injectable wait so tests can feed scripted replies instead of sleeping.
public typealias ReportSleeper = @MainActor (TimeInterval) async throws -> Void

struct ReportError: Error {
    let message: String
}

@MainActor
public final class DeepReportGenerator {
    private let messageList: MessageList
    private let budgets: ReportBudgets
    private let sleeper: ReportSleeper
    private let collector = ReportCollector()
    private var outstandingPlays = 0
    private var priorObserver: ((String) -> Void)?

    public init(messageList: MessageList,
                budgets: ReportBudgets = .standard,
                sleeper: @escaping ReportSleeper = { try await Task.sleep(for: .seconds($0)) }) {
        self.messageList = messageList
        self.budgets = budgets
        self.sleeper = sleeper
    }

    public func generate(model: DeepReportModel, gameRecord: GameRecord) async {
        guard let session = messageList.session else {
            model.stage = .failed("No engine session.")
            return
        }
        guard !session.gobanState.reportGenerationActive else { return }

        let sideToMove = session.player.nextColorFromShowBoard
        seedModel(model, session: session, gameRecord: gameRecord, sideToMove: sideToMove)

        collector.reset()
        outstandingPlays = 0
        priorObserver = session.lineObserver
        let collector = self.collector
        session.lineObserver = { line in collector.ingest(line: line) }
        session.gobanState.reportGenerationActive = true

        do {
            try await runProbes(model: model, session: session, sideToMove: sideToMove)
            restore(session: session, gameRecord: gameRecord)
            model.stage = .complete
        } catch is CancellationError {
            restore(session: session, gameRecord: gameRecord)
            model.stage = .cancelled
        } catch let error as ReportError {
            restore(session: session, gameRecord: gameRecord)
            model.stage = .failed(error.message)
        } catch {
            restore(session: session, gameRecord: gameRecord)
            model.stage = .failed(error.localizedDescription)
        }
    }

    // MARK: - Stages

    private func runProbes(model: DeepReportModel,
                           session: GameSession,
                           sideToMove: PlayerColor) async throws {
        let width = model.boardWidth
        let height = model.boardHeight
        let parser = AnalysisLineParser(boardWidth: width, boardHeight: height, nextColor: .white)
        let mySymbol = sideToMove == .black ? "b" : "w"
        let oppSymbol = sideToMove == .black ? "w" : "b"

        // Stage 1: snapshot (zero mutation) — candidates, PVs, root + subtree ownership.
        model.stage = .snapshot
        send("kata-set-param maxVisits \(GtpCommandBuilder.unboundedMaxVisits)", stage: nil)
        send("kata-analyze interval \(ReportConstants.probeInterval) maxmoves \(ReportConstants.probeMaxMoves) ownership true movesOwnership true rootInfo true",
             stage: .snapshot)
        try await sleeper(budgets.snapshot)
        try checkEngineError()
        send("stop", stage: nil)
        guard let snapshotLine = collector.latestLine(for: .snapshot) else {
            throw ReportError("The engine produced no analysis for this position.")
        }
        let snapshot = parser.parse(message: snapshotLine)
        guard let rootInfo = snapshot.rootInfo else {
            throw ReportError("The engine's analysis carried no root values.")
        }
        let position = PositionSummary(
            winrate: ReportPerspective.winrate(rootInfo.winrate, for: sideToMove),
            scoreLead: ReportPerspective.score(rootInfo.scoreLead, for: sideToMove),
            visits: rootInfo.visits)
        model.position = position
        model.candidates = buildCandidates(from: snapshot, position: position,
                                           sideToMove: sideToMove, width: width, height: height)

        // Stage 2: pass probe (zero mutation) — opponent to move on the same board.
        model.stage = .passProbe
        send("kata-analyze \(oppSymbol) interval \(ReportConstants.probeInterval) maxmoves \(ReportConstants.probeMaxMoves) ownership true rootInfo true",
             stage: .passProbe)
        try await sleeper(budgets.pass)
        try checkEngineError()
        send("stop", stage: nil)
        if let passLine = collector.latestLine(for: .passProbe) {
            let passParsed = parser.parse(message: passLine)
            model.passComparison = buildPassComparison(passParsed: passParsed,
                                                       snapshot: snapshot,
                                                       sideToMove: sideToMove,
                                                       best: model.candidates.first,
                                                       width: width, height: height)
        }

        // Stage 3: tenuki probes — play the candidate, analyze with the SAME side
        // to move (= opponent ignored it), undo. The only state mutation.
        for (index, candidate) in model.candidates.enumerated() {
            guard candidate.vertex != "pass" else { continue }
            model.stage = .tenuki(index)
            send("play \(mySymbol) \(candidate.vertex)", stage: nil)
            outstandingPlays = 1
            send("kata-analyze \(mySymbol) interval \(ReportConstants.probeInterval) maxmoves \(ReportConstants.probeMaxMoves) ownership true rootInfo true",
                 stage: .tenuki(index))
            try await sleeper(budgets.tenuki)
            try checkEngineError()
            send("stop", stage: nil)
            send("undo", stage: nil)
            outstandingPlays = 0
            if let line = collector.latestLine(for: .tenuki(index)) {
                let parsed = parser.parse(message: line)
                model.candidates[index].tenuki = buildTenuki(parsed: parsed,
                                                             sideToMove: sideToMove,
                                                             width: width, height: height)
            }
        }
    }

    // MARK: - Builders (White-perspective in, side-to-move out)

    private func buildCandidates(from snapshot: ParsedAnalysis,
                                 position: PositionSummary,
                                 sideToMove: PlayerColor,
                                 width: Int, height: Int) -> [CandidateReport] {
        rankedEntries(in: snapshot, width: width, height: height)
            .prefix(budgets.candidateCount)
            .map { vertex, info in
                let winrate = ReportPerspective.winrate(info.winrate, for: sideToMove)
                let scoreLead = ReportPerspective.score(info.scoreLead, for: sideToMove)
                return CandidateReport(
                    vertex: vertex,
                    visits: info.visits,
                    winrate: winrate,
                    scoreLead: scoreLead,
                    winrateDelta: winrate - position.winrate,
                    scoreLeadDelta: scoreLead - position.scoreLead,
                    pv: info.pv,
                    ownershipDelta: OwnershipDelta.grid(base: snapshot.rawOwnership,
                                                        probe: info.movesOwnership ?? [],
                                                        width: width, height: height),
                    tenuki: nil)
            }
    }

    private func buildPassComparison(passParsed: ParsedAnalysis,
                                     snapshot: ParsedAnalysis,
                                     sideToMove: PlayerColor,
                                     best: CandidateReport?,
                                     width: Int, height: Int) -> PassComparison? {
        guard let rootInfo = passParsed.rootInfo,
              let punishment = rankedEntries(in: passParsed, width: width, height: height).first
        else { return nil }
        let winrate = ReportPerspective.winrate(rootInfo.winrate, for: sideToMove)
        let scoreLead = ReportPerspective.score(rootInfo.scoreLead, for: sideToMove)
        // Best-candidate subtree ownership minus the pass scenario's root
        // ownership: what playing (vs passing) does to each point.
        let bestOwnership = bestCandidateOwnership(snapshot: snapshot, best: best, width: width, height: height)
        let delta = OwnershipDelta.grid(base: passParsed.rawOwnership,
                                        probe: bestOwnership,
                                        width: width, height: height)
        return PassComparison(
            punishmentVertex: punishment.vertex,
            winrate: winrate,
            scoreLead: scoreLead,
            winrateDeltaVsBest: (best?.winrate ?? winrate) - winrate,
            scoreLeadDeltaVsBest: (best?.scoreLead ?? scoreLead) - scoreLead,
            ownershipDelta: delta,
            contestedPoints: OwnershipDelta.contestedPoints(in: delta, width: width, height: height))
    }

    private func bestCandidateOwnership(snapshot: ParsedAnalysis,
                                        best: CandidateReport?,
                                        width: Int, height: Int) -> [Float] {
        guard let best,
              let entry = rankedEntries(in: snapshot, width: width, height: height)
                  .first(where: { $0.vertex == best.vertex }),
              let movesOwnership = entry.info.movesOwnership
        else { return snapshot.rawOwnership }
        return movesOwnership
    }

    private func buildTenuki(parsed: ParsedAnalysis,
                             sideToMove: PlayerColor,
                             width: Int, height: Int) -> TenukiFollowUp? {
        guard let rootInfo = parsed.rootInfo,
              let reply = rankedEntries(in: parsed, width: width, height: height).first
        else { return nil }
        return TenukiFollowUp(
            vertex: reply.vertex,
            winrate: ReportPerspective.winrate(rootInfo.winrate, for: sideToMove),
            scoreLead: ReportPerspective.score(rootInfo.scoreLead, for: sideToMove),
            visits: rootInfo.visits,
            pv: reply.info.pv)
    }

    /// Candidates ordered strongest-first, mirroring Analysis.candidateMoves:
    /// visits desc, then utilityLcb desc, then vertex. "pass" points convert to
    /// the literal vertex "pass" instead of being dropped.
    private func rankedEntries(in parsed: ParsedAnalysis,
                               width: Int, height: Int) -> [(vertex: String, info: AnalysisInfo)] {
        parsed.info.compactMap { point, info -> (String, AnalysisInfo)? in
            if point == BoardPoint.pass(width: width, height: height) {
                return ("pass", info)
            }
            guard let vertex = Coordinate(x: point.x, y: point.y + 1,
                                          width: width, height: height)?.move else { return nil }
            return (vertex, info)
        }
        .sorted {
            if $0.1.visits != $1.1.visits { return $0.1.visits > $1.1.visits }
            if $0.1.utilityLcb != $1.1.utilityLcb { return $0.1.utilityLcb > $1.1.utilityLcb }
            return $0.0 < $1.0
        }
        .map { (vertex: $0.0, info: $0.1) }
    }

    // MARK: - Plumbing

    private func send(_ command: String, stage: ReportStage?) {
        collector.willSend(stage: stage)
        messageList.appendAndSend(command: command)
    }

    private func checkEngineError() throws {
        if collector.sawError {
            throw ReportError("The engine reported an error while probing.")
        }
    }

    private func seedModel(_ model: DeepReportModel,
                           session: GameSession,
                           gameRecord: GameRecord,
                           sideToMove: PlayerColor) {
        model.stage = .snapshot
        model.moveNumber = gameRecord.currentIndex
        model.visitsPerSecondText = session.analysis.visitsPerSecond > 0
            ? session.analysis.visitsPerSecondText : nil
        model.sideToMove = sideToMove
        model.boardWidth = Int(session.board.width)
        model.boardHeight = Int(session.board.height)
        model.blackVertices = vertices(of: session.stones.blackPoints,
                                       width: model.boardWidth, height: model.boardHeight)
        model.whiteVertices = vertices(of: session.stones.whitePoints,
                                       width: model.boardWidth, height: model.boardHeight)
    }

    private func vertices(of points: [BoardPoint], width: Int, height: Int) -> [String] {
        points.compactMap { Coordinate(x: $0.x, y: $0.y + 1, width: width, height: height)?.move }
    }

    /// Single restore path for every exit: undo any outstanding probe play,
    /// stop whatever streams, hand the line stream back, unfreeze live
    /// collection, and re-arm via the standard post-execution sequence (which
    /// resets the sticky maxVisits before kata-analyze).
    private func restore(session: GameSession, gameRecord: GameRecord) {
        session.lineObserver = priorObserver
        priorObserver = nil
        session.gobanState.reportGenerationActive = false
        messageList.appendAndSend(command: "stop")
        while outstandingPlays > 0 {
            messageList.appendAndSend(command: "undo")
            outstandingPlays -= 1
        }
        session.gobanState.sendPostExecutionCommands(config: gameRecord.concreteConfig,
                                                     messageList: messageList,
                                                     player: session.player)
    }
}
```

Note on `Stones`: its stone lists are `blackPoints`/`whitePoints` (`[BoardPoint]`, used by `BoardView`'s tap gate). If the compiler reports a different element container (e.g. `Set`), adapt `vertices(of:)`'s parameter type to match — the mapping logic is unchanged.

- [ ] **Step 5: Run the suite** — `-only-testing:"KataGo AnytimeTests/DeepReportGeneratorTests"`. Expected: TEST SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/DeepReportGenerator.swift" "ios/KataGo iOS/KataGo iOSTests/DeepReportGeneratorTests.swift" "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(report): DeepReportGenerator probe orchestration (happy path)"
```

---

### Task 8: DeepReportGenerator — abort and restore paths

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOSTests/DeepReportGeneratorTests.swift` (append tests)
- Modify (only if a test exposes a gap): `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/DeepReportGenerator.swift`

**Interfaces:**
- Consumes: Task 7's generator + fixture. The `sleeperOverride` init hook simulates cancellation (throw `CancellationError`) and hangs (feed nothing).
- Produces: verified guarantees later tasks rely on: every exit path restores `lineObserver`, clears `reportGenerationActive`, sends exactly `outstandingPlays` undos, and re-arms via showboard.

- [ ] **Step 1: Append the failing tests**

Append inside `struct DeepReportGeneratorTests`:

```swift
    @Test func cancellationBeforeAnyPlayRestoresWithoutUndo() async {
        let f = Fixture(sleeperOverride: { _ in throw CancellationError() })
        await f.generator.generate(model: f.model, gameRecord: f.record)

        #expect(f.model.stage == .cancelled)
        #expect(f.session.gobanState.reportGenerationActive == false)
        #expect(f.session.lineObserver == nil)
        #expect(!f.engine.sent.contains("undo"))          // no play happened
        #expect(f.engine.sent.contains("stop"))           // restore stop
        #expect(f.engine.sent.contains("showboard"))      // re-arm path ran
    }

    @Test func cancellationMidTenukiUndoesTheOutstandingPlay() async {
        // Cancel during the FIRST tenuki sleep (sleeper call #3): the candidate
        // play is on the engine board and must be undone by restore.
        let f = Fixture()
        let script = f.script
        let generator = DeepReportGenerator(
            messageList: f.session.messageList,
            budgets: ReportBudgets(snapshot: 0, pass: 0, tenuki: 0, candidateCount: 2),
            sleeper: { interval in
                if script.step >= 2 { throw CancellationError() }   // #3 = first tenuki
                try await script.sleeper(interval)
            }
        )
        await generator.generate(model: f.model, gameRecord: f.record)

        #expect(f.model.stage == .cancelled)
        let sent = f.engine.sent
        #expect(sent.filter { $0 == "undo" }.count == 1)  // exactly the outstanding play
        #expect(sent.contains("play b A1"))
        #expect(f.session.gobanState.reportGenerationActive == false)
        #expect(sent.contains("showboard"))
    }

    @Test func engineErrorFailsAndRestores() async {
        let f = Fixture(sleeperOverride: { _ in })        // feed nothing...
        f.session.lineObserver?("? illegal move")          // ...but generate() hasn't run yet
        // Drive an error DURING the snapshot sleep instead:
        let script = f.script
        let generator = DeepReportGenerator(
            messageList: f.session.messageList,
            budgets: ReportBudgets(snapshot: 0, pass: 0, tenuki: 0, candidateCount: 2),
            sleeper: { _ in script.feed(["? illegal probe"]) }
        )
        await generator.generate(model: f.model, gameRecord: f.record)

        guard case .failed = f.model.stage else {
            Issue.record("expected .failed, got \(f.model.stage)")
            return
        }
        #expect(f.session.gobanState.reportGenerationActive == false)
        #expect(f.engine.sent.contains("showboard"))
    }

    @Test func silentEngineFailsWithNoData() async {
        let f = Fixture(sleeperOverride: { _ in })        // engine never replies
        await f.generator.generate(model: f.model, gameRecord: f.record)

        guard case .failed(let message) = f.model.stage else {
            Issue.record("expected .failed, got \(f.model.stage)")
            return
        }
        #expect(message.contains("no analysis"))
        #expect(f.session.gobanState.reportGenerationActive == false)
        #expect(f.engine.sent.contains("showboard"))
    }
```

- [ ] **Step 2: Run to verify status** — `-only-testing:"KataGo AnytimeTests/DeepReportGeneratorTests"`.

Expected: all four SHOULD already pass if Task 7's restore paths are correct — run to prove it. Any failure here is a real generator bug: fix the generator (not the test) until green. Pay attention to `engineErrorFailsAndRestores`: the first `Fixture(sleeperOverride:)` line feeds an error to a nil observer (harmless no-op) — the real assertion path uses the second generator.

- [ ] **Step 3: Commit**

```bash
git add "ios/KataGo iOS/KataGo iOSTests/DeepReportGeneratorTests.swift" "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/DeepReportGenerator.swift"
git commit -m "test(report): generator abort/restore path coverage"
```

---

### Task 9: ReportNarrator — deterministic facts + streamed FoundationModels narration

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/ReportNarrator.swift`
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/DeepReportGenerator.swift` (insert narration before `.complete`)
- Create: `ios/KataGo iOS/KataGo iOSTests/ReportNarratorTests.swift`
- Modify: `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj` (test file registration)

**Interfaces:**
- Consumes: `DeepReportModel` (Task 4), `CommentTone.prompt` (existing extension in Commentator.swift), `Config.tone`/`Config.temperature`/`Config.useLLM` (existing).
- Produces:
  - `public enum ReportNarrator`:
    - `static func facts(from model: DeepReportModel) -> [String]` — PURE, `@MainActor`, no FoundationModels: the deterministic fact bullet list. Numbers formatted to whole percents / one-decimal points; deltas within `ReportConstants.winrateNoise`/`scoreNoise` AND probe visits < `lowVisitThreshold` are suffixed `"(within noise)"`.
    - `static func narrate(model: DeepReportModel, tone: CommentTone, temperature: Double) async` — `@MainActor`; guards `#if canImport(FoundationModels)` + `SystemLanguageModel.default.availability`; streams cumulative snapshots into `model.narrative`; on unavailability sets `model.narrativeUnavailableReason`; on any thrown error leaves `narrative` as-is (partial text is fine) and returns.
  - Generator change: after `restore(...)` on the success path, if the game's `useLLM` is true, set `model.stage = .narrating`, `await ReportNarrator.narrate(model:tone:temperature:)`, then `.complete`; else straight to `.complete` (and on tvOS the canImport guard makes narrate a no-op).

- [ ] **Step 1: Register the test file** — `touch` + `ruby /tmp/add_test_file.rb ReportNarratorTests.swift`.

- [ ] **Step 2: Write the failing tests (facts only — the LLM call is not unit-testable)**

Full contents of `ReportNarratorTests.swift`:

```swift
//
//  ReportNarratorTests.swift
//  KataGo AnytimeTests
//

import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

@MainActor
struct ReportNarratorTests {
    private func makeModel() -> DeepReportModel {
        let model = DeepReportModel()
        model.moveNumber = 42
        model.sideToMove = .black
        model.position = PositionSummary(winrate: 0.42, scoreLead: -4.0, visits: 150)
        model.candidates = [
            CandidateReport(vertex: "A1", visits: 100, winrate: 0.40, scoreLead: -5.0,
                            winrateDelta: -0.02, scoreLeadDelta: -1.0, pv: ["A1", "B2"],
                            ownershipDelta: [:],
                            tenuki: TenukiFollowUp(vertex: "B2", winrate: 0.56, scoreLead: 0.5,
                                                   visits: 45, pv: ["B2", "A2"])),
        ]
        model.passComparison = PassComparison(punishmentVertex: "B2", winrate: 0.28, scoreLead: -7.0,
                                              winrateDeltaVsBest: 0.12, scoreLeadDeltaVsBest: 2.0,
                                              ownershipDelta: [:],
                                              contestedPoints: [
                                                ContestedPoint(point: BoardPoint(x: 0, y: 1),
                                                               vertex: "A2", delta: -0.4,
                                                               regionName: "upper left"),
                                              ])
        return model
    }

    @Test func factsCoverEverySection() {
        let facts = ReportNarrator.facts(from: makeModel())
        let joined = facts.joined(separator: "\n")
        #expect(joined.contains("move 42"))
        #expect(joined.contains("Black"))
        #expect(joined.contains("42%"))            // position winrate
        #expect(joined.contains("A1"))             // candidate
        #expect(joined.contains("B2"))             // tenuki reply + punishment
        #expect(joined.contains("pass"))           // pass comparison present
        #expect(joined.contains("upper left"))     // contested region
    }

    @Test func lowVisitSmallDeltasAreMarkedWithinNoise() {
        let model = makeModel()   // candidate delta -0.02 at 100 visits (not low)
        var facts = ReportNarrator.facts(from: model)
        #expect(!facts.joined(separator: "\n").contains("within noise"))

        // Re-build with a low-visit candidate: same delta now within noise.
        model.candidates = [
            CandidateReport(vertex: "A1", visits: 30, winrate: 0.41, scoreLead: -4.5,
                            winrateDelta: -0.01, scoreLeadDelta: -0.5, pv: [],
                            ownershipDelta: [:], tenuki: nil),
        ]
        facts = ReportNarrator.facts(from: model)
        #expect(facts.joined(separator: "\n").contains("within noise"))
    }

    @Test func factsAreDeterministic() {
        let a = ReportNarrator.facts(from: makeModel())
        let b = ReportNarrator.facts(from: makeModel())
        #expect(a == b)
    }
}
```

- [ ] **Step 3: Run to verify failure** — `-only-testing:"KataGo AnytimeTests/ReportNarratorTests"`. Expected: BUILD FAILURE (type doesn't exist).

- [ ] **Step 4: Implement**

Full contents of `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/ReportNarrator.swift`:

```swift
//
//  ReportNarrator.swift
//  KataGoUICore
//
//  Deterministic fact list + streamed FoundationModels narration for the Deep
//  Analysis Report. The LLM NEVER computes: it rewords the facts built here,
//  under instructions forbidding invented moves or numbers. All facts are in
//  the reported side-to-move's perspective (DeepReportModel's contract).
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels   // Apple's on-device LLM — unavailable on tvOS
#endif

public enum ReportNarrator {
    // MARK: - Facts (pure, testable)

    @MainActor
    public static func facts(from model: DeepReportModel) -> [String] {
        var facts: [String] = []
        let side = model.sideToMove == .black ? "Black" : "White"
        facts.append("Position: move \(model.moveNumber), \(side) to play.")

        if let position = model.position {
            facts.append("Current evaluation for \(side): \(percent(position.winrate)) win rate, \(points(position.scoreLead)) points, from \(position.visits) visits.")
        }

        for candidate in model.candidates {
            var line = "Candidate \(candidate.vertex): \(percent(candidate.winrate)) win rate (\(signedPercent(candidate.winrateDelta)) vs the position\(noiseSuffix(candidate.winrateDelta, scoreDelta: candidate.scoreLeadDelta, visits: candidate.visits))), \(points(candidate.scoreLead)) points, \(candidate.visits) visits."
            if !candidate.pv.isEmpty {
                line += " Expected continuation: \(candidate.pv.joined(separator: " "))."
            }
            facts.append(line)
            if let tenuki = candidate.tenuki {
                facts.append("If the opponent ignores \(candidate.vertex) (plays elsewhere), \(side) follows up with \(tenuki.vertex): \(percent(tenuki.winrate)) win rate, \(points(tenuki.scoreLead)) points.")
            }
        }

        if let pass = model.passComparison {
            facts.append("If \(side) passes instead: \(percent(pass.winrate)) win rate — playing the best candidate is worth \(signedPercent(pass.winrateDeltaVsBest)) and \(points(pass.scoreLeadDeltaVsBest)) points; the opponent would punish at \(pass.punishmentVertex).")
            if !pass.contestedPoints.isEmpty {
                let regions = orderedUniqueRegions(pass.contestedPoints)
                facts.append("Most contested areas (largest ownership swings between playing and passing): \(regions.joined(separator: ", ")).")
            }
        }
        return facts
    }

    private static func percent(_ value: Float) -> String {
        String(format: "%.0f%%", value * 100)
    }

    private static func signedPercent(_ value: Float) -> String {
        String(format: "%+.0f%%", value * 100)
    }

    private static func points(_ value: Float) -> String {
        String(format: "%+.1f", value)
    }

    private static func noiseSuffix(_ winrateDelta: Float, scoreDelta: Float, visits: Int) -> String {
        let small = winrateDelta.magnitude < ReportConstants.winrateNoise
            && scoreDelta.magnitude < ReportConstants.scoreNoise
        return (small && visits < ReportConstants.lowVisitThreshold) ? ", within noise" : ""
    }

    private static func orderedUniqueRegions(_ points: [ContestedPoint]) -> [String] {
        var seen = Set<String>()
        return points.compactMap { seen.insert($0.regionName).inserted ? $0.regionName : nil }
    }

    // MARK: - Narration (FoundationModels)

    /// Streams a short narrative over the facts into `model.narrative`.
    /// No-op (with a reason) when Apple Intelligence is unavailable; a thrown
    /// generation error leaves whatever partial text already streamed.
    @MainActor
    public static func narrate(model: DeepReportModel,
                               tone: CommentTone,
                               temperature: Double) async {
#if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else {
            model.narrativeUnavailableReason = "Apple Intelligence is not available on this device."
            return
        }
        let instructions = """
        You are a Go (baduk) teaching assistant. You summarize a game engine's findings for the player to move.
        Rules: Use ONLY the facts provided. Never invent moves, coordinates, or numbers. If a fact is marked "within noise", describe those options as about equally good. Write 2 to 4 short paragraphs of plain prose — no headings, no lists. Adopt \(tone.prompt).
        """
        let prompt = "Engine findings:\n" + facts(from: model).map { "- \($0)" }.joined(separator: "\n")
        do {
            let session = LanguageModelSession(instructions: instructions)
            let stream = session.streamResponse(to: prompt,
                                                options: GenerationOptions(temperature: temperature))
            for try await partial in stream {
                model.narrative = String(describing: partial.content)
            }
        } catch {
            // Keep any partial narrative; the data report stands on its own.
        }
#else
        model.narrativeUnavailableReason = "Apple Intelligence is not available on this platform."
#endif
    }
}
```

API note for the implementer: `streamResponse(to:options:)` for a plain-text prompt yields cumulative snapshots. If the compiler rejects `partial.content` (the element may BE the string snapshot depending on SDK), use `model.narrative = String(describing: partial)` — one-line adaptation; do not restructure. If `String(describing:)` produces wrapper noise in manual testing, switch to the snapshot's documented text property in the current SDK.

- [ ] **Step 5: Hook narration into the generator's success path**

In `DeepReportGenerator.generate`, replace the success arm:

```swift
        do {
            try await runProbes(model: model, session: session, sideToMove: sideToMove)
            restore(session: session, gameRecord: gameRecord)
            if gameRecord.concreteConfig.useLLM {
                model.stage = .narrating
                await ReportNarrator.narrate(model: model,
                                             tone: gameRecord.concreteConfig.tone,
                                             temperature: Double(gameRecord.concreteConfig.temperature))
            }
            model.stage = .complete
        } catch is CancellationError {
```

If `concreteConfig.tone` / `.temperature` / `.useLLM` don't resolve (Config API drift), use the same accessors CommentView/Commentator use: `gameRecord.config?.useLLM ?? false`, `gameRecord.config?.tone ?? .technical`, `Double(gameRecord.config?.temperature ?? Config.defaultTemperature)`.

- [ ] **Step 6: Run narrator suite + generator suite** (generator tests use `useLLM` default false, so narration stays out of their path):

```bash
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/ReportNarratorTests" -only-testing:"KataGo AnytimeTests/DeepReportGeneratorTests"
```

Expected: TEST SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/ReportNarrator.swift" "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/DeepReportGenerator.swift" "ios/KataGo iOS/KataGo iOSTests/ReportNarratorTests.swift" "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(report): deterministic facts + streamed FoundationModels narration"
```

---

### Task 10: ReportBoardView — static mini-board with Δ-ownership and PV overlays

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Rendering/ReportBoardView.swift`

**Interfaces:**
- Consumes: `WidgetBoardView(width:height:blackVertices:whiteVertices:)` and `parseVertex(_:width:height:)` — both public in `KataGoGameStore`, re-exported by KataGoUICore (`@_exported import` in GameStoreReexport.swift), so no extra import.
- Produces: `public struct ReportBoardView: View` with `public enum ReportBoardOverlay { case none, ownershipDelta([BoardPoint: Float], perspective: PlayerColor), pv([String], startingWith: PlayerColor) }` and `public init(width: Int, height: Int, blackVertices: [String], whiteVertices: [String], overlay: ReportBoardOverlay)`. Blue = gain for `perspective`, orange = loss (colorblind-safe pair). The view is square via `.aspectRatio(1, contentMode: .fit)`.
- Geometry contract: replicates WidgetBoardView's cell/origin math exactly (`cell = min(w/width, h/height)`, origins center the grid) so overlays align with its stones. `BoardPoint.y == 0` is the BOTTOM row → screen row = `height - 1 - point.y`.

This is a visual component: verification is compile + previews (no unit test).

- [ ] **Step 1: Implement**

Full contents of `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Rendering/ReportBoardView.swift`:

```swift
//
//  ReportBoardView.swift
//  KataGoUICore
//
//  Static mini-board for the Deep Analysis Report: the widget's vector board
//  plus one overlay layer — an ownership-delta heatmap or a numbered PV.
//  Not bound to live engine state; everything is passed in.
//

import SwiftUI

public enum ReportBoardOverlay {
    case none
    /// White-perspective ownership deltas; rendered relative to `perspective`
    /// (blue = that side gains the point, orange = loses it).
    case ownershipDelta([BoardPoint: Float], perspective: PlayerColor)
    /// Principal variation as GTP vertices; ghost stones alternate colors
    /// starting with `startingWith`. "pass" entries advance numbering unseen.
    case pv([String], startingWith: PlayerColor)
}

public struct ReportBoardView: View {
    let width: Int
    let height: Int
    let blackVertices: [String]
    let whiteVertices: [String]
    let overlay: ReportBoardOverlay

    /// Minimum |Δ| worth painting — smaller swings are visual noise.
    private static let deltaFloor: Float = 0.05

    public init(width: Int, height: Int,
                blackVertices: [String], whiteVertices: [String],
                overlay: ReportBoardOverlay) {
        self.width = width
        self.height = height
        self.blackVertices = blackVertices
        self.whiteVertices = whiteVertices
        self.overlay = overlay
    }

    public var body: some View {
        GeometryReader { geo in
            // Must mirror WidgetBoardView's internal math so overlays align.
            let cell = min(geo.size.width / CGFloat(width), geo.size.height / CGFloat(height))
            let originX = (geo.size.width - cell * CGFloat(width - 1)) / 2
            let originY = (geo.size.height - cell * CGFloat(height - 1)) / 2

            ZStack {
                WidgetBoardView(width: width, height: height,
                                blackVertices: blackVertices, whiteVertices: whiteVertices)
                overlayLayer(cell: cell, originX: originX, originY: originY)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder
    private func overlayLayer(cell: CGFloat, originX: CGFloat, originY: CGFloat) -> some View {
        switch overlay {
        case .none:
            EmptyView()

        case .ownershipDelta(let grid, let perspective):
            let entries = grid.filter { $0.value.magnitude >= Self.deltaFloor }
                .map { (point: $0.key, delta: $0.value) }
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                // Positive delta = toward White; convert to the report side.
                let gain = perspective == .white ? entry.delta > 0 : entry.delta < 0
                RoundedRectangle(cornerRadius: cell * 0.15)
                    .fill(gain ? Color.blue : Color.orange)
                    .opacity(Double(min(entry.delta.magnitude, 0.85)))
                    .frame(width: cell * 0.85, height: cell * 0.85)
                    .position(position(of: entry.point, cell: cell,
                                       originX: originX, originY: originY))
            }

        case .pv(let vertices, let startingWith):
            let stones = pvStones(vertices, startingWith: startingWith)
            ForEach(Array(stones.enumerated()), id: \.offset) { _, stone in
                ZStack {
                    Circle()
                        .fill(stone.color == .black ? Color.black : Color.white)
                        .opacity(0.75)
                    Text("\(stone.number)")
                        .font(.system(size: cell * 0.5, weight: .bold, design: .rounded))
                        .foregroundStyle(stone.color == .black ? Color.white : Color.black)
                }
                .frame(width: cell * 0.92, height: cell * 0.92)
                .position(CGPoint(x: originX + CGFloat(stone.x) * cell,
                                  y: originY + CGFloat(stone.y) * cell))
            }
        }
    }

    private func position(of point: BoardPoint, cell: CGFloat,
                          originX: CGFloat, originY: CGFloat) -> CGPoint {
        // BoardPoint y = 0 is the bottom row; screen y = 0 is the top.
        CGPoint(x: originX + CGFloat(point.x) * cell,
                y: originY + CGFloat(height - 1 - point.y) * cell)
    }

    private struct PVStone {
        let x: Int
        let y: Int   // screen-grid y (0 = top), from parseVertex
        let number: Int
        let color: PlayerColor
    }

    private func pvStones(_ vertices: [String], startingWith: PlayerColor) -> [PVStone] {
        var stones: [PVStone] = []
        var color = startingWith
        for (index, vertex) in vertices.enumerated() {
            defer { color = color == .black ? .white : .black }
            guard vertex != "pass",
                  let grid = parseVertex(vertex, width: width, height: height) else { continue }
            stones.append(PVStone(x: grid.x, y: grid.y, number: index + 1, color: color))
        }
        return stones
    }
}

#Preview("Ownership delta") {
    ReportBoardView(width: 9, height: 9,
                    blackVertices: ["C3", "G7"], whiteVertices: ["G3", "C7"],
                    overlay: .ownershipDelta([BoardPoint(x: 2, y: 6): -0.6,
                                              BoardPoint(x: 6, y: 2): 0.4,
                                              BoardPoint(x: 4, y: 4): 0.08],
                                             perspective: .black))
    .padding()
}

#Preview("PV") {
    ReportBoardView(width: 9, height: 9,
                    blackVertices: ["C3"], whiteVertices: ["G7"],
                    overlay: .pv(["E5", "G5", "pass", "C7"], startingWith: .black))
    .padding()
}
```

- [ ] **Step 2: Build to verify**

```bash
cd "ios/KataGo iOS" && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug -quiet
```

Expected: BUILD SUCCEEDED. (If `parseVertex`'s tuple labels differ, the compiler will say so — its public signature is `parseVertex(_ vertex: String, width: Int, height: Int) -> (x: Int, y: Int)?` with y = 0 at the TOP, matching this code.)

- [ ] **Step 3: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Rendering/ReportBoardView.swift"
git commit -m "feat(report): static mini-board with ownership-delta and PV overlays"
```

---

### Task 11: DeepReportView — the progressive report sheet

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Rendering/DeepReportView.swift`

**Interfaces:**
- Consumes: `DeepReportModel`/`DeepReportGenerator`/`ReportBudgets` (Tasks 4/7), `ReportNarrator.facts` (Task 9), `ReportBoardView` (Task 10), environment object `MessageList` — the ONLY one the entry points must inject (board size, stones, side to move all arrive via the model, seeded by the generator from the session) — plus a plain `gameRecord: GameRecord` property (CommentView pattern).
- Produces: `public struct DeepReportView: View` with `public init(gameRecord: GameRecord)`. Present it wrapped in `NavigationStack` (both platforms). Generation starts in `.task(id: runID)` — dismissing the sheet cancels the task, which the generator turns into abort+restore. Toolbar: Cancel while generating; Done + Copy-to-Comment + Regenerate when finished.

Visual component: verification is compile + previews (generation logic is already tested at the generator level).

- [ ] **Step 1: Implement**

Full contents of `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Rendering/DeepReportView.swift`:

```swift
//
//  DeepReportView.swift
//  KataGoUICore
//
//  The Deep Analysis Report sheet, shared by iOS/visionOS (.sheet) and macOS
//  (NSHostingController + presentAsSheet). Sections render skeletons and fill
//  in as probe stages land; the narrative streams in last. Dismissing the
//  sheet cancels the .task, which the generator turns into abort + restore.
//

import SwiftUI

public struct DeepReportView: View {
    var gameRecord: GameRecord
    @Environment(MessageList.self) var messageList
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = DeepReportModel()
    @State private var runID = 0

    public init(gameRecord: GameRecord) {
        self.gameRecord = gameRecord
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                positionSection
                candidatesSection
                passSection
                narrativeSection
            }
            .padding()
        }
        .navigationTitle("Deep Report")
#if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar { toolbarContent }
        .task(id: runID) {
            model = DeepReportModel()
            let generator = DeepReportGenerator(messageList: messageList)
            await generator.generate(model: model, gameRecord: gameRecord)
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Spec: app backgrounding aborts generation. Dismissing cancels the
            // .task, which the generator turns into abort + restore.
            if newPhase == .background && model.isGenerating {
                dismiss()
            }
        }
    }

    // MARK: - Sections

    private var sideName: String { model.sideToMove == .black ? "Black" : "White" }

    @ViewBuilder
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(gameRecord.name)
                .font(.headline)
            Text("Move \(model.moveNumber) · \(sideName) to play")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let vps = model.visitsPerSecondText {
                Text(vps)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if case .failed(let message) = model.stage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var positionSection: some View {
        if let position = model.position {
            HStack(spacing: 16) {
                statView("Win Rate", String(format: "%.0f%%", position.winrate * 100))
                statView("Score", String(format: "%+.1f", position.scoreLead))
                statView("Visits", "\(position.visits)")
                if position.visits < ReportConstants.lowVisitThreshold {
                    quickEstimateBadge
                }
            }
        } else if model.isGenerating {
            skeletonRow(height: 44)
        }
    }

    @ViewBuilder
    private var candidatesSection: some View {
        if model.candidates.isEmpty && model.isGenerating {
            skeletonRow(height: 180)
        }
        ForEach(model.candidates) { candidate in
            CandidateSectionView(candidate: candidate,
                                 model: model,
                                 sideName: sideName)
        }
    }

    @ViewBuilder
    private var passSection: some View {
        if let pass = model.passComparison {
            VStack(alignment: .leading, spacing: 8) {
                Text("Playing vs. Passing")
                    .font(.title3.bold())
                Text("If \(sideName) passes: \(String(format: "%.0f%%", pass.winrate * 100)) win rate — playing is worth \(String(format: "%+.0f%%", pass.winrateDeltaVsBest * 100)) and \(String(format: "%+.1f", pass.scoreLeadDeltaVsBest)) points. The opponent would punish at \(pass.punishmentVertex).")
                    .font(.callout)
                ReportBoardView(width: model.boardWidth, height: model.boardHeight,
                                blackVertices: model.blackVertices,
                                whiteVertices: model.whiteVertices,
                                overlay: .ownershipDelta(pass.ownershipDelta,
                                                         perspective: model.sideToMove))
                    .frame(maxWidth: 360)
                deltaLegend
                if !pass.contestedPoints.isEmpty {
                    Text("Most contested: " + pass.contestedPoints.map(\.regionName)
                        .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                        .joined(separator: ", "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var narrativeSection: some View {
        if let reason = model.narrativeUnavailableReason {
            if gameRecord.config?.useLLM == true {
                Label(reason, systemImage: "sparkles.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if !model.narrative.isEmpty || model.stage == .narrating {
            VStack(alignment: .leading, spacing: 8) {
                Label("Summary", systemImage: "sparkles")
                    .font(.title3.bold())
                Text(model.narrative)
                if model.stage == .narrating {
                    ProgressView()
                }
            }
        }
    }

    // MARK: - Toolbar & actions

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if model.isGenerating {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }   // cancels .task → abort + restore
            }
            ToolbarItem(placement: .confirmationAction) {
                ProgressView()
            }
        } else {
            ToolbarItem(placement: .cancellationAction) {
                Button("Regenerate", systemImage: "arrow.clockwise") { runID += 1 }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Copy to Comment", systemImage: "text.bubble") { copyToComment() }
                    .disabled(model.position == nil)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func copyToComment() {
        let text = model.narrative.isEmpty
            ? ReportNarrator.facts(from: model).joined(separator: "\n")
            : model.narrative
        if gameRecord.comments == nil { gameRecord.comments = [:] }
        let existing = gameRecord.comments?[gameRecord.currentIndex] ?? ""
        gameRecord.comments?[gameRecord.currentIndex] =
            existing.isEmpty ? text : existing + "\n\n" + text
    }

    // MARK: - Bits

    private func statView(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().bold())
        }
    }

    private var quickEstimateBadge: some View {
        Text("quick estimate")
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.yellow.opacity(0.3), in: Capsule())
    }

    private var deltaLegend: some View {
        HStack(spacing: 12) {
            Label("\(sideName) gains", systemImage: "square.fill")
                .foregroundStyle(.blue)
            Label("\(sideName) loses", systemImage: "square.fill")
                .foregroundStyle(.orange)
        }
        .font(.caption)
    }

    private func skeletonRow(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(.quaternary)
            .frame(height: height)
            .overlay(ProgressView())
    }
}

/// One candidate's block: stats, tenuki callout, and a PV / Δ-ownership
/// toggled mini-board. Own struct so each candidate keeps its own toggle state.
struct CandidateSectionView: View {
    let candidate: CandidateReport
    let model: DeepReportModel
    let sideName: String
    @State private var showsDelta = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Candidate \(candidate.vertex)")
                    .font(.title3.bold())
                if candidate.visits < ReportConstants.lowVisitThreshold {
                    Text("quick estimate")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.yellow.opacity(0.3), in: Capsule())
                }
            }
            Text("\(String(format: "%.0f%%", candidate.winrate * 100)) win rate (\(String(format: "%+.0f%%", candidate.winrateDelta * 100))) · \(String(format: "%+.1f", candidate.scoreLead)) points · \(candidate.visits) visits")
                .font(.callout)
            if let tenuki = candidate.tenuki {
                Label("If ignored, \(sideName) follows up with \(tenuki.vertex) (\(String(format: "%.0f%%", tenuki.winrate * 100)) win rate, \(String(format: "%+.1f", tenuki.scoreLead)) points).",
                      systemImage: "arrow.turn.down.right")
                    .font(.callout)
            }
            if !candidate.pv.isEmpty || !candidate.ownershipDelta.isEmpty {
                Picker("View", selection: $showsDelta) {
                    Text("Variation").tag(false)
                    Text("Δ Ownership").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                ReportBoardView(width: model.boardWidth, height: model.boardHeight,
                                blackVertices: model.blackVertices,
                                whiteVertices: model.whiteVertices,
                                overlay: showsDelta
                                    ? .ownershipDelta(candidate.ownershipDelta,
                                                      perspective: model.sideToMove)
                                    : .pv(candidate.pv, startingWith: model.sideToMove))
                    .frame(maxWidth: 360)
            }
        }
    }
}

#Preview("Filled") {
    let model = DeepReportModel()
    model.moveNumber = 42
    model.sideToMove = .black
    model.boardWidth = 9
    model.boardHeight = 9
    model.blackVertices = ["C3", "G7"]
    model.whiteVertices = ["G3"]
    model.position = PositionSummary(winrate: 0.42, scoreLead: -4.0, visits: 150)
    model.candidates = [
        CandidateReport(vertex: "E5", visits: 100, winrate: 0.40, scoreLead: -5.0,
                        winrateDelta: -0.02, scoreLeadDelta: -1.0, pv: ["E5", "G5", "C7"],
                        ownershipDelta: [BoardPoint(x: 4, y: 4): -0.5],
                        tenuki: TenukiFollowUp(vertex: "G5", winrate: 0.56, scoreLead: 0.5,
                                               visits: 45, pv: ["G5"])),
    ]
    model.passComparison = PassComparison(punishmentVertex: "E5", winrate: 0.28, scoreLead: -7.0,
                                          winrateDeltaVsBest: 0.12, scoreLeadDeltaVsBest: 2.0,
                                          ownershipDelta: [BoardPoint(x: 2, y: 6): -0.6],
                                          contestedPoints: [])
    model.stage = .complete
    model.narrative = "Black is slightly behind here. E5 keeps the game close..."
    return NavigationStack {
        DeepReportViewPreviewHost(model: model)
    }
}

/// Preview host: DeepReportView normally builds its own model in .task; for a
/// static preview we render the same sections through a tiny shim.
private struct DeepReportViewPreviewHost: View {
    let model: DeepReportModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(model.candidates) { candidate in
                    CandidateSectionView(candidate: candidate, model: model, sideName: "Black")
                }
            }
            .padding()
        }
    }
}
```

Note: the preview host renders `CandidateSectionView` directly because `DeepReportView.task` would try to talk to a live engine in previews. Do not add environment-dependent previews for the full view.

- [ ] **Step 2: Build to verify**

```bash
cd "ios/KataGo iOS" && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug -quiet
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Rendering/DeepReportView.swift"
git commit -m "feat(report): progressive DeepReportView sheet"
```

---

### Task 12: iOS/visionOS entry point — More menu item + sheet

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/GameList/PlusMenuView.swift`

**Interfaces:**
- Consumes: `DeepReportView` (Task 11), `GobanState.shouldGenMove(config:player:)`, `GobanState.passCount`, `GobanState.reportGenerationActive`, `GameRecord.concreteConfig`. The sheet inherits ContentView's environment (GobanState, MessageList, Turn, BoardSize, Stones are all injected there), so no `.environment` calls are needed.
- Produces: a "Deep Report" item in the More menu, disabled while an AI move is due, the game is finished (two passes), or a report is already running.

- [ ] **Step 1: Add the menu item, state, and sheet**

In `PlusMenuView.swift`:

1. Add the environment + state (next to the existing `@Environment`/`@State` declarations):

```swift
    @Environment(Turn.self) var player
    @Environment(Stones.self) var stones
    @State private var showingReport = false
```

2. Inside the `if gameRecord != nil { ... }` group that holds Configurations/Developer Mode, add after the "Developer Mode" button:

```swift
                Button {
                    showingReport = true
                } label: {
                    Label("Deep Report", systemImage: "doc.text.magnifyingglass")
                }
                .disabled(reportDisabled)
```

3. Add the gating helper (after the `body` property):

```swift
    /// Deep Report gating: engine/board ready, no in-flight AI move (its
    /// cancellable search would interleave with the probes), game not
    /// finished, no report running.
    private var reportDisabled: Bool {
        guard let gameRecord else { return true }
        return !stones.isReady
            || gobanState.reportGenerationActive
            || gobanState.passCount >= 2
            || gobanState.shouldGenMove(config: gameRecord.concreteConfig, player: player)
    }
```

4. Add the sheet, chained after the existing `.sheet(isPresented: $showingDeveloper)` block:

```swift
        .sheet(isPresented: $showingReport) {
            if let gameRecord {
                NavigationStack {
                    DeepReportView(gameRecord: gameRecord)
                }
            }
        }
```

5. Update the `#Preview` at the bottom — it must now also inject `Turn`:

```swift
#Preview {
    PlusMenuView(
        gameRecord: GameRecord(config: Config()),
        maxBoardLength: 19
    )
    .environment(NavigationContext())
    .environment(GobanState())
    .environment(ThumbnailModel())
    .environment(TopUIState())
    .environment(Turn())
    .environment(Stones())
}
```

- [ ] **Step 2: Build iOS + visionOS**

```bash
cd "ios/KataGo iOS" && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug -quiet && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug -quiet
```

Expected: BUILD SUCCEEDED twice. (If `PlusMenuView` is mounted anywhere that doesn't have `Turn` in the environment — e.g. an empty-state toolbar — the app would crash at @Environment resolution there; `GobanView`/`TopToolbarView` both live under ContentView's injection, and `Turn` is injected there as `session.player`, so all mounts are covered. If a build/preview reveals an uncovered mount, inject `.environment(Turn())` is WRONG — pass the real `session.player` from that mount's owner.)

- [ ] **Step 3: Commit**

```bash
git add "ios/KataGo iOS/KataGo iOS/GameList/PlusMenuView.swift"
git commit -m "feat(report): iOS/visionOS Deep Report entry in the More menu"
```

---

### Task 13: macOS entry point — Game menu item + presentAsSheet

**Files:**
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/AppDelegate.swift` (gameMenu(), ~line 264)
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/MainWindowController.swift` (new action + validateMenuItem case)

**Interfaces:**
- Consumes: `DeepReportView` (Task 11) wrapped in `NavigationStack`, `NSHostingController`, `presentAsSheet` (precedent: InspectorInfoViewController.swift:435), `MainWindowController.session`/`navigationContext` (existing properties), the AppDelegate target-nil responder-chain menu convention.
- Produces: Game menu → "Deep Analysis Report…" (no key equivalent), enabled only with a selected game, board ready, no AI move due, game not finished, no report running. The hosting view injects the single environment object DeepReportView declares: messageList.

- [ ] **Step 1: Add the menu item**

In `AppDelegate.swift` `gameMenu()`, after the "Deactivate Branch" item (before `return menu`):

```swift
        menu.addItem(.separator())

        // Generates the Deep Analysis Report sheet for the current position.
        // No key equivalent (an infrequent, deliberate action). Routed through
        // the responder chain; validateMenuItem gates it on a selected game,
        // no AI move in flight, and no report already running.
        menu.addItem(withTitle: "Deep Analysis Report…",
                     action: #selector(MainWindowController.showDeepReport(_:)),
                     keyEquivalent: "")
```

- [ ] **Step 2: Add the action to MainWindowController**

In `MainWindowController.swift`, near the other Game-menu actions (e.g. after `toggleEditing(_:)` ~line 2266):

```swift
    // MARK: - Deep Analysis Report

    /// Game-menu "Deep Analysis Report…": presents the shared SwiftUI report
    /// sheet. Injects exactly the environment objects DeepReportView declares
    /// (messageList only) — the InspectorTabs wrapper pattern. Sheet size comes
    /// from the SwiftUI root's min frame (the ConfigEditorViewController
    /// precedent uses AppKit constraints).
    @objc func showDeepReport(_ sender: Any?) {
        guard let gameRecord = navigationContext.selectedGameRecord,
              !session.gobanState.reportGenerationActive else { return }
        let root = NavigationStack {
            DeepReportView(gameRecord: gameRecord)
        }
        .environment(session.messageList)
        .frame(minWidth: 560, minHeight: 640)
        let hosting = NSHostingController(rootView: root)
        contentViewController?.presentAsSheet(hosting)
    }
```

- [ ] **Step 3: Gate it in validateMenuItem**

Locate `validateMenuItem(_:)` in `MainWindowController.swift` (it owns enable state for the Game-menu items) and add, alongside the existing per-action cases:

```swift
        if menuItem.action == #selector(showDeepReport(_:)) {
            guard let gameRecord = navigationContext.selectedGameRecord else { return false }
            return session.stones.isReady
                && !session.gobanState.reportGenerationActive
                && session.gobanState.passCount < 2
                && !session.gobanState.shouldGenMove(config: gameRecord.concreteConfig,
                                                     player: session.player)
        }
```

- [ ] **Step 4: Build macOS**

```bash
cd "ios/KataGo iOS" && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS' -configuration Debug -quiet
```

Expected: BUILD SUCCEEDED. (Reminder: the macOS scheme is `KataGo Anytime Mac` — the `KataGo Anytime` scheme does not build for macOS.)

- [ ] **Step 5: Commit**

```bash
git add "ios/KataGo iOS/KataGo Anytime Mac/AppDelegate.swift" "ios/KataGo iOS/KataGo Anytime Mac/MainWindowController.swift"
git commit -m "feat(report): macOS Deep Analysis Report menu item + sheet"
```

---

### Task 14: Final verification sweep

**Files:** none (verification only; fix-forward anything found, in the task where it belongs).

- [ ] **Step 1: Full unit suite**

```bash
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17'
```

Expected: TEST SUCCEEDED, zero failures. (CI runs no tests — this local run is the only gate.)

- [ ] **Step 2: All-platform builds**

```bash
cd "ios/KataGo iOS" \
  && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug -quiet \
  && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug -quiet \
  && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS' -configuration Debug -quiet
```

Also confirm the tvOS target still builds (the package gained files that must compile there):

```bash
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime TV" -destination 'generic/platform=tvOS' -configuration Debug -quiet
```

(If the TV scheme name differs, list schemes with `xcodebuild -list -project "KataGo Anytime.xcodeproj"` and use the TV one.)

Expected: BUILD SUCCEEDED for all.

- [ ] **Step 3: Manual QA on the iOS Simulator (run the app, Developer Mode console open in a second window if useful)**

Walk this checklist against a real game with analysis running:

1. More menu → Deep Report: sheet opens instantly with skeletons; sections fill in; total ≲ 15 s on the simulator (sim is slower than device — the 5 s target is a device number).
2. While generating: Cancel dismisses; reopen the game — board position unchanged, analysis overlay streaming again (the restore + re-arm worked; verify via Developer Mode: a `showboard` and `kata-analyze` appear after the cancel).
3. Complete report: candidates show PV toggle boards, tenuki callouts, pass section with heatmap; visits shown; "quick estimate" badges appear when visits are low.
4. With per-game "Apple Intelligence" (useLLM) ON: narrative streams into the Summary section (device/sim with Apple Intelligence only; otherwise the unavailability hint shows).
5. Copy to Comment: text lands in the comment for the current move; existing comment is appended to, not replaced.
6. Regenerate: report rebuilds; engine state still consistent afterwards.
7. Branch-position report: enter a variation (play a non-mainline move on a locked game), generate — header shows the branch move number; after Done, branch still active, no record corruption (game list thumbnail unchanged).
8. AI-vs-human game with AI to move: the Deep Report menu item is disabled.
9. macOS: Game menu → Deep Analysis Report… presents a ≥560×640 sheet; report completes; ⌘-menu items disabled while generating (validateMenuItem); after Done, live analysis resumes in the window.

- [ ] **Step 4: Update the spec status line**

In `docs/superpowers/specs/2026-07-03-deep-analysis-report-design.md`, change the Status bullet to `Implemented (see docs/superpowers/plans/2026-07-03-deep-analysis-report.md)`. Commit:

```bash
git add docs/superpowers/specs/2026-07-03-deep-analysis-report-design.md
git commit -m "docs: mark deep analysis report spec implemented"
```

---

## Deferred (explicitly NOT in this plan — from the spec's v2 list)

- Depth picker (quick/standard/deep budgets)
- Persistent/structured report storage; report sharing
- Non-modal macOS report window with staleness indicator
- Tapping a report candidate to play it on the live board
