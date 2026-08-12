# tvOS Pass-Slide Sentence-Synced Re-Choreography Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **CORRECTION — 2026-08-12.** This plan shipped as written and is kept intact as the record of what shipped; nothing below has been rewritten. One decision was later **reversed**: the chip-label constraint (Global Constraints, "Chip label (user-confirmed)"). A pass forfeits the move while a tenuki relocates it, so one caption cannot describe both — the pass beat reads "Black passes" again. The `PassChipKind` → `PlayerColor?` collapse of Task 2 is being restored as a two-case `BeatCaption` (`passes(PlayerColor)` / `playsElsewhere(PlayerColor)`). See the correction note under the affected constraint.

**Goal:** The broadcast's "Playing vs. Passing" slide interleaves sentence-by-sentence with the board — bare board while "If Black passes…" types, the pass chip beat, the punish sentence then the punish stone, the restored contested-areas sentence then the bare→best→Δ payoff.

**Architecture:** Pure-data change riding the existing lockstep presenter: `ReportNarrator.passFacts` gains a `split:` broadcast form (three facts), `BroadcastScript.frames(for: .pass)` gets a new timeline using `.fact(i)`-anchored **barrier frames** (copies of the last appended frame) to hold the beat drain until each sentence types, and `PassChipKind` collapses to `PlayerColor?` because every chip now reads "\<Color\> plays elsewhere". `BroadcastController` is untouched.

**Tech Stack:** Swift 6 / SwiftUI, Swift Testing (`@Test`/`#expect`), SwiftPM package `KataGoUICore`, tvOS app target `KataGo Anytime TV`.

## Global Constraints

- **`BroadcastController.swift` MUST NOT change.** The presenter (emit-then-type-then-drain loop, frozen-frames prefix adoption, skip/dwell/early-genmove) already handles the new timeline as pure data — adversarially verified by trace.
- **iOS byte-identity:** `ReportNarrator.facts(from:)` output must be byte-identical before/after. The default (`split: false`) pass fact is `head + "; " + punish + "."` — exactly today's string. The contested fact is now unconditional (both forms) when `contestedPoints` is non-empty.
- **Barrier = copy of the LAST APPENDED frame**, never a hardcoded board. With `punishmentVertex == "pass"` the punish frame is skipped and `.fact(1)`/`.fact(2)` are two consecutive chip-frame copies; a hardcoded "punish + chip" barrier would place a "pass" stone (drawn off-grid).
- **No `.fact(i)` anchor may reference `i >= facts.count`** — a never-typing fact would strand every later frame. The `.fact(2)` barrier condition (`!contestedPoints.isEmpty`) is byte-for-byte the fact-2 existence condition in `passFacts`.
- Chip label (user-confirmed): "**Black plays elsewhere**" for the pass beat too — NOT "Black passes". Contested sentence: the **full iOS wording** verbatim. Punish sentence **keeps the tail** " if Black doesn't play at …" when a best move is named.
  - **REVERSED 2026-08-12 (the line above is the original decision, kept as the record):** the pass beat reads "**Black passes**" again. A pass forfeits the move and a tenuki relocates it, so one caption cannot describe both. Task 2's collapsed `PassChipKind` → `PlayerColor?` is restored as a two-case `BeatCaption` — `passes(PlayerColor)` for the pass beat, `playsElsewhere(PlayerColor)` for the tenuki phases, which keep their wording. The contested/punish sentence constraints are unaffected.
- In tests, spell `ReportBoardOverlay.none` where an optional chain could make `.none` ambiguous (Optional.none trap).
- Swift Testing suites cannot be selected with `-only-testing` — run the full iOS-sim suite. Pipe xcodebuild through `tee` with `set -o pipefail` and judge by `TEST SUCCEEDED` / `BUILD SUCCEEDED` markers.
- English-only in all committed content. Never push. Commit messages end with:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01BaAS47ebfehEhSq2vXwpVy`
- Working directory for all builds/tests: `ios/KataGo iOS/`.

---

### Task 1: Narrator split form + fact-level test updates

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/ReportNarrator.swift:62-84`
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/BroadcastScript.swift:160-161`
- Test: `ios/KataGo iOS/KataGo iOSTests/ReportNarratorTests.swift`, `ios/KataGo iOS/KataGo iOSTests/BroadcastScriptTests.swift`

**Interfaces:**
- Produces: `ReportNarrator.passFacts(from: DeepReportModel, split: Bool = false) -> [String]`. Split form (broadcast): `[head + ".", punish + ".", contestedFact?]` — 3 facts when contested points exist, else 2. Default: `[head + "; " + punish + ".", contestedFact?]` — byte-identical to today. The `includeContestedAreas` parameter is deleted.
- Task 2's frame timeline relies on: fact 1 always exists; fact 2 exists iff `!contestedPoints.isEmpty`.

- [ ] **Step 1: Rewrite the two failing/changed tests first**

In `ReportNarratorTests.swift`, replace the whole `passFactsWithoutContestedDropOnlyTheSecondFact` test (lines 209-226, including its doc comment) with:

```swift
    /// Choreography round 2: the broadcast splits the pass sentence so the
    /// board can act each half out. Reconstruction pin: the split re-joins
    /// into the report sentence, so the two surfaces can never drift.
    @Test func passFactsSplitFormReJoinsIntoTheReportSentence() {
        let model = makeModel()
        let full = ReportNarrator.passFacts(from: model)
        let split = ReportNarrator.passFacts(from: model, split: true)
        #expect(full.count == 2)
        #expect(split.count == 3)
        #expect(full[0] == String(split[0].dropLast()) + "; " + split[1])
        #expect(split[2] == full[1])   // contested fact identical in both forms

        // With no contested points both forms drop the third fact only.
        model.passComparison = PassComparison(punishmentVertex: "B2", winrate: 0.28,
                                              scoreLead: -7.0, winrateDeltaVsBest: 0.12,
                                              scoreLeadDeltaVsBest: 2.0,
                                              ownershipDelta: [:], contestedPoints: [])
        let bare = ReportNarrator.passFacts(from: model)
        let bareSplit = ReportNarrator.passFacts(from: model, split: true)
        #expect(bare.count == 1)
        #expect(bareSplit.count == 2)
        #expect(bare[0] == String(bareSplit[0].dropLast()) + "; " + bareSplit[1])
    }
```

In the same file, update the doc comment of `factsFromStillIncludesContinuationAndContested` (line 228-230) to:

```swift
    /// The defaults guard: the broadcast variants can never leak into
    /// facts(from:) — the iOS report sheet, narration prompt, and
    /// Copy-to-Comment keep the joined sentence and both coordinate lists.
```

In `BroadcastScriptTests.swift`, replace the whole `broadcastFactsCarryNoCoordinateListSentences` test (lines 115-121) with:

```swift
    @Test func broadcastFactsCarryNoCoordinateListSentences() {
        for slide in BroadcastScript.slides(from: fullModel()) {
            let joined = slide.facts.joined(separator: "\n")
            #expect(!joined.contains("Expected continuation"))
            if slide.kind == .pass {
                // Round 2: the contested sentence returned — it types while
                // the Δ overlay shows the swings on the board.
                #expect(joined.contains("Most contested areas"))
            } else {
                #expect(!joined.contains("Most contested areas"))
            }
        }
    }
```

- [ ] **Step 2: Build the test target and verify these tests FAIL to compile**

Run (from `ios/KataGo iOS/`):
```bash
set -o pipefail
xcodebuild build-for-testing -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```
Expected: FAIL — `passFacts(from:split:)` does not exist yet (extra argument 'split').

- [ ] **Step 3: Implement the narrator split**

In `ReportNarrator.swift`, replace the whole `passFacts` function (lines 62-84, including its doc comment) with:

```swift
    /// The pass-comparison facts (+ the contested-areas line when present).
    /// `split: true` (the TV broadcast) splits the sentence into two facts —
    /// the pass evaluation, then the punishment — so the slide board can act
    /// each out as its sentence types. The default joins them into the single
    /// report sentence, byte-identical to the pre-split output.
    @MainActor
    public static func passFacts(from model: DeepReportModel,
                                 split: Bool = false) -> [String] {
        guard let pass = model.passComparison else { return [] }
        let side = model.sideToMove == .black ? "Black" : "White"
        let opponent = model.sideToMove == .black ? "White" : "Black"
        let best = model.candidates.first.flatMap { $0.vertex == "pass" ? nil : $0.vertex }
        let playing = best.map { "playing \($0)" } ?? "playing the best candidate"
        let head = "If \(side) passes instead: \(percent(pass.winrate)) win rate — \(playing) is worth \(signedPercent(pass.winrateDeltaVsBest)) and \(points(pass.scoreLeadDeltaVsBest)) points"
        var punish = "\(opponent) would punish at \(pass.punishmentVertex)"
        if let best {
            punish += " if \(side) doesn't play at \(best)"
        }
        var facts = split ? [head + ".", punish + "."]
                          : [head + "; " + punish + "."]
        if !pass.contestedPoints.isEmpty {
            let regions = orderedUniqueRegions(pass.contestedPoints)
            facts.append("Most contested areas (largest ownership swings between playing and passing): \(regions.joined(separator: ", ")).")
        }
        return facts
    }
```

In `BroadcastScript.swift`, change the pass-slide facts call (lines 160-161) from:

```swift
                facts: ReportNarrator.passFacts(from: model,
                                                includeContestedAreas: false)))
```

to:

```swift
                facts: ReportNarrator.passFacts(from: model, split: true)))
```

- [ ] **Step 4: Run the full test suite, verify green**

```bash
set -o pipefail
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tee /tmp/task1-tests.log | grep -E "Test Suite|TEST"
```
Expected: `TEST SUCCEEDED`, 0 failures. (The pass slide's frames are still the OLD timeline — its extra facts simply type after the frames drain; no frame test depends on the fact count.)

- [ ] **Step 5: Commit**

```bash
git add -A "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/ReportNarrator.swift" "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/BroadcastScript.swift" "ios/KataGo iOS/KataGo iOSTests/ReportNarratorTests.swift" "ios/KataGo iOS/KataGo iOSTests/BroadcastScriptTests.swift"
git commit -m "feat(broadcast): passFacts split form; contested sentence returns to the broadcast"
```

---

### Task 2: Chip type collapse + new pass timeline + frame tests

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/BroadcastScript.swift` (PassChipKind deletion, frame field, tenukiPhase, `.pass` timeline)
- Modify: `ios/KataGo iOS/KataGo Anytime TV/TVBroadcastSlideView.swift` (chip view + call site + doc comments)
- Test: `ios/KataGo iOS/KataGo iOSTests/BroadcastScriptTests.swift`, `ios/KataGo iOS/KataGo iOSTests/BroadcastControllerTests.swift` (one literal)

**Interfaces:**
- Consumes: Task 1's split facts (fact 0 head / fact 1 punish / fact 2 contested-when-present).
- Produces: `BroadcastBoardFrame.passChip: PlayerColor?` (nil = no chip; the color is WHO plays elsewhere). `PassChipKind` no longer exists. New `.pass` timeline (8 frames in the full case).

- [ ] **Step 1: Update the frame-expectation tests first**

In `BroadcastScriptTests.swift`:

Replace `.playsElsewhere(.white)` with `.white` at the four tenuki-chip assertion sites (lines 156, 161, 226, 231 — in `bestSlideTenukiPhaseActsOutIgnoreAndFollowUp` and `alternativeSlideTenukiPhaseActsOutIgnoreAndFollowUp`).

Replace the whole `passSlideActsOutBothScenariosAndEndsCanonically` test (lines 251-273) with:

```swift
    /// Round 2 (user feedback): the pass slide interleaves sentence-by-
    /// sentence — bare board while "If Black passes…" types, the chip beat,
    /// a barrier while "would punish at…" types, the punish stone, a barrier
    /// while the contested sentence types, then the payoff: bare board →
    /// best move → the Δ the static slide always showed.
    @Test func passSlideActsOutBothScenariosAndEndsCanonically() {
        let model = fullModel()
        let pass = BroadcastScript.slides(from: model)[2]
        let beat = BroadcastConstants.choreographyBeatSeconds
        #expect(BroadcastScript.frames(for: pass, model: model) == [
            BroadcastBoardFrame(anchor: .fact(0), placedStones: [],
                                overlay: .none, passChip: nil),
            BroadcastBoardFrame(anchor: .afterPrevious(beat), placedStones: [],
                                overlay: .none, passChip: .black),
            BroadcastBoardFrame(anchor: .fact(1), placedStones: [],
                                overlay: .none, passChip: .black),
            BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                placedStones: [PlacedStone(vertex: "Q16", color: .white)],
                                overlay: .none, passChip: .black),
            BroadcastBoardFrame(anchor: .fact(2),
                                placedStones: [PlacedStone(vertex: "Q16", color: .white)],
                                overlay: .none, passChip: .black),
            BroadcastBoardFrame(anchor: .afterPrevious(beat), placedStones: [],
                                overlay: .none, passChip: nil),
            BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                placedStones: [PlacedStone(vertex: "Q16", color: .black)],
                                overlay: .none, passChip: nil),
            // Canonical end: the same board the static pass slide showed —
            // best stone marked over the Δ grid.
            BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                placedStones: [PlacedStone(vertex: "Q16", color: .black)],
                                overlay: .ownershipDelta([BoardPoint(x: 15, y: 15): 0.5]),
                                passChip: nil),
        ])
    }
```

Directly after it, add the degenerate-barrier pin (no existing test exercises punish=="pass" with contested non-empty):

```swift
    /// punish == "pass" + contested non-empty: the punish frame is skipped
    /// and .fact(1)/.fact(2) become two consecutive barriers, both copies of
    /// the chip frame — a hardcoded punish barrier would place a "pass"
    /// stone (drawn off-grid).
    @Test func passSlideWithPassPunishmentUsesConsecutiveChipBarriers() {
        let model = fullModel()
        model.passComparison = PassComparison(punishmentVertex: "pass", winrate: 0.3,
                                              scoreLead: -5.0, winrateDeltaVsBest: 0.2,
                                              scoreLeadDeltaVsBest: 6.0,
                                              ownershipDelta: [BoardPoint(x: 15, y: 15): 0.5],
                                              contestedPoints: [
                                                ContestedPoint(point: BoardPoint(x: 15, y: 15),
                                                               vertex: "Q16", delta: 0.5,
                                                               regionName: "upper right"),
                                              ])
        let pass = BroadcastScript.slides(from: model)[2]
        let beat = BroadcastConstants.choreographyBeatSeconds
        #expect(BroadcastScript.frames(for: pass, model: model) == [
            BroadcastBoardFrame(anchor: .fact(0), placedStones: [],
                                overlay: .none, passChip: nil),
            BroadcastBoardFrame(anchor: .afterPrevious(beat), placedStones: [],
                                overlay: .none, passChip: .black),
            BroadcastBoardFrame(anchor: .fact(1), placedStones: [],
                                overlay: .none, passChip: .black),
            BroadcastBoardFrame(anchor: .fact(2), placedStones: [],
                                overlay: .none, passChip: .black),
            BroadcastBoardFrame(anchor: .afterPrevious(beat), placedStones: [],
                                overlay: .none, passChip: nil),
            BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                placedStones: [PlacedStone(vertex: "Q16", color: .black)],
                                overlay: .none, passChip: nil),
            BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                placedStones: [PlacedStone(vertex: "Q16", color: .black)],
                                overlay: .ownershipDelta([BoardPoint(x: 15, y: 15): 0.5]),
                                passChip: nil),
        ])
    }
```

In `BroadcastControllerTests.swift` line 531, change `.playsElsewhere(.white)` to `.white`:

```swift
            if f.controller.currentFrame?.passChip == .white {
```

(The fixture's side to move is black, so `.white` still uniquely selects the tenuki phase — the pass slide's chip is `.black`.)

- [ ] **Step 2: Implement the chip type collapse in BroadcastScript.swift**

Delete the `PassChipKind` enum entirely (lines 59-66):

```swift
/// The on-board caption for an acted-out pass beat. Carries WHO acts; the
/// TV layer owns the user-facing copy.
public enum PassChipKind: Equatable {
    /// Tenuki phases: the opponent ignores the candidate ("White plays elsewhere").
    case playsElsewhere(PlayerColor)
    /// The pass slide: the side to move passes ("Black passes").
    case passes(PlayerColor)
}
```

Change the frame field (line 83) and its doc, plus the init parameter (line 86), from `PassChipKind?` to `PlayerColor?`:

```swift
    /// The color who "plays elsewhere" in an acted-out pass/tenuki beat;
    /// nil = no chip. The TV layer owns the caption copy
    /// ("Black plays elsewhere").
    public let passChip: PlayerColor?
```

```swift
    public init(anchor: Anchor, placedStones: [PlacedStone],
                overlay: ReportBoardOverlay, passChip: PlayerColor?) {
```

In `tenukiPhase` (lines 295-315), change both `passChip: .playsElsewhere(opponent)` to `passChip: opponent`.

- [ ] **Step 3: Implement the new `.pass` timeline**

Replace the whole `case .pass:` block in `frames(for:model:)` (lines 244-269) with:

```swift
        case .pass:
            guard let pass = model.passComparison else { return [] }
            let bestStones = bestVertex.map { [PlacedStone(vertex: $0, color: side)] } ?? []
            // Fact 0 ("If Black passes instead: …"): open on the bare board,
            // then act the pass — chip only, no stone.
            var frames = [BroadcastBoardFrame(anchor: .fact(0), placedStones: [],
                                              overlay: .none, passChip: nil)]
            frames.append(BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                              placedStones: [],
                                              overlay: .none, passChip: side))
            // A barrier holds the beat drain so the next stone waits for its
            // sentence: a .fact-anchored copy of the LAST APPENDED frame
            // (never a hardcoded board — with a "pass" punishment the two
            // barriers are both chip-frame copies). Emitting one is a visual
            // no-op; its .fact index must exist or every later frame strands.
            func appendBarrier(at factIndex: Int) {
                guard let last = frames.last else { return }
                frames.append(BroadcastBoardFrame(anchor: .fact(factIndex),
                                                  placedStones: last.placedStones,
                                                  overlay: last.overlay,
                                                  passChip: last.passChip))
            }
            // Fact 1 ("White would punish at …") types over the unchanged
            // chip board, then the punish stone lands.
            appendBarrier(at: 1)
            if pass.punishmentVertex != "pass" {
                frames.append(BroadcastBoardFrame(
                    anchor: .afterPrevious(beat),
                    placedStones: [PlacedStone(vertex: pass.punishmentVertex,
                                               color: opponent)],
                    overlay: .none, passChip: side))
            }
            // Fact 2 (contested areas) exists exactly when contestedPoints is
            // non-empty — the same condition as passFacts. Then the payoff:
            // bare board → best move → the Δ the static slide always showed.
            if !pass.contestedPoints.isEmpty {
                appendBarrier(at: 2)
            }
            frames.append(BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                              placedStones: [],
                                              overlay: .none, passChip: nil))
            if !bestStones.isEmpty {
                frames.append(BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                                  placedStones: bestStones,
                                                  overlay: .none, passChip: nil))
            }
            frames.append(BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                              placedStones: bestStones,
                                              overlay: .ownershipDelta(pass.ownershipDelta),
                                              passChip: nil))
            return frames
```

- [ ] **Step 4: Update the TV chip view**

In `TVBroadcastSlideView.swift`, change the call site (line 34) from `TVPassChip(kind: chip)` to `TVPassChip(color: chip)`, and replace the whole `TVPassChip` struct including its doc comment (lines 43-74) with:

```swift
/// The acted-out pass beat's caption ("Black plays elsewhere"): stone glyph
/// + label in a capsule, top-center over the board. The band above the top
/// grid line only ever holds decorative coordinate letters, so the chip can
/// never cover an acting stone on any board size.
private struct TVPassChip: View {
    /// Who plays elsewhere in the acted-out beat.
    let color: PlayerColor

    var body: some View {
        HStack(spacing: 12) {
            TVStoneIndicator(isBlack: color == .black)
            Text("\(color == .black ? "Black" : "White") plays elsewhere")
                .font(.title3.weight(.semibold))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
    }
}
```

- [ ] **Step 5: Run the full test suite AND the TV build, verify green**

```bash
set -o pipefail
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tee /tmp/task2-tests.log | grep -E "Test Suite|TEST"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime TV" -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | tail -5
```
Expected: `TEST SUCCEEDED` (0 failures) and `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add -A "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/BroadcastScript.swift" "ios/KataGo iOS/KataGo Anytime TV/TVBroadcastSlideView.swift" "ios/KataGo iOS/KataGo iOSTests/BroadcastScriptTests.swift" "ios/KataGo iOS/KataGo iOSTests/BroadcastControllerTests.swift"
git commit -m "feat(broadcast): pass slide acts out each sentence; chip is a PlayerColor"
```

---

### Task 3: Controller lockstep test + preview verification

**Files:**
- Test: `ios/KataGo iOS/KataGo iOSTests/BroadcastControllerTests.swift`
- Verify (no expected change): `ios/KataGo iOS/KataGo Anytime TV/TVBroadcastSlideView.swift` previews

**Interfaces:**
- Consumes: Task 2's timeline. Fixture facts: `stageFullReport` (side black, punish "E5" → the punish frame is `PlacedStone(vertex: "E5", color: .white)`, `passChip == .black`; contested is empty so the punish stone drains right after fact 1 types). A **white** E5 stone is unique across all three slides' frames — every other placed stone in the fixture is black.

- [ ] **Step 1: Add the lockstep test**

In `BroadcastControllerTests.swift`, directly after `lateTenukiFactProducesItsFramesWhenItLands` (ends line 537), add:

```swift
    @Test("Pass slide: the punish stone lands only after its sentence typed")
    func passSlidePunishStoneWaitsForItsSentence() async {
        let f = Fixture()
        var sawPunishFrame = false
        var textPrecededStone = false
        f.controller.noteTurnChanged(game: f.record)
        for _ in 0..<20_000 {
            if f.controller.phase == .awaitingMove { break }
            if !sawPunishFrame,
               f.controller.currentFrame?.placedStones
                   .contains(PlacedStone(vertex: "E5", color: .white)) == true {
                sawPunishFrame = true
                textPrecededStone = f.controller.typedText.contains("would punish at E5")
            }
            await Task.yield()
        }
        #expect(sawPunishFrame)
        #expect(textPrecededStone)
    }
```

- [ ] **Step 2: Run the full test suite, verify green**

```bash
set -o pipefail
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tee /tmp/task3-tests.log | grep -E "Test Suite|TEST"
```
Expected: `TEST SUCCEEDED`, 0 failures, including the new test.

- [ ] **Step 3: Verify the chip previews still index the intended frames**

Read `TVBroadcastSlideView.swift` previews. `previewModel()`'s passComparison has `contestedPoints: []` and punish "R13", so the new pass frame list is `[bare, chip, .fact(1) barrier, punish+chip, bare, best, best+Δ]` — `#Preview("Pass — punish + chip")` uses `previewFrames(2)[3]`, which is STILL the punish+chip frame (index survives by coincidence). `#Preview("Best — tenuki chip")` uses `previewFrames(0)[5]` — best timeline untouched. If either index no longer lands on its named frame, fix the index; otherwise no edit.

- [ ] **Step 4: Commit**

```bash
git add -A "ios/KataGo iOS/KataGo iOSTests/BroadcastControllerTests.swift"
git commit -m "test(broadcast): pin punish stone waits for its sentence"
```

---

### Task 4: Whole-suite verification + 5-scheme builds + tvOS sim forensics

**Files:** none modified (verification only; a QA report file under `.superpowers/sdd/`).

- [ ] **Step 1: Full iOS-sim test suite** — `TEST SUCCEEDED`, 0 failures (command as in Task 3 Step 2).

- [ ] **Step 2: All five scheme builds** (from `ios/KataGo iOS/`, each judged by `BUILD SUCCEEDED` with pipefail):
  - `KataGo Anytime` → `platform=iOS Simulator,name=iPhone 17`
  - `KataGo Anytime Mac` → `platform=macOS`
  - `KataGo Anytime Vision` → `platform=visionOS Simulator,name=Apple Vision Pro`
  - `KataGo Anytime TV` → `platform=tvOS Simulator,name=Apple TV`
  - `KataGo Anytime Watch` → `platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)`

- [ ] **Step 3: tvOS sim forensics** — install and launch on the Apple TV simulator (app product is "KataGo TV.app" under "DerivedData/KataGo Anytime/Build/Products"), let the broadcast run ≥2 full cycles, capture screenshots of the pass slide at intervals, and verify from screenshots + `log stream`:
  - Pass slide opens on the BARE board (no best stone) while "If … passes instead" types.
  - Chip "… plays elsewhere" appears after that sentence, on the bare board.
  - The punish stone appears only after "would punish at" has typed.
  - The contested sentence types (it is back in the panel), then bare → best stone → Δ overlay end the slide.
  - No stray chip under the next cycle's first slide; one licensed gen-move per cycle; engine idles under slides (CPU duty cycle as before).

- [ ] **Step 4: Write the QA report** to `.superpowers/sdd/task-4-report.md` (screenshots' findings, timings, any anomalies) — no commit unless files changed.
