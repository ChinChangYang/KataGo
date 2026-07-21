# tvOS Broadcast Fact-Synced Board Choreography Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The tvOS deep-report broadcast's slide board becomes a choreographed actor synced to the typewriter — PV plays one stone at a time, slide transitions and tenuki/pass ideas are acted out on the board — and the coordinate-list sentences the board now performs are removed from the broadcast text; the text panel widens to close the board-to-text gap.

**Architecture:** A pure frame model (`BroadcastBoardFrame`, built by `BroadcastScript.frames(for:model:)`) describes each slide's board timeline; `BroadcastController` presents frames in lockstep with the typewriter (a fact's frames appear as it starts typing; its trailing beats drain before the next fact); `TVBroadcastSlideBoard` renders the current frame plus a pass-chip caption. No engine-facing change of any kind.

**Tech Stack:** Swift 6 / SwiftUI, Swift Testing (`@Test`/`#expect`), SwiftPM package `KataGoUICore`, tvOS app target `KataGo Anytime TV`.

## Global Constraints

- **Engine-state protocol is untouchable** (docs/superpowers/plans/2026-07-21-tvos-deep-report-broadcast.md, "Engine-state protocol"): `analysisStatus` stays `.clear` while broadcasting; `suppressesGenMove` stays true forever; one gen-move per cycle via the `broadcastGenMovePending` license; `issueGenMove` re-asserts `.clear` before sending; NEVER call `maybePauseAnalysis()` in a broadcast path; BoardView stays mounted. This feature adds ZERO engine traffic — frames are pure presentation.
- **Removal scope: TV broadcast only.** `ReportNarrator.facts(from:)`, the LLM narration prompt, and Copy-to-Comment keep the "Expected continuation: …" and "Most contested areas …" sentences byte-identical.
- Pacing constants (QA-tunable, exact values): `pvStoneSeconds = 0.9`, `choreographyBeatSeconds = 1.2`, both in `BroadcastConstants`.
- Panel width exact math: 24 leading + 1080 board + 24 spacer + **752** panel + 40 trailing = 1920. Both the live panel and the slide panel share the one `Group` frame.
- `⚠️ -only-testing` cannot select a Swift Testing suite (0 tests = vacuous pass) — always run the full scheme test suite; judge by `** TEST SUCCEEDED **` and 0 failures with `set -o pipefail`.
- Piped `xcodebuild` exit codes lie — `set -o pipefail` plus grepping the BUILD/TEST SUCCEEDED marker is mandatory.
- All new files already exist (every change edits registered files) — **no pbxproj work in this plan**.
- English-only in all committed content. Never push to remote (the user decides push timing). Prefer `trash` over `rm`.
- Commit trailers on every commit:
  ```
  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01BaAS47ebfehEhSq2vXwpVy
  ```
- Swift gotchas that WILL bite: `frame?.overlay == .none` is ambiguous (Optional.none vs `ReportBoardOverlay.none`) — compare against `ReportBoardOverlay.none` spelled out, or pattern-match. `Task` is Equatable by identity — use `==`, `===` does not compile.

**Test/build commands** (run from the repo root):

```bash
# Full test suite (the only test gate):
cd "ios/KataGo iOS" && set -o pipefail && \
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -5
# Expected: ** TEST SUCCEEDED **

# tvOS build (Task 4+):
cd "ios/KataGo iOS" && set -o pipefail && \
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime TV" \
  -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | tail -5
# Expected: ** BUILD SUCCEEDED **
```

RED steps: when the failure is a compile error (new API not yet implemented), `xcodebuild build-for-testing … | tail -5` showing `** TEST BUILD FAILED **` is sufficient evidence — don't wait for a full suite run to fail compiling.

---

### Task 1: ReportNarrator broadcast variants + `ReportBoardOverlay: Equatable`

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/ReportNarrator.swift` (lines ~41–78: `candidateFacts`, `passFacts`)
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Rendering/ReportBoardView.swift:14` (overlay enum declaration)
- Test: `ios/KataGo iOS/KataGo iOSTests/ReportNarratorTests.swift`, `ios/KataGo iOS/KataGo iOSTests/BroadcastScriptTests.swift`

**Interfaces:**
- Consumes: existing `ReportNarrator.candidateFacts(from:index:)` / `passFacts(from:)` (built strings unchanged), `ReportBoardOverlay`.
- Produces (Tasks 2–3 rely on these exact signatures):
  - `ReportNarrator.candidateFacts(from: DeepReportModel, index: Int, includeContinuation: Bool = true) -> [String]`
  - `ReportNarrator.passFacts(from: DeepReportModel, includeContestedAreas: Bool = true) -> [String]`
  - `public enum ReportBoardOverlay: Equatable`

- [ ] **Step 1: Write the failing tests**

Append inside `struct ReportNarratorTests` in `ReportNarratorTests.swift`:

```swift
    /// Choreography round: the broadcast drops the PV coordinate list — the
    /// board plays it instead. Exact-suffix pin: default == variant + the
    /// appendage, so the two surfaces can never drift.
    @Test func candidateFactsWithoutContinuationDropOnlyTheAppendage() {
        let model = makeModel()
        let full = ReportNarrator.candidateFacts(from: model, index: 0)
        let broadcast = ReportNarrator.candidateFacts(from: model, index: 0,
                                                      includeContinuation: false)
        #expect(full.count == broadcast.count)
        #expect(full[0] == broadcast[0] + " Expected continuation: A1 B2.")
        #expect(full[1] == broadcast[1])                 // tenuki line untouched
        #expect(!broadcast[0].contains("Expected continuation"))
    }

    /// Same treatment for the contested-areas sentence on the pass fact.
    @Test func passFactsWithoutContestedDropOnlyTheSecondFact() {
        let model = makeModel()
        let full = ReportNarrator.passFacts(from: model)
        let broadcast = ReportNarrator.passFacts(from: model,
                                                 includeContestedAreas: false)
        #expect(full.count == 2)
        #expect(broadcast.count == 1)
        #expect(full[0] == broadcast[0])

        // With no contested points the variants are identical.
        model.passComparison = PassComparison(punishmentVertex: "B2", winrate: 0.28,
                                              scoreLead: -7.0, winrateDeltaVsBest: 0.12,
                                              scoreLeadDeltaVsBest: 2.0,
                                              ownershipDelta: [:], contestedPoints: [])
        #expect(ReportNarrator.passFacts(from: model)
                == ReportNarrator.passFacts(from: model, includeContestedAreas: false))
    }

    /// The defaults guard: the flags can never leak into facts(from:) — the
    /// iOS report sheet, narration prompt, and Copy-to-Comment keep both
    /// sentences.
    @Test func factsFromStillIncludesContinuationAndContested() {
        let joined = ReportNarrator.facts(from: makeModel()).joined(separator: "\n")
        #expect(joined.contains("Expected continuation: A1 B2."))
        #expect(joined.contains("Most contested areas"))
    }
```

Append inside `struct BroadcastScriptTests` in `BroadcastScriptTests.swift`:

```swift
    // MARK: - Overlay equality (frame-model prerequisite)

    @Test func reportBoardOverlayIsEquatable() {
        #expect(ReportBoardOverlay.pv(["A1"], startingWith: .black)
                == ReportBoardOverlay.pv(["A1"], startingWith: .black))
        #expect(ReportBoardOverlay.pv(["A1"], startingWith: .black)
                != ReportBoardOverlay.pv(["A1"], startingWith: .white))
        #expect(ReportBoardOverlay.ownershipDelta([BoardPoint(x: 1, y: 1): 0.5])
                == ReportBoardOverlay.ownershipDelta([BoardPoint(x: 1, y: 1): 0.5]))
        #expect(ReportBoardOverlay.ownershipDelta([:]) != ReportBoardOverlay.none)
    }
```

- [ ] **Step 2: Verify RED**

Run the build-for-testing command. Expected: `** TEST BUILD FAILED **` — `candidateFacts` has no `includeContinuation` parameter; `ReportBoardOverlay` does not conform to `Equatable`.

- [ ] **Step 3: Implement**

In `ReportBoardView.swift:14` change the declaration only:

```swift
public enum ReportBoardOverlay: Equatable {
```

In `ReportNarrator.swift`, change the two builders (signatures + the two appendage sites; everything else byte-identical):

```swift
    /// One candidate's fact line (+ its tenuki line when present). Labels
    /// match the report UI ("Best move …" / "Alternative …").
    /// `includeContinuation: false` (the TV broadcast) drops the PV
    /// coordinate list — the slide board plays the continuation instead.
    @MainActor
    public static func candidateFacts(from model: DeepReportModel, index: Int,
                                      includeContinuation: Bool = true) -> [String] {
```

and the appendage site becomes:

```swift
        if includeContinuation, !candidate.pv.isEmpty {
            line += " Expected continuation: \(candidate.pv.joined(separator: " "))."
        }
```

```swift
    /// The pass-comparison fact (+ contested-areas line when present).
    /// `includeContestedAreas: false` (the TV broadcast) drops the region
    /// list — the slide's Δ overlay shows the swings instead.
    @MainActor
    public static func passFacts(from model: DeepReportModel,
                                 includeContestedAreas: Bool = true) -> [String] {
```

and the contested site becomes:

```swift
        if includeContestedAreas, !pass.contestedPoints.isEmpty {
            let regions = orderedUniqueRegions(pass.contestedPoints)
            facts.append("Most contested areas (largest ownership swings between playing and passing): \(regions.joined(separator: ", ")).")
        }
```

`facts(from:)` and `narrate()` are not touched (they compose with the defaults).

- [ ] **Step 4: Run the full test suite — GREEN**

Expected: `** TEST SUCCEEDED **`, 0 failures (all existing byte-identical narrator pins pass unchanged).

- [ ] **Step 5: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/ReportNarrator.swift" \
        "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Rendering/ReportBoardView.swift" \
        "ios/KataGo iOS/KataGo iOSTests/ReportNarratorTests.swift" \
        "ios/KataGo iOS/KataGo iOSTests/BroadcastScriptTests.swift"
git commit -m "feat(report): narrator facts gain broadcast variants; overlay becomes Equatable"
```

---

### Task 2: `BroadcastScript` frame model + `frames(for:model:)`

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/BroadcastScript.swift`
- Test: `ios/KataGo iOS/KataGo iOSTests/BroadcastScriptTests.swift`

**Interfaces:**
- Consumes: Task 1's `includeContinuation:`/`includeContestedAreas:` flags; `ReportNarrator.positionFacts(from:)`; `ReportBoardOverlay: Equatable`.
- Produces (Tasks 3–4 rely on these exact names):
  - `public struct PlacedStone: Equatable { let vertex: String; let color: PlayerColor }` (public memberwise init)
  - `public enum PassChipKind: Equatable { case playsElsewhere(PlayerColor); case passes(PlayerColor) }`
  - `public struct BroadcastBoardFrame: Equatable` with `anchor: Anchor` (`case fact(Int)` / `case afterPrevious(TimeInterval)`), `placedStones: [PlacedStone]`, `overlay: ReportBoardOverlay`, `passChip: PassChipKind?`, public memberwise init, and helpers `blackVertices(base:) -> [String]`, `whiteVertices(base:) -> [String]`, `lastMoveVertex: String?`
  - `BroadcastScript.frames(for: BroadcastSlide, model: DeepReportModel) -> [BroadcastBoardFrame]` (`@MainActor` like the rest of `BroadcastScript`)
  - `BroadcastConstants.pvStoneSeconds = 0.9`, `BroadcastConstants.choreographyBeatSeconds = 1.2`
  - `BroadcastSlide.facts` no longer contain the two removed sentences. **`BroadcastSlide.overlay`/`markedMove` still exist in this task** (the TV view still compiles against them; Task 4 deletes them).

- [ ] **Step 1: Extend the test fixture**

In `BroadcastScriptTests.swift`, `fullModel()` gains a position (so anchor indices are exercised at their production value of 2) and a contested point (so the removal pin bites). Replace the body:

```swift
    private func fullModel() -> DeepReportModel {
        let model = DeepReportModel()
        model.sideToMove = .black
        model.position = PositionSummary(winrate: 0.55, scoreLead: 1.5, visits: 200)
        model.candidates = [
            candidate("Q16", tenuki: TenukiFollowUp(vertex: "R14", winrate: 0.6,
                                                    scoreLead: 2.0, visits: 40, pv: ["R14"])),
            candidate("D4", delta: [BoardPoint(x: 3, y: 3): -0.4]),
        ]
        model.passComparison = PassComparison(punishmentVertex: "Q16", winrate: 0.3,
                                              scoreLead: -5.0, winrateDeltaVsBest: 0.2,
                                              scoreLeadDeltaVsBest: 6.0,
                                              ownershipDelta: [BoardPoint(x: 15, y: 15): 0.5],
                                              contestedPoints: [
                                                ContestedPoint(point: BoardPoint(x: 15, y: 15),
                                                               vertex: "Q16", delta: 0.5,
                                                               regionName: "upper right"),
                                              ])
        model.stage = .complete
        return model
    }
```

- [ ] **Step 2: Write the failing tests**

Append inside `struct BroadcastScriptTests`:

```swift
    // MARK: - Removed coordinate-list sentences (broadcast only)

    @Test func broadcastFactsCarryNoCoordinateListSentences() {
        for slide in BroadcastScript.slides(from: fullModel()) {
            let joined = slide.facts.joined(separator: "\n")
            #expect(!joined.contains("Expected continuation"))
            #expect(!joined.contains("Most contested areas"))
        }
    }

    // MARK: - Board choreography frames

    @Test func bestSlideFramesPlayPVOneStonePerFrame() {
        let model = fullModel()
        let best = BroadcastScript.slides(from: model)[0]
        let frames = BroadcastScript.frames(for: best, model: model)
        // bare open, pv1, pv2, then the 3-frame tenuki phase
        #expect(frames.count == 6)
        #expect(frames[0] == BroadcastBoardFrame(anchor: .fact(0), placedStones: [],
                                                 overlay: .none, passChip: nil))
        #expect(frames[1] == BroadcastBoardFrame(
            anchor: .fact(2),
            placedStones: [],
            overlay: .pv(["Q16"], startingWith: .black),
            passChip: nil))
        #expect(frames[2] == BroadcastBoardFrame(
            anchor: .afterPrevious(BroadcastConstants.pvStoneSeconds),
            placedStones: [],
            overlay: .pv(["Q16", "C3"], startingWith: .black),
            passChip: nil))
    }

    @Test func bestSlideTenukiPhaseActsOutIgnoreAndFollowUp() {
        let model = fullModel()
        let best = BroadcastScript.slides(from: model)[0]
        let frames = BroadcastScript.frames(for: best, model: model)
        let beat = BroadcastConstants.choreographyBeatSeconds
        let q16 = PlacedStone(vertex: "Q16", color: .black)
        #expect(frames[3] == BroadcastBoardFrame(anchor: .fact(3), placedStones: [q16],
                                                 overlay: .none, passChip: nil))
        #expect(frames[4] == BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                                 placedStones: [q16],
                                                 overlay: .none,
                                                 passChip: .playsElsewhere(.white)))
        #expect(frames[5] == BroadcastBoardFrame(
            anchor: .afterPrevious(beat),
            placedStones: [q16, PlacedStone(vertex: "R14", color: .black)],
            overlay: .none,
            passChip: .playsElsewhere(.white)))
        #expect(frames[5].lastMoveVertex == "R14")   // the punish stone gets the red dot
    }

    @Test func bestSlideWithoutTenukiEndsAfterPV() {
        let model = fullModel()
        model.candidates[0] = candidate("Q16")   // tenuki nil
        let best = BroadcastScript.slides(from: model)[0]
        let frames = BroadcastScript.frames(for: best, model: model)
        #expect(frames.count == 3)               // bare + pv1 + pv2, no tenuki phase
        #expect(frames.allSatisfy { $0.passChip == nil })
    }

    @Test func factAnchorIndexTracksPositionFactCount() {
        let model = fullModel()                  // position set → positionFacts.count == 2
        var frames = BroadcastScript.frames(for: BroadcastScript.slides(from: model)[0],
                                            model: model)
        #expect(frames[1].anchor == .fact(2))
        #expect(frames[3].anchor == .fact(3))

        model.position = nil                     // test generators legally stage candidates alone
        frames = BroadcastScript.frames(for: BroadcastScript.slides(from: model)[0],
                                        model: model)
        #expect(frames[1].anchor == .fact(1))
        #expect(frames[3].anchor == .fact(2))
    }

    @Test func alternativeSlideEntersWithBestStoneThenAltDelta() {
        let model = fullModel()
        let alternative = BroadcastScript.slides(from: model)[1]
        let beat = BroadcastConstants.choreographyBeatSeconds
        let d4 = PlacedStone(vertex: "D4", color: .black)
        #expect(BroadcastScript.frames(for: alternative, model: model) == [
            BroadcastBoardFrame(anchor: .fact(0),
                                placedStones: [PlacedStone(vertex: "Q16", color: .black)],
                                overlay: .none, passChip: nil),
            BroadcastBoardFrame(anchor: .afterPrevious(beat), placedStones: [],
                                overlay: .none, passChip: nil),
            BroadcastBoardFrame(anchor: .afterPrevious(beat), placedStones: [d4],
                                overlay: .none, passChip: nil),
            BroadcastBoardFrame(anchor: .afterPrevious(beat), placedStones: [d4],
                                overlay: .ownershipDelta([BoardPoint(x: 3, y: 3): -0.4]),
                                passChip: nil),
        ])
    }

    @Test func alternativeWithoutDeltaPlaysItsPVInstead() {
        let model = fullModel()
        model.candidates[1] = candidate("D4")    // empty ownershipDelta, pv ["D4", "C3"]
        let alternative = BroadcastScript.slides(from: model)[1]
        let frames = BroadcastScript.frames(for: alternative, model: model)
        // entry: best stone, bare — then PV playback (prefix 1 IS the alt stone)
        #expect(frames.count == 4)
        #expect(frames[2] == BroadcastBoardFrame(
            anchor: .afterPrevious(BroadcastConstants.choreographyBeatSeconds),
            placedStones: [],
            overlay: .pv(["D4"], startingWith: .black),
            passChip: nil))
        #expect(frames[3].overlay == ReportBoardOverlay.pv(["D4", "C3"], startingWith: .black))
        #expect(frames[3].anchor == .afterPrevious(BroadcastConstants.pvStoneSeconds))
    }

    @Test func passSlideActsOutBothScenariosAndEndsCanonically() {
        let model = fullModel()
        let pass = BroadcastScript.slides(from: model)[2]
        let beat = BroadcastConstants.choreographyBeatSeconds
        #expect(BroadcastScript.frames(for: pass, model: model) == [
            BroadcastBoardFrame(anchor: .fact(0), placedStones: [],
                                overlay: .none, passChip: nil),
            BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                placedStones: [PlacedStone(vertex: "Q16", color: .black)],
                                overlay: .none, passChip: nil),
            BroadcastBoardFrame(anchor: .afterPrevious(beat), placedStones: [],
                                overlay: .none, passChip: .passes(.black)),
            BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                placedStones: [PlacedStone(vertex: "Q16", color: .white)],
                                overlay: .none, passChip: .passes(.black)),
            // Canonical end: the same board the static pass slide showed —
            // best stone marked over the Δ grid.
            BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                placedStones: [PlacedStone(vertex: "Q16", color: .black)],
                                overlay: .ownershipDelta([BoardPoint(x: 15, y: 15): 0.5]),
                                passChip: nil),
        ])
    }

    @Test func pvOverlayNeverCoexistsWithPlacedStones() {
        let model = fullModel()
        model.candidates[1] = candidate("D4")    // force the alt-PV fallback too
        for slide in BroadcastScript.slides(from: model) {
            for frame in BroadcastScript.frames(for: slide, model: model) {
                if case .pv = frame.overlay {
                    #expect(frame.placedStones.isEmpty)
                }
            }
        }
    }

    @Test func framesNeverPlacePassVerticesOrDuplicates() {
        let model = fullModel()
        model.candidates[0] = CandidateReport(
            vertex: "pass", visits: 100, winrate: 0.5, scoreLead: 0,
            winrateDelta: 0, scoreLeadDelta: 0, pv: [], ownershipDelta: [:],
            tenuki: TenukiFollowUp(vertex: "C3", winrate: 0.5, scoreLead: 0,
                                   visits: 10, pv: []))
        model.passComparison = PassComparison(punishmentVertex: "pass", winrate: 0.3,
                                              scoreLead: -5.0, winrateDeltaVsBest: 0.2,
                                              scoreLeadDeltaVsBest: 6.0,
                                              ownershipDelta: [:], contestedPoints: [])
        for slide in BroadcastScript.slides(from: model) {
            for frame in BroadcastScript.frames(for: slide, model: model) {
                #expect(!frame.placedStones.contains { $0.vertex == "pass" })
                let vertices = frame.placedStones.map(\.vertex)
                #expect(Set(vertices).count == vertices.count)
            }
        }
    }

    @Test func framesAreEquatableAndDeterministic() {
        let model = fullModel()
        for slide in BroadcastScript.slides(from: model) {
            #expect(BroadcastScript.frames(for: slide, model: model)
                    == BroadcastScript.frames(for: slide, model: model))
        }
    }

    @Test func mergedVertexHelpersFilterPassAndDedupe() {
        let frame = BroadcastBoardFrame(
            anchor: .fact(0),
            placedStones: [PlacedStone(vertex: "Q16", color: .black),
                           PlacedStone(vertex: "pass", color: .black),
                           PlacedStone(vertex: "Q16", color: .black),
                           PlacedStone(vertex: "C3", color: .white)],
            overlay: .none, passChip: nil)
        #expect(frame.blackVertices(base: ["D4", "Q16"]) == ["D4", "Q16"])
        #expect(frame.whiteVertices(base: ["D16"]) == ["D16", "C3"])
        #expect(frame.lastMoveVertex == "C3")

        let empty = BroadcastBoardFrame(anchor: .fact(0), placedStones: [],
                                        overlay: .none, passChip: nil)
        #expect(empty.lastMoveVertex == nil)

        let passLast = BroadcastBoardFrame(
            anchor: .fact(0),
            placedStones: [PlacedStone(vertex: "pass", color: .black)],
            overlay: .none, passChip: nil)
        #expect(passLast.lastMoveVertex == nil)
    }
```

- [ ] **Step 3: Verify RED**

Run build-for-testing. Expected: `** TEST BUILD FAILED **` — `BroadcastBoardFrame` etc. undefined.

- [ ] **Step 4: Implement**

In `BroadcastScript.swift`:

(a) Add to `BroadcastConstants`:

```swift
    /// PV playback: one continuation stone lands per this interval.
    public static let pvStoneSeconds: TimeInterval = 0.9
    /// Choreography beat: transitions, pass chips, punish stones.
    public static let choreographyBeatSeconds: TimeInterval = 1.2
```

(b) Flip the fact flags inside `slides(from:)` (the three call sites become `candidateFacts(from: model, index: 0, includeContinuation: false)`, `candidateFacts(from: model, index: 1, includeContinuation: false)`, `passFacts(from: model, includeContestedAreas: false)`). `overlay:`/`markedMove:` construction stays exactly as-is in this task.

(c) Add the frame model (file scope, above `BroadcastScript`):

```swift
/// A hypothetical stone placed on the report's base position during a
/// choreography frame. The LAST placed stone of a frame carries the red
/// current-move dot.
public struct PlacedStone: Equatable {
    public let vertex: String
    public let color: PlayerColor

    public init(vertex: String, color: PlayerColor) {
        self.vertex = vertex
        self.color = color
    }
}

/// The on-board caption for an acted-out pass beat. Carries WHO acts; the
/// TV layer owns the user-facing copy.
public enum PassChipKind: Equatable {
    /// Tenuki phases: the opponent ignores the candidate ("White plays elsewhere").
    case playsElsewhere(PlayerColor)
    /// The pass slide: the side to move passes ("Black passes").
    case passes(PlayerColor)
}

/// One board state of a slide's choreography. Frames are ordered; each shows
/// when its anchor is satisfied. A frame uses EITHER a .pv overlay OR
/// placedStones, never both (PV prefixes already draw their own stones) —
/// pinned by a test invariant, not types.
public struct BroadcastBoardFrame: Equatable {
    public enum Anchor: Equatable {
        /// Show the moment the fact at this index starts typing.
        case fact(Int)
        /// Show this long after the previous frame appeared.
        case afterPrevious(TimeInterval)
    }

    public let anchor: Anchor
    public let placedStones: [PlacedStone]
    public let overlay: ReportBoardOverlay
    public let passChip: PassChipKind?

    public init(anchor: Anchor, placedStones: [PlacedStone],
                overlay: ReportBoardOverlay, passChip: PassChipKind?) {
        self.anchor = anchor
        self.placedStones = placedStones
        self.overlay = overlay
        self.passChip = passChip
    }

    /// Merged, deduped, "pass"-filtered vertex list for the renderer. A
    /// literal "pass" would draw OFF-GRID: BoardPoint(move:) maps the pass
    /// move to a synthetic point below the board and the base-vertex
    /// compactMap has no pass guard. frames(for:model:) never emits one;
    /// this filters defensively anyway.
    public func blackVertices(base: [String]) -> [String] {
        merged(base: base, color: .black)
    }

    public func whiteVertices(base: [String]) -> [String] {
        merged(base: base, color: .white)
    }

    /// The red current-move dot: the newest placed stone. The renderer's
    /// dot layer no-ops unless a stone sits at the point, which the merged
    /// vertex lists guarantee.
    public var lastMoveVertex: String? {
        placedStones.last.flatMap { $0.vertex == "pass" ? nil : $0.vertex }
    }

    private func merged(base: [String], color: PlayerColor) -> [String] {
        var seen = Set(base)
        var result = base
        for stone in placedStones
        where stone.color == color && stone.vertex != "pass"
            && seen.insert(stone.vertex).inserted {
            result.append(stone.vertex)
        }
        return result
    }
}
```

(d) Add to `BroadcastScript` (inside the `@MainActor public enum`):

```swift
    /// The slide's board choreography, in presentation order. Derived from
    /// the same model snapshot as the slide's facts, so .fact anchors can
    /// never drift from the fact list: anchor indices are COMPUTED from
    /// positionFacts(from:).count — test generators legally stage candidates
    /// with no position, which shifts every index (never hard-code 2/3).
    public static func frames(for slide: BroadcastSlide,
                              model: DeepReportModel) -> [BroadcastBoardFrame] {
        let side = model.sideToMove
        let opponent: PlayerColor = side == .black ? .white : .black
        let beat = BroadcastConstants.choreographyBeatSeconds
        let bestVertex = model.candidates.first.flatMap { $0.vertex == "pass" ? nil : $0.vertex }

        switch slide.kind {
        case .best:
            guard let best = model.candidates.first else { return [] }
            let bestFactIndex = ReportNarrator.positionFacts(from: model).count
            var frames = [BroadcastBoardFrame(anchor: .fact(0), placedStones: [],
                                              overlay: .none, passChip: nil)]
            frames += pvPlayback(best.pv, startingWith: side,
                                 firstAnchor: .fact(bestFactIndex))
            if let tenuki = best.tenuki {
                frames += tenukiPhase(candidate: best.vertex, punish: tenuki.vertex,
                                      factIndex: bestFactIndex + 1,
                                      side: side, opponent: opponent)
            }
            return frames

        case .alternative:
            guard model.candidates.count > 1 else { return [] }
            let alternative = model.candidates[1]
            var frames: [BroadcastBoardFrame] = []
            // Entry choreography (grilled): show the best move, undo it to
            // the previous board, then play the alternative. A "pass" best
            // has nothing to show — open on the previous board directly.
            if let bestVertex {
                frames.append(BroadcastBoardFrame(
                    anchor: .fact(0),
                    placedStones: [PlacedStone(vertex: bestVertex, color: side)],
                    overlay: .none, passChip: nil))
                frames.append(BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                                  placedStones: [],
                                                  overlay: .none, passChip: nil))
            } else {
                frames.append(BroadcastBoardFrame(anchor: .fact(0), placedStones: [],
                                                  overlay: .none, passChip: nil))
            }
            if !alternative.ownershipDelta.isEmpty {
                if alternative.vertex != "pass" {
                    let altStone = [PlacedStone(vertex: alternative.vertex, color: side)]
                    frames.append(BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                                      placedStones: altStone,
                                                      overlay: .none, passChip: nil))
                    frames.append(BroadcastBoardFrame(
                        anchor: .afterPrevious(beat),
                        placedStones: altStone,
                        overlay: .ownershipDelta(alternative.ownershipDelta),
                        passChip: nil))
                } else {
                    frames.append(BroadcastBoardFrame(
                        anchor: .afterPrevious(beat),
                        placedStones: [],
                        overlay: .ownershipDelta(alternative.ownershipDelta),
                        passChip: nil))
                }
            } else {
                // Δ never landed: play the alternative's PV instead —
                // prefix 1 IS the alternative stone, so the .pv/placedStones
                // exclusivity holds.
                frames += pvPlayback(alternative.pv, startingWith: side,
                                     firstAnchor: .afterPrevious(beat))
            }
            if let tenuki = alternative.tenuki {
                frames += tenukiPhase(candidate: alternative.vertex,
                                      punish: tenuki.vertex, factIndex: 1,
                                      side: side, opponent: opponent)
            }
            return frames

        case .pass:
            guard let pass = model.passComparison else { return [] }
            var frames = [BroadcastBoardFrame(anchor: .fact(0), placedStones: [],
                                              overlay: .none, passChip: nil)]
            let bestStones = bestVertex.map { [PlacedStone(vertex: $0, color: side)] } ?? []
            if !bestStones.isEmpty {
                frames.append(BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                                  placedStones: bestStones,
                                                  overlay: .none, passChip: nil))
            }
            frames.append(BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                              placedStones: [],
                                              overlay: .none, passChip: .passes(side)))
            if pass.punishmentVertex != "pass" {
                frames.append(BroadcastBoardFrame(
                    anchor: .afterPrevious(beat),
                    placedStones: [PlacedStone(vertex: pass.punishmentVertex,
                                               color: opponent)],
                    overlay: .none, passChip: .passes(side)))
            }
            // Canonical end: the board the static pass slide always showed.
            frames.append(BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                              placedStones: bestStones,
                                              overlay: .ownershipDelta(pass.ownershipDelta),
                                              passChip: nil))
            return frames
        }
    }

    /// One frame per PV prefix: the first at `firstAnchor`, the rest a stone
    /// cadence apart. Empty PVs produce no frames. "pass" entries inside a
    /// PV are harmless: the overlay's renderer skips them (numbering
    /// advances unseen), so the beat passes with no new stone.
    private static func pvPlayback(_ pv: [String], startingWith side: PlayerColor,
                                   firstAnchor: BroadcastBoardFrame.Anchor)
        -> [BroadcastBoardFrame] {
        guard !pv.isEmpty else { return [] }
        return (1...pv.count).map { count in
            BroadcastBoardFrame(
                anchor: count == 1 ? firstAnchor
                                   : .afterPrevious(BroadcastConstants.pvStoneSeconds),
                placedStones: [],
                overlay: .pv(Array(pv.prefix(count)), startingWith: side),
                passChip: nil)
        }
    }

    /// The acted-out tenuki idea: candidate stone → "opponent plays
    /// elsewhere" chip → the same color's punish stone (two consecutive
    /// same-color stones). A "pass" candidate or punish vertex has no stone
    /// to act with: no phase — the typed fact still tells the story.
    private static func tenukiPhase(candidate: String, punish: String,
                                    factIndex: Int, side: PlayerColor,
                                    opponent: PlayerColor) -> [BroadcastBoardFrame] {
        guard candidate != "pass", punish != "pass" else { return [] }
        let beat = BroadcastConstants.choreographyBeatSeconds
        let candidateStone = PlacedStone(vertex: candidate, color: side)
        return [
            BroadcastBoardFrame(anchor: .fact(factIndex),
                                placedStones: [candidateStone],
                                overlay: .none, passChip: nil),
            BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                placedStones: [candidateStone],
                                overlay: .none,
                                passChip: .playsElsewhere(opponent)),
            BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                placedStones: [candidateStone,
                                               PlacedStone(vertex: punish, color: side)],
                                overlay: .none,
                                passChip: .playsElsewhere(opponent)),
        ]
    }
```

- [ ] **Step 5: Run the full test suite — GREEN**

Expected: `** TEST SUCCEEDED **`. The pre-existing slide tests (`bestSlideLeadsWithPositionFactsAndUsesPVOverlay`, `alternativeSlideUsesDeltaOverlayWithMarkedMove`, `alternativeWithoutDeltaFallsBackToPVWithoutMark`, `passSlideMarksTheBestMove`) still pass — `overlay`/`markedMove` are untouched until Task 4.

- [ ] **Step 6: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/BroadcastScript.swift" \
        "ios/KataGo iOS/KataGo iOSTests/BroadcastScriptTests.swift"
git commit -m "feat(broadcast): board choreography frame model - PV playback, tenuki and pass scenarios"
```

---

### Task 3: Controller lockstep presenter

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/BroadcastController.swift`
- Test: `ios/KataGo iOS/KataGo iOSTests/BroadcastControllerTests.swift`

**Interfaces:**
- Consumes: Task 2's `BroadcastScript.frames(for:model:)`, `BroadcastBoardFrame`, `PassChipKind`, constants.
- Produces (Task 4 relies on): `BroadcastController.currentFrame: BroadcastBoardFrame?` (`public private(set)`), non-nil exactly while `currentSlide` is non-nil.

**Seven binding constraints from the adversarial design review — each is a requirement of this task:**
1. **Cancellation discipline:** every new wait loop carries an explicit `Task.isCancelled` check (the dwell-loop idiom); the presenter's outer loop keeps today's exact fact-driven exit (`factsMayGrow` poll / `break` when settled) — never "wait for a frame's anchor to exist". A missed check hard-hangs `pause()` (`await cycle?.value` never returns; `pauseTask` stays non-nil; all later Play/Pause presses early-return).
2. **Freeze frames at slide entry:** re-derivation adopts a fresh list only when it strictly extends the current one (`fresh.count > frames.count && Array(fresh.prefix(frames.count)) == frames`). `setAlternative` can replace `model.candidates` wholesale mid-show.
3. **Skip = single consumption at the slide epilogue:** every loop keeps `!skipRequested` in its condition and breaks to the ONE existing consume-and-return epilogue; beats drain at `pollSeconds` granularity.
4. **Computed anchors:** already guaranteed by Task 2 (`frames(for:)` computes indices); the controller never mentions literal fact indices.
5. **`currentFrame` write discipline:** the slide's first frame is assigned in the same synchronous block as `currentSlide` (before the early-genmove `await`); every other `currentFrame` write is immediately preceded by a cancellation/skip check with no `await` between.
6. **Degenerate vertices:** handled entirely in Task 2's `frames(for:)`; the controller treats frames as opaque.
7. **Beats accrue into `elapsed`:** beat-drain sleeps add to `elapsed` exactly as typewriter chunk delays do, so the dwell formula stays honest.

- [ ] **Step 1: Write the failing tests**

Append inside `struct BroadcastControllerTests` in `BroadcastControllerTests.swift` (the `Fixture`, `stageFullReport`, `Box`, and pump idioms already exist there — reuse them; `stageFullReport` sets `position`, so the best slide's facts are `[position, eval, best line, tenuki]` and its PV is `["E5", "C3"]`):

```swift
    // MARK: - Choreography: lockstep frames

    @Test("The slide opens on its first frame; the PV stone waits for its fact")
    func frameAppearsWhenItsFactStartsTyping() async {
        let f = Fixture()
        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.currentFrame != nil })
        // Slide entry: the bare-position frame (fact 0's), synchronously with
        // currentSlide.
        #expect(f.controller.currentSlide != nil)
        #expect(f.controller.currentFrame?.overlay == ReportBoardOverlay.none)
        #expect(f.controller.currentFrame?.placedStones.isEmpty == true)
        // The first PV frame appears only once the best-move fact starts —
        // by then both position facts are fully typed.
        await f.pump(until: {
            if let overlay = f.controller.currentFrame?.overlay,
               case .pv = overlay { return true }
            return false
        })
        #expect(f.controller.typedText.contains("visits."))
    }

    @Test("Beat frames drain before the next fact: the tenuki phase never starts mid-PV")
    func afterPreviousFramesDrainBeforeNextFact() async {
        let f = Fixture()
        var sawFullPV = false
        var pvCompleteBeforeTenuki = false
        f.controller.noteTurnChanged(game: f.record)
        for _ in 0..<20_000 {
            if f.controller.phase == .awaitingMove { break }
            if let overlay = f.controller.currentFrame?.overlay,
               case .pv(let vertices, _) = overlay, vertices.count == 2 {
                sawFullPV = true
            }
            if f.controller.currentFrame?.placedStones.first?.vertex == "E5",
               f.controller.currentFrame?.overlay == ReportBoardOverlay.none,
               f.controller.slideNumber == 1 {
                pvCompleteBeforeTenuki = sawFullPV   // tenuki phase began
                break
            }
            await Task.yield()
        }
        #expect(sawFullPV)
        #expect(pvCompleteBeforeTenuki)
    }

    @Test("Skip during a beat drain ends the slide; the next slide still types")
    func skipSlideAbortsFrameDrain() async {
        let f = Fixture()
        var maxLenSlide2 = 0
        var skipped = false
        f.controller.noteTurnChanged(game: f.record)
        for _ in 0..<20_000 {
            if f.controller.phase == .awaitingMove { break }
            if f.controller.slideNumber == 2 {
                maxLenSlide2 = max(maxLenSlide2, f.controller.typedText.count)
            }
            // Skip the FIRST slide the moment a PV frame is up (mid-drain).
            if !skipped, f.controller.slideNumber == 1,
               let overlay = f.controller.currentFrame?.overlay,
               case .pv = overlay {
                f.controller.skipSlide()
                skipped = true
            }
            await Task.yield()
        }
        #expect(skipped)
        #expect(maxLenSlide2 > 0)   // slide 2 typed through — no stale skip flag
    }

    @Test("Pause lands while a beat frame is draining and returns")
    func pauseDuringBeatDrainReturns() async {
        let f = Fixture()
        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: {
            if let overlay = f.controller.currentFrame?.overlay,
               case .pv = overlay { return true }
            return false
        })
        await f.controller.pause(game: f.record)   // hangs here if a drain loop misses Task.isCancelled
        #expect(f.controller.phase == .paused)
        #expect(f.controller.currentFrame == nil)
        #expect(f.controller.currentSlide == nil)
    }

    @Test("currentFrame clears at cycle end and on cancelAll")
    func currentFrameClearsAtCycleEndAndOnCancelAll() async {
        let f = Fixture()
        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.phase == .awaitingMove })
        #expect(f.controller.currentFrame == nil)

        f.session.player.nextColorForPlayCommand = .white
        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.currentFrame != nil })
        f.controller.cancelAll()
        #expect(f.controller.currentFrame == nil)
    }

    @Test("A late tenuki fact grows the frozen frame list and acts out its phase")
    func lateTenukiFactProducesItsFramesWhenItLands() async {
        let f = Fixture(generate: { model, _ in
            BroadcastControllerTests.stageFullReport(model)
            model.candidates[0].tenuki = nil
            model.stage = .tenuki(0)                  // best slide's facts may grow
            for _ in 0..<300 { await Task.yield() }   // land mid-typewriter
            model.candidates[0].tenuki = TenukiFollowUp(vertex: "C3", winrate: 0.65,
                                                        scoreLead: 3.0, visits: 40,
                                                        pv: ["C3"])
            model.stage = .complete
        })
        var sawTenukiChip = false
        f.controller.noteTurnChanged(game: f.record)
        for _ in 0..<20_000 {
            if f.controller.phase == .awaitingMove { break }
            if f.controller.currentFrame?.passChip == .playsElsewhere(.white) {
                sawTenukiChip = true
            }
            await Task.yield()
        }
        #expect(sawTenukiChip)
    }

    @Test("Frames freeze at slide entry: a mid-slide candidate swap cannot reshape the choreography")
    func framesFrozenAtSlideEntryAdoptOnlyPrefixExtensions() async {
        let settle = Box()
        let f = Fixture(generate: { model, _ in
            BroadcastControllerTests.stageFullReport(model)
            model.stage = .passProbe                  // keep generation open
            while settle.value == 0 { await Task.yield() }
            model.stage = .complete
        })
        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.isShowingSlides })
        f.controller.skipSlide()
        await f.pump(until: { f.controller.slideNumber == 2 })

        // The setAlternative window: wholesale candidate swap while the
        // Alternative slide is showing — flips the Δ branch to Δ-empty.
        let model = f.controller.reportModel!
        model.candidates[1] = CandidateReport(vertex: "G7", visits: 5, winrate: 0.5,
                                              scoreLead: 0, winrateDelta: 0,
                                              scoreLeadDelta: 0, pv: ["G7"],
                                              ownershipDelta: [:], tenuki: nil)
        var sawFrozenDelta = false
        for _ in 0..<20_000 {
            if f.controller.phase == .awaitingMove { break }
            if f.controller.slideNumber == 2,
               let overlay = f.controller.currentFrame?.overlay,
               case .ownershipDelta = overlay {
                sawFrozenDelta = true
                if settle.value == 0 { settle.value = 1 }   // release the generator
            }
            await Task.yield()
        }
        #expect(sawFrozenDelta)   // the frozen C3 Δ frame still showed
    }
```

- [ ] **Step 2: Verify RED**

Run build-for-testing. Expected: `** TEST BUILD FAILED **` — `currentFrame` undefined on `BroadcastController`.

- [ ] **Step 3: Implement**

In `BroadcastController.swift`:

(a) Add the published state below `reportModel`:

```swift
    /// The slide board's current choreography frame; non-nil exactly while
    /// currentSlide is non-nil (the first frame is assigned in the same
    /// synchronous block as the slide).
    public private(set) var currentFrame: BroadcastBoardFrame?
```

(b) In `pause()`'s task body, extend the state clears:

```swift
            self.currentSlide = nil
            self.currentFrame = nil
            self.typedText = ""
            self.slideNumber = 0
```

(c) In `cancelAll()`, extend the clears:

```swift
        currentSlide = nil
        currentFrame = nil
        typedText = ""
        slideNumber = 0
```

(d) In `runCycle`, the slide-assignment block (currently `phase = .slides(index)` … `currentSlide = slides[index]`) becomes:

```swift
            phase = .slides(index)
            slideNumber = index + 1
            slideCount = max(slides.count, slideCount)
            currentSlide = slides[index]
            // Constraint 5: the first frame lands in the SAME synchronous
            // block — the early-genmove await below would otherwise render
            // the new slide's title over the previous slide's terminal frame
            // (a stray pass chip under "Best Move …").
            currentFrame = BroadcastScript.frames(for: slides[index], model: model).first
```

and the call `await typewrite(slideIndex: index, model: model)` becomes `await present(slideIndex: index, model: model)`.

(e) In `runCycle`'s token-guarded epilogue, extend the clears:

```swift
        if cycleToken == token {
            currentSlide = nil
            currentFrame = nil
            typedText = ""
            slideNumber = 0
        }
```

(f) Replace `typewrite(slideIndex:model:)` wholesale with:

```swift
    /// Types one slide's facts word-by-word while advancing its board
    /// choreography in LOCKSTEP: a fact's frames appear the moment it starts
    /// typing, its trailing beat frames drain before the next fact starts,
    /// and the dwell runs after both text and frames are done. Tolerates a
    /// fact list that is still growing (slide 1's tenuki line lands
    /// mid-typewriter).
    ///
    /// Frames are FROZEN at slide entry: re-derivation adopts a fresh list
    /// only when it strictly extends the current one (the late tenuki tail).
    /// setAlternative can replace model.candidates wholesale mid-show
    /// (resume-after-Undo + forced probe) — an unfrozen rebuild could flip
    /// the Δ/PV branch and reshape the list mid-drain.
    private func present(slideIndex: Int, model: DeepReportModel) async {
        typedText = ""
        var elapsed: TimeInterval = 0
        var factIndex = 0
        var frames: [BroadcastBoardFrame] = []
        var frameCursor = 0

        func refreshFrames() {
            let slides = BroadcastScript.slides(from: model)
            guard slideIndex < slides.count else { return }
            let fresh = BroadcastScript.frames(for: slides[slideIndex], model: model)
            if frames.isEmpty
                || (fresh.count > frames.count
                    && Array(fresh.prefix(frames.count)) == frames) {
                frames = fresh
            }
        }
        refreshFrames()

        // Emit every frame due at the CURRENT fact (anchor .fact(i),
        // i ≤ factIndex). No sleeps: these show as their fact starts typing.
        func emitDueFactFrames() {
            while frameCursor < frames.count,
                  case .fact(let i) = frames[frameCursor].anchor, i <= factIndex {
                currentFrame = frames[frameCursor]
                frameCursor += 1
            }
        }

        // Drain consecutive beat frames at poll granularity so a skip stays
        // responsive and a pause's cancellation is honored; beat time accrues
        // into `elapsed` so the dwell formula stays honest.
        func drainBeatFrames() async {
            while frameCursor < frames.count,
                  case .afterPrevious(let beatLength) = frames[frameCursor].anchor {
                var waited: TimeInterval = 0
                while waited < beatLength {
                    if Task.isCancelled || skipRequested { return }
                    try? await sleeper(BroadcastConstants.pollSeconds)
                    waited += BroadcastConstants.pollSeconds
                    elapsed += BroadcastConstants.pollSeconds
                }
                if Task.isCancelled || skipRequested { return }
                currentFrame = frames[frameCursor]
                frameCursor += 1
            }
        }

        while !Task.isCancelled && !skipRequested {
            let slides = BroadcastScript.slides(from: model)
            guard slideIndex < slides.count else { break }
            let slide = slides[slideIndex]
            let facts = slide.facts
            refreshFrames()
            if factIndex < facts.count {
                emitDueFactFrames()
                for chunk in BroadcastScript.typewriterChunks(facts[factIndex]) {
                    guard !Task.isCancelled && !skipRequested else { break }
                    typedText += chunk
                    let delay = Double(chunk.count) / BroadcastConstants.charactersPerSecond
                    try? await sleeper(delay)
                    elapsed += delay
                }
                typedText += "\n"
                factIndex += 1
                await drainBeatFrames()
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
        // Poll the dwell so a skip pressed during it is honored AND consumed.
        // A single sleeper(dwell) swallowed such a skip, and the stale flag
        // then blanked the NEXT slide on entry (see the F4 regression).
        var dwelled: TimeInterval = 0
        while dwelled < dwell {
            if Task.isCancelled { return }
            if skipRequested {
                skipRequested = false
                return
            }
            try? await sleeper(BroadcastConstants.pollSeconds)
            dwelled += BroadcastConstants.pollSeconds
        }
    }
```

Note the skip-flag topology is IDENTICAL to today's: helpers return on `skipRequested` **without consuming**; the only consumption points remain the slide epilogue and the dwell poll. Adding a third consumption point re-introduces the "skip demoted to skip-one-beat" bug; removing the epilogue one re-introduces F4.

- [ ] **Step 4: Run the full test suite — GREEN**

Expected: `** TEST SUCCEEDED **`. All ~16 pre-existing broadcast controller tests must pass unchanged — they pin the six closed races; a regression here is a stop-and-rethink, not a test edit.

- [ ] **Step 5: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/BroadcastController.swift" \
        "ios/KataGo iOS/KataGo iOSTests/BroadcastControllerTests.swift"
git commit -m "feat(broadcast): controller presents board frames in lockstep with the typewriter"
```

---

### Task 4: TV views — frame rendering, pass chip, 752 pt panel, dead-field cut

**Files:**
- Modify: `ios/KataGo iOS/KataGo Anytime TV/TVBroadcastSlideView.swift` (board takes a frame; pass chip; previews)
- Modify: `ios/KataGo iOS/KataGo Anytime TV/TVSelfPlayScreen.swift` (call site; panel width 500 → 752; stale comment)
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/BroadcastScript.swift` (delete `BroadcastSlide.overlay`/`markedMove` — now dead)
- Test: `ios/KataGo iOS/KataGo iOSTests/BroadcastScriptTests.swift` (migrate the four overlay/markedMove pins)

**Interfaces:**
- Consumes: Task 2's frame model + helpers; Task 3's `broadcast.currentFrame`.
- Produces: `TVBroadcastSlideBoard(frame: BroadcastBoardFrame, model: DeepReportModel)`; `BroadcastSlide` is `{kind, title, facts}` only.

- [ ] **Step 1: Cut the dead slide fields**

In `BroadcastScript.swift`, `BroadcastSlide` becomes:

```swift
/// One board-plus-facts segment of the broadcast. Board content lives in the
/// slide's frame timeline (frames(for:model:)) — the slide itself carries
/// only identity, title, and text.
public struct BroadcastSlide {
    public let kind: BroadcastSlideKind
    public let title: String
    public let facts: [String]
}
```

and `slides(from:)` drops every `overlay:`/`markedMove:` argument (and the `hasDelta` local), leaving:

```swift
    public static func slides(from model: DeepReportModel) -> [BroadcastSlide] {
        var slides: [BroadcastSlide] = []
        if let best = model.candidates.first {
            slides.append(BroadcastSlide(
                kind: .best,
                title: "Best Move \(best.vertex)",
                facts: ReportNarrator.positionFacts(from: model)
                    + ReportNarrator.candidateFacts(from: model, index: 0,
                                                    includeContinuation: false)))
        }
        if model.candidates.count > 1 {
            slides.append(BroadcastSlide(
                kind: .alternative,
                title: "Alternative \(model.candidates[1].vertex)",
                facts: ReportNarrator.candidateFacts(from: model, index: 1,
                                                     includeContinuation: false)))
        }
        if model.passComparison != nil {
            slides.append(BroadcastSlide(
                kind: .pass,
                title: "Playing vs. Passing",
                facts: ReportNarrator.passFacts(from: model,
                                                includeContestedAreas: false)))
        }
        return slides
    }
```

Also update the file's header comment (it still says "titles/facts/overlays").

- [ ] **Step 2: Migrate the four obsolete slide tests**

In `BroadcastScriptTests.swift` — the board-content assertions these tests carried are already re-pinned by Task 2's frames tests; slim them to their facts/title pins:

```swift
    @Test func bestSlideLeadsWithPositionFacts() {
        let best = BroadcastScript.slides(from: fullModel())[0]
        #expect(best.facts.first?.hasPrefix("Position: move") == true)
        #expect(best.facts.contains { $0.hasPrefix("Best move Q16") })
    }

    @Test func passSlideNamesThePassComparison() {
        let pass = BroadcastScript.slides(from: fullModel())[2]
        #expect(pass.facts.first?.contains("passes instead") == true)
    }
```

(replacing `bestSlideLeadsWithPositionFactsAndUsesPVOverlay` and `passSlideMarksTheBestMove`; DELETE `alternativeSlideUsesDeltaOverlayWithMarkedMove` and `alternativeWithoutDeltaFallsBackToPVWithoutMark` outright — `alternativeSlideEntersWithBestStoneThenAltDelta` and `alternativeWithoutDeltaPlaysItsPVInstead` from Task 2 pin the same behavior at frame level).

- [ ] **Step 3: Rewrite `TVBroadcastSlideView.swift`**

Replace `TVBroadcastSlideBoard` and add the chip (panel unchanged); replace the DEBUG previews:

```swift
/// The hero-slot slide board: the controller's current choreography frame
/// rendered over the report's base position. Full-bleed (no inner padding) —
/// Dimensions centers the wood with its own margins, and the removed margin
/// closes the board-to-panel gap. Opaque backdrop so the live board
/// underneath can't ghost through.
struct TVBroadcastSlideBoard: View {
    let frame: BroadcastBoardFrame
    let model: DeepReportModel

    var body: some View {
        ReportBoardView(width: model.boardWidth, height: model.boardHeight,
                        blackVertices: frame.blackVertices(base: model.blackVertices),
                        whiteVertices: frame.whiteVertices(base: model.whiteVertices),
                        overlay: frame.overlay,
                        lastMoveVertex: frame.lastMoveVertex,
                        isClassicStoneStyle: model.isClassicStoneStyle,
                        showCoordinate: model.showCoordinate,
                        verticalFlip: model.verticalFlip)
            .overlay(alignment: .top) {
                if let chip = frame.passChip {
                    TVPassChip(kind: chip)
                        .padding(.top, 28)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
    }
}

/// The acted-out pass beat's caption ("White plays elsewhere" / "Black
/// passes"): stone glyph + label in a capsule, top-center over the board.
/// The band above the top grid line only ever holds decorative coordinate
/// letters, so the chip can never cover an acting stone on any board size.
private struct TVPassChip: View {
    let kind: PassChipKind

    private var color: PlayerColor {
        switch kind {
        case .playsElsewhere(let color), .passes(let color): color
        }
    }

    private var label: String {
        let name = color == .black ? "Black" : "White"
        switch kind {
        case .playsElsewhere: return "\(name) plays elsewhere"
        case .passes: return "\(name) passes"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            TVStoneIndicator(isBlack: color == .black)
            Text(label)
                .font(.title3.weight(.semibold))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
    }
}
```

New DEBUG previews (replace the existing three; `previewModel()` gains a tenuki and a pass comparison):

```swift
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
                        tenuki: TenukiFollowUp(vertex: "R10", winrate: 0.6,
                                               scoreLead: 2.5, visits: 60,
                                               pv: ["R10"])),
        CandidateReport(vertex: "C6", visits: 90, winrate: 0.53, scoreLead: 0.9,
                        winrateDelta: -0.03, scoreLeadDelta: -0.9, pv: ["C6"],
                        ownershipDelta: [BoardPoint(x: 2, y: 5): -0.5,
                                         BoardPoint(x: 3, y: 6): 0.3],
                        tenuki: nil),
    ]
    model.passComparison = PassComparison(punishmentVertex: "R13", winrate: 0.31,
                                          scoreLead: -4.0, winrateDeltaVsBest: 0.25,
                                          scoreLeadDeltaVsBest: 5.8,
                                          ownershipDelta: [BoardPoint(x: 16, y: 13): 0.6,
                                                           BoardPoint(x: 15, y: 12): -0.4],
                                          contestedPoints: [])
    return model
}

@MainActor
private func previewFrames(_ slideIndex: Int) -> [BroadcastBoardFrame] {
    let model = previewModel()
    let slides = BroadcastScript.slides(from: model)
    return BroadcastScript.frames(for: slides[slideIndex], model: model)
}

#Preview("Best — mid-PV") {
    TVBroadcastSlideBoard(frame: previewFrames(0)[2], model: previewModel())
        .frame(width: 900, height: 900)
}

#Preview("Best — tenuki chip") {
    TVBroadcastSlideBoard(frame: previewFrames(0)[5], model: previewModel())
        .frame(width: 900, height: 900)
}

#Preview("Alternative — entry (best stone only)") {
    TVBroadcastSlideBoard(frame: previewFrames(1)[0], model: previewModel())
        .frame(width: 900, height: 900)
}

#Preview("Alternative — delta") {
    TVBroadcastSlideBoard(frame: previewFrames(1).last!, model: previewModel())
        .frame(width: 900, height: 900)
}

#Preview("Pass — punish + chip") {
    TVBroadcastSlideBoard(frame: previewFrames(2)[3], model: previewModel())
        .frame(width: 900, height: 900)
}

#Preview("Slide panel — streaming") {
    TVBroadcastSlidePanel(title: "Best Move R14",
                          text: "Position: move 12, Black to play.\nBest move R14: 56% win rate",
                          slideNumber: 1,
                          slideCount: 3)
        .frame(width: 752, height: 900)
        .background(.thinMaterial)
}
#endif
```

(Preview frame indices are stable against the fixed fixture: best frames = bare, pv1, pv2, pv3, tenuki-stone, tenuki-chip, tenuki-punish — index 5 is the chip frame; pass frames = bare, best, chip, punish+chip, canonical — index 3 is the punish frame.)

- [ ] **Step 4: Update `TVSelfPlayScreen.swift`**

(a) The slide-board branch (in the hero `ZStack`) becomes:

```swift
                        if let broadcast, broadcast.currentSlide != nil,
                           let frame = broadcast.currentFrame,
                           let model = broadcast.reportModel {
                            TVBroadcastSlideBoard(frame: frame, model: model)
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
```

(The presence gate stays `currentSlide != nil` — the paused-state masking relies on that shape.)

(b) The panel `Group`'s `.frame(width: 500, height: 1000, alignment: .top)` becomes `.frame(width: 752, height: 1000, alignment: .top)`, and its comment's first sentence becomes: `// Hard ceiling: 752 pt is the max width that keeps the Spacer at its 24 pt floor (24 + 1080 + 24 + 752 + 40 = 1920); the 1000 pt height is the screen minus the 40 pt vertical margins.` (keep the rest of the comment).

(c) In `panel(for:)`, the title comment "in the 500 pt panel" becomes "in the 752 pt panel". (`TVReviewScreen`'s own 500 pt panel and its comments are OUT of scope — that screen is unchanged.)

- [ ] **Step 5: Run the full test suite AND the tvOS build — GREEN**

Both commands from the header. Expected: `** TEST SUCCEEDED **` and `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add "ios/KataGo iOS/KataGo Anytime TV/TVBroadcastSlideView.swift" \
        "ios/KataGo iOS/KataGo Anytime TV/TVSelfPlayScreen.swift" \
        "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/BroadcastScript.swift" \
        "ios/KataGo iOS/KataGo iOSTests/BroadcastScriptTests.swift"
git commit -m "feat(tv): slide board acts out the choreography; panel widens to 752"
```

---

### Task 5: Whole-branch verification

**Files:** none modified (verification only; fixes loop back into the owning task's files).

- [ ] **Step 1: Full test suite** — `** TEST SUCCEEDED **`, 0 failures.
- [ ] **Step 2: All five scheme builds** (`KataGo Anytime`, `KataGo Anytime Mac`, `KataGo Anytime Vision`, `KataGo Anytime TV`, `KataGo Anytime Watch` — commands in CLAUDE.md), each judged by its `** BUILD SUCCEEDED **` marker with pipefail.
- [ ] **Step 3: tvOS simulator forensics** — boot an Apple TV simulator, install and launch the app (product name "KataGo TV.app" under "DerivedData/KataGo Anytime/Build/Products" — the real DerivedData path, not a stale local one), navigate is NOT scriptable (synthetic keys never reach the sim remote): use the launch-arg route-push pattern from `project_tvos_selfplay` memory if direct navigation is needed, then verify via logs + CPU sampling over ≥3 broadcast cycles: probe bursts followed by idle slideshows (the engine idles under slides — slideshows are now LONGER, so idle stretches lengthen), stones land only via the licensed gen-move, no runaway `kata-analyze` after exiting the screen.
- [ ] **Step 4:** Record outcome in the progress ledger; hands-on Apple TV QA items go to the user (pacing feel via `pvStoneSeconds`/`choreographyBeatSeconds`; pass-chip legibility; skip during PV/beats/dwell; pause mid-choreography; resume-after-Undo; 752 panel in both modes; transition continuity).
