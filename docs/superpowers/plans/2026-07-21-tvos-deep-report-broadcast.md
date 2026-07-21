# tvOS Deep-Report Broadcast Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the tvOS "KataGo vs KataGo" self-play loop with a commentated broadcast: every move gets a Deep Analysis Report whose three boards are shown one-by-one full-size with typewriter-streamed fact text, then the engine plays the next move, endlessly.

**Architecture:** A new `BroadcastController` (KataGoUICore, fully unit-testable) drives a per-move cycle: run `DeepReportGenerator` on the current position → start the slideshow as soon as the snapshot stage lands (~2 s) → stream deterministic `ReportNarrator` facts per slide with a typewriter → issue a single licensed gen-move when the last slide starts → loop on the turn-change signal. The TV screen (`TVSelfPlayScreen`) hosts the controller, overlays a full-size `ReportBoardView` on the hero slot during slides, and swaps its panel to the streaming text. Pausing cancels the cycle and restores today's full interactive screen (cursor play, Top Moves picks, Undo).

**Tech Stack:** SwiftUI (tvOS 26), Swift Testing, existing KataGoUICore Report machinery (`DeepReportGenerator`/`DeepReportModel`/`ReportNarrator`/`ReportBoardView`), GTP over the in-process engine.

## Design decisions (from the grilled design session, all user-confirmed)

- Target = tvOS **self-play spectate only** (review screen untouched). The broadcast **replaces** the current fast loop in both manual and attract entry.
- The **existing genmove machinery plays the moves** (keeps opening variety via cfg temperature, pass/game-end/RE handling); the report never places moves.
- **Every move** gets a report segment; after the **first pass**, reports are skipped (plain genmove to the interstitial).
- Slides = **Best Move (PV board) → Alternative (Δ-ownership board) → Playing vs. Passing (Δ board)** — all three, in that order, only the ones whose data landed.
- Text = **deterministic ReportNarrator facts** (tvOS has no FoundationModels), revealed word-by-word; a slide advances on typewriter-complete + dwell, with a minimum slide time.
- **Slideshow starts at snapshot completion** (~2 s); later facts stream in append-only. **Gen-move is sent when the final slide starts** so the stone lands as the live board returns.
- Controls while running: right/Select = skip slide, Play/Pause = pause, Menu = exit. **Pause = today's interactive screen**; resume re-enters the loop (report first). Attract stays any-press-exits.
- A `.failed`/`.cancelled` report silently skips its slideshow and plays the move.
- Winrate headline + score chart are fed from the **report snapshot** (converted to black-positive); continuous kata-analyze never streams while the broadcast runs.

## Engine-state protocol (the load-bearing invariants — read before touching Tasks 3, 4, 6)

1. **`analysisStatus` stays `.clear` while the broadcast runs.** `BoardView`'s turn observer calls `maybeRequestAnalysis` at every turn change; with `.clear` it is inert (`shouldRequestAnalysis` requires `!= .clear`). Without this, a continuous-analyze command issued at the same turn change that starts a report cycle leaves an un-acked `=` crossing the generator's `lineObserver` swap → `ReportCollector` FIFO desync → "engine produced no analysis" (the documented round-7 stray-ack failure class in `project_deep_analysis_report`).
2. **`suppressesGenMove` stays `true` for the whole broadcast** (running AND paused). The single gen-move per cycle is licensed by a new one-shot `GobanState.broadcastGenMovePending`, consumed exactly once in `GameSession.postProcessAIMove` — so a gen-move reply can never re-enter the free-running loop, and the pause/pick/undo machinery keeps today's semantics.
3. **`issueGenMove` re-asserts `.clear` before sending.** After a paused-interactive stretch, status is `.run`; setting `.clear` fires TVRootView's status observer (`"stop"`), whose ack drains ahead of the gen-move reply on the FIFO pipe — never near a collector swap.
4. **Never call `maybePauseAnalysis()` around report generation** (round-7 gotcha). The generator's own probe cancellation + `restore()` leave the engine idle.
5. **BoardView stays mounted across the whole broadcast.** Its `onAppear` resets the turn to `.unknown` and sends `showboard` — remounting it per slide would fire spurious turn-change edges into the cycle trigger. The slide board is an overlay in a `ZStack`.

## Global Constraints

- English-only in ALL committed content (code, comments, docs) — no CJK anywhere.
- NEVER modify SwiftData `@Model` classes (`GameRecord`, `Config`) — CloudKit schema is frozen.
- Shared-package (`KataGoUICore`) changes must be **additive**: iOS/macOS/visionOS Deep Report behavior stays byte-identical (existing narrator/report tests must pass unchanged).
- Working directory for all build/test commands: `ios/KataGo iOS/`.
- Tests run ONLY on iOS Simulator (scheme `KataGo Anytime`, iPhone 17). ⚠️ `-only-testing` cannot select a Swift Testing suite (0 tests = vacuous pass) — always run the full test action and grep the output.
- ⚠️ Piped `xcodebuild` exit codes lie — use `set -o pipefail` and/or grep for `** TEST SUCCEEDED **` / `** BUILD SUCCEEDED **`.
- New files in Xcode targets (TV app target, `KataGo AnytimeTests`) must be registered in the pbxproj via the `xcodeproj` Ruby gem (filename-only `new_reference` — a group-prefixed path doubles). SwiftPM files under `KataGoUICore/Sources/` need no registration.
- Commit after each task; do NOT push (Xcode Cloud pushes are spaced ≥ ~1 day by project policy).
- All five schemes must still build: `KataGo Anytime`, `KataGo Anytime Mac`, `KataGo Anytime Vision`, `KataGo Anytime TV`, `KataGo Anytime Watch`.

---

### Task 1: ReportNarrator per-section fact functions

Split `ReportNarrator.facts(from:)` into three public per-section builders so the broadcast can assign facts to slides. `facts(from:)` becomes a composition and its output stays byte-identical (existing `ReportNarratorTests` pin it).

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/ReportNarrator.swift`
- Test: `ios/KataGo iOS/KataGo iOSTests/ReportNarratorTests.swift` (extend — file already registered)

**Interfaces:**
- Produces (used by Task 2):
  - `ReportNarrator.positionFacts(from model: DeepReportModel) -> [String]` (@MainActor)
  - `ReportNarrator.candidateFacts(from model: DeepReportModel, index: Int) -> [String]` (@MainActor; `[]` for out-of-range index)
  - `ReportNarrator.passFacts(from model: DeepReportModel) -> [String]` (@MainActor; `[]` when `passComparison == nil`)

- [ ] **Step 1: Write the failing test**

Append to the existing `ReportNarratorTests` struct in `ios/KataGo iOS/KataGo iOSTests/ReportNarratorTests.swift`:

```swift
    /// The broadcast consumes facts per section; facts(from:) must be exactly
    /// the concatenation so the two surfaces can never drift.
    @Test func factsAreTheConcatenationOfSectionFacts() {
        let model = makeModel()
        let composed = ReportNarrator.positionFacts(from: model)
            + model.candidates.indices.flatMap { ReportNarrator.candidateFacts(from: model, index: $0) }
            + ReportNarrator.passFacts(from: model)
        #expect(composed == ReportNarrator.facts(from: model))
    }

    @Test func sectionFactsAreEmptyForMissingSections() {
        let model = DeepReportModel()
        model.sideToMove = .black
        #expect(ReportNarrator.positionFacts(from: model).count == 1)   // position line only
        #expect(ReportNarrator.candidateFacts(from: model, index: 0).isEmpty)
        #expect(ReportNarrator.candidateFacts(from: model, index: 5).isEmpty)
        #expect(ReportNarrator.passFacts(from: model).isEmpty)
    }

    @Test func candidateFactsCarryTenukiWhenPresent() {
        let model = makeModel()
        let facts = ReportNarrator.candidateFacts(from: model, index: 0)
        #expect(facts.count == 2)                       // candidate line + tenuki line
        #expect(facts[0].hasPrefix("Best move A1"))
        #expect(facts[1].contains("ignores A1"))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd "ios/KataGo iOS" && set -o pipefail && xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -30
```
Expected: BUILD FAILED — `positionFacts`/`candidateFacts`/`passFacts` do not exist.

- [ ] **Step 3: Implement the split**

In `ReportNarrator.swift`, replace the body of `facts(from:)` and add the three functions. The string-building lines move verbatim from the current `facts(from:)` — do not reword any text:

```swift
    @MainActor
    public static func facts(from model: DeepReportModel) -> [String] {
        positionFacts(from: model)
            + model.candidates.indices.flatMap { candidateFacts(from: model, index: $0) }
            + passFacts(from: model)
    }

    /// "Position: …" + the current-evaluation line (when the snapshot landed).
    @MainActor
    public static func positionFacts(from model: DeepReportModel) -> [String] {
        var facts: [String] = []
        let side = model.sideToMove == .black ? "Black" : "White"
        facts.append("Position: move \(model.moveNumber), \(side) to play.")
        if let position = model.position {
            facts.append("Current evaluation for \(side): \(percent(position.winrate)) win rate, \(points(position.scoreLead)) points, from \(position.visits) visits.")
        }
        return facts
    }

    /// One candidate's fact line (+ its tenuki line when present). Labels
    /// match the report UI ("Best move …" / "Alternative …").
    @MainActor
    public static func candidateFacts(from model: DeepReportModel, index: Int) -> [String] {
        guard model.candidates.indices.contains(index) else { return [] }
        let candidate = model.candidates[index]
        let side = model.sideToMove == .black ? "Black" : "White"
        let opponent = model.sideToMove == .black ? "White" : "Black"
        var facts: [String] = []
        let label = index == 0 ? "Best move" : "Alternative"
        var line = "\(label) \(candidate.vertex): \(percent(candidate.winrate)) win rate (\(signedPercent(candidate.winrateDelta)) vs the position\(noiseSuffix(candidate.winrateDelta, scoreDelta: candidate.scoreLeadDelta, visits: candidate.visits))), \(points(candidate.scoreLead)) points, \(candidate.visits) visits."
        if !candidate.pv.isEmpty {
            line += " Expected continuation: \(candidate.pv.joined(separator: " "))."
        }
        facts.append(line)
        if let tenuki = candidate.tenuki {
            facts.append("If \(opponent) ignores \(candidate.vertex) (plays elsewhere), \(side) follows up with \(tenuki.vertex): \(percent(tenuki.winrate)) win rate, \(points(tenuki.scoreLead)) points.")
        }
        return facts
    }

    /// The pass-comparison fact (+ contested-areas line when present).
    @MainActor
    public static func passFacts(from model: DeepReportModel) -> [String] {
        guard let pass = model.passComparison else { return [] }
        let side = model.sideToMove == .black ? "Black" : "White"
        let opponent = model.sideToMove == .black ? "White" : "Black"
        var facts: [String] = []
        let best = model.candidates.first.flatMap { $0.vertex == "pass" ? nil : $0.vertex }
        let playing = best.map { "playing \($0)" } ?? "playing the best candidate"
        var fact = "If \(side) passes instead: \(percent(pass.winrate)) win rate — \(playing) is worth \(signedPercent(pass.winrateDeltaVsBest)) and \(points(pass.scoreLeadDeltaVsBest)) points; \(opponent) would punish at \(pass.punishmentVertex)"
        if let best {
            fact += " if \(side) doesn't play at \(best)"
        }
        facts.append(fact + ".")
        if !pass.contestedPoints.isEmpty {
            let regions = orderedUniqueRegions(pass.contestedPoints)
            facts.append("Most contested areas (largest ownership swings between playing and passing): \(regions.joined(separator: ", ")).")
        }
        return facts
    }
```

Delete the old monolithic body (the moved lines) from the previous `facts(from:)`.

- [ ] **Step 4: Run tests to verify they pass**

Same command as Step 2. Expected: `** TEST SUCCEEDED **`, and every pre-existing `ReportNarratorTests` case still green (the byte-identical pin).

- [ ] **Step 5: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/ReportNarrator.swift" "ios/KataGo iOS/KataGo iOSTests/ReportNarratorTests.swift"
git commit -m "refactor(report): split narrator facts into per-section builders"
```

---

### Task 2: BroadcastScript — slides, typewriter chunks, constants

Pure slide-building over a (possibly still-generating) `DeepReportModel`. No engine, no timing — fully unit-tested.

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/BroadcastScript.swift`
- Create + register: `ios/KataGo iOS/KataGo iOSTests/BroadcastScriptTests.swift`

**Interfaces:**
- Consumes: Task 1's `positionFacts`/`candidateFacts`/`passFacts`; existing `ReportBoardOverlay`, `ReportMarkedMove`, `DeepReportModel`.
- Produces (used by Tasks 4, 5):
  - `enum BroadcastSlideKind: Equatable, Sendable { case best, alternative, pass }`
  - `struct BroadcastSlide { let kind: BroadcastSlideKind; let title: String; let facts: [String]; let overlay: ReportBoardOverlay; let markedMove: ReportMarkedMove? }`
  - `enum BroadcastConstants { charactersPerSecond: Double = 30; dwellSeconds: TimeInterval = 2.5; minimumSlideSeconds: TimeInterval = 6.0; pollSeconds: TimeInterval = 0.1 }`
  - `BroadcastScript.slides(from model: DeepReportModel) -> [BroadcastSlide]` (@MainActor)
  - `BroadcastScript.factsMayGrow(kind: BroadcastSlideKind, model: DeepReportModel) -> Bool` (@MainActor)
  - `BroadcastScript.typewriterChunks(_ text: String) -> [String]`
  - `extension DeepReportModel.Stage { var isSettled: Bool }` (true for `.complete`/`.failed`/`.cancelled`)

- [ ] **Step 1: Write the failing test**

Create `ios/KataGo iOS/KataGo iOSTests/BroadcastScriptTests.swift`:

```swift
//
//  BroadcastScriptTests.swift
//  KataGo AnytimeTests
//
//  Pure slide-building for the tvOS Deep-Report Broadcast: which slides exist
//  for a partially/fully generated report model, their titles/facts/overlays,
//  the may-still-grow signal the typewriter waits on, and word chunking.
//

import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

@MainActor
struct BroadcastScriptTests {
    private func candidate(_ vertex: String, tenuki: TenukiFollowUp? = nil,
                           delta: [BoardPoint: Float] = [:]) -> CandidateReport {
        CandidateReport(vertex: vertex, visits: 100, winrate: 0.55, scoreLead: 1.5,
                        winrateDelta: -0.01, scoreLeadDelta: -0.5, pv: [vertex, "C3"],
                        ownershipDelta: delta, tenuki: tenuki)
    }

    private func fullModel() -> DeepReportModel {
        let model = DeepReportModel()
        model.sideToMove = .black
        model.candidates = [
            candidate("Q16", tenuki: TenukiFollowUp(vertex: "R14", winrate: 0.6,
                                                    scoreLead: 2.0, visits: 40, pv: ["R14"])),
            candidate("D4", delta: [BoardPoint(x: 3, y: 3): -0.4]),
        ]
        model.passComparison = PassComparison(punishmentVertex: "Q16", winrate: 0.3,
                                              scoreLead: -5.0, winrateDeltaVsBest: 0.2,
                                              scoreLeadDeltaVsBest: 6.0,
                                              ownershipDelta: [BoardPoint(x: 15, y: 15): 0.5],
                                              contestedPoints: [])
        model.stage = .complete
        return model
    }

    @Test func fullReportYieldsThreeSlidesInOrder() {
        let slides = BroadcastScript.slides(from: fullModel())
        #expect(slides.map(\.kind) == [.best, .alternative, .pass])
        #expect(slides[0].title == "Best Move Q16")
        #expect(slides[1].title == "Alternative D4")
        #expect(slides[2].title == "Playing vs. Passing")
    }

    @Test func bestSlideLeadsWithPositionFactsAndUsesPVOverlay() {
        let model = fullModel()
        let best = BroadcastScript.slides(from: model)[0]
        #expect(best.facts.first?.hasPrefix("Position: move") == true)
        #expect(best.facts.contains { $0.hasPrefix("Best move Q16") })
        guard case .pv(let vertices, let starting) = best.overlay else {
            Issue.record("expected PV overlay"); return
        }
        #expect(vertices == ["Q16", "C3"])
        #expect(starting == .black)
        #expect(best.markedMove == nil)
    }

    @Test func alternativeSlideUsesDeltaOverlayWithMarkedMove() {
        let alternative = BroadcastScript.slides(from: fullModel())[1]
        guard case .ownershipDelta = alternative.overlay else {
            Issue.record("expected delta overlay"); return
        }
        #expect(alternative.markedMove?.vertex == "D4")
        #expect(alternative.markedMove?.color == .black)
    }

    @Test func alternativeWithoutDeltaFallsBackToPVWithoutMark() {
        let model = fullModel()
        model.candidates[1] = candidate("D4")   // empty ownershipDelta
        let alternative = BroadcastScript.slides(from: model)[1]
        guard case .pv = alternative.overlay else {
            Issue.record("expected PV fallback"); return
        }
        #expect(alternative.markedMove == nil)
    }

    @Test func passSlideMarksTheBestMove() {
        let pass = BroadcastScript.slides(from: fullModel())[2]
        #expect(pass.markedMove?.vertex == "Q16")
        #expect(pass.facts.first?.contains("passes instead") == true)
    }

    @Test func partialModelYieldsOnlyLandedSlides() {
        let model = fullModel()
        model.passComparison = nil
        model.stage = .snapshot
        #expect(BroadcastScript.slides(from: model).map(\.kind) == [.best, .alternative])
        model.candidates = []
        #expect(BroadcastScript.slides(from: model).isEmpty)
    }

    @Test func factsMayGrowOnlyWhileACandidateAwaitsTenuki() {
        let model = fullModel()
        model.stage = .tenuki(1)
        #expect(!BroadcastScript.factsMayGrow(kind: .best, model: model))        // tenuki landed
        model.candidates[1] = candidate("D4")                                     // no tenuki yet
        #expect(BroadcastScript.factsMayGrow(kind: .alternative, model: model))
        #expect(!BroadcastScript.factsMayGrow(kind: .pass, model: model))         // never grows
        model.stage = .complete
        #expect(!BroadcastScript.factsMayGrow(kind: .alternative, model: model))  // settled
    }

    @Test func stageSettlement() {
        #expect(DeepReportModel.Stage.complete.isSettled)
        #expect(DeepReportModel.Stage.failed("x").isSettled)
        #expect(DeepReportModel.Stage.cancelled.isSettled)
        #expect(!DeepReportModel.Stage.snapshot.isSettled)
        #expect(!DeepReportModel.Stage.narrating.isSettled)
    }

    @Test func typewriterChunksRoundTrip() {
        let text = "Best move Q16: 55% win rate."
        let chunks = BroadcastScript.typewriterChunks(text)
        #expect(chunks.joined() == text)
        #expect(chunks.count == 6)                 // one chunk per word incl. its space
        #expect(BroadcastScript.typewriterChunks("").isEmpty)
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
ref = group.new_reference("BroadcastScriptTests.swift")   # filename ONLY — a group-prefixed path doubles
target.source_build_phase.add_file_reference(ref)
project.save
'
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
cd "ios/KataGo iOS" && set -o pipefail && xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -30
```
Expected: BUILD FAILED — `BroadcastScript` not defined.

- [ ] **Step 4: Implement BroadcastScript**

Create `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/BroadcastScript.swift`:

```swift
//
//  BroadcastScript.swift
//  KataGoUICore
//
//  Pure slide-building for the tvOS Deep-Report Broadcast. A slideshow is
//  derived from a DeepReportModel that may still be generating: only slides
//  whose sections landed exist, and a candidate slide's fact list can grow
//  once (its tenuki line) while probes are still running. All content reuses
//  ReportNarrator's per-section facts and the report UI's titles, so the
//  broadcast can never drift from what the iOS report sheet shows.
//

import Foundation

public enum BroadcastSlideKind: Equatable, Sendable {
    case best
    case alternative
    case pass
}

/// One board-plus-facts segment of the broadcast.
public struct BroadcastSlide {
    public let kind: BroadcastSlideKind
    public let title: String
    public let facts: [String]
    public let overlay: ReportBoardOverlay
    public let markedMove: ReportMarkedMove?
}

/// Broadcast pacing knobs (QA-tunable, not load-bearing).
public enum BroadcastConstants {
    /// Typewriter reveal speed.
    public static let charactersPerSecond: Double = 30
    /// Absorb-the-board pause after a slide's text completes.
    public static let dwellSeconds: TimeInterval = 2.5
    /// Short facts must not flash by: a slide's floor including typing time.
    public static let minimumSlideSeconds: TimeInterval = 6.0
    /// Controller poll cadence while waiting on generation stages.
    public static let pollSeconds: TimeInterval = 0.1
}

public extension DeepReportModel.Stage {
    /// Generation reached an end state — no further sections will land.
    /// (`.narrating` is NOT settled: it precedes `.complete`, though facts
    /// no longer change there.)
    var isSettled: Bool {
        switch self {
        case .complete, .failed, .cancelled: return true
        case .idle, .snapshot, .passProbe, .tenuki, .narrating: return false
        }
    }
}

@MainActor
public enum BroadcastScript {
    /// The slides whose report sections have landed, in broadcast order.
    /// Overlay choices mirror the iOS report sheet: the best candidate shows
    /// its variation (its Δ-vs-root is ~zero by construction), the
    /// alternative shows Δ-ownership with the candidate marked, and the pass
    /// comparison shows its Δ grid with the best move marked.
    public static func slides(from model: DeepReportModel) -> [BroadcastSlide] {
        var slides: [BroadcastSlide] = []
        if let best = model.candidates.first {
            slides.append(BroadcastSlide(
                kind: .best,
                title: "Best Move \(best.vertex)",
                facts: ReportNarrator.positionFacts(from: model)
                    + ReportNarrator.candidateFacts(from: model, index: 0),
                overlay: .pv(best.pv, startingWith: model.sideToMove),
                markedMove: nil))
        }
        if model.candidates.count > 1 {
            let alternative = model.candidates[1]
            let hasDelta = !alternative.ownershipDelta.isEmpty
            slides.append(BroadcastSlide(
                kind: .alternative,
                title: "Alternative \(alternative.vertex)",
                facts: ReportNarrator.candidateFacts(from: model, index: 1),
                overlay: hasDelta
                    ? .ownershipDelta(alternative.ownershipDelta)
                    : .pv(alternative.pv, startingWith: model.sideToMove),
                markedMove: hasDelta
                    ? ReportMarkedMove(vertex: alternative.vertex, color: model.sideToMove)
                    : nil))
        }
        if let pass = model.passComparison {
            slides.append(BroadcastSlide(
                kind: .pass,
                title: "Playing vs. Passing",
                facts: ReportNarrator.passFacts(from: model),
                overlay: .ownershipDelta(pass.ownershipDelta),
                markedMove: model.candidates.first.map {
                    ReportMarkedMove(vertex: $0.vertex, color: model.sideToMove)
                }))
        }
        return slides
    }

    /// Whether a slide's fact list can still gain a line (a candidate's
    /// tenuki fact lands mid-typewriter on the first slide). The typewriter
    /// waits on this instead of the whole generation, so an early slide never
    /// blocks on later stages that belong to other slides.
    public static func factsMayGrow(kind: BroadcastSlideKind, model: DeepReportModel) -> Bool {
        guard !model.stage.isSettled else { return false }
        switch kind {
        case .best:
            return model.candidates.first?.tenuki == nil
        case .alternative:
            return model.candidates.count > 1 && model.candidates[1].tenuki == nil
        case .pass:
            return false
        }
    }

    /// Word-chunks with separators preserved: joined chunks reproduce the
    /// exact text, so the typewriter can append chunk-by-chunk.
    public static func typewriterChunks(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == " " {
                chunks.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Same command as Step 3. Expected: `** TEST SUCCEEDED **` with `BroadcastScriptTests` cases listed as passed.

- [ ] **Step 6: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/BroadcastScript.swift" "ios/KataGo iOS/KataGo iOSTests/BroadcastScriptTests.swift" "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(tv): broadcast slide script over the deep-report model"
```

---

### Task 3: The licensed gen-move (GobanState + GameSession)

The broadcast keeps `suppressesGenMove == true` forever, so `postProcessAIMove` would drop every gen-move reply. Add a one-shot license: `GobanState.broadcastGenMovePending`, set when the broadcast issues its gen-move, consumed exactly once when the `play` reply arrives.

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/GobanState.swift` (near `suppressesGenMove`, and near `requestAnalysis`)
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Session/GameSession.swift` (`postProcessAIMove`, the guard at ~line 455)
- Create + register: `ios/KataGo iOS/KataGo iOSTests/BroadcastGenMoveTests.swift`

**Interfaces:**
- Consumes: existing `GtpCommandBuilder.genMoveAnalyzeCommands(effectiveProfile:maxTime:interval:maxMoves:)`, `Config` accessors (`blackMaxTime`, `whiteMaxTime`, `effectiveHumanProfileForBlack/White`, `analysisInterval`, `maxAnalysisMoves`).
- Produces (used by Task 4):
  - `GobanState.broadcastGenMovePending: Bool` (public var, default `false`)
  - `GobanState.requestBroadcastGenMove(config: Config, messageList: MessageList, nextColorForPlayCommand: PlayerColor?)` — no-op when `passCount >= 2` or the side to move has `maxTime == 0`; otherwise arms the license, sends the gen-move-analyze bundle, sets `waitingForAnalysis = true`.

- [ ] **Step 1: Write the failing test**

Create `ios/KataGo iOS/KataGo iOSTests/BroadcastGenMoveTests.swift` (fixture mirrors `GameSessionPostProcessAIMoveGuardTests`):

```swift
//
//  BroadcastGenMoveTests.swift
//  KataGo AnytimeTests
//
//  The tvOS broadcast's licensed gen-move: suppressesGenMove stays true for
//  the whole broadcast, so a single gen-move reply is let through
//  postProcessAIMove by the one-shot broadcastGenMovePending license —
//  armed by requestBroadcastGenMove, consumed on the first play line.
//

import Testing
import SwiftUI
import SwiftData
@testable import KataGoUICore

@MainActor
struct BroadcastGenMoveTests {

    private final class CapturedMove {
        var value: String?
    }

    @MainActor
    private struct Fixture {
        let session = GameSession()
        let navigation = NavigationContext()
        let audioModel = AudioModel()
        let record: GameRecord
        let captured = CapturedMove()

        init() {
            // The real broadcast record: createGameRecord + both maxTimes 1.0
            // (requestBroadcastGenMove is a no-op for a side with maxTime 0).
            record = SelfPlayGame.makeRecord()
            navigation.selectedGameRecord = record
            session.board.width = 19
            session.board.height = 19
            session.player.nextColorForPlayCommand = .black
            session.gobanState.suppressesGenMove = true   // broadcast invariant
        }

        func receivePlayReply() {
            let captured = self.captured
            session.postProcessAIMove(message: "play Q16",
                                      navigationContext: navigation,
                                      audioModel: audioModel,
                                      aiMove: Binding(get: { captured.value },
                                                      set: { captured.value = $0 }))
        }

        func sent(_ fragment: String) -> Bool {
            session.messageList.messages.contains { $0.text.contains(fragment) }
        }
    }

    @Test("requestBroadcastGenMove arms the license and sends the bundle")
    func requestArmsAndSends() {
        let f = Fixture()
        let config = f.record.concreteConfig

        f.session.gobanState.requestBroadcastGenMove(config: config,
                                                     messageList: f.session.messageList,
                                                     nextColorForPlayCommand: .black)

        #expect(f.session.gobanState.broadcastGenMovePending)
        #expect(f.sent("kata-search_analyze_cancellable"))
        #expect(f.session.gobanState.waitingForAnalysis)
    }

    @Test("Game over (two passes): no command, no license")
    func gameOverIsANoOp() {
        let f = Fixture()
        f.session.gobanState.passCount = 2

        f.session.gobanState.requestBroadcastGenMove(config: f.record.concreteConfig,
                                                     messageList: f.session.messageList,
                                                     nextColorForPlayCommand: .black)

        #expect(!f.session.gobanState.broadcastGenMovePending)
        #expect(!f.sent("kata-search_analyze_cancellable"))
    }

    @Test("Licensed reply plays through suppression, exactly once")
    func licensePlaysOneReply() {
        let f = Fixture()
        f.session.gobanState.broadcastGenMovePending = true

        f.receivePlayReply()

        #expect(f.captured.value == "Q16")
        #expect(f.sent("play b Q16"))
        #expect(!f.session.gobanState.broadcastGenMovePending)   // consumed

        // A second stray play line is back to the plain suppression drop.
        f.captured.value = nil
        f.session.player.nextColorForPlayCommand = .white
        f.receivePlayReply()
        #expect(f.captured.value == nil)
    }

    @Test("License is consumed even when another guard drops the reply")
    func licenseConsumedOnDroppedReply() {
        let f = Fixture()
        f.session.gobanState.broadcastGenMovePending = true
        f.session.gobanState.pendingMoveTurn = "b"     // pick mid-legality-check

        f.receivePlayReply()

        #expect(f.captured.value == nil)
        #expect(!f.session.gobanState.broadcastGenMovePending)
    }

    @Test("Unlicensed suppression still drops (the existing pin)")
    func unlicensedStillDrops() {
        let f = Fixture()

        f.receivePlayReply()

        #expect(f.captured.value == nil)
        #expect(!f.sent("play b Q16"))
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
ref = group.new_reference("BroadcastGenMoveTests.swift")
target.source_build_phase.add_file_reference(ref)
project.save
'
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
cd "ios/KataGo iOS" && set -o pipefail && xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -30
```
Expected: BUILD FAILED — `broadcastGenMovePending` / `requestBroadcastGenMove` not defined.

- [ ] **Step 4: Implement the license**

In `GobanState.swift`, directly below the `public var suppressesGenMove = false` declaration, add:

```swift
    /// The tvOS broadcast's one-shot gen-move license. The broadcast keeps
    /// `suppressesGenMove` true for its whole lifetime (the turn observer
    /// must never free-run the game), so its single per-cycle gen-move reply
    /// would be dropped by postProcessAIMove's guard — this flag licenses
    /// exactly one reply through it; postProcessAIMove consumes it.
    public var broadcastGenMovePending = false
```

Below `requestAnalysis(config:messageList:nextColorForPlayCommand:)`, add:

```swift
    /// Issue the broadcast's single gen-move for the side to move. Mirrors
    /// getRequestAnalysisCommands' gen-move branch but bypasses the
    /// suppressesGenMove gate via the one-shot license instead of clearing it
    /// (which would re-enter the free-running loop at the next turn change).
    public func requestBroadcastGenMove(config: Config,
                                        messageList: MessageList,
                                        nextColorForPlayCommand: PlayerColor?) {
        guard passCount < 2 else { return }
        let commands: [String]
        if nextColorForPlayCommand == .black, config.blackMaxTime > 0 {
            commands = GtpCommandBuilder.genMoveAnalyzeCommands(
                effectiveProfile: config.effectiveHumanProfileForBlack,
                maxTime: config.blackMaxTime,
                interval: config.analysisInterval,
                maxMoves: config.maxAnalysisMoves)
        } else if nextColorForPlayCommand == .white, config.whiteMaxTime > 0 {
            commands = GtpCommandBuilder.genMoveAnalyzeCommands(
                effectiveProfile: config.effectiveHumanProfileForWhite,
                maxTime: config.whiteMaxTime,
                interval: config.analysisInterval,
                maxMoves: config.maxAnalysisMoves)
        } else {
            return
        }
        broadcastGenMovePending = true
        messageList.appendAndSend(commands: commands)
        waitingForAnalysis = true
    }
```

In `GameSession.swift` `postProcessAIMove`, replace the existing guard:

```swift
        guard !gobanState.suppressesGenMove,
              !gobanState.isAutoPlaying,
              gobanState.pendingMoveTurn == nil else { return }
```

with:

```swift
        // The tvOS broadcast licenses exactly ONE gen-move reply through the
        // suppression guard (suppressesGenMove stays true for its whole
        // lifetime). The license is consumed on this play line even when a
        // later guard drops it — the broadcast re-issues per cycle, and a
        // stale license must never leak a future stray reply through.
        let broadcastLicensed = gobanState.broadcastGenMovePending
        gobanState.broadcastGenMovePending = false
        guard broadcastLicensed || !gobanState.suppressesGenMove,
              !gobanState.isAutoPlaying,
              gobanState.pendingMoveTurn == nil else { return }
```

- [ ] **Step 5: Run tests to verify they pass**

Same command as Step 3. Expected: `** TEST SUCCEEDED **` — including every pre-existing `GameSessionPostProcessAIMoveGuardTests` case (the unlicensed paths are untouched).

- [ ] **Step 6: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/GobanState.swift" "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Session/GameSession.swift" "ios/KataGo iOS/KataGo iOSTests/BroadcastGenMoveTests.swift" "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(tv): one-shot licensed gen-move through the suppression guard"
```

---

### Task 4: BroadcastController — the cycle state machine

The heart of the feature: report → slides → gen-move → chain, with pause/resume/skip, snapshot stats, endgame skip, and failure degradation. Lives in KataGoUICore with injectable generation + sleeper seams so every path is unit-testable on the iOS simulator.

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/BroadcastController.swift`
- Create + register: `ios/KataGo iOS/KataGo iOSTests/BroadcastControllerTests.swift`

**Interfaces:**
- Consumes: Task 2's `BroadcastScript`/`BroadcastSlide`/`BroadcastConstants`/`isSettled`; Task 3's `requestBroadcastGenMove`; existing `DeepReportGenerator`, `ReportSleeper`, `GameSession` model objects.
- Produces (used by Tasks 5, 6):
  - `enum BroadcastPhase: Equatable, Sendable { case idle, generating, slides(Int), awaitingMove, paused }`
  - `@Observable @MainActor final class BroadcastController` with:
    - `init(messageList:gobanState:player:rootWinrate:rootScore:generateReport:sleeper:)` (last two default to the real generator and `Task.sleep`)
    - `phase: BroadcastPhase`, `currentSlide: BroadcastSlide?`, `slideNumber: Int`, `slideCount: Int`, `typedText: String`, `reportModel: DeepReportModel?` (all read-only outside)
    - `isShowingSlides: Bool`
    - `noteTurnChanged(game: GameRecord)`, `skipSlide()`, `pause(game: GameRecord) async`, `resume(game: GameRecord)`, `cancelAll()`

- [ ] **Step 1: Write the failing test**

Create `ios/KataGo iOS/KataGo iOSTests/BroadcastControllerTests.swift`:

```swift
//
//  BroadcastControllerTests.swift
//  KataGo AnytimeTests
//
//  The broadcast cycle state machine, with a scripted report generator and a
//  yield-only sleeper so every path runs timing-free. Spin-waits are bounded
//  MainActor yield loops (the controller's tasks are MainActor too, so
//  yielding drives them deterministically forward).
//

import Testing
import SwiftData
@testable import KataGoUICore

@MainActor
struct BroadcastControllerTests {

    private static func stageFullReport(_ model: DeepReportModel) {
        model.sideToMove = .black
        model.boardWidth = 9
        model.boardHeight = 9
        model.moveNumber = 3
        model.position = PositionSummary(winrate: 0.6, scoreLead: 2.0, visits: 200)
        model.candidates = [
            CandidateReport(vertex: "E5", visits: 120, winrate: 0.6, scoreLead: 2.0,
                            winrateDelta: 0, scoreLeadDelta: 0, pv: ["E5", "C3"],
                            ownershipDelta: [:],
                            tenuki: TenukiFollowUp(vertex: "C3", winrate: 0.65,
                                                   scoreLead: 3.0, visits: 40, pv: ["C3"])),
            CandidateReport(vertex: "C3", visits: 60, winrate: 0.58, scoreLead: 1.5,
                            winrateDelta: -0.02, scoreLeadDelta: -0.5, pv: ["C3"],
                            ownershipDelta: [BoardPoint(x: 2, y: 2): -0.4],
                            tenuki: TenukiFollowUp(vertex: "E5", winrate: 0.6,
                                                   scoreLead: 2.0, visits: 30, pv: ["E5"])),
        ]
        model.passComparison = PassComparison(punishmentVertex: "E5", winrate: 0.35,
                                              scoreLead: -3.0, winrateDeltaVsBest: 0.25,
                                              scoreLeadDeltaVsBest: 5.0,
                                              ownershipDelta: [:], contestedPoints: [])
        model.stage = .complete
    }

    @MainActor
    private struct Fixture {
        let session = GameSession()
        let record: GameRecord
        let controller: BroadcastController

        init(generate: @escaping @MainActor (DeepReportModel, GameRecord) async -> Void
                = { model, _ in BroadcastControllerTests.stageFullReport(model) }) {
            // The real broadcast record: createGameRecord + both maxTimes 1.0
            // (requestBroadcastGenMove is a no-op for a side with maxTime 0).
            record = SelfPlayGame.makeRecord()
            session.board.width = 9
            session.board.height = 9
            session.player.nextColorForPlayCommand = .black
            session.gobanState.suppressesGenMove = true
            session.gobanState.analysisStatus = .clear
            controller = BroadcastController(messageList: session.messageList,
                                             gobanState: session.gobanState,
                                             player: session.player,
                                             rootWinrate: session.rootWinrate,
                                             rootScore: session.rootScore,
                                             generateReport: generate,
                                             sleeper: { _ in await Task.yield() })
        }

        func sent(_ fragment: String) -> Bool {
            session.messageList.messages.contains { $0.text.contains(fragment) }
        }

        func sentCount(_ fragment: String) -> Int {
            session.messageList.messages.filter { $0.text.contains(fragment) }.count
        }

        /// Bounded MainActor pump: yields until the condition holds.
        func pump(until condition: () -> Bool) async {
            for _ in 0..<20_000 {
                if condition() { return }
                await Task.yield()
            }
            Issue.record("pump timed out")
        }
    }

    @Test("A full cycle: slides in order, gen-move at the last slide, awaitingMove")
    func fullCycleRunsSlidesAndIssuesGenMove() async {
        let f = Fixture()

        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.phase == .awaitingMove })

        #expect(f.sent("kata-search_analyze_cancellable"))
        #expect(f.session.gobanState.broadcastGenMovePending)
        #expect(f.controller.currentSlide == nil)
        #expect(f.controller.typedText.isEmpty)
        // Snapshot stats were written black-positive at slideshow start.
        #expect(f.session.rootWinrate.black == 0.6)
        #expect(f.session.rootScore.black == 2.0)
        #expect(f.record.scoreLeads?[f.record.currentIndex] == 2.0)
        #expect(f.record.winRates?[f.record.currentIndex] == 0.6)
    }

    @Test("Turn change mid-slides chains straight into the next cycle")
    func moveLandedMidSlidesChains() async {
        let f = Fixture()

        f.controller.noteTurnChanged(game: f.record)
        // The gen-move goes out when the LAST slide starts; simulate its
        // reply landing while a slide is still typing.
        await f.pump(until: { f.session.gobanState.broadcastGenMovePending })
        f.session.player.nextColorForPlayCommand = .white
        f.controller.noteTurnChanged(game: f.record)

        // The finished cycle chains into a second one whose own gen-move
        // makes two sends total (the transient awaitingMove between cycles
        // is too brief to pump on), then the second cycle parks.
        await f.pump(until: { f.sentCount("kata-search_analyze_cancellable") >= 2 })
        await f.pump(until: { f.controller.phase == .awaitingMove })
    }

    @Test("Skip fast-forwards slides; skipping the last slide issues the gen-move")
    func skipAdvancesSlides() async {
        let f = Fixture()

        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.isShowingSlides })
        f.controller.skipSlide()
        await f.pump(until: { f.controller.slideNumber >= 2 })
        f.controller.skipSlide()
        await f.pump(until: { f.controller.slideNumber >= 3 })
        f.controller.skipSlide()
        await f.pump(until: { f.controller.phase == .awaitingMove })
        #expect(f.sent("kata-search_analyze_cancellable"))
    }

    @Test("First pass: no report segment, immediate gen-move")
    func firstPassSkipsReport() async {
        let f = Fixture()
        f.session.gobanState.passCount = 1

        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.phase == .awaitingMove })

        #expect(f.controller.reportModel == nil)
        #expect(f.sent("kata-search_analyze_cancellable"))
    }

    @Test("Game over: the cycle trigger goes idle")
    func gameOverGoesIdle() async {
        let f = Fixture()
        f.session.gobanState.passCount = 2

        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.phase == .idle })
        #expect(!f.sent("kata-search_analyze_cancellable"))
    }

    @Test("Failed generation: no slides, the move still plays")
    func failureDegradesToPlainMove() async {
        let f = Fixture(generate: { model, _ in model.stage = .failed("no analysis") })

        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.phase == .awaitingMove })

        #expect(f.controller.currentSlide == nil)
        #expect(f.sent("kata-search_analyze_cancellable"))
    }

    @Test("Pause cancels the cycle and re-arms continuous analysis for the interactive screen")
    func pauseCancelsAndRearms() async {
        let f = Fixture(generate: { model, _ in
            model.sideToMove = .black
            model.candidates = [CandidateReport(vertex: "E5", visits: 10, winrate: 0.5,
                                                scoreLead: 0, winrateDelta: 0, scoreLeadDelta: 0,
                                                pv: ["E5"], ownershipDelta: [:], tenuki: nil)]
            while !Task.isCancelled { await Task.yield() }
            model.stage = .cancelled
        })

        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.isShowingSlides })
        await f.controller.pause(game: f.record)

        #expect(f.controller.phase == .paused)
        #expect(f.controller.currentSlide == nil)
        #expect(f.session.gobanState.analysisStatus == .run)
        #expect(f.sent("kata-analyze"))                        // continuous re-arm
        #expect(f.session.gobanState.suppressesGenMove)        // invariant holds
        #expect(!f.sent("kata-search_analyze_cancellable"))    // no gen-move while paused
    }

    @Test("Resume runs a fresh full cycle and restores the .clear protocol at gen-move time")
    func resumeRestoresProtocol() async {
        let f = Fixture()

        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.phase == .awaitingMove })
        await f.controller.pause(game: f.record)
        #expect(f.session.gobanState.analysisStatus == .run)

        f.controller.resume(game: f.record)
        await f.pump(until: { f.controller.phase == .awaitingMove })
        #expect(f.session.gobanState.analysisStatus == .clear)
    }

    @Test("cancelAll abandons everything and returns to idle")
    func cancelAllReturnsToIdle() async {
        let f = Fixture()

        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.isShowingSlides })
        f.controller.cancelAll()

        #expect(f.controller.phase == .idle)
        #expect(f.controller.currentSlide == nil)
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
ref = group.new_reference("BroadcastControllerTests.swift")
target.source_build_phase.add_file_reference(ref)
project.save
'
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
cd "ios/KataGo iOS" && set -o pipefail && xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -30
```
Expected: BUILD FAILED — `BroadcastController` not defined.

- [ ] **Step 4: Implement BroadcastController**

Create `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/BroadcastController.swift`:

```swift
//
//  BroadcastController.swift
//  KataGoUICore
//
//  Drives the tvOS self-play "commentated broadcast" loop:
//  report → slides → licensed gen-move → (turn change) → report …
//
//  Engine-state protocol (see the broadcast plan; all four are load-bearing):
//  - analysisStatus stays .clear while the broadcast runs, so BoardView's
//    turn observer never issues an analyze command at the same turn change
//    that starts a report cycle. An un-acked `=` crossing the generator's
//    lineObserver swap would desync the ReportCollector FIFO (the round-7
//    stray-ack class).
//  - suppressesGenMove stays true for the whole broadcast; the single
//    per-cycle gen-move is licensed via gobanState.broadcastGenMovePending,
//    consumed exactly once in GameSession.postProcessAIMove.
//  - issueGenMove re-asserts .clear BEFORE sending (a paused-interactive
//    stretch runs .run): the status observer's "stop" ack then drains ahead
//    of the gen-move reply on the FIFO pipe, never near a collector swap.
//  - maybePauseAnalysis is NEVER called around generation; the generator's
//    probe cancellation + restore() leave the engine idle on their own.
//

import SwiftUI

public enum BroadcastPhase: Equatable, Sendable {
    case idle
    case generating
    case slides(Int)
    case awaitingMove
    case paused
}

@Observable
@MainActor
public final class BroadcastController {
    public private(set) var phase: BroadcastPhase = .idle
    public private(set) var currentSlide: BroadcastSlide?
    /// 1-based number of the showing slide, 0 between slideshows.
    public private(set) var slideNumber = 0
    /// Highest slide count observed this cycle (for progress dots).
    public private(set) var slideCount = 0
    public private(set) var typedText = ""
    public private(set) var reportModel: DeepReportModel?

    private let messageList: MessageList
    private let gobanState: GobanState
    private let player: Turn
    private let rootWinrate: Winrate
    private let rootScore: Score
    /// Report seam — tests script model stages instead of probing an engine.
    private let generateReport: @MainActor (DeepReportModel, GameRecord) async -> Void
    private let sleeper: ReportSleeper

    private var cycleTask: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?
    private var moveLanded = false
    private var genMoveIssued = false
    private var skipRequested = false

    public init(messageList: MessageList,
                gobanState: GobanState,
                player: Turn,
                rootWinrate: Winrate,
                rootScore: Score,
                generateReport: (@MainActor (DeepReportModel, GameRecord) async -> Void)? = nil,
                sleeper: @escaping ReportSleeper = { try await Task.sleep(for: .seconds($0)) }) {
        self.messageList = messageList
        self.gobanState = gobanState
        self.player = player
        self.rootWinrate = rootWinrate
        self.rootScore = rootScore
        self.generateReport = generateReport ?? { [messageList] model, game in
            await DeepReportGenerator(messageList: messageList)
                .generate(model: model, gameRecord: game)
        }
        self.sleeper = sleeper
    }

    public var isShowingSlides: Bool { currentSlide != nil }

    /// The screen's turn-change hook (fires off BoardView's shared observer
    /// signal). Starts the first cycle, chains the next one, or records that
    /// the pre-sent gen-move's stone landed mid-slideshow.
    public func noteTurnChanged(game: GameRecord) {
        guard player.nextColorForPlayCommand != .unknown else { return }
        switch phase {
        case .idle, .awaitingMove:
            startCycle(game: game)
        case .generating, .slides:
            if genMoveIssued { moveLanded = true }
        case .paused:
            break
        }
    }

    /// Fast-forward: end the current slide now. Past the last slide this
    /// exits the slideshow, which issues the gen-move ("play the move now").
    public func skipSlide() {
        skipRequested = true
    }

    /// Cancel the running cycle (probe cancellation → restore) and hand the
    /// screen to the interactive paused UI. Continuous analysis re-arms so
    /// the Top Moves list fills — unlike the old self-play pause there is no
    /// live stream to freeze, because the broadcast never runs one.
    public func pause(game: GameRecord) async {
        let task = cycleTask
        cycleTask = nil
        task?.cancel()
        await task?.value
        currentSlide = nil
        typedText = ""
        slideNumber = 0
        phase = .paused
        gobanState.analysisStatus = .run
        gobanState.requestAnalysis(config: game.concreteConfig,
                                   messageList: messageList,
                                   nextColorForPlayCommand: player.nextColorForPlayCommand)
    }

    /// Re-enter the loop from the current (possibly user-altered) position.
    /// The next cycle's first probe cancels the paused screen's continuous
    /// analyze mid-stream — the safe, iOS-identical cancellation (its `=`
    /// ack was consumed long ago). issueGenMove restores the .clear protocol
    /// at the cycle's end.
    public func resume(game: GameRecord) {
        guard phase == .paused else { return }
        startCycle(game: game)
    }

    /// Teardown / new-game restart: abandon everything. The generator's
    /// probe-session defer runs restore() on cancellation, so the engine
    /// comes back to the game position on its own.
    public func cancelAll() {
        cycleTask?.cancel()
        cycleTask = nil
        generationTask?.cancel()
        generationTask = nil
        currentSlide = nil
        typedText = ""
        slideNumber = 0
        phase = .idle
    }

    // MARK: - Cycle

    private func startCycle(game: GameRecord) {
        guard cycleTask == nil else { return }
        guard gobanState.passCount < 2 else {
            phase = .idle
            return
        }
        moveLanded = false
        genMoveIssued = false
        skipRequested = false
        slideCount = 0
        guard gobanState.passCount == 0 else {
            // Endgame formality (grilled decision): once passing starts,
            // no report segments — answer immediately, the interstitial
            // machinery takes over after the second pass.
            reportModel = nil
            issueGenMove(game: game)
            phase = .awaitingMove
            return
        }
        phase = .generating
        cycleTask = Task { [weak self] in
            guard let self else { return }
            let chain = await self.runCycle(game: game)
            self.cycleTask = nil
            if chain {
                self.startCycle(game: game)
            }
        }
    }

    /// Returns true when the gen-move's stone already landed mid-slideshow,
    /// so the caller chains straight into the next cycle.
    private func runCycle(game: GameRecord) async -> Bool {
        let model = DeepReportModel()
        reportModel = model
        let generation = Task { [generateReport] in
            await generateReport(model, game)
        }
        generationTask = generation

        // Overlap-at-snapshot: the slideshow starts as soon as the first
        // slide's data lands (~2 s), while pass/tenuki probes continue.
        while BroadcastScript.slides(from: model).isEmpty && !model.stage.isSettled {
            if Task.isCancelled {
                generation.cancel()
                await generation.value
                return false
            }
            try? await sleeper(BroadcastConstants.pollSeconds)
        }
        writeSnapshotStats(model: model, game: game)

        var index = 0
        while !Task.isCancelled {
            let slides = BroadcastScript.slides(from: model)
            if index >= slides.count {
                if model.stage.isSettled { break }
                try? await sleeper(BroadcastConstants.pollSeconds)
                continue
            }
            phase = .slides(index)
            slideNumber = index + 1
            slideCount = max(slides.count, slideCount)
            currentSlide = slides[index]
            if model.stage.isSettled && index == slides.count - 1 && !genMoveIssued {
                // Early gen-move (grilled decision): sent as the FINAL slide
                // starts, so the reply lands invisibly (hero and panel both
                // show report content) and the stone appears the moment the
                // live board returns. Generation is settled — restore() ran.
                await generation.value
                issueGenMove(game: game)
            }
            await typewrite(slideIndex: index, model: model)
            index += 1
        }

        if Task.isCancelled {
            generation.cancel()
        }
        await generation.value
        currentSlide = nil
        typedText = ""
        slideNumber = 0
        if Task.isCancelled { return false }
        if !genMoveIssued {
            issueGenMove(game: game)
        }
        phase = .awaitingMove
        return moveLanded
    }

    /// Types one slide's facts word-by-word, tolerating a fact list that is
    /// still growing (slide 1's tenuki line lands mid-typewriter), then
    /// dwells so short slides don't flash by.
    private func typewrite(slideIndex: Int, model: DeepReportModel) async {
        typedText = ""
        var elapsed: TimeInterval = 0
        var factIndex = 0
        while !Task.isCancelled && !skipRequested {
            let slides = BroadcastScript.slides(from: model)
            guard slideIndex < slides.count else { break }
            let slide = slides[slideIndex]
            let facts = slide.facts
            if factIndex < facts.count {
                for chunk in BroadcastScript.typewriterChunks(facts[factIndex]) {
                    guard !Task.isCancelled && !skipRequested else { break }
                    typedText += chunk
                    let delay = Double(chunk.count) / BroadcastConstants.charactersPerSecond
                    try? await sleeper(delay)
                    elapsed += delay
                }
                typedText += "\n"
                factIndex += 1
            } else if BroadcastScript.factsMayGrow(kind: slide.kind, model: model) {
                try? await sleeper(BroadcastConstants.pollSeconds)
                elapsed += BroadcastConstants.pollSeconds
            } else {
                break
            }
        }
        if skipRequested {
            skipRequested = false
            return
        }
        guard !Task.isCancelled else { return }
        let dwell = max(BroadcastConstants.minimumSlideSeconds - elapsed,
                        BroadcastConstants.dwellSeconds)
        try? await sleeper(dwell)
    }

    private func issueGenMove(game: GameRecord) {
        guard !genMoveIssued else { return }
        guard gobanState.passCount < 2 else { return }
        genMoveIssued = true
        // Restore the broadcast protocol BEFORE the gen-move: after a
        // paused-interactive stretch status is .run, and the .clear
        // transition fires the TV root's "stop" — its ack drains ahead of
        // the gen-move reply on the FIFO pipe, and .clear keeps BoardView's
        // turn observer silent at the upcoming turn change.
        if gobanState.analysisStatus != .clear {
            gobanState.analysisStatus = .clear
        }
        gobanState.requestBroadcastGenMove(config: game.concreteConfig,
                                           messageList: messageList,
                                           nextColorForPlayCommand: player.nextColorForPlayCommand)
    }

    /// The broadcast never streams continuous analysis, so the winrate
    /// headline and score chart are fed from the report's own snapshot
    /// (side-to-move perspective → black-positive).
    private func writeSnapshotStats(model: DeepReportModel, game: GameRecord) {
        guard let position = model.position else { return }
        let blackWinrate = model.sideToMove == .black ? position.winrate : 1 - position.winrate
        let blackScore = model.sideToMove == .black ? position.scoreLead : -position.scoreLead
        rootWinrate.black = blackWinrate
        rootScore.black = blackScore
        game.winRates?[game.currentIndex] = blackWinrate
        withAnimation(.spring) {
            game.scoreLeads?[game.currentIndex] = blackScore
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Same command as Step 3. Expected: `** TEST SUCCEEDED **` with all `BroadcastControllerTests` green. If a pump times out, check MainActor scheduling first — every controller task and the sleeper must stay on the MainActor for yield-pumping to drive them.

- [ ] **Step 6: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/BroadcastController.swift" "ios/KataGo iOS/KataGo iOSTests/BroadcastControllerTests.swift" "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(tv): broadcast cycle controller (report -> slides -> licensed gen-move)"
```

---

### Task 5: TV slide views + previews

The hero-slot slide board and the streaming side panel, plus RenderPreview coverage.

**Files:**
- Create + register (TV target): `ios/KataGo iOS/KataGo Anytime TV/TVBroadcastSlideView.swift`

**Interfaces:**
- Consumes: `BroadcastSlide`, `DeepReportModel`, `ReportBoardView` (Task 2 / existing).
- Produces (used by Task 6):
  - `struct TVBroadcastSlideBoard: View { let slide: BroadcastSlide; let model: DeepReportModel }` — full-size opaque report board for the 1080 pt hero slot.
  - `struct TVBroadcastSlidePanel: View { let title: String; let text: String; let slideNumber: Int; let slideCount: Int }` — slide title, typed text, progress dots.

- [ ] **Step 1: Implement the views**

Create `ios/KataGo iOS/KataGo Anytime TV/TVBroadcastSlideView.swift`:

```swift
//
//  TVBroadcastSlideView.swift
//  KataGo Anytime TV
//
//  The broadcast's slide presentation: a full-size ReportBoardView in the
//  hero slot (opaque backdrop so the live board underneath can't ghost
//  through) and the side panel's title + typewriter text + progress dots.
//  Both are pure value renderers — the BroadcastController owns all state.
//

import SwiftUI
import KataGoUICore

/// The hero-slot slide board. Sized by the parent (the 1080 pt square).
struct TVBroadcastSlideBoard: View {
    let slide: BroadcastSlide
    let model: DeepReportModel

    var body: some View {
        ReportBoardView(width: model.boardWidth, height: model.boardHeight,
                        blackVertices: model.blackVertices,
                        whiteVertices: model.whiteVertices,
                        overlay: slide.overlay,
                        markedMove: slide.markedMove,
                        isClassicStoneStyle: model.isClassicStoneStyle,
                        showCoordinate: model.showCoordinate,
                        verticalFlip: model.verticalFlip)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
    }
}

/// The side panel's slide content: title, streaming facts, progress dots.
struct TVBroadcastSlidePanel: View {
    let title: String
    let text: String
    let slideNumber: Int
    let slideCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.bold())
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(text)
                .font(.body)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            if slideCount > 1 {
                HStack(spacing: 10) {
                    ForEach(1...slideCount, id: \.self) { number in
                        Circle()
                            .fill(number == slideNumber ? Color.tvWoodAccent
                                                        : Color(white: 0.4))
                            .frame(width: 12, height: 12)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
@MainActor
private func previewModel() -> DeepReportModel {
    let model = DeepReportModel()
    model.sideToMove = .black
    model.boardWidth = 19
    model.boardHeight = 19
    model.blackVertices = ["Q16", "D4", "Q4"]
    model.whiteVertices = ["D16", "Q3"]
    model.candidates = [
        CandidateReport(vertex: "R14", visits: 210, winrate: 0.56, scoreLead: 1.8,
                        winrateDelta: 0, scoreLeadDelta: 0,
                        pv: ["R14", "R10", "Q12"], ownershipDelta: [:],
                        tenuki: nil),
        CandidateReport(vertex: "C6", visits: 90, winrate: 0.53, scoreLead: 0.9,
                        winrateDelta: -0.03, scoreLeadDelta: -0.9, pv: ["C6"],
                        ownershipDelta: [BoardPoint(x: 2, y: 5): -0.5,
                                         BoardPoint(x: 3, y: 6): 0.3],
                        tenuki: nil),
    ]
    return model
}

#Preview("Slide board — Best (PV)") {
    TVBroadcastSlideBoard(slide: BroadcastScript.slides(from: previewModel())[0],
                          model: previewModel())
        .frame(width: 900, height: 900)
}

#Preview("Slide board — Alternative (delta)") {
    TVBroadcastSlideBoard(slide: BroadcastScript.slides(from: previewModel())[1],
                          model: previewModel())
        .frame(width: 900, height: 900)
}

#Preview("Slide panel — streaming") {
    TVBroadcastSlidePanel(title: "Best Move R14",
                          text: "Position: move 12, Black to play.\nBest move R14: 56% win rate",
                          slideNumber: 1,
                          slideCount: 3)
        .frame(width: 500, height: 900)
        .background(.thinMaterial)
}
#endif
```

- [ ] **Step 2: Register the file in the TV target**

```bash
cd "ios/KataGo iOS" && ruby -e '
require "xcodeproj"
project = Xcodeproj::Project.open("KataGo Anytime.xcodeproj")
target = project.targets.find { |t| t.name == "KataGo Anytime TV" }
group = project.main_group.find_subpath("KataGo Anytime TV", false)
ref = group.new_reference("TVBroadcastSlideView.swift")
target.source_build_phase.add_file_reference(ref)
project.save
'
```

- [ ] **Step 3: Build the TV scheme**

```bash
cd "ios/KataGo iOS" && set -o pipefail && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime TV" -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Render the previews (visual check)**

Use the Xcode MCP `RenderPreview` tool with `sourceFilePath: "KataGo Anytime TV/TVBroadcastSlideView.swift"`, `previewDefinitionIndexInFile: 0`, then `1`, then `2` (0-based per file; the active scheme can stay `KataGo Anytime TV`). Expected: PV board with numbered ghost stones; Δ board with grayscale squares and a red-dotted marked stone; panel with title, two text lines, and three dots with the first highlighted.

- [ ] **Step 5: Commit**

```bash
git add "ios/KataGo iOS/KataGo Anytime TV/TVBroadcastSlideView.swift" "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(tv): broadcast slide board and streaming panel views"
```

---

### Task 6: TVSelfPlayScreen integration

Wire the controller into the self-play screen: broadcast entry protocol, hero-slot slide overlay, panel swap, controls, pause/resume, restart/teardown.

**Files:**
- Modify: `ios/KataGo iOS/KataGo Anytime TV/TVSelfPlayScreen.swift`

**Interfaces:**
- Consumes: `BroadcastController`, `BroadcastPhase`, `TVBroadcastSlideBoard`, `TVBroadcastSlidePanel` (Tasks 4–5).
- Produces: user-visible behavior only.

Apply the following edits (function-by-function; unchanged code not shown is left exactly as is):

- [ ] **Step 1: Add controller state and the turn-change hook**

Add to the `@State` block:

```swift
    /// The broadcast loop driver (created at entry — it needs the session's
    /// environment objects). nil only before startIfNeeded runs.
    @State private var broadcast: BroadcastController?
```

Replace the `isPaused` computed property:

```swift
    /// Paused = the broadcast handed the screen to the interactive UI.
    /// (suppressesGenMove is no longer the pause signal — it stays true for
    /// the whole broadcast; the licensed gen-move plays the moves.)
    private var isPaused: Bool { broadcast?.phase == .paused }

    private var isShowingSlides: Bool { broadcast?.isShowingSlides == true }
```

In `content`, after the existing `.onChange(of: gobanState.passCount)` modifier, add:

```swift
        .onChange(of: player.nextColorForPlayCommand) { _, newValue in
            // The broadcast's cycle trigger — mirrors BoardView's turn
            // observer signal. BoardView's own observer is inert while the
            // broadcast runs (analysisStatus .clear), so this is the only
            // reaction to a landed stone.
            guard newValue != .unknown, let game, !isGameOver else { return }
            broadcast?.noteTurnChanged(game: game)
        }
```

- [ ] **Step 2: Overlay the slide board on the hero slot**

Wrap the existing `BoardView(...)` (keeping ALL of its modifiers on the ZStack's board child exactly as they are) in a `ZStack`, and gate the board's focusability on the broadcast being paused:

```swift
                    ZStack {
                        BoardView(gameRecord: game,
                                  interactive: false,
                                  showsCapturedStones: false,
                                  showsPass: false,
                                  showsWinrateBar: false,
                                  highlightedPoint: highlightedPoint,
                                  cursorPoint: ghost.point,
                                  commentIsFocused: $commentFocused)
                            // ... (existing modifiers unchanged, EXCEPT:)
                            // .focusable(route.entry == .manual)  →
                            .focusable(route.entry == .manual && isPaused)

                        if let broadcast, let slide = broadcast.currentSlide,
                           let model = broadcast.reportModel {
                            TVBroadcastSlideBoard(slide: slide, model: model)
                                // Skip controls: right/Select advance the
                                // slide; past the last one the move plays
                                // immediately. Attract stays unfocusable so
                                // any press exits at the root.
                                .focusable(route.entry == .manual)
                                .onMoveCommand { direction in
                                    if direction == .right { broadcast.skipSlide() }
                                }
                                .tvSelectPress(isEnabled: route.entry == .manual,
                                               perform: { broadcast.skipSlide() })
                        }
                    }
                    .frame(width: 1080, height: 1080)
```

Move the `.frame(width: 1080, height: 1080)` from the BoardView onto the ZStack (the board keeps every other modifier). The cursor-aiming affordance (`boardFocused`/ghost) is now reachable only while paused — the broadcast is watch-first, play-on-pause (grilled decision).

- [ ] **Step 3: Swap the panel while slides show**

Replace the `panel(for:)` call site:

```swift
                    Group {
                        if let broadcast, let slide = broadcast.currentSlide {
                            TVBroadcastSlidePanel(title: slide.title,
                                                  text: broadcast.typedText,
                                                  slideNumber: broadcast.slideNumber,
                                                  slideCount: broadcast.slideCount)
                        } else {
                            panel(for: game)
                        }
                    }
                    .frame(width: 500, height: 1000, alignment: .top)
                    .padding(.vertical, 40)
                    .disabled(isAiming)
                    .focusSection()
```

In `panel(for:)`, show the generation beat and gate the interactive rows on pause. Replace the `TVBestMovesList(...)` block and the manual-controls block:

```swift
            if isPaused {
                // Interactive pause: picks explore (suppression keeps the AI
                // from answering), exactly the old paused semantics.
                TVBestMovesList(candidates: analysis.candidateMoves(width: Int(board.width),
                                                                    height: Int(board.height),
                                                                    limit: 3),
                                isEnabled: route.entry == .manual && !isGameOver,
                                rowCount: 3,
                                onFocus: { highlightedPoint = $0?.point },
                                onPick: pick)
            } else if broadcast?.phase == .generating {
                Label("Analyzing…", systemImage: "sparkles")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if route.entry == .manual {
                HStack(spacing: 16) {
                    if isPaused {
                        stepBackButton(for: game)
                    }
                    pauseResumeButton
                }
            }
```

- [ ] **Step 4: Route pause/resume through the controller**

Replace `togglePause()`:

```swift
    /// Pause = cancel the broadcast cycle (probes cancel → restore) and hand
    /// the screen to the interactive UI with continuous analysis running so
    /// Top Moves fills. Resume = re-enter the loop (report first, then the
    /// licensed gen-move). suppressesGenMove stays TRUE in both states —
    /// the broadcast invariant; NEVER call maybePauseAnalysis around the
    /// report (the round-7 stray-ack gotcha).
    private func togglePause() {
        guard let game, let broadcast, !isGameOver else { return }
        if broadcast.phase == .paused {
            broadcast.resume(game: game)
        } else {
            Task { await broadcast.pause(game: game) }
        }
    }
```

In `submit(vertex:)`, add the paused gate as the first guard condition:

```swift
        guard isPaused,
              !isGameOver,
              stones.isReady,
              gobanState.pendingMoveTurn == nil,
              let turn = player.nextColorSymbolForPlayCommand else { return }
```

In `stepBack()`, no change to the body — but it is now only reachable while paused (the button renders in the paused panel only). Leave `gobanState.suppressesGenMove = true` in place (idempotent under the invariant).

- [ ] **Step 5: Entry / restart / teardown protocol**

In `startIfNeeded()`, replace the lines

```swift
        gobanState.suppressesGenMove = false
        gobanState.forcesBranchOnPlay = false
```
through
```swift
        gobanState.eyeStatus = .opened
        gobanState.analysisStatus = .run
```

with:

```swift
        // Broadcast protocol: suppression stays TRUE forever (the licensed
        // gen-move plays the moves) and analysisStatus stays .clear so
        // BoardView's turn observer never races an analyze command against a
        // report cycle's collector swap. The .clear transition fires the TV
        // root's "stop"; its ack drains long before the first cycle (FIFO:
        // stop-ack < showboard reply < turn change < first probe).
        gobanState.suppressesGenMove = true
        gobanState.forcesBranchOnPlay = false
        navigationContext.selectedGameRecord = newGame
        gobanState.passCount = 0
        analysisWasUserOff = (gobanState.analysisStatus == .clear)
        gobanState.eyeStatus = .opened
        gobanState.analysisStatus = .clear
        broadcast = BroadcastController(messageList: messageList,
                                        gobanState: gobanState,
                                        player: player,
                                        rootWinrate: rootWinrate,
                                        rootScore: rootScore)
```

(The `navigationContext.selectedGameRecord`/`passCount` lines move up unchanged — delete their old occurrences so nothing doubles.)

In `restart()`, replace

```swift
        gobanState.analysisStatus = .run
        gobanState.suppressesGenMove = false
```

with:

```swift
        broadcast?.cancelAll()
        gobanState.analysisStatus = .clear
        gobanState.suppressesGenMove = true
```

The existing `player.nextColorForPlayCommand = .unknown` reset at the end of `restart()` composes with the controller: the fresh game's showboard reply produces a guaranteed turn change → `noteTurnChanged` → first cycle of the new game.

In `tearDown()`, add `broadcast?.cancelAll()` as the FIRST line, and replace the analysis-restore tail:

```swift
        if analysisWasUserOff {
            gobanState.analysisStatus = .clear
            gobanState.eyeStatus = .closed
        }
```

with:

```swift
        if analysisWasUserOff {
            gobanState.analysisStatus = .clear
            gobanState.eyeStatus = .closed
        } else if gobanState.analysisStatus == .clear {
            // Lift the broadcast's protocol-.clear so other screens read it
            // as system-paused (resumable on entry normalization), not
            // user-OFF. A paused-interactive exit leaves .run for BoardView's
            // onDisappear machinery, which this branch then skips.
            gobanState.analysisStatus = .pause
        }
```

- [ ] **Step 6: Update the previews**

The existing `#Preview` bodies stage `analysisStatus = .run` — they still render (the driver is bypassed via `previewGame`). Add one broadcast preview after the existing ones:

```swift
// Mid-broadcast: slide board over the hero slot, streaming panel.
#Preview("Self-play — broadcast slide") {
    let game = TVPreviewData.denseAnalyzedGame()
    let session = TVPreviewData.reviewSession(game: game,
                                              blackWinrate: 0.55,
                                              blackScore: 1.5)
    return TVSelfPlayPreviewHost(game: game, session: session)
}
```

(The slide overlay itself needs a running controller; this preview pins the base screen. The slide views have their own previews from Task 5.)

- [ ] **Step 7: Build TV + run the full test suite**

```bash
cd "ios/KataGo iOS" && set -o pipefail && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime TV" -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

```bash
cd "ios/KataGo iOS" && set -o pipefail && xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -10
```
Expected: `** TEST SUCCEEDED **` (0 failures).

- [ ] **Step 8: Commit**

```bash
git add "ios/KataGo iOS/KataGo Anytime TV/TVSelfPlayScreen.swift"
git commit -m "feat(tv): self-play becomes the deep-report broadcast"
```

---

### Task 7: Full verification + simulator QA

**Files:** none (verification only).

- [ ] **Step 1: Build all five schemes**

```bash
cd "ios/KataGo iOS" && set -o pipefail \
&& xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | tail -3 \
&& xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS' -configuration Debug 2>&1 | tail -3 \
&& xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Vision" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' 2>&1 | tail -3 \
&& xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime TV" -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | tail -3 \
&& xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Watch" -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' 2>&1 | tail -3
```
Expected: five `** BUILD SUCCEEDED **` lines. ⚠️ Don't run iOS and macOS xcodebuild concurrently against the same DerivedData (build.db lock).

- [ ] **Step 2: Full unit-test suite**

```bash
cd "ios/KataGo iOS" && set -o pipefail && xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -10
```
Expected: `** TEST SUCCEEDED **`, 0 failures.

- [ ] **Step 3: Live tvOS simulator QA**

Boot an Apple TV 4K simulator, install and launch the app (product name is `KataGo TV.app`, build products land in project-local `DerivedData/KataGo Anytime/Build/Products/Debug-appletvsimulator/`). Drive it with the computer-use MCP; keyboard arrows/Return reach the app, but Menu ONLY works via Window ▸ Show Apple TV Remote (⇧⌘R) — reopen that window before every Menu press (it hides when the main window takes focus). Note: sim CoreML is CPU-only, so reports are weak/slow relative to device — judge flow, not strength.

Checklist:
1. Library → "KataGo vs KataGo" card → screen enters, "Analyzing…" appears in the panel, then slide 1 ("Best Move …") replaces the hero board with typewriter text streaming.
2. Slides advance Best → Alternative → Playing vs. Passing; progress dots track; after the last slide the live board returns WITH the new stone already placed (early gen-move), and the next "Analyzing…"/slide cycle begins.
3. Winrate headline and score chart update as moves accrue (snapshot-fed).
4. Right-arrow (or Select) during a slide skips to the next; skipping the last slide makes the move play promptly.
5. Play/Pause pauses: interactive panel returns (Top Moves fills after a beat — continuous analysis re-armed), Undo works, a Top-Moves pick plays a stone with NO AI answer, Resume re-enters the loop with a fresh report on the altered position.
6. Menu exits mid-slideshow cleanly (no engine churn afterward: CPU near-idle in Activity Monitor after ~10 s).
7. Let a game reach two passes (or play both passes while paused): interstitial shows, next game starts with a fresh report on the empty board.
8. Attract mode (idle 180 s on the library, or temporarily lower the threshold): broadcast runs as the screensaver; ANY remote press exits.

- [ ] **Step 4: Re-check the report on iOS (regression)**

On an iPhone 17 simulator run, open any game → ⋯ → Deep Analysis Report: report generates, sections fill, Done dismisses, analysis resumes. (Tasks 1/3 touched shared narrator/session code; the suite pins this, but one live pass is cheap insurance.)

- [ ] **Step 5: Final commit (if QA produced fixes)**

Commit any QA fixes with their own messages. Do not push (project policy: Xcode Cloud pushes are spaced).

---

## Self-Review Notes

- **Spec coverage:** replace-self-play ✓ (Task 6), genmove-plays ✓ (Task 3/4), every-move + first-pass skip ✓ (Task 4 `startCycle`), three slides in order ✓ (Task 2), typewriter facts ✓ (Tasks 1/2/4), overlap-at-snapshot + early gen-move ✓ (Task 4 `runCycle`), skip/pause/resume controls ✓ (Tasks 4/6), failure degradation ✓ (Task 4), snapshot-fed stats ✓ (Task 4 `writeSnapshotStats`), attract inherits ✓ (Task 6 — same screen, focusability gated to manual).
- **Round-7 gotcha compliance:** no `maybePauseAnalysis` anywhere near generation; `.clear` protocol keeps BoardView's observer silent at cycle-start turn changes; the only status transitions near probes are FIFO-safe (stop-ack drains behind a full engine round-trip or ahead of a gen-move on the same pipe).
- **Type consistency check:** `BroadcastSlide`/`BroadcastSlideKind`/`BroadcastConstants`/`BroadcastScript`/`BroadcastPhase`/`BroadcastController`/`broadcastGenMovePending`/`requestBroadcastGenMove` are used with identical spelling across Tasks 2–6; `ReportNarrator.positionFacts/candidateFacts(from:index:)/passFacts` across Tasks 1–2.
