//
//  DeepReportGeneratorTests.swift
//  KataGo AnytimeTests
//
//  The injectable sleeper makes these tests deterministic: each "sleep" feeds
//  the scripted engine replies for that stage synchronously, so no wall-clock
//  timing is involved.
//

import Testing
import Foundation
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
    /// Forced-probe reply for the engine-#2 default (B2): all root visits
    /// funneled into B2 (rootInfo visits == move visits) — the visit-parity
    /// probe every Alternative gets.
    static let forcedLineB2 = "info move B2 visits 95 winrate 0.54 scoreLead 2.8 utilityLcb 0.4 order 0 pv B2 A2 movesOwnership 0.1 0.1 0.1 0.1 "
        + "rootInfo visits 95 utility 0.1 winrate 0.55 scoreMean 3.0 scoreStdev 8.0 scoreLead 3.0 scoreSelfplay 3.1 weight 95.0 "
        + "ownership 0.5 0.5 0.5 0.5 ownershipStdev 0.1 0.1 0.1 0.1"

    @MainActor
    final class Script {
        let session: GameSession
        var step = 0
        /// Cold-engine simulation: the first snapshot analyze is acked but
        /// never reports, so the generator's one retry has to carry it. The
        /// two extra sleeps are absorbed here so the rest of the conversation
        /// keeps its existing step numbers.
        var overrideFirstSnapshotWithSilence = false
        /// A rejected snapshot command — must NOT be retried.
        var errorTheFirstSnapshot = false
        private var silenceConsumed = false
        private var silenceStep = 0
        init(session: GameSession) { self.session = session }
        func feed(_ lines: [String]) { lines.forEach { session.lineObserver?($0) } }
        func sleeper(_ interval: TimeInterval) async throws {
            if errorTheFirstSnapshot, step == 0 {
                step += 1
                feed(["= ", "? cannot analyze this position"])
                return
            }
            if overrideFirstSnapshotWithSilence, !silenceConsumed {
                silenceStep += 1
                switch silenceStep {
                case 1:   // silent attempt: set-param ack + analyze header, no report line
                    feed(["= ", "="])
                case 2:   // its post-stop grace
                    break
                case 3:   // the retry: stop ack, set-param ack, analyze header, report line
                    feed(["= ", "= ", "=", DeepReportGeneratorTests.snapshotLine])
                case 4:   // the retry's grace; hand back to the shared script at the pass probe
                    silenceConsumed = true
                    step = 2
                default:
                    break
                }
                return
            }
            step += 1
            switch step {
            case 1:   // snapshot probe: set-param ack, analyze header, report line
                feed(["= ", "=", DeepReportGeneratorTests.snapshotLine])
            case 2:   // snapshot's post-stop grace: nothing to feed
                break
            case 3:   // pass probe: stop ack, analyze header, report line
                      // (ADR 0003: the pass stage runs BEFORE the parity probe)
                feed(["= ", "=", DeepReportGeneratorTests.passLine])
            case 4:   // pass probe's post-stop grace: nothing to feed
                break
            case 5:   // parity probe for the engine-#2 alternative: stop ack, header, line
                feed(["= ", "=", DeepReportGeneratorTests.forcedLineB2])
            case 6:   // parity probe's post-stop grace: nothing to feed
                break
            case 7:   // tenuki 0 probe: stop ack, play ack, analyze header, report line
                feed(["= ", "= ", "=", DeepReportGeneratorTests.tenukiLine])
            case 8:   // tenuki 0's post-stop grace: nothing to feed
                break
            case 9:   // tenuki 1 probe: stop ack, undo ack, play ack, header, report line
                feed(["= ", "= ", "= ", "=", DeepReportGeneratorTests.tenukiLine])
            case 10:  // tenuki 1's post-stop grace: nothing to feed
                break
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

    /// The full probe command stream of the happy-path fixture, in order.
    /// Snapshot, then the PASS probe, then the Alternative's visit-parity
    /// probe, then the tenuki probes: ADR 0003 puts the pass stage ahead of
    /// the newest, least-proven probe so it cannot starve the oldest feature.
    static let expectedProbePrefix = [
        "kata-set-param maxVisits 1000000000",
        "kata-analyze interval 50 maxmoves 8 ownership true movesOwnership true rootInfo true",
        "stop",
        "kata-analyze w interval 10 maxmoves 8 ownership true rootInfo true",
        "stop",
        "kata-analyze b interval 10 allow b B2 1 maxmoves 8 ownership true movesOwnership true rootInfo true",
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

    /// A cold engine — the first cycle after a replay screen opens — can spend
    /// the whole snapshot budget loading and emit its first report line only
    /// afterwards. Silence there is fatal (no candidates, no report), so it
    /// costs the opening move of a replay ALL of its commentary. Observed in
    /// the tvOS simulator as `generate FAILED 'The engine produced no analysis
    /// for this position.'` on cycle 1, with every later cycle perfect. One
    /// retry turns that into a lost beat instead of a lost report.
    @Test func aSilentFirstSnapshotIsRetriedRatherThanFailingTheReport() async {
        let f = Fixture()
        // Step 1 answers the analyze but never reports; the retry at step 3
        // does. Everything after shifts by the retry's two sleeps.
        f.script.overrideFirstSnapshotWithSilence = true

        await f.generator.generate(model: f.model, gameRecord: f.record)

        #expect(f.model.stage == .complete)
        #expect(f.model.candidates.count == 2)
        #expect(f.model.passComparison != nil)
        // Two analyze commands for one snapshot: the silent try, then the retry.
        let snapshotAnalyzes = f.engine.sent.filter {
            $0 == "kata-analyze interval 50 maxmoves 8 ownership true movesOwnership true rootInfo true"
        }
        #expect(snapshotAnalyzes.count == 2)
    }

    /// The retry is silence-only: repeating a command the engine just rejected
    /// would only burn a second budget, so an ERROR still fails immediately.
    @Test func anErroringSnapshotFailsWithoutARetry() async {
        let f = Fixture()
        f.script.errorTheFirstSnapshot = true

        await f.generator.generate(model: f.model, gameRecord: f.record)

        guard case .failed = f.model.stage else {
            Issue.record("expected a failed report, got \(f.model.stage)")
            return
        }
        let snapshotAnalyzes = f.engine.sent.filter {
            $0 == "kata-analyze interval 50 maxmoves 8 ownership true movesOwnership true rootInfo true"
        }
        #expect(snapshotAnalyzes.count == 1)
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

        // Visit parity: the engine-#2 alternative was re-valued by its own
        // forced probe — 95 funneled visits, not the snapshot's 50.
        #expect(f.model.candidates[1].vertex == "B2")
        #expect(f.model.candidates[1].visits == 95)
        #expect(abs(f.model.candidates[1].winrate - 0.46) < 1e-4)

        // Pass comparison: White-persp 0.72 → Black 0.28; best candidate 0.40.
        #expect(abs((f.model.passComparison?.winrate ?? 0) - 0.28) < 1e-4)
        #expect(abs((f.model.passComparison?.winrateDeltaVsBest ?? 0) - 0.12) < 1e-4)
        #expect(f.model.passComparison?.punishmentVertex == "B2")
        #expect(f.model.passComparison?.contestedPoints.isEmpty == false)

        // Exact probe command stream, in order.
        let sent = f.engine.sent
        let expectedPrefix = Self.expectedProbePrefix
        #expect(Array(sent.prefix(expectedPrefix.count)) == expectedPrefix)
        // Restore: a final stop then the board re-sync showboard.
        #expect(sent.dropFirst(expectedPrefix.count).contains("stop"))
        #expect(sent.dropFirst(expectedPrefix.count).contains("showboard"))
        #expect(sent.dropFirst(expectedPrefix.count).contains("play b pass"))

        // Cleanup: flags and observer restored.
        #expect(f.session.gobanState.reportGenerationActive == false)
        #expect(f.session.lineObserver == nil)

        // Off-branch: the committed move number is reported and
        // Copy-to-Comment stays available.
        #expect(f.model.moveNumber == f.record.currentIndex)
        #expect(f.model.isBranchPosition == false)
    }

    @Test func restoreDoesNotRearmContinuousAnalysis() async {
        let f = Fixture()
        // Make the re-arm preconditions explicit rather than relying on
        // defaults: analysis is on and it is Black's turn, so the old
        // restore's sendPostExecutionCommands would provably emit a
        // kata-analyze bundle here.
        f.session.gobanState.analysisStatus = .run
        f.session.player.nextColorForPlayCommand = .black
        await f.generator.generate(model: f.model, gameRecord: f.record)

        #expect(f.model.stage == .complete)
        // Restore still stops, re-anchors the side to move, and re-syncs the
        // board — but must NOT re-arm analysis: the Deep Report sheet pauses
        // live analysis, and it stays paused until the user resumes manually.
        let tail = f.engine.sent.dropFirst(Self.expectedProbePrefix.count)
        #expect(tail.contains("stop"))
        #expect(tail.contains("showboard"))
        #expect(tail.contains("play b pass"))
        #expect(tail.allSatisfy { !$0.hasPrefix("kata-analyze") && !$0.hasPrefix("kata-search") })
    }

    @Test func branchPositionSeedsBranchFlagAndMoveNumber() async {
        let f = Fixture()
        // Activate a branch: the record stays frozen at the divergence point
        // while the viewed line is branchSgf/branchIndex.
        f.record.currentIndex = 3
        f.session.gobanState.branchSgf = "(;GM[1]FF[4]SZ[2])"
        f.session.gobanState.branchIndex = 7
        await f.generator.generate(model: f.model, gameRecord: f.record)

        #expect(f.model.stage == .complete)
        // The header promises the BRANCH move number, not the frozen
        // divergence-point currentIndex, and the branch flag disables
        // Copy-to-Comment (which is keyed by the committed currentIndex).
        #expect(f.model.moveNumber == 7)
        #expect(f.model.isBranchPosition == true)
        // The probes never touch branch state.
        #expect(f.session.gobanState.branchSgf == "(;GM[1]FF[4]SZ[2])")
        #expect(f.session.gobanState.branchIndex == 7)
        #expect(f.record.currentIndex == 3)
    }

    @Test func cancellationBeforeAnyPlayRestoresWithoutUndo() async {
        let f = Fixture(sleeperOverride: { _ in throw CancellationError() })
        await f.generator.generate(model: f.model, gameRecord: f.record)

        #expect(f.model.stage == .cancelled)
        #expect(f.session.gobanState.reportGenerationActive == false)
        #expect(f.session.lineObserver == nil)
        // No candidate play happened, so the only undo is the side-to-move
        // re-anchor's (play pass + undo).
        #expect(f.engine.sent.filter { $0 == "undo" }.count == 1)
        #expect(f.engine.sent.contains("play b pass"))
        #expect(!f.engine.sent.contains("play b A1"))
        #expect(f.engine.sent.contains("stop"))           // restore stop
        #expect(f.engine.sent.contains("showboard"))      // restore showboard ran
    }

    @Test func cancellationMidTenukiUndoesTheOutstandingPlay() async {
        // Calls 1-6 (snapshot probe + grace, pass probe + grace, parity probe
        // + grace) delegate to the script; call #7 — the first tenuki probe
        // sleep, after `play b A1` was sent — throws. The candidate play is
        // on the engine board and must be undone by restore.
        let f = Fixture()
        let script = f.script
        let generator = DeepReportGenerator(
            messageList: f.session.messageList,
            budgets: ReportBudgets(snapshot: 0, pass: 0, tenuki: 0, candidateCount: 2),
            sleeper: { interval in
                if script.step >= 6 { throw CancellationError() }   // #7 = first tenuki probe
                try await script.sleeper(interval)
            }
        )
        await generator.generate(model: f.model, gameRecord: f.record)

        #expect(f.model.stage == .cancelled)
        let sent = f.engine.sent
        #expect(sent.filter { $0 == "undo" }.count == 2)   // candidate play + pass re-anchor
        #expect(sent.contains("play b pass"))
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

        guard case .failed(let message) = f.model.stage else {
            Issue.record("expected .failed, got \(f.model.stage)")
            return
        }
        #expect(message.contains("error while probing"))
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

    // MARK: - ADR 0003: a failed probe drops its own section, not the report

    /// THE regression a tester reported: the broadcast's "Playing vs. Passing"
    /// slide silently vanished because ONE engine error line — raised during
    /// the newest, least-proven probe (the Alternative's visit-parity probe) —
    /// aborted every later stage AND poisoned every later `checkEngineError`.
    /// The pass stage now runs first and the parity failure drops only its own
    /// section, so the pass comparison survives and its slide is still built.
    ///
    /// Deliberately asserts nothing about the stages AFTER the error: an error
    /// reply does not pop the collector's command FIFO, so replies that follow
    /// one inside the same probe session are routed unreliably (pre-existing
    /// behaviour, newly reachable now that the session keeps probing).
    @Test("An engine error in the parity probe still leaves the pass section and its slide")
    func parityProbeErrorKeepsThePassSectionAndItsSlide() async {
        let f = Fixture(sleeperOverride: { _ in })
        let script = DeepReportAlternativeTests.StepScript(session: f.session, steps: [
            ["= ", "=", Self.snapshotLine],   // snapshot probe
            [],                               // snapshot's stop grace
            ["= ", "=", Self.passLine],       // PASS probe — lands before the parity probe
            [],                               // pass stop grace
            ["= ", "? engine error"],         // parity probe: stop ack, then the error
        ])
        let generator = DeepReportGenerator(
            messageList: f.session.messageList,
            budgets: ReportBudgets(snapshot: 0, pass: 0, tenuki: 0, candidateCount: 2),
            sleeper: { try await script.sleeper($0) }
        )

        await generator.generate(model: f.model, gameRecord: f.record)

        // The report survives the hiccup...
        #expect(f.model.stage == .complete)
        // ...WITH its pass comparison (White-persp 0.72 → Black 0.28).
        #expect(f.model.passComparison != nil)
        #expect(f.model.passComparison?.punishmentVertex == "B2")
        #expect(abs((f.model.passComparison?.winrate ?? 0) - 0.28) < 1e-4)
        // ...and the broadcast still builds the Playing vs. Passing slide.
        #expect(BroadcastScript.slides(from: f.model).map(\.kind) == [.best, .alternative, .pass])
        // Only the parity SECTION is absent: the alternative keeps the
        // snapshot's own 50-visit numbers instead of a probed 95.
        #expect(f.model.candidates.map(\.vertex) == ["A1", "B2"])
        #expect(f.model.candidates[1].visits == 50)
        #expect(f.session.gobanState.reportGenerationActive == false)
        #expect(f.engine.sent.contains("showboard"))
    }

    /// Per-stage catches must never swallow a CancellationError: pause, skip
    /// and the probe-session teardown are all built on it. A cancel during the
    /// (isolated) pass stage aborts the WHOLE report — no later stage runs.
    @Test("Cancellation during an isolated stage still aborts the whole report")
    func cancellationDuringAnIsolatedStageAbortsEverything() async {
        let f = Fixture()
        let script = f.script
        let generator = DeepReportGenerator(
            messageList: f.session.messageList,
            budgets: ReportBudgets(snapshot: 0, pass: 0, tenuki: 0, candidateCount: 2),
            sleeper: { interval in
                // Calls 1-2 are the snapshot probe + its grace; call #3 is the
                // pass probe's sleep, the first ISOLATED stage.
                if script.step >= 2 { throw CancellationError() }
                try await script.sleeper(interval)
            }
        )

        await generator.generate(model: f.model, gameRecord: f.record)

        #expect(f.model.stage == .cancelled)
        #expect(f.model.passComparison == nil)
        // Neither later stage ran: the cancel propagated out of runProbes
        // instead of being absorbed as "this section is simply absent".
        #expect(!f.engine.sent.contains { $0.contains("allow b B2") })
        #expect(!f.engine.sent.contains("play b A1"))
        #expect(f.session.gobanState.reportGenerationActive == false)
        #expect(f.engine.sent.contains("showboard"))
    }

    /// The re-entrancy bail must SETTLE the stage, not leave it .idle: a
    /// broadcast cycle polls the model waiting for a landed/settled stage, and
    /// an .idle bail would spin that loop forever.
    @Test func reentrancyBailSettlesToFailedStage() async {
        let f = Fixture()
        f.session.gobanState.reportGenerationActive = true   // another report is active

        await f.generator.generate(model: f.model, gameRecord: f.record)

        guard case .failed(let message) = f.model.stage else {
            Issue.record("expected .failed, got \(f.model.stage)")
            return
        }
        #expect(message == "Another report is active.")
    }
}
