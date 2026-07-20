//
//  DeepReportRefineTests.swift
//  KataGo AnytimeTests
//
//  refine(): re-runs the probe pipeline at doubled budgets, replacing report
//  sections in place — the pick is preserved, the multiplier caps at 8×, and
//  a cancelled/failed refine leaves the completed report standing.
//

import Testing
import Foundation
@testable import KataGo_Anytime
@testable import KataGoUICore

@MainActor
struct DeepReportRefineTests {
    static let snapshotLine = DeepReportGeneratorTests.snapshotLine
    /// A later, deeper search that flips the ranking: B2 overtakes A1.
    static let swappedSnapshotLine = "info move B2 visits 120 winrate 0.55 scoreLead 3.0 utilityLcb 0.5 order 0 pv B2 movesOwnership 0.1 0.1 0.1 0.1 "
        + "info move A1 visits 90 winrate 0.60 scoreLead 5.0 utilityLcb 0.4 order 1 pv A1 B2 movesOwnership 0.9 0.9 0.9 0.9 "
        + "rootInfo visits 210 utility 0.2 winrate 0.57 scoreMean 3.5 scoreStdev 8.0 scoreLead 3.5 scoreSelfplay 3.6 weight 210.0 "
        + "ownership 0.5 0.5 0.5 0.5 ownershipStdev 0.1 0.1 0.1 0.1"
    static let passLine = DeepReportGeneratorTests.passLine
    static let tenukiLine = DeepReportGeneratorTests.tenukiLine
    static let forcedLine = DeepReportAlternativeTests.forcedLine

    /// One full no-forced-probe probe conversation (generate or refine):
    /// snapshot, grace, pass, grace, tenuki 0, grace, tenuki 1, grace.
    static func conversation(snapshot: String = snapshotLine) -> [[String]] {
        [
            ["= ", "=", snapshot],
            [],
            ["= ", "=", passLine],
            [],
            ["= ", "= ", "=", tenukiLine],
            [],
            ["= ", "= ", "= ", "=", tenukiLine],
            [],
        ]
    }

    /// Records every sleep interval while feeding the scripted conversation.
    @MainActor
    final class RecordingScript {
        let session: GameSession
        let steps: [[String]]
        var step = 0
        var intervals: [TimeInterval] = []
        init(session: GameSession, steps: [[String]]) {
            self.session = session
            self.steps = steps
        }
        func sleeper(_ interval: TimeInterval) async throws {
            intervals.append(interval)
            defer { step += 1 }
            guard step < steps.count else { return }
            steps[step].forEach { session.lineObserver?($0) }
        }
        /// The probe sleeps only (stop-grace sleeps filtered out).
        var probeIntervals: [TimeInterval] {
            intervals.filter { $0 != ReportConstants.stopGrace }
        }
    }

    @MainActor
    struct Fixture {
        let session = GameSession()
        let engine = ReportProbeEngine()
        let record: GameRecord
        let model = DeepReportModel()
        let script: RecordingScript
        let generator: DeepReportGenerator

        init(sgf: String = "(;GM[1]FF[4]SZ[2])",
             budgets: ReportBudgets = ReportBudgets(snapshot: 0, pass: 0, tenuki: 0, candidateCount: 2),
             steps: [[String]],
             sleeperOverride: ((RecordingScript, TimeInterval) async throws -> Void)? = nil) {
            record = GameRecord.createGameRecord(sgf: sgf, currentIndex: 0, name: "Report")
            session.useEngine(engine)
            session.board.width = 2
            session.board.height = 2
            session.player.nextColorFromShowBoard = .black
            let script = RecordingScript(session: session, steps: steps)
            self.script = script
            generator = DeepReportGenerator(
                messageList: session.messageList,
                budgets: budgets,
                sleeper: { interval in
                    if let sleeperOverride {
                        try await sleeperOverride(script, interval)
                    } else {
                        try await script.sleeper(interval)
                    }
                }
            )
        }
    }

    @Test func refineDoublesBudgetsAndCapsAtEight() async {
        // Base 2/1/1 budgets: generate sleeps 2/1/1/1, then refines sleep
        // 4/2/2/2 → 8/4/4/4 → 16/8/8/8 → 16/8/8/8 (capped).
        let f = Fixture(budgets: ReportBudgets(snapshot: 2, pass: 1, tenuki: 1, candidateCount: 2),
                        steps: Array(repeating: Self.conversation(), count: 5).flatMap { $0 })
        await f.generator.generate(model: f.model, gameRecord: f.record)
        #expect(f.model.budgetMultiplier == 1)

        await f.generator.refine(model: f.model, gameRecord: f.record)
        #expect(f.model.budgetMultiplier == 2)
        await f.generator.refine(model: f.model, gameRecord: f.record)
        #expect(f.model.budgetMultiplier == 4)
        await f.generator.refine(model: f.model, gameRecord: f.record)
        #expect(f.model.budgetMultiplier == 8)
        #expect(f.model.isAtBudgetCap)
        await f.generator.refine(model: f.model, gameRecord: f.record)
        #expect(f.model.budgetMultiplier == 8)

        #expect(f.script.probeIntervals == [
            2, 1, 1, 1,
            4, 2, 2, 2,
            8, 4, 4, 4,
            16, 8, 8, 8,
            16, 8, 8, 8,
        ])
        #expect(f.model.stage == .complete)
    }

    @Test func refineReplacesSectionsInPlace() async {
        let f = Fixture(steps: Self.conversation() + Self.conversation(snapshot: Self.swappedSnapshotLine))
        await f.generator.generate(model: f.model, gameRecord: f.record)
        #expect(f.model.candidates.map(\.vertex) == ["A1", "B2"])
        #expect(f.model.position?.visits == 150)

        await f.generator.refine(model: f.model, gameRecord: f.record)

        // The deeper snapshot's ranking replaced the report: B2 is now best.
        #expect(f.model.stage == .complete)
        #expect(f.model.position?.visits == 210)
        #expect(f.model.candidates.map(\.vertex) == ["B2", "A1"])
        #expect(f.model.alternativeSource == .engine)
        #expect(f.model.candidates.allSatisfy { $0.tenuki != nil })
        #expect(f.session.gobanState.reportGenerationActive == false)
    }

    @Test func refinePreservesGameMovePick() async {
        // Game move B2 seeds the alternative; the refine's snapshot still
        // ranks A1 best, so the preserved B2 alternative is rebuilt from the
        // new snapshot (still .gameMove).
        let f = Fixture(sgf: "(;GM[1]FF[4]SZ[2];B[ba])",
                        steps: Self.conversation() + Self.conversation())
        await f.generator.generate(model: f.model, gameRecord: f.record)
        #expect(f.model.alternativeSource == .gameMove)

        await f.generator.refine(model: f.model, gameRecord: f.record)

        #expect(f.model.stage == .complete)
        #expect(f.model.candidates.map(\.vertex) == ["A1", "B2"])
        #expect(f.model.alternativeSource == .gameMove)
        #expect(f.model.budgetMultiplier == 2)
    }

    @Test func refineReprobesPickOutsideNewTopCandidates() async {
        // The user's picked A2 never appears in snapshots: every refine must
        // re-run the forced-allow probe for it at the scaled budget.
        let refineConversation: [[String]] = [
            ["= ", "=", Self.snapshotLine],
            [],
            ["= ", "=", Self.forcedLine],       // forced re-probe of the pick
            [],
            ["= ", "=", Self.passLine],
            [],
            ["= ", "= ", "=", Self.tenukiLine],
            [],
            ["= ", "= ", "= ", "=", Self.tenukiLine],
            [],
        ]
        let f = Fixture(steps: Self.conversation() + [
            ["= ", "=", Self.forcedLine],       // repick A2: forced probe
            [],
            ["= ", "= ", "=", Self.tenukiLine], // repick A2: tenuki
            [],
        ] + refineConversation)
        await f.generator.generate(model: f.model, gameRecord: f.record)
        await f.generator.repickAlternative(model: f.model, gameRecord: f.record, vertex: "A2")
        #expect(f.model.candidates.map(\.vertex) == ["A1", "A2"])
        let sentBefore = f.engine.sent.count

        await f.generator.refine(model: f.model, gameRecord: f.record)

        #expect(f.model.stage == .complete)
        #expect(f.model.candidates.map(\.vertex) == ["A1", "A2"])
        #expect(f.model.alternativeSource == .userPick)
        let refineSent = Array(f.engine.sent.dropFirst(sentBefore))
        #expect(refineSent.contains(
            "kata-analyze b interval 10 allow b A2 1 maxmoves 8 ownership true movesOwnership true rootInfo true"))
    }

    @Test func refineResetsPickWhenItBecomesBest() async {
        // Game move B2 is the alternative; the deeper refine snapshot makes
        // B2 the BEST move — the alternative resets to the smart default
        // (engine #2 here) with a notice.
        let f = Fixture(sgf: "(;GM[1]FF[4]SZ[2];B[ba])",
                        steps: Self.conversation() + Self.conversation(snapshot: Self.swappedSnapshotLine))
        await f.generator.generate(model: f.model, gameRecord: f.record)
        #expect(f.model.alternativeSource == .gameMove)

        await f.generator.refine(model: f.model, gameRecord: f.record)

        #expect(f.model.stage == .complete)
        #expect(f.model.candidates.map(\.vertex) == ["B2", "A1"])
        #expect(f.model.alternativeSource == .engine)
        #expect(f.model.transientNotice != nil)
    }

    @Test func cancelledRefineKeepsCompletedReport() async {
        var refining = false
        let f = Fixture(steps: Self.conversation(),
                        sleeperOverride: { script, interval in
                            if refining { throw CancellationError() }
                            try await script.sleeper(interval)
                        })
        await f.generator.generate(model: f.model, gameRecord: f.record)
        let priorVertices = f.model.candidates.map(\.vertex)
        let priorVisits = f.model.position?.visits
        refining = true

        await f.generator.refine(model: f.model, gameRecord: f.record)

        #expect(f.model.stage == .complete)
        #expect(f.model.candidates.map(\.vertex) == priorVertices)
        #expect(f.model.position?.visits == priorVisits)
        #expect(f.model.budgetMultiplier == 1)
        #expect(f.model.transientNotice != nil)
        #expect(f.session.gobanState.reportGenerationActive == false)
        // The aborted refine still restored (stop + showboard ran again).
        #expect(f.engine.sent.filter { $0 == "showboard" }.count >= 2)
    }

    @Test func engineErrorMidRefineKeepsCompletedReport() async {
        var refining = false
        let f = Fixture(steps: Self.conversation(),
                        sleeperOverride: { script, interval in
                            if refining {
                                script.session.lineObserver?("? engine crashed")
                            } else {
                                try await script.sleeper(interval)
                            }
                        })
        await f.generator.generate(model: f.model, gameRecord: f.record)
        let priorVertices = f.model.candidates.map(\.vertex)
        refining = true

        await f.generator.refine(model: f.model, gameRecord: f.record)

        #expect(f.model.stage == .complete)
        #expect(f.model.candidates.map(\.vertex) == priorVertices)
        #expect(f.model.budgetMultiplier == 1)
        #expect(f.model.transientNotice != nil)
        #expect(f.session.gobanState.reportGenerationActive == false)
    }

    @Test func silentRefineSnapshotKeepsCompletedReport() async {
        // The refine's snapshot probe yields nothing: the old report stands.
        let f = Fixture(steps: Self.conversation() + [["= ", "="], []])
        await f.generator.generate(model: f.model, gameRecord: f.record)
        let priorVertices = f.model.candidates.map(\.vertex)

        await f.generator.refine(model: f.model, gameRecord: f.record)

        #expect(f.model.stage == .complete)
        #expect(f.model.candidates.map(\.vertex) == priorVertices)
        #expect(f.model.budgetMultiplier == 1)
        #expect(f.model.transientNotice != nil)
    }

    @Test func refineRequiresCompletedReport() async {
        let f = Fixture(steps: [])
        f.model.stage = .failed("x")
        let sentBefore = f.engine.sent.count

        await f.generator.refine(model: f.model, gameRecord: f.record)

        #expect(f.engine.sent.count == sentBefore)
        #expect(f.model.stage == .failed("x"))
    }
}
