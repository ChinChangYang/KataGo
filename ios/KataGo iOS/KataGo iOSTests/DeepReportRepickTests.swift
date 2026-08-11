//
//  DeepReportRepickTests.swift
//  KataGo AnytimeTests
//
//  repickAlternative: targeted re-probe of a newly picked Alternative on a
//  completed report. Visit parity: every pick runs its own forced-allow
//  probe — the snapshot cache only backstops a silent engine. Same
//  scripted-sleeper pattern as DeepReportGeneratorTests; the StepScript's
//  counter continues across generate → repick, so each test describes the
//  whole conversation as one step list.
//

import Testing
import Foundation
@testable import KataGo_Anytime
@testable import KataGoUICore

@MainActor
struct DeepReportRepickTests {
    /// Snapshot ranking A1 (100) > B2 (50) > B1 (10): B1 is cached but not in
    /// the top-2 report — picking it exercises the parity probe with a cached
    /// entry standing by as the silence fallback.
    static let snapshotLine = "info move A1 visits 100 winrate 0.60 scoreLead 5.0 utilityLcb 0.5 order 0 pv A1 B2 movesOwnership 0.9 0.9 0.9 0.9 "
        + "info move B2 visits 50 winrate 0.55 scoreLead 3.0 utilityLcb 0.4 order 1 pv B2 movesOwnership 0.1 0.1 0.1 0.1 "
        + "info move B1 visits 10 winrate 0.52 scoreLead 2.5 utilityLcb 0.2 order 2 pv B1 A2 movesOwnership 0.3 0.3 0.3 0.3 "
        + "rootInfo visits 160 utility 0.2 winrate 0.58 scoreMean 4.0 scoreStdev 8.0 scoreLead 4.0 scoreSelfplay 4.2 weight 160.0 "
        + "ownership 0.5 0.5 0.5 0.5 ownershipStdev 0.1 0.1 0.1 0.1"
    static let passLine = DeepReportGeneratorTests.passLine
    static let tenukiLine = DeepReportGeneratorTests.tenukiLine
    static let forcedLine = DeepReportAlternativeTests.forcedLine
    static let forcedLineB2 = DeepReportGeneratorTests.forcedLineB2
    /// Forced-probe reply for a snapshot-ranked pick (B1): all root visits
    /// funneled into B1 (rootInfo visits == move visits).
    static let forcedLineB1 = "info move B1 visits 88 winrate 0.53 scoreLead 2.6 utilityLcb 0.3 order 0 pv B1 A2 movesOwnership 0.3 0.3 0.3 0.3 "
        + "rootInfo visits 88 utility 0.1 winrate 0.53 scoreMean 2.6 scoreStdev 8.0 scoreLead 2.6 scoreSelfplay 2.6 weight 88.0 "
        + "ownership 0.5 0.5 0.5 0.5 ownershipStdev 0.1 0.1 0.1 0.1"

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

    @MainActor
    struct Fixture {
        let session = GameSession()
        let engine = ReportProbeEngine()
        let record: GameRecord
        let model = DeepReportModel()
        let generator: DeepReportGenerator

        init(sgf: String = "(;GM[1]FF[4]SZ[2])", steps: [[String]]) {
            record = GameRecord.createGameRecord(sgf: sgf, currentIndex: 0, name: "Report")
            session.useEngine(engine)
            session.board.width = 2
            session.board.height = 2
            session.player.nextColorFromShowBoard = .black
            let script = DeepReportAlternativeTests.StepScript(session: session, steps: steps)
            generator = DeepReportGenerator(
                messageList: session.messageList,
                budgets: ReportBudgets(snapshot: 0, pass: 0, tenuki: 0, candidateCount: 2),
                sleeper: { try await script.sleeper($0) }
            )
        }
    }

    @Test func repickRunsForcedProbeEvenForSnapshotRankedPick() async {
        // Visit parity: picking B1 (snapshot-ranked, 10 visits) must still run
        // a forced-allow probe so the alternative's values carry real search.
        // Repick conversation: maxVisits-reset ack + header + forced line,
        // grace, tenuki feed, grace. Every repick opens with the unbounded
        // maxVisits reset — a prior gen-move may have left its sticky
        // 400-visit cap behind.
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
        // The tenuki follow-up was re-probed for the new alternative.
        #expect(alt.tenuki?.vertex == "B2")
        let repickSent = Array(f.engine.sent.dropFirst(sentBefore))
        #expect(repickSent.contains("kata-set-param maxVisits 1000000000"))
        #expect(repickSent.contains(
            "kata-analyze b interval 10 allow b B1 1 maxmoves 8 ownership true movesOwnership true rootInfo true"))
        #expect(repickSent.contains("play b B1"))
        // Best move untouched; probe session restored.
        #expect(f.model.candidates[0].vertex == "A1")
        #expect(f.session.gobanState.reportGenerationActive == false)
        #expect(repickSent.contains("showboard"))
        #expect(f.model.transientNotice == nil)
    }

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

    @Test func uncachedRepickRunsForcedProbe() async {
        // Repick conversation: forced probe feed (set-param ack, header, line),
        // grace, tenuki feed (stop ack, play ack, header, line), grace.
        let f = Fixture(steps: Self.generateSteps + [
            ["= ", "=", Self.forcedLine],
            [],
            ["= ", "= ", "=", Self.tenukiLine],
            [],
        ])
        await f.generator.generate(model: f.model, gameRecord: f.record)
        let sentBefore = f.engine.sent.count

        await f.generator.repickAlternative(model: f.model, gameRecord: f.record, vertex: "A2")

        #expect(f.model.stage == .complete)
        #expect(f.model.candidates.map(\.vertex) == ["A1", "A2"])
        #expect(f.model.alternativeSource == .userPick)
        let repickSent = Array(f.engine.sent.dropFirst(sentBefore))
        #expect(repickSent.contains("kata-set-param maxVisits 1000000000"))
        #expect(repickSent.contains(
            "kata-analyze b interval 10 allow b A2 1 maxmoves 8 ownership true movesOwnership true rootInfo true"))
        #expect(repickSent.contains("play b A2"))
        #expect(f.model.candidates[1].tenuki?.vertex == "B2")
        #expect(f.session.gobanState.reportGenerationActive == false)
    }

    @Test func failedRepickKeepsPriorAlternativeAndNotices() async {
        // The forced probe yields no info line (illegal vertex): the prior
        // alternative must survive untouched and the user gets a notice.
        let f = Fixture(steps: Self.generateSteps + [
            ["= ", "="],
            [],
        ])
        await f.generator.generate(model: f.model, gameRecord: f.record)
        let priorWinrate = f.model.candidates[1].winrate

        await f.generator.repickAlternative(model: f.model, gameRecord: f.record, vertex: "A2")

        #expect(f.model.stage == .complete)
        #expect(f.model.candidates.map(\.vertex) == ["A1", "B2"])
        #expect(abs(f.model.candidates[1].winrate - priorWinrate) < 1e-6)
        #expect(f.model.alternativeSource == .engine)
        #expect(f.model.transientNotice?.contains("A2") == true)
        #expect(f.session.gobanState.reportGenerationActive == false)
        // The failed probe session still restored (stop + showboard ran).
        #expect(f.engine.sent.filter { $0 == "showboard" }.count >= 2)
    }

    @Test func repickOfBestMoveIsANoOp() async {
        let f = Fixture(steps: Self.generateSteps)
        await f.generator.generate(model: f.model, gameRecord: f.record)
        let sentBefore = f.engine.sent.count

        await f.generator.repickAlternative(model: f.model, gameRecord: f.record, vertex: "A1")

        #expect(f.engine.sent.count == sentBefore)
        #expect(f.model.candidates.map(\.vertex) == ["A1", "B2"])
        #expect(f.model.stage == .complete)
    }

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
}
