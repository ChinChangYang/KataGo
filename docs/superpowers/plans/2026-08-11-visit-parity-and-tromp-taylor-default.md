# Visit Parity + Tromp-Taylor Default Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
> **This repo's constraint:** builds/tests must run SERIALLY in the main session (DerivedData lock produces spurious TEST FAILED with two concurrent xcodebuilds; never delegate a build sweep to a subagent). Prefer inline execution.

**Goal:** (A) The Deep Analysis Report's Alternative slot always gets its own forced-candidate probe so its visit count is in the Best Move's ballpark ("visit parity"); (B) the app's default game becomes the Tromp-Taylor preset with komi 7.5 on every creation surface, so the Ruleset picker never shows "Custom"/inconsistent komi for a fresh game.

**Architecture:** (A) is confined to `DeepReportGenerator` + its four scripted-sleeper test files: a new `forcedAlternativeInfo` helper distills the existing `forcedCandidateProbe` to one vertex's info; `applyAlternative`/`applyDefaultAlternative` route every alternative origin (engine #2, game move, user pick, refine-preserved pick) through it, with the cached snapshot entry demoted to a silence fallback. (B) centralizes the default in `Config`'s default-value constants + a new `GameRecord.defaultRuleString`, then points every per-surface default (Mac ⌘N, tvOS form, visionOS, photo import, Messages) at the Tromp-Taylor preset. Decisions recorded in `CONTEXT.md` + `docs/adr/0001-default-ruleset-tromp-taylor.md`.

**Tech Stack:** Swift / Swift Testing (`@Test`/`#expect`), SwiftData (default VALUES only — schema frozen), GTP over `kata-analyze ... allow`, xcodebuild + `swift test`.

## Global Constraints

- English-only committed content; scan the diff before committing.
- NEVER alter SwiftData `@Model` schema (attributes/types/relationships). Changing default value constants is allowed per ADR 0001; nothing else.
- All 5 schemes must build: `KataGo Anytime`, `KataGo Anytime Mac`, `KataGo Anytime Vision`, `KataGo Anytime TV`, `KataGo Anytime Watch`.
- Working dir for all build/test commands: `ios/KataGo iOS`. Never run two xcodebuild invocations concurrently. Piped xcodebuild exit codes lie — use `set -o pipefail` or grep `BUILD SUCCEEDED` / `TEST SUCCEEDED`.
- KataGoUICore package tests (GoRulesKitTests etc.) NEVER run under xcodebuild — run `swift test` in `ios/KataGo iOS/KataGoUICore` separately.
- Do NOT reintroduce low-visit warning chrome in the report UI (round-6b user decision); `ReportNarrator`'s `lowVisitThreshold` hedge stays as-is.
- Round-6b: no "(game move)"/"(your pick)" suffixes on the Alternative heading — visit parity changes values, never labels.
- Commit per task on `ios-dev` (no push — pushes are spaced ≥ ~1 day and trigger Xcode Cloud). Commit trailers:
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>` and the Claude-Session URL line from the harness.
- Unit-test invocation (fast, targeted): `xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/<ClassName>"` (test target display name is `KataGo AnytimeTests`).

---

## Feature A — Deep Report visit parity

Decisions (grilled + approved): every Alternative origin gets a dedicated forced probe (Q1a); budget = `tenuki` budget × refine multiplier, wall-clock as today (Q6a); staged in-place UX unchanged (Q2); cached snapshot entry becomes the silence fallback; refine's preserved-pick path and both smart-default paths go through the same parity helper.

### Task 1: `repickAlternative` always probes (+ `forcedAlternativeInfo` helper)

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/DeepReportGenerator.swift` (repick body lines ~316-335; new helper near `forcedCandidateProbe` ~line 498)
- Test: `ios/KataGo iOS/KataGo iOSTests/DeepReportRepickTests.swift`

**Interfaces:**
- Produces: `private func forcedAlternativeInfo(vertex: String, budget: TimeInterval, mySymbol: String, parser: AnalysisLineParser, width: Int, height: Int) async throws -> AnalysisInfo?` — Tasks 2-3 call it via `applyAlternative`.
- Consumes: existing `forcedCandidateProbe`, `rankedEntries`, `model.snapshotEntries`.

- [ ] **Step 1: Rewrite the repick tests to expect a probe for a snapshot-ranked pick**

In `DeepReportRepickTests.swift`:

1. Add a forced-line fixture for B1 after `static let forcedLine`:

```swift
    /// Forced-probe reply for a snapshot-ranked pick (B1): all root visits
    /// funneled into B1 (rootInfo visits == move visits).
    static let forcedLineB1 = "info move B1 visits 88 winrate 0.53 scoreLead 2.6 utilityLcb 0.3 order 0 pv B1 A2 movesOwnership 0.3 0.3 0.3 0.3 "
        + "rootInfo visits 88 utility 0.1 winrate 0.53 scoreMean 2.6 scoreStdev 8.0 scoreLead 2.6 scoreSelfplay 2.6 weight 88.0 "
        + "ownership 0.5 0.5 0.5 0.5 ownershipStdev 0.1 0.1 0.1 0.1"
```

2. `generateSteps` gains the parity-probe slot for the engine-#2 default (B2). The B2 fixture lives in `DeepReportGeneratorTests` (the base fixture file every report test file already references — see Task 2 Step 1 for its exact text); here reference it and add a local alias next to the existing `static let forcedLine` alias:

```swift
    static let forcedLineB2 = DeepReportGeneratorTests.forcedLineB2

    /// generate()'s conversation: snapshot, grace, parity probe for the
    /// Alternative slot, grace, pass, grace, tenuki 0, grace, tenuki 1, grace.
    static let generateSteps: [[String]] = [
        ["= ", "=", snapshotLine],
        [],
        ["= ", "=", forcedLineB2],
        [],
        ["= ", "=", passLine],
        [],
        ["= ", "= ", "=", tenukiLine],
        [],
        ["= ", "= ", "= ", "=", tenukiLine],
        [],
    ]
```

**IMPORTANT sequencing:** `generateSteps` drives `generate()`, whose parity probe is implemented in Task 2, not this task. To keep every intermediate commit green, Task 1 changes `generate()`-independent things only if the steps still line up — they don't (the extra step would desync the script). Therefore Tasks 1 and 2 are ONE test cycle in two files: write ALL Task-1 and Task-2 test changes first, watch them fail, then implement the full generator change (helpers + repick + runProbes) before running again. Keep the commits separate only if both test files and the generator land in the FIRST commit and Task 2's commit is docs-only — otherwise merge Tasks 1+2 into a single commit `feat(report): visit parity for the Alternative slot (repick + initial run)`. (Task 3 — refine — stays its own cycle/commit because `runRefineProbes` changes independently.)

3. Replace `cachedRepickSkipsForcedProbe` with:

```swift
    @Test func repickRunsForcedProbeEvenForSnapshotRankedPick() async {
        // Visit parity: picking B1 (snapshot-ranked, 10 visits) must still run
        // a forced-allow probe so the alternative's values carry real search.
        // Repick conversation: maxVisits-reset ack + header + forced line,
        // grace, tenuki feed, grace.
        let f = Fixture(steps: Self.generateSteps + [
            ["= ", "=", Self.forcedLineB1],
            [],
            ["= ", "= ", "=", Self.tenukiLine],
            [],
        ])
        await f.generator.generate(model: f.model, gameRecord: f.record)
        #expect(f.model.candidates.map(\.vertex) == ["A1", "B2"])
        let sentBefore = f.engine.sent.count

        await f.generator.repickAlternative(model: f.model, gameRecord: f.record, vertex: "B1")

        #expect(f.model.stage == .complete)
        #expect(f.model.candidates.map(\.vertex) == ["A1", "B1"])
        #expect(f.model.alternativeSource == .userPick)
        // Probed info: values come from the forced line (White 0.53/2.6 →
        // Black 0.47/-2.6), NOT the snapshot's 10-visit entry.
        let alt = f.model.candidates[1]
        #expect(alt.visits == 88)
        #expect(abs(alt.winrate - 0.47) < 1e-4)
        #expect(abs(alt.scoreLead - (-2.6)) < 1e-4)
        #expect(alt.pv == ["B1", "A2"])
        #expect(alt.tenuki?.vertex == "B2")
        let repickSent = Array(f.engine.sent.dropFirst(sentBefore))
        #expect(repickSent.contains("kata-set-param maxVisits 1000000000"))
        #expect(repickSent.contains(
            "kata-analyze b interval 10 allow b B1 1 maxmoves 8 ownership true movesOwnership true rootInfo true"))
        #expect(repickSent.contains("play b B1"))
        #expect(f.model.candidates[0].vertex == "A1")
        #expect(f.session.gobanState.reportGenerationActive == false)
        #expect(repickSent.contains("showboard"))
        #expect(f.model.transientNotice == nil)
    }
```

4. Add the silence-fallback test:

```swift
    @Test func repickProbeSilenceFallsBackToCachedInfo() async {
        // The forced probe stays silent for a snapshot-ranked pick: the cached
        // 10-visit entry backstops it — degraded parity beats a failed pick.
        let f = Fixture(steps: Self.generateSteps + [
            ["= ", "="],
            [],
            ["= ", "= ", "=", Self.tenukiLine],
            [],
        ])
        await f.generator.generate(model: f.model, gameRecord: f.record)

        await f.generator.repickAlternative(model: f.model, gameRecord: f.record, vertex: "B1")

        #expect(f.model.stage == .complete)
        #expect(f.model.candidates.map(\.vertex) == ["A1", "B1"])
        #expect(f.model.alternativeSource == .userPick)
        let alt = f.model.candidates[1]
        #expect(alt.visits == 10)
        #expect(abs(alt.winrate - 0.48) < 1e-4)
        #expect(f.model.transientNotice == nil)
    }
```

5. `uncachedRepickRunsForcedProbe`, `failedRepickKeepsPriorAlternativeAndNotices`, `repickOfBestMoveIsANoOp` keep their bodies but their fixtures use `Self.generateSteps` which now has 10 entries — no other edits needed (the repick feeds are appended after, unchanged).

6. `repickOfGameMoveRestoresGameMoveLabel` — each repick now needs a forced feed:

```swift
    @Test func repickOfGameMoveRestoresGameMoveLabel() async {
        // Game move B2 seeds the alternative (.gameMove); picking B1 makes it
        // .userPick; re-picking B2 restores the .gameMove label. Every pick
        // runs its parity probe.
        let f = Fixture(sgf: "(;GM[1]FF[4]SZ[2];B[ba])", steps: Self.generateSteps + [
            ["= ", "=", Self.forcedLineB1],       // repick B1: parity probe
            [],
            ["= ", "= ", "=", Self.tenukiLine],   // repick B1: tenuki
            [],
            ["= ", "=", Self.forcedLineB2],       // repick B2: parity probe
            [],
            ["= ", "= ", "=", Self.tenukiLine],   // repick B2: tenuki
            [],
        ])
        await f.generator.generate(model: f.model, gameRecord: f.record)
        #expect(f.model.alternativeSource == .gameMove)

        await f.generator.repickAlternative(model: f.model, gameRecord: f.record, vertex: "B1")
        #expect(f.model.alternativeSource == .userPick)

        await f.generator.repickAlternative(model: f.model, gameRecord: f.record, vertex: "B2")
        #expect(f.model.alternativeSource == .gameMove)
        #expect(f.model.candidates.map(\.vertex) == ["A1", "B2"])
        #expect(f.model.stage == .complete)
    }
```

7. Update the class doc comment ("no-reprobe cached path" wording → "parity probe path; cache is the silence fallback").

- [ ] **Step 2: Write Task 2's test changes too** (see Task 2 Steps 1-2 — same cycle, per the sequencing note above)

- [ ] **Step 3: Run the two report test classes to verify the new expectations fail**

Run (from `ios/KataGo iOS`):
```bash
set -o pipefail; xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/DeepReportRepickTests" -only-testing:"KataGo AnytimeTests/DeepReportAlternativeTests" -only-testing:"KataGo AnytimeTests/DeepReportGeneratorTests" 2>&1 | tail -40
```
Expected: FAIL (steps desync — e.g. `candidates` empty or `allow` command missing).

- [ ] **Step 4: Implement the generator change (Tasks 1+2 impl together)**

In `DeepReportGenerator.swift`:

1. Add below `forcedCandidateProbe`:

```swift
    /// One forced-candidate probe distilled to the nominated vertex's own info
    /// entry — the visit-parity workhorse (see CONTEXT.md "Visit parity").
    /// nil when the vertex can't be probed ("pass" has no allow form) or the
    /// engine stayed silent / never ranked it (typically an illegal vertex).
    private func forcedAlternativeInfo(vertex: String,
                                       budget: TimeInterval,
                                       mySymbol: String,
                                       parser: AnalysisLineParser,
                                       width: Int, height: Int) async throws -> AnalysisInfo? {
        guard vertex != "pass",
              let parsed = try await forcedCandidateProbe(vertex: vertex, budget: budget,
                                                          mySymbol: mySymbol, parser: parser)
        else { return nil }
        return rankedEntries(in: parsed, width: width, height: height)
            .first(where: { $0.vertex == vertex })?.info
    }
```

2. In `repickAlternative`, replace the `let info: AnalysisInfo` / `if let entry ... else { guard ... }` block (currently the cached-first branch) with:

```swift
                // Visit parity: even a snapshot-ranked pick gets its own
                // probe; the cached entry only backstops a silent engine.
                let info: AnalysisInfo
                if let probed = try await forcedAlternativeInfo(vertex: vertex, budget: budget,
                                                                mySymbol: mySymbol, parser: parser,
                                                                width: width, height: height) {
                    info = probed
                } else if let entry = model.snapshotEntries.first(where: { $0.vertex == vertex }) {
                    info = entry.info
                } else {
                    throw ReportError("The engine couldn't analyze \(vertex) here — it may be an illegal move.")
                }
```

3. Update `repickAlternative`'s doc comment (line ~285): "only the picked move is probed (cached snapshot info when available, one forced-allow probe otherwise, …)" → "the picked move always gets its own forced-allow probe (visit parity; the cached snapshot entry only backstops a silent engine), plus its tenuki follow-up".

4. Apply Task 2 Step 3's implementation (below) in the same edit session.

- [ ] **Step 5: Run the same three test classes; verify PASS** (command from Step 3). Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/DeepReportGenerator.swift" "ios/KataGo iOS/KataGo iOSTests/DeepReportRepickTests.swift" "ios/KataGo iOS/KataGo iOSTests/DeepReportAlternativeTests.swift" "ios/KataGo iOS/KataGo iOSTests/DeepReportGeneratorTests.swift"
git commit -m "feat(report): visit parity — every Alternative gets its own forced probe"
```

### Task 2: Initial-run parity (`applyAlternative` + `applyDefaultAlternative`)

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/DeepReportGenerator.swift` (`runProbes` lines ~160-188; new helpers; delete nothing yet)
- Test: `ios/KataGo iOS/KataGo iOSTests/DeepReportAlternativeTests.swift`, `ios/KataGo iOS/KataGo iOSTests/DeepReportGeneratorTests.swift`

**Interfaces:**
- Produces: `private func applyAlternative(vertex: String, source: AlternativeSource, budget: TimeInterval, model: DeepReportModel, position: PositionSummary, mySymbol: String, parser: AnalysisLineParser, sideToMove: PlayerColor, width: Int, height: Int) async throws -> Bool` and `private func applyDefaultAlternative(model: DeepReportModel, position: PositionSummary, budget: TimeInterval, mySymbol: String, parser: AnalysisLineParser, sideToMove: PlayerColor, width: Int, height: Int) async throws` — Task 3 reuses both.
- Consumes: Task 1's `forcedAlternativeInfo`.

- [ ] **Step 1: Update `DeepReportGeneratorTests`**

1. Add the shared B2 fixture to `DeepReportGeneratorTests` (the base file the other report test files reference; Task 1's `DeepReportRepickTests.forcedLineB2` alias points at it):

```swift
    /// Forced-probe reply for the engine-#2 default (B2): all root visits
    /// funneled into B2 (rootInfo visits == move visits) — the visit-parity
    /// probe every Alternative gets.
    static let forcedLineB2 = "info move B2 visits 95 winrate 0.54 scoreLead 2.8 utilityLcb 0.4 order 0 pv B2 A2 movesOwnership 0.1 0.1 0.1 0.1 "
        + "rootInfo visits 95 utility 0.1 winrate 0.55 scoreMean 3.0 scoreStdev 8.0 scoreLead 3.0 scoreSelfplay 3.1 weight 95.0 "
        + "ownership 0.5 0.5 0.5 0.5 ownershipStdev 0.1 0.1 0.1 0.1"
```

2. Renumber `Script.sleeper` cases (insert the parity probe as calls 3-4):

```swift
            case 1:   // snapshot probe: set-param ack, analyze header, report line
                feed(["= ", "=", DeepReportGeneratorTests.snapshotLine])
            case 2:   // snapshot's post-stop grace: nothing to feed
                break
            case 3:   // parity probe for the engine-#2 alternative: stop ack, header, line
                feed(["= ", "=", DeepReportGeneratorTests.forcedLineB2])
            case 4:   // parity probe's post-stop grace: nothing to feed
                break
            case 5:   // pass probe: stop ack, analyze header, report line
                feed(["= ", "=", DeepReportGeneratorTests.passLine])
            case 6:   // pass probe's post-stop grace: nothing to feed
                break
            case 7:   // tenuki 0 probe: stop ack, play ack, analyze header, report line
                feed(["= ", "= ", "=", DeepReportGeneratorTests.tenukiLine])
            case 8:   // tenuki 0's post-stop grace: nothing to feed
                break
            case 9:   // tenuki 1 probe: stop ack, undo ack, play ack, header, report line
                feed(["= ", "= ", "= ", "=", DeepReportGeneratorTests.tenukiLine])
            case 10:  // tenuki 1's post-stop grace: nothing to feed
                break
```

3. `expectedProbePrefix` — insert the parity probe after the snapshot's `stop`:

```swift
    static let expectedProbePrefix = [
        "kata-set-param maxVisits 1000000000",
        "kata-analyze interval 50 maxmoves 8 ownership true movesOwnership true rootInfo true",
        "stop",
        "kata-analyze b interval 10 allow b B2 1 maxmoves 8 ownership true movesOwnership true rootInfo true",
        "stop",
        "kata-analyze w interval 10 maxmoves 8 ownership true rootInfo true",
        "stop",
        "play b A1",
        "kata-analyze b interval 10 maxmoves 8 ownership true rootInfo true",
        "stop",
        "undo",
        "play b B2",
        "kata-analyze b interval 10 maxmoves 8 ownership true rootInfo true",
        "stop",
        "undo",
    ]
```

4. In `happyPathBuildsFullReport`, after the candidates[0] assertions add:

```swift
        // Visit parity: the engine-#2 alternative was re-valued by its own
        // forced probe — 95 funneled visits, not the snapshot's 50.
        #expect(f.model.candidates[1].vertex == "B2")
        #expect(f.model.candidates[1].visits == 95)
        #expect(abs(f.model.candidates[1].winrate - 0.46) < 1e-4)
```

5. `cancellationMidTenukiUndoesTheOutstandingPlay`: the first tenuki probe is now sleeper call #7 — change `if script.step >= 4` to `if script.step >= 6` and its comment (`// #7 = first tenuki probe`).

- [ ] **Step 2: Update `DeepReportAlternativeTests`**

1. Default `Fixture` steps (the `steps ?? [...]` literal) gain the parity slot after the snapshot grace:

```swift
            let script = StepScript(session: session, steps: steps ?? [
                ["= ", "=", DeepReportAlternativeTests.snapshotLine],
                [],
                ["= ", "=", DeepReportGeneratorTests.forcedLineB2],
                [],
                ["= ", "=", DeepReportAlternativeTests.passLine],
                [],
                ["= ", "= ", "=", DeepReportAlternativeTests.tenukiLine],
                [],
                ["= ", "= ", "= ", "=", DeepReportAlternativeTests.tenukiLine],
                [],
            ])
```
Update the `/// The default steps mirror...` comment to name the parity slot.

2. `gameMoveInsideTopCandidatesBecomesAlternativeFromCache` → rename `gameMoveInsideTopCandidatesStillGetsParityProbe`; sgf `B[ba]` makes B2 the game move (same vertex as engine #2, so the default fixture feed works); flip the `allow` assertion and check probed values:

```swift
    @Test func gameMoveInsideTopCandidatesStillGetsParityProbe() async {
        // Next recorded move B2 = the snapshot's #2 candidate. Visit parity:
        // even a snapshot-ranked game move gets its own forced-allow probe;
        // its values come from that probe, not the 50-visit snapshot entry.
        let f = Fixture(sgf: "(;GM[1]FF[4]SZ[2];B[ba])")
        await f.generator.generate(model: f.model, gameRecord: f.record)

        #expect(f.model.stage == .complete)
        #expect(f.model.gameMoveVertex == "B2")
        #expect(f.model.alternativeSource == .gameMove)
        #expect(f.model.candidates.map(\.vertex) == ["A1", "B2"])
        #expect(f.engine.sent.contains(
            "kata-analyze b interval 10 allow b B2 1 maxmoves 8 ownership true movesOwnership true rootInfo true"))
        #expect(f.model.candidates[1].visits == 95)
        // Both candidates still get their tenuki probes.
        #expect(f.engine.sent.contains("play b A1"))
        #expect(f.engine.sent.contains("play b B2"))
    }
```

3. `gameMoveOutsideTopCandidatesRunsForcedProbe`: fixture already uses `forcedProbeSteps` (10 entries, forced slot in place) — body unchanged; verify it still passes.

4. `forcedProbeSilenceFallsBackToEngineAlternative`: unchanged body (silent probe → cached engine #2 stays, source `.engine`) — the steps helper already matches. Keep.

5. `gameMoveEqualToBestKeepsEngineAlternative`: the game move IS the best, so the ALTERNATIVE (engine #2 = B2) now gets the parity probe. Default fixture feed covers it; flip the assertion:

```swift
        #expect(f.model.candidates.map(\.vertex) == ["A1", "B2"])
        // The engine-#2 alternative still gets its parity probe.
        #expect(f.engine.sent.contains { $0.contains("allow b B2") })
        #expect(f.model.candidates[1].visits == 95)
```

6. `passNextMoveYieldsNoGameMove`, `wrongColorNextMoveYieldsNoGameMove`, `gameTipYieldsNoGameMove`, `branchPositionIgnoresGameMove`, `snapshotCachesEntriesAndOwnership`: bodies unchanged — they use the default fixture whose steps now include the parity slot. No edits beyond the fixture.

- [ ] **Step 3: Implement — `runProbes` seeding through the parity helpers**

In `DeepReportGenerator.swift`:

1. Add (near `setAlternative`):

```swift
    /// Visit parity (CONTEXT.md): evaluate `vertex` with its own forced probe
    /// so its visits land in the Best Move's ballpark; the cached snapshot
    /// entry only backstops a silent engine. Returns false when neither
    /// source can value the vertex (caller keeps the incumbent alternative).
    private func applyAlternative(vertex: String,
                                  source: AlternativeSource,
                                  budget: TimeInterval,
                                  model: DeepReportModel,
                                  position: PositionSummary,
                                  mySymbol: String,
                                  parser: AnalysisLineParser,
                                  sideToMove: PlayerColor,
                                  width: Int, height: Int) async throws -> Bool {
        let probed = try await forcedAlternativeInfo(vertex: vertex, budget: budget,
                                                     mySymbol: mySymbol, parser: parser,
                                                     width: width, height: height)
        let info = probed ?? model.snapshotEntries.first(where: { $0.vertex == vertex })?.info
        guard let info else { return false }
        setAlternative(buildCandidate(vertex: vertex, info: info,
                                      position: position, sideToMove: sideToMove,
                                      baseOwnership: model.snapshotOwnership,
                                      width: width, height: height),
                       source: source, model: model)
        return true
    }

    /// Seeds the Alternative slot with the smart default — the game's
    /// recorded move when it differs from the best move, else the engine's
    /// #2 — and evaluates it under visit parity. When nothing applies
    /// (single-candidate snapshot, or a silent probe with no cache) the
    /// snapshot's own #2 stays.
    private func applyDefaultAlternative(model: DeepReportModel,
                                         position: PositionSummary,
                                         budget: TimeInterval,
                                         mySymbol: String,
                                         parser: AnalysisLineParser,
                                         sideToMove: PlayerColor,
                                         width: Int, height: Int) async throws {
        model.alternativeSource = .engine
        let choice: (vertex: String, source: AlternativeSource)?
        if let gameMove = model.gameMoveVertex, gameMove != model.candidates.first?.vertex {
            choice = (gameMove, .gameMove)
        } else if model.candidates.count > 1 {
            choice = (model.candidates[1].vertex, .engine)
        } else {
            choice = nil
        }
        guard let choice else { return }
        _ = try await applyAlternative(vertex: choice.vertex, source: choice.source,
                                       budget: budget, model: model, position: position,
                                       mySymbol: mySymbol, parser: parser,
                                       sideToMove: sideToMove, width: width, height: height)
    }
```

2. In `runProbes`, replace the whole smart-default block (from `model.gameMoveVertex = gameMoveVertex(...)` through the end of the `if let gameMove ... }` at line ~188) with:

```swift
        // Smart default for the Alternative slot: the game's actually-played
        // next move (when reviewing mid-game and it differs from the best
        // move) beats the engine's #2 pedagogically — "what you played vs.
        // what's best". Visit parity: whichever move fills the slot gets its
        // own forced probe; probe silence falls back to the snapshot cache.
        model.gameMoveVertex = gameMoveVertex(session: session,
                                              gameRecord: gameRecord,
                                              sideToMove: sideToMove)
        try await applyDefaultAlternative(model: model, position: position,
                                          budget: budgets.tenuki,
                                          mySymbol: mySymbol, parser: parser,
                                          sideToMove: sideToMove,
                                          width: width, height: height)
```

- [ ] **Step 4: Run + commit** — covered by Task 1 Steps 3-6 (same cycle). If Task 1 was committed with all of this already (per the sequencing note), this task's commit is nothing — mark done.

### Task 3: Refine parity (preserved pick + smart-default reset)

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/DeepReportGenerator.swift` (`runRefineProbes` ~lines 216-263; delete `applyGameMoveDefault` ~lines 265-283)
- Test: `ios/KataGo iOS/KataGo iOSTests/DeepReportRefineTests.swift`

**Interfaces:**
- Consumes: Task 2's `applyAlternative` / `applyDefaultAlternative` (exact signatures above).

- [ ] **Step 1: Rewrite the refine tests' conversations**

In `DeepReportRefineTests.swift`:

1. Add a forced-line fixture for A1 (the engine-#2 default after the swapped snapshot) and extend `conversation`:

```swift
    /// Forced-probe reply for A1 (the engine-#2 default once B2 leads).
    static let forcedLineA1 = "info move A1 visits 92 winrate 0.59 scoreLead 4.8 utilityLcb 0.4 order 0 pv A1 B2 movesOwnership 0.9 0.9 0.9 0.9 "
        + "rootInfo visits 92 utility 0.2 winrate 0.58 scoreMean 4.0 scoreStdev 8.0 scoreLead 4.0 scoreSelfplay 4.2 weight 92.0 "
        + "ownership 0.5 0.5 0.5 0.5 ownershipStdev 0.1 0.1 0.1 0.1"

    /// One full probe conversation (generate or refine): snapshot, grace,
    /// parity probe for the Alternative slot, grace, pass, grace, tenuki 0,
    /// grace, tenuki 1, grace.
    static func conversation(snapshot: String = snapshotLine,
                             forced: String = DeepReportGeneratorTests.forcedLineB2) -> [[String]] {
        [
            ["= ", "=", snapshot],
            [],
            ["= ", "=", forced],
            [],
            ["= ", "=", passLine],
            [],
            ["= ", "= ", "=", tenukiLine],
            [],
            ["= ", "= ", "= ", "=", tenukiLine],
            [],
        ]
    }
```

2. `refineDoublesBudgetsAndCapsAtEight` — new expected intervals (the parity probe sleeps `tenuki × multiplier`):

```swift
        #expect(f.script.probeIntervals == [
            2, 1, 1, 1, 1,
            4, 2, 2, 2, 2,
            8, 4, 4, 4, 4,
            16, 8, 8, 8, 8,
            16, 8, 8, 8, 8,
        ])
```
Also update the test's leading comment.

3. `refineReplacesSectionsInPlace`: steps → `Self.conversation() + Self.conversation(snapshot: Self.swappedSnapshotLine, forced: Self.forcedLineA1)`. Add a parity assertion after the existing ones:

```swift
        // Parity: the new engine-#2 alternative (A1) carries its probe's visits.
        #expect(f.model.candidates[1].visits == 92)
```

4. `refinePreservesGameMovePick`: steps stay `Self.conversation() + Self.conversation()` (preserved B2 is probed in the same forced slot). Body unchanged.

5. `refineReprobesPickOutsideNewTopCandidates`: `refineConversation`'s forced slot already exists — keep, but its comment becomes "// parity re-probe of the preserved pick". Body unchanged.

6. `refineResetsPickWhenItBecomesBest`: steps → `Self.conversation() + Self.conversation(snapshot: Self.swappedSnapshotLine, forced: Self.forcedLineA1)`. Add:

```swift
        #expect(f.model.candidates[1].visits == 92)
```

7. `cancelledRefineKeepsCompletedReport`, `engineErrorMidRefineKeepsCompletedReport`, `silentRefineSnapshotKeepsCompletedReport`, `refineRequiresCompletedReport`: unchanged (they abort before/at the snapshot).

- [ ] **Step 2: Run the refine test class; verify the new expectations FAIL**

```bash
set -o pipefail; xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/DeepReportRefineTests" 2>&1 | tail -30
```
Expected: FAIL (extra sleep interval missing / cached path taken).

- [ ] **Step 3: Implement — route `runRefineProbes` through the parity helpers**

Replace the whole `if let preserved = preservedVertex { ... } else { applyGameMoveDefault(...) }` block (lines ~225-255) with:

```swift
        if let preserved = preservedVertex {
            if preserved == model.candidates.first?.vertex {
                model.transientNotice = "\(preserved) is now the Best Move — the alternative was reset."
                try await applyDefaultAlternative(model: model, position: position,
                                                  budget: scaled.tenuki, mySymbol: mySymbol,
                                                  parser: parser, sideToMove: sideToMove,
                                                  width: width, height: height)
            } else if try await applyAlternative(vertex: preserved, source: preservedSource,
                                                 budget: scaled.tenuki, model: model,
                                                 position: position, mySymbol: mySymbol,
                                                 parser: parser, sideToMove: sideToMove,
                                                 width: width, height: height) {
                // Preserved pick re-evaluated at the deeper budget (parity).
            } else {
                model.transientNotice = "The engine couldn't re-analyze \(preserved) — the alternative was reset."
                try await applyDefaultAlternative(model: model, position: position,
                                                  budget: scaled.tenuki, mySymbol: mySymbol,
                                                  parser: parser, sideToMove: sideToMove,
                                                  width: width, height: height)
            }
        } else {
            try await applyDefaultAlternative(model: model, position: position,
                                              budget: scaled.tenuki, mySymbol: mySymbol,
                                              parser: parser, sideToMove: sideToMove,
                                              width: width, height: height)
        }
```

Delete `applyGameMoveDefault` entirely. Update `runRefineProbes`'s doc comment (lines ~202-207): "…a picked or game-move vertex is preserved and re-probed under visit parity; if it became the best move — or can't be re-analyzed — the slot falls back to the smart default (also parity-probed) with a notice."

- [ ] **Step 4: Run the refine class again; verify PASS** (command from Step 2). Expected: PASS.

- [ ] **Step 5: Run ALL report test classes together** (Repick, Alternative, Generator, Refine, plus `GobanStateResumeAnalysisTests` which shares `ReportProbeEngine`):

```bash
set -o pipefail; xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/DeepReportRepickTests" -only-testing:"KataGo AnytimeTests/DeepReportAlternativeTests" -only-testing:"KataGo AnytimeTests/DeepReportGeneratorTests" -only-testing:"KataGo AnytimeTests/DeepReportRefineTests" -only-testing:"KataGo AnytimeTests/GobanStateResumeAnalysisTests" 2>&1 | tail -20
```
Expected: TEST SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Report/DeepReportGenerator.swift" "ios/KataGo iOS/KataGo iOSTests/DeepReportRefineTests.swift"
git commit -m "feat(report): refine preserves the pick under visit parity"
```

---

## Feature B — Default ruleset Tromp-Taylor, komi 7.5

Decisions (grilled + approved): Tromp-Taylor preset + suggested komi 7.5 (Q3); every creation surface, single source of truth (Q4); no migration (Q5); named `RU[tromp-taylor]` token (Q7); photo import + Messages flip too (Q8); Mac rule-index hole fixed now (Q9); GoRulesKit Korean-ko + NZ-komi fixes now (Q10); default VALUES in `ConfigModel.swift` may change (Q11 / ADR 0001).

Tromp-Taylor expansion (from `rules.cpp`, test-locked): ko POSITIONAL, scoring AREA, tax NONE, multi-stone suicide LEGAL, no button, whb 0 — suggested komi 7.5.

### Task 4: `Config` default constants + consistency test

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/ConfigModel.swift` (constants only: `defaultKomi` ~:244, `defaultRule` ~:270, `defaultKoRule` ~:629, `defaultMultiStoneSuicideLegal` ~:686)
- Test: `ios/KataGo iOS/KataGo iOSTests/NewGameRulesetTests.swift`

**Interfaces:**
- Produces: `Config.defaultKomi == 7.5`, `Config.defaultRule == 6` (`Config.rules[6] == "tromp-taylor"`), `Config.defaultKoRule == 1` (POSITIONAL), `Config.defaultMultiStoneSuicideLegal == true`. Tax/scoring/button/whb defaults unchanged (already TT). Tasks 5-9 rely on these.

- [ ] **Step 1: Write the failing consistency test** (append to `NewGameRulesetTests.swift`):

```swift
    /// ADR 0001: the default game is the Tromp-Taylor preset with its
    /// suggested komi — every Config default constant must stay consistent
    /// with the preset's engine-parsed expansion.
    @Test func defaultConfigIsTrompTaylorPreset() throws {
        #expect(Config.rules[Config.defaultRule] == "tromp-taylor")
        #expect(NewGameRuleset.preset(fromConfigRule: Config.defaultRule) == .trompTaylor)
        let expanded = try #require(NewGameRules.expand(.trompTaylor))
        let defaults = NewGameRuleComponents(
            koRule: try #require(KoRule(rawValue: Config.defaultKoRule)),
            scoringRule: try #require(ScoringRule(rawValue: Config.defaultScoringRule)),
            taxRule: try #require(TaxRule(rawValue: Config.defaultTaxRule)),
            multiStoneSuicideLegal: Config.defaultMultiStoneSuicideLegal,
            hasButton: Config.defaultHasButton,
            whiteHandicapBonusRule: try #require(WhiteHandicapBonusRule(rawValue: Config.defaultWhiteHandicapBonusRule)))
        #expect(defaults == expanded)
        #expect(NewGameRules.match(defaults) == .trompTaylor)
        #expect(Config.defaultKomi == NewGameRules.suggestedKomi(expanded))
    }
```
(If `KoRule` etc. aren't `Int`-raw representable in this direction, use the enum cases directly: `koRule: .positional, scoringRule: .area, taxRule: .none, whiteHandicapBonusRule: .zero` and separately `#expect(Config.defaultKoRule == KoRule.positional.rawValue)` — check `GameRules.swift` first.)

- [ ] **Step 2: Run it; verify FAIL** (Chinese-ish defaults):

```bash
set -o pipefail; xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/NewGameRulesetTests" 2>&1 | tail -20
```

- [ ] **Step 3: Change the four constants** in `ConfigModel.swift` (default VALUES only — see ADR 0001; do NOT touch property declarations, the `rules` array, or anything else):

```swift
    public static let defaultKomi: Float = 7.5
```
```swift
    /// Config.rules[6] == "tromp-taylor" — the default game's ruleset
    /// (ADR 0001: docs/adr/0001-default-ruleset-tromp-taylor.md).
    public static let defaultRule = 6
```
```swift
    public static let defaultKoRule: Int = 1   // POSITIONAL — Tromp-Taylor (ADR 0001)
```
```swift
    public static let defaultMultiStoneSuicideLegal = true   // Tromp-Taylor (ADR 0001)
```
(Match each existing declaration's exact spelling/type annotation when editing; the comments above are additions.)

- [ ] **Step 4: Run the NewGameRulesetTests + ConfigModelTests classes; verify PASS**:

```bash
set -o pipefail; xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/NewGameRulesetTests" -only-testing:"KataGo AnytimeTests/ConfigModelTests" 2>&1 | tail -20
```
(`ConfigModelTests.testDefaultInitialization` compares against the constants, so it must stay green untouched.)

- [ ] **Step 5: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/ConfigModel.swift" "ios/KataGo iOS/KataGo iOSTests/NewGameRulesetTests.swift"
git commit -m "feat(rules): default Config is the Tromp-Taylor preset, komi 7.5"
```

### Task 5: Default SGF — `defaultRuleString` + composed `defaultSgf`/`makeDefaultSgf`

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/GameRecord.swift` (lines 28-33)
- Test: `ios/KataGo iOS/KataGo iOSTests/GameRecordTests.swift`

**Interfaces:**
- Produces: `GameRecord.defaultRuleString == "tromp-taylor"` (public; Tasks 6-7 use it); `GameRecord.defaultSgf == "(;FF[4]GM[1]SZ[19]PB[]PW[]HA[0]KM[7.5]RU[tromp-taylor])"`.
- Consumes: `Config.komiText`, `Config.defaultKomi` (same module).

- [ ] **Step 1: Write the failing test** (append to `GameRecordTests.swift`):

```swift
    /// ADR 0001: the default game's SGF carries the named Tromp-Taylor token
    /// and the preset's suggested komi, and createGameRecord derives that
    /// komi into the Config.
    @Test func defaultSgfIsTrompTaylorWithSuggestedKomi() async throws {
        #expect(GameRecord.defaultSgf == "(;FF[4]GM[1]SZ[19]PB[]PW[]HA[0]KM[7.5]RU[tromp-taylor])")
        #expect(GameRecord.makeDefaultSgf(boardSize: 9) == "(;FF[4]GM[1]SZ[9]PB[]PW[]HA[0]KM[7.5]RU[tromp-taylor])")
        let record = GameRecord.createGameRecord()
        #expect(record.concreteConfig.komi == 7.5)
        #expect(record.concreteConfig.rule == Config.defaultRule)
    }
```
(Verify the accessor is `concreteConfig` — grep `concreteConfig` in `GameRecord+SGF.swift`/`GameRecord.swift`; if it's optional `config`, adapt with `try #require(record.config)`.)

- [ ] **Step 2: Run the GameRecordTests class; verify the new test FAILS** (old `KM[7]` string).

- [ ] **Step 3: Implement** — replace lines 28-33 of `GameRecord.swift`:

```swift
    /// The default game's ruleset token: Tromp-Taylor, KataGo's canonical
    /// rules (ADR 0001). Every fresh-game surface composes its SGF from this
    /// and `Config.defaultKomi` so the default cannot drift per-platform.
    public static let defaultRuleString = "tromp-taylor"
    public static let defaultSgf = makeDefaultSgf(boardSize: 19)
    public static let defaultName = "New Game"

    public static func makeDefaultSgf(boardSize: Int) -> String {
        "(;FF[4]GM[1]SZ[\(boardSize)]PB[]PW[]HA[0]KM[\(Config.komiText(Config.defaultKomi))]RU[\(defaultRuleString)])"
    }
```
(Keep `defaultName` exactly where it was; only the SGF constants change.)

- [ ] **Step 4: Run the GameRecordTests + SgfReplayDifferentialTests + GobanStateReviewLockTests + SelfPlayGameTests classes** (all touch `defaultSgf`); expected PASS — `editingAfterLoad` compares `sgf == GameRecord.defaultSgf` so fresh games still auto-unlock; the differential replay is rules-agnostic:

```bash
set -o pipefail; xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/GameRecordTests" -only-testing:"KataGo AnytimeTests/SgfReplayDifferentialTests" -only-testing:"KataGo AnytimeTests/GobanStateReviewLockTests" -only-testing:"KataGo AnytimeTests/SelfPlayGameTests" -only-testing:"KataGo AnytimeTests/GobanStateBranchTests" 2>&1 | tail -20
```
Known accepted consequence (Q5, no migration): EXISTING tester games whose SGF is the old `KM[7]` default string stop matching `editingAfterLoad`'s auto-unlock and will load locked — tester data disposable, do not add a compatibility branch.

- [ ] **Step 5: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/GameRecord.swift" "ios/KataGo iOS/KataGo iOSTests/GameRecordTests.swift"
git commit -m "feat(rules): default SGF carries RU[tromp-taylor] KM[7.5]"
```

### Task 6: visionOS — derive `startNewGame` from the shared constants

**Files:**
- Modify: `ios/KataGo iOS/KataGo Anytime Vision/VisionRootView.swift` (lines ~741-747)

**Interfaces:**
- Consumes: `GameRecord.defaultRuleString`, `Config.defaultKomi`, `GameRecord.makeSgf(width:height:komi:ruleString:)`.

- [ ] **Step 1: Implement** — replace the hardcoded literals:

```swift
    /// Any width x height in 2...cap (the Custom panel's steppers enforce the
    /// bounds; the quick 9/13/19 buttons disable above the cap). Default komi
    /// and rules (ADR 0001) — the square path produces makeDefaultSgf
    /// byte-for-byte.
    private func startNewGame(width: Int, height: Int) {
        let record = GameRecord.createGameRecord(
            sgf: GameRecord.makeSgf(width: width, height: height, komi: Config.defaultKomi,
                                    ruleString: GameRecord.defaultRuleString))
```
(Rest of the function body unchanged. If `Config` isn't in scope, add `import KataGoGameStore` alongside the file's existing imports.)

- [ ] **Step 2: Build visionOS; verify BUILD SUCCEEDED** (no test target reaches this file):

```bash
set -o pipefail; xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Vision" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
```

- [ ] **Step 3: Commit**

```bash
git add "ios/KataGo iOS/KataGo Anytime Vision/VisionRootView.swift"
git commit -m "feat(vision): new-game path derives rules/komi from the shared default"
```

### Task 7: macOS ⌘N — default Tromp-Taylor + persist the preset's rule index (Q9 hole)

**Files:**
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/NewGameViewController.swift` (init ~lines 36-71, `create` ~line 298-309, `onCreate` type ~line 30)
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/LibraryActions.swift` (closure ~lines 46-52)

**Interfaces:**
- Produces: `onCreate: (_ sgf: String, _ name: String, _ configRuleIndex: Int) -> Void` — LibraryActions is the only instantiation site (verified by grep).
- Consumes: `NewGameRuleset.trompTaylor`, `.configRuleIndex`, `GameRecord.createGameRecord(sgf:name:)`, `record.concreteConfig`.

- [ ] **Step 1: Implement `NewGameViewController`**

```swift
    /// Called once, on Create, with the SGF (encoding size/komi/rules), the
    /// name, and the chosen preset's Config.rule index (Custom → -1) so the
    /// caller can persist the label createGameRecord doesn't derive.
    private let onCreate: (_ sgf: String, _ name: String, _ configRuleIndex: Int) -> Void
```
```swift
    private var komi: Float = 7.5
    private var preset: NewGameRuleset = .trompTaylor
```
In `init` (default components — ADR 0001):
```swift
        self.components = NewGameRules.expand(.trompTaylor)
            ?? NewGameRuleComponents(koRule: .positional, scoringRule: .area, taxRule: .none,
                                     multiStoneSuicideLegal: true, hasButton: false,
                                     whiteHandicapBonusRule: .zero)
```
Also update the `init(maxBoardLength:onCreate:)` parameter type to the 3-arg closure. In `create(_:)`:
```swift
        onCreate(sgf, name, preset.configRuleIndex)
```

- [ ] **Step 2: Implement `LibraryActions.newGame`** — closure takes the third param and persists it:

```swift
            let dialog = NewGameViewController(maxBoardLength: self.launchedMaxBoardLength) {
                [weak self] sgf, name, configRuleIndex in
                guard let self else { return }
                let previous = self.navigationContext.selectedGameRecord
                let untitled = GameRecord.createGameRecord(sgf: sgf, name: name)
                // createGameRecord doesn't derive Config.rule from RU[]; carry
                // the chosen preset's label so other surfaces (tvOS cards)
                // don't mislabel Mac-created games.
                untitled.concreteConfig.rule = configRuleIndex
```
(Rest of the closure body unchanged.)

- [ ] **Step 3: Build macOS; verify BUILD SUCCEEDED; run Mac tests if the scheme has a test action** (SmokeTests/GameDraftTests exist — try it; if the scheme reports no test action, note it and move on):

```bash
set -o pipefail; xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS' -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
set -o pipefail; xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS' 2>&1 | tail -15
```

- [ ] **Step 4: Commit**

```bash
git add "ios/KataGo iOS/KataGo Anytime Mac/NewGameViewController.swift" "ios/KataGo iOS/KataGo Anytime Mac/LibraryActions.swift"
git commit -m "feat(mac): New Game defaults to Tromp-Taylor and persists the preset's rule index"
```

### Task 8: tvOS form — default Tromp-Taylor

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Util/TVNewGameForm.swift` (lines 18, 57, 61)
- Test: `ios/KataGo iOS/KataGo iOSTests/TVNewGameFormTests.swift`

**Interfaces:**
- Consumes: `GameRecord.defaultRuleString`, `Config.defaultKomi`.

- [ ] **Step 1: Write the failing test** (append to `TVNewGameFormTests.swift`):

```swift
    @Test("the form defaults to the app default ruleset (ADR 0001)")
    func defaultsToTrompTaylor() throws {
        let form = TVNewGameForm(maxBoardLength: 37)
        #expect(form.ruleset == .trompTaylor)
        #expect(form.komi == 7.5)
        let sgf = try #require(form.sgf)
        #expect(sgf.contains("RU[tromp-taylor]"))
        #expect(sgf.contains("KM[7.5]"))
    }
```

- [ ] **Step 2: Run the class; verify FAIL** (`.chinese` default).

- [ ] **Step 3: Implement** in `TVNewGameForm.swift`:

```swift
    public var ruleset: NewGameRuleset = .trompTaylor
```
```swift
        guard let components = NewGameRules.expand(ruleset) else { return Config.defaultKomi }
```
```swift
    public var ruleString: String { ruleset.sgfToken ?? GameRecord.defaultRuleString }
```

- [ ] **Step 4: Run TVNewGameFormTests; verify PASS.** Also build tvOS:

```bash
set -o pipefail; xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime TV" -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
```

- [ ] **Step 5: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Util/TVNewGameForm.swift" "ios/KataGo iOS/KataGo iOSTests/TVNewGameFormTests.swift"
git commit -m "feat(tv): New Game form defaults to Tromp-Taylor"
```

### Task 9: Photo import — synthesized SGF carries the app default

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/GobanRecogKit/RecognizedBoard.swift` (line ~106 + doc comment 76-87)
- Test: `ios/KataGo iOS/KataGo iOSTests/RecognizedBoardSgfTests.swift`

**Interfaces:**
- Produces: synthesized SGF header `...SZ[n]RU[tromp-taylor]KM[7.5]PL[...]`.
- Note: GobanRecogKit must not gain a KataGoGameStore dependency it doesn't have — check its Package.swift target deps first; if absent, keep string literals (`"tromp-taylor"`, `"7.5"`) with a comment pointing at `GameRecord.defaultRuleString`/ADR 0001, and add a cross-module consistency test in the iOS test target instead.

- [ ] **Step 1: Update `RecognizedBoardSgfTests`** — grep for `RU[Chinese]`/`KM[7]` expectations and flip them to `RU[tromp-taylor]`/`KM[7.5]`. Add (or extend) an assertion:

```swift
        #expect(sgf.contains("RU[tromp-taylor]KM[7.5]"))
        // Cross-module consistency with the app default (ADR 0001):
        #expect(sgf.contains("RU[\(GameRecord.defaultRuleString)]"))
```

- [ ] **Step 2: Run the class; verify FAIL.**

- [ ] **Step 3: Implement** — in `synthesizedSGF`:

```swift
        var sgf = "(;GM[1]FF[4]CA[UTF-8]AP[KataGo Anytime]SZ[\(size)]RU[tromp-taylor]KM[7.5]PL[\(pl)]"
```
Update the contract doc comment: `RU[tromp-taylor]` is the app's default ruleset (ADR 0001); `KM[7.5]` matches `Config.defaultKomi` so the displayed komi is consistent after import. Keep the "must be written" rationale sentences.

- [ ] **Step 4: Run the class; verify PASS. Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/GobanRecogKit/RecognizedBoard.swift" "ios/KataGo iOS/KataGo iOSTests/RecognizedBoardSgfTests.swift"
git commit -m "feat(recog): imported boards default to Tromp-Taylor 7.5"
```

### Task 10: Messages extension default + GoRulesKit preset corrections (Q8+Q10)

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/GoRulesKit/GoRules.swift` (korean ~:51-54, newZealand ~:63-66)
- Modify: `ios/KataGo iOS/KataGoAnytimeMessages/SetupCardView.swift` (line 54)
- Test: `ios/KataGo iOS/KataGoUICore/Tests/GoRulesKitTests/GoRulesKitTests.swift`

**Interfaces:**
- Produces: `GoRules.korean.koRule == .simple`; `GoRules.newZealand.komi == 7.5`; Messages setup card opens on Tromp-Taylor.
- Do NOT touch the bare `GoRules.init` defaults or `MessageGameCodec` — old threads decode explicit values; changing init defaults could alter decoded games.

- [ ] **Step 1: Write the failing package tests** (append to `GoRulesKitTests.swift`):

```swift
    @Test func koreanMatchesTheEngineBranch() {
        // cpp/game/rules.cpp parses "korean" in the same branch as Japanese:
        // SIMPLE ko, territory, seki tax, komi 6.5.
        var expected = GoRules.japanese
        expected.komi = GoRules.korean.komi
        #expect(GoRules.korean == expected)
        #expect(GoRules.korean.koRule == .simple)
    }

    @Test func newZealandKomiMatchesTheEngineDefault() {
        // cpp/game/rules.cpp: new-zealand → komi 7.5.
        #expect(GoRules.newZealand.komi == 7.5)
    }
```

- [ ] **Step 2: Run the package tests; verify the two FAIL** (from `ios/KataGo iOS/KataGoUICore`):

```bash
cd KataGoUICore && swift test --filter GoRulesKitTests 2>&1 | tail -15; cd ..
```

- [ ] **Step 3: Implement** in `GoRules.swift`:

```swift
    public static let korean = GoRules(
        koRule: .simple, scoringRule: .territory, taxRule: .seki,
        multiStoneSuicideLegal: false, hasButton: false,
        whiteHandicapBonusRule: .zero, komi: 6.5)
```
```swift
    public static let newZealand = GoRules(
        koRule: .situational, scoringRule: .area, taxRule: .none,
        multiStoneSuicideLegal: true, hasButton: false,
        whiteHandicapBonusRule: .zero, komi: 7.5)
```
And in `SetupCardView.swift`:
```swift
    @State private var rules: GoRules = .trompTaylor
```

- [ ] **Step 4: Run package tests (PASS) + build iOS** (the Messages appex builds with the iOS scheme):

```bash
cd KataGoUICore && swift test --filter GoRulesKitTests 2>&1 | tail -10; cd ..
set -o pipefail; xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
```

- [ ] **Step 5: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/GoRulesKit/GoRules.swift" "ios/KataGo iOS/KataGoAnytimeMessages/SetupCardView.swift" "ios/KataGo iOS/KataGoUICore/Tests/GoRulesKitTests/GoRulesKitTests.swift"
git commit -m "feat(messages): default Tromp-Taylor; fix Korean ko + NZ komi in GoRulesKit"
```

### Task 11: Full verification sweep + docs

**Files:**
- Verify only (no source edits expected). Docs: `CONTEXT.md`, `docs/adr/0001-default-ruleset-tromp-taylor.md` (already written), this plan's checkboxes.

- [ ] **Step 1: Full unit-test run (iOS scheme)** — the only test gate; expect ~1000+ tests green:

```bash
set -o pipefail; xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -25
```
Expected: TEST SUCCEEDED, 0 failures. Investigate ANY failure before proceeding (do not rerun-to-green).

- [ ] **Step 2: Full package tests**:

```bash
cd KataGoUICore && swift test 2>&1 | tail -10; cd ..
```

- [ ] **Step 3: Serial 5-platform build sweep** (one at a time; grep verdicts):

```bash
set -o pipefail; for scheme_dest in "KataGo Anytime|platform=iOS Simulator,name=iPhone 17" "KataGo Anytime Mac|platform=macOS" "KataGo Anytime Vision|platform=visionOS Simulator,name=Apple Vision Pro" "KataGo Anytime TV|platform=tvOS Simulator,name=Apple TV" "KataGo Anytime Watch|platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)"; do IFS='|' read -r s d <<< "$scheme_dest"; echo "== $s =="; xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "$s" -destination "$d" -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)" || echo "BUILD FAILED (no verdict)"; done
```
Expected: five `BUILD SUCCEEDED` lines.

- [ ] **Step 4: English-only + diff scan** — `git log --stat` the new commits; `git diff master...HEAD -- CONTEXT.md docs/` etc.; confirm no CJK, no stray files (e.g. the untracked `KataGo Anytime/` cruft must NOT be committed).

- [ ] **Step 5: Commit docs** (CONTEXT.md, ADR, plan file) if not yet committed:

```bash
git add CONTEXT.md docs/adr/0001-default-ruleset-tromp-taylor.md docs/superpowers/plans/2026-08-11-visit-parity-and-tromp-taylor-default.md
git commit -m "docs: domain glossary, ADR 0001 (Tromp-Taylor default), implementation plan"
```

- [ ] **Step 6: Adversarial review pass** (ultracode): run a read-only multi-agent review of `git diff <base>..HEAD` (correctness / probe-protocol regressions / defaults-drift), verify findings, fix anything confirmed, re-run affected tests.

## Deferred to human QA (report in final summary)

- Device latency of the report with the extra ~1-2 s parity probe (vs the ~5 s budget); Refine at 8× now sleeps 8 s more than before.
- Live sim/device run: pick a snapshot-ranked low-policy move → visits jump to the best move's ballpark without Refine.
- Mac ⌘N: create a TT-default game → tvOS card shows "Tromp-Taylor" (Q9 fix) — needs an iCloud round-trip.
- Messages: new thread setup card opens on Tromp-Taylor komi 7.5.
- Existing tester games with the old `KM[7]` default SGF now load LOCKED (accepted, Q5).
