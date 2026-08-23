//
//  DeepReportPatienceTests.swift
//  KataGo AnytimeTests
//
//  Evidence-terminated probes and the per-cycle patience pool (docs/adr/0006).
//
//  The script here is REACTIVE rather than step-indexed: it acks whatever the
//  generator has sent since the last sleep, in send order, and answers the
//  current analyze once that stage has been silent for as many polls as the
//  test asked. That keeps a test's meaning ("the pass probe reports on poll 3")
//  independent of how many sleeps the stages before it happened to consume.
//

import Testing
import Foundation
@testable import KataGo_Anytime
@testable import KataGoUICore

@MainActor
struct DeepReportPatienceTests {

    /// Which probe an analyze command belongs to. Side to move is Black, so
    /// the pass probe is the only one that analyzes as White.
    enum Probe: Hashable {
        case snapshot, pass, forced, tenuki

        init?(analyze command: String) {
            guard command.hasPrefix("kata-analyze") else { return nil }
            if command.hasPrefix("kata-analyze interval") { self = .snapshot }
            else if command.contains(" allow ") { self = .forced }
            else if command.hasPrefix("kata-analyze w") { self = .pass }
            else { self = .tenuki }
        }
    }

    private static let twoMoveLine = "info move A1 visits 100 winrate 0.60 scoreLead 5.0 utilityLcb 0.5 order 0 pv A1 B2 movesOwnership 0.9 0.9 0.9 0.9 "
        + "info move B2 visits 50 winrate 0.55 scoreLead 3.0 utilityLcb 0.4 order 1 pv B2 movesOwnership 0.1 0.1 0.1 0.1 "
        + "rootInfo visits 150 utility 0.2 winrate 0.58 scoreMean 4.0 scoreStdev 8.0 scoreLead 4.0 scoreSelfplay 4.2 weight 150.0 "
        + "ownership 0.5 0.5 0.5 0.5 ownershipStdev 0.1 0.1 0.1 0.1"
    /// One searched move — enough for a section, but one short of the two the
    /// snapshot needs before an Alternative card can exist.
    private static let oneMoveLine = "info move A1 visits 100 winrate 0.60 scoreLead 5.0 utilityLcb 0.5 order 0 pv A1 B2 movesOwnership 0.9 0.9 0.9 0.9 "
        + "rootInfo visits 100 utility 0.2 winrate 0.58 scoreMean 4.0 scoreStdev 8.0 scoreLead 4.0 scoreSelfplay 4.2 weight 100.0 "
        + "ownership 0.5 0.5 0.5 0.5 ownershipStdev 0.1 0.1 0.1 0.1"
    /// The prior-only entry KataGo really does print: `visits 0`, the ROOT's
    /// scoreLead verbatim, a one-move PV. `filterZeroVisitMoves` cannot
    /// suppress it (it takes its buffer by value), and the winrate is not
    /// exactly 0.5, so the Swift parser keeps it too. Nothing was searched.
    private static let zeroVisitLine = "info move A1 visits 0 winrate 0.61 scoreLead 4.0 utilityLcb 0.5 order 0 pv A1 "
        + "rootInfo visits 1 utility 0.2 winrate 0.58 scoreMean 4.0 scoreStdev 8.0 scoreLead 4.0 scoreSelfplay 4.2 weight 1.0 "
        + "ownership 0.5 0.5 0.5 0.5 ownershipStdev 0.1 0.1 0.1 0.1"
    private static let passLine = "info move B2 visits 40 winrate 0.75 scoreLead 8.0 utilityLcb 0.6 order 0 pv B2 A1 "
        + "rootInfo visits 60 utility 0.4 winrate 0.72 scoreMean 7.0 scoreStdev 8.0 scoreLead 7.0 scoreSelfplay 7.1 weight 60.0 "
        + "ownership 0.8 0.8 0.8 0.8 ownershipStdev 0.1 0.1 0.1 0.1"

    @MainActor
    final class Script {
        let session: GameSession
        let engine: ReportProbeEngine
        /// Polls a probe stays silent past its floor before it answers.
        /// Absent = answers immediately; `.max` = never answers.
        var silentPolls: [Probe: Int] = [:]
        /// The reply a probe eventually gives, when not the default.
        var replies: [Probe: String] = [:]
        /// Sleeps observed per probe past that probe's floor — the poll count.
        private(set) var pollsByProbe: [Probe: Int] = [:]
        /// Runs on every sleep, so a test can cancel mid-poll.
        var onSleep: (() -> Void)?

        private var ackedCount = 0
        private var current: Probe?
        private var answered: Set<Probe> = []
        private var sleepsForCurrent = 0
        /// Set when the generator sends `stop`, so the post-stop grace sleep
        /// is not miscounted as another poll of the stage that just ended.
        private var currentClosed = true

        init(session: GameSession, engine: ReportProbeEngine) {
            self.session = session
            self.engine = engine
        }

        func polls(_ probe: Probe) -> Int { pollsByProbe[probe] ?? 0 }

        private func feed(_ lines: [String]) { lines.forEach { session.lineObserver?($0) } }

        private func defaultReply(for probe: Probe) -> String {
            switch probe {
            case .snapshot: DeepReportPatienceTests.twoMoveLine
            case .pass: DeepReportPatienceTests.passLine
            case .forced, .tenuki: DeepReportPatienceTests.twoMoveLine
            }
        }

        func sleeper(_ interval: TimeInterval) async throws {
            onSleep?()
            // Ack everything sent since the last sleep, in send order, so the
            // collector's FIFO stays aligned exactly as the real wire does.
            let sent = engine.sent
            while ackedCount < sent.count {
                let command = sent[ackedCount]
                ackedCount += 1
                if let probe = Probe(analyze: command) {
                    // A bare "=" analyze response header, printed before the
                    // info stream. Every analyze opens a FRESH stage window —
                    // the two tenuki probes are separate windows of one kind.
                    feed(["="])
                    current = probe
                    sleepsForCurrent = 0
                    currentClosed = false
                    answered.remove(probe)
                } else {
                    feed(["= "])
                    if command == "stop" { currentClosed = true }
                }
            }

            guard let probe = current else { return }
            // The floor sleep is not a poll; every sleep after it is, up to
            // and including the one whose reply ends the wait. The post-stop
            // grace sleep is not (currentClosed).
            if sleepsForCurrent > 0, !currentClosed {
                pollsByProbe[probe, default: 0] += 1
            }
            if !answered.contains(probe), sleepsForCurrent >= (silentPolls[probe] ?? 0) {
                answered.insert(probe)
                feed([replies[probe] ?? defaultReply(for: probe)])
            }
            sleepsForCurrent += 1
        }
    }

    @MainActor
    struct Fixture {
        let session = GameSession.accepting()
        let engine = ReportProbeEngine()
        let record: GameRecord
        let model = DeepReportModel()
        let script: Script
        let generator: DeepReportGenerator

        init(patiencePool: TimeInterval) {
            record = GameRecord.createGameRecord(name: "Patience")
            session.useEngine(engine)
            session.board.width = 2
            session.board.height = 2
            session.player.nextColorFromShowBoard = .black
            let script = Script(session: session, engine: engine)
            self.script = script
            generator = DeepReportGenerator(
                messageList: session.messageList,
                budgets: ReportBudgets(snapshot: 0, pass: 0, tenuki: 0,
                                       candidateCount: 2, patiencePool: patiencePool),
                sleeper: { try await script.sleeper($0) })
        }
    }

    /// Polls one stage may buy: min(per-stage cap, pool) / poll interval.
    private static func polls(for allowance: TimeInterval) -> Int {
        Int((allowance / ReportConstants.probePollInterval).rounded())
    }

    // MARK: - The fix

    /// THE regression. A cold 19x19 pass probe reports nothing inside its fixed
    /// 1 s window, so `passComparison` stayed nil and the "Playing vs. Passing"
    /// card silently ceased to exist — logged only, by ADR 0003's design.
    @Test("A pass probe silent at its floor still lands its card during patience")
    func silentPassProbeStillLandsItsCard() async {
        let f = Fixture(patiencePool: 6.0)
        f.script.silentPolls[.pass] = 4

        await f.generator.generate(model: f.model, gameRecord: f.record)

        #expect(f.model.stage == .complete)
        #expect(f.model.passComparison != nil)
        #expect(f.script.polls(.pass) == 4)
    }

    /// The Alternative card needs the snapshot to have ranked TWO moves; a
    /// starved snapshot that expands one costs the card without failing.
    @Test("The snapshot waits past thin evidence for a second candidate")
    func snapshotWaitsForASecondCandidate() async {
        let f = Fixture(patiencePool: 6.0)
        f.script.silentPolls[.snapshot] = 3

        await f.generator.generate(model: f.model, gameRecord: f.record)

        #expect(f.model.candidates.count == 2)
        #expect(f.script.polls(.snapshot) == 3)
    }

    /// A prior-only entry is not evidence: terminating on it would publish the
    /// position's own scoreLead as though it evaluated a different move.
    @Test("A zero-visit line does not end the wait")
    func zeroVisitLineIsNotEvidence() async {
        let f = Fixture(patiencePool: 6.0)
        f.script.replies[.pass] = Self.zeroVisitLine

        await f.generator.generate(model: f.model, gameRecord: f.record)

        // The line landed immediately, yet the stage kept waiting to its full
        // allowance and then dropped its section rather than fabricating one.
        #expect(f.script.polls(.pass) == Self.polls(for: ReportConstants.probePatienceCap))
        #expect(f.model.passComparison == nil)
        #expect(f.model.stage == .complete)
    }

    // MARK: - The bounds

    @Test("One stage cannot spend more than the per-stage cap")
    func perStageCapBoundsOneStage() async {
        let f = Fixture(patiencePool: 6.0)
        f.script.silentPolls[.pass] = .max          // never answers

        await f.generator.generate(model: f.model, gameRecord: f.record)

        #expect(f.script.polls(.pass) == Self.polls(for: ReportConstants.probePatienceCap))
        #expect(f.model.passComparison == nil)      // ADR 0003: section absent, report lands
        #expect(f.model.stage == .complete)
    }

    /// The pool, not the cap, is the cycle's worst case: a pool smaller than
    /// the cap bounds the very first starved stage.
    @Test("The pool bounds the wait when it is smaller than the cap")
    func poolBoundsTheWait() async {
        let f = Fixture(patiencePool: 0.5)
        f.script.silentPolls[.pass] = .max

        await f.generator.generate(model: f.model, gameRecord: f.record)

        #expect(f.script.polls(.pass) == Self.polls(for: 0.5))
    }

    /// Spends are cumulative across stages, so the CYCLE's worst case is
    /// "floors + pool" rather than the cap multiplied by the stage count.
    @Test("A drained pool leaves nothing for later stages")
    func poolIsSharedAcrossStages() async {
        let f = Fixture(patiencePool: ReportConstants.probePatienceCap)
        f.script.silentPolls[.pass] = .max
        f.script.silentPolls[.tenuki] = .max

        await f.generator.generate(model: f.model, gameRecord: f.record)

        #expect(f.script.polls(.pass) == Self.polls(for: ReportConstants.probePatienceCap))
        #expect(f.script.polls(.tenuki) == 0)       // pool already spent
    }

    /// Thin evidence gets a shorter, separately-measured allowance: a position
    /// with one sensible move must not burn the whole cap waiting for a second
    /// that will never arrive.
    @Test("Thin evidence stops waiting on its own shorter allowance")
    func thinEvidenceUsesItsShorterAllowance() async {
        let f = Fixture(patiencePool: 6.0)
        f.script.replies[.snapshot] = Self.oneMoveLine

        await f.generator.generate(model: f.model, gameRecord: f.record)

        #expect(f.script.polls(.snapshot)
                == Self.polls(for: ReportConstants.thinEvidencePatience))
        #expect(f.script.polls(.snapshot)
                < Self.polls(for: ReportConstants.probePatienceCap))
        #expect(f.model.candidates.count == 1)      // no Alternative card, honestly
    }

    // MARK: - Exactness preserved

    @Test("Cancellation during the patience poll aborts promptly")
    func cancellationDuringPollAborts() async {
        let f = Fixture(patiencePool: 6.0)
        f.script.silentPolls[.pass] = .max

        let task = Task { @MainActor in
            await f.generator.generate(model: f.model, gameRecord: f.record)
        }
        // Cancel as soon as the pass probe has started polling — well before
        // its allowance would have expired.
        f.script.onSleep = {
            if f.script.polls(.pass) == 3 { task.cancel() }
        }
        await task.value

        #expect(f.model.stage == .cancelled)
        #expect(f.script.polls(.pass) < Self.polls(for: ReportConstants.probePatienceCap))
    }

    /// The iOS/macOS sheet's "~5 s quick report" promise: with no pool the poll
    /// loop consumes no sleeps at all, so the conversation is byte-for-byte
    /// what it was before patience existed.
    @Test("The standard profile spends no patience whatsoever")
    func standardProfileIsInert() async {
        #expect(ReportBudgets.standard.patiencePool == 0)
        #expect(ReportBudgets.broadcast.patiencePool > 0)

        let f = Fixture(patiencePool: 0)
        f.script.silentPolls[.pass] = .max

        await f.generator.generate(model: f.model, gameRecord: f.record)

        #expect(f.script.polls(.pass) == 0)
        #expect(f.model.passComparison == nil)
        #expect(f.model.stage == .complete)
    }

    /// Refine escalates depth, not patience: multiplying an allowance for a
    /// starved engine by 8 would let one press wait the better part of a minute.
    @Test("Refine scales the floors but not the pool")
    func refineDoesNotScaleThePool() {
        let scaled = ReportBudgets.broadcast.scaled(by: 8)
        #expect(scaled.snapshot == ReportBudgets.broadcast.snapshot * 8)
        #expect(scaled.patiencePool == ReportBudgets.broadcast.patiencePool)
    }
}
