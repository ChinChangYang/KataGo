//
//  DeepReportAlternativeTests.swift
//  KataGo AnytimeTests
//
//  Smart-default + repick behavior for the report's pickable Alternative slot.
//  Same deterministic scripted-sleeper pattern as DeepReportGeneratorTests;
//  2x2-board SGF fixtures drive the real SgfOperations bridge:
//  B[ab] → A1, B[ba] → B2, B[aa] → A2.
//

import Testing
import Foundation
@testable import KataGo_Anytime
@testable import KataGoUICore

@MainActor
struct DeepReportAlternativeTests {
    static let snapshotLine = DeepReportGeneratorTests.snapshotLine
    static let passLine = DeepReportGeneratorTests.passLine
    static let tenukiLine = DeepReportGeneratorTests.tenukiLine
    static let forcedLine = "info move A2 visits 20 winrate 0.50 scoreLead 2.0 utilityLcb 0.3 order 0 pv A2 B1 movesOwnership 0.2 0.2 0.2 0.2 "
        + "rootInfo visits 20 utility 0.0 winrate 0.50 scoreMean 2.0 scoreStdev 8.0 scoreLead 2.0 scoreSelfplay 2.0 weight 20.0 "
        + "ownership 0.5 0.5 0.5 0.5 ownershipStdev 0.1 0.1 0.1 0.1"

    /// Feeds `steps[i]` on the i-th sleeper call (missing steps feed nothing),
    /// so tests describe the full probe conversation as data.
    @MainActor
    final class StepScript {
        let session: GameSession
        let steps: [[String]]
        var step = 0
        init(session: GameSession, steps: [[String]]) {
            self.session = session
            self.steps = steps
        }
        func sleeper(_ interval: TimeInterval) async throws {
            defer { step += 1 }
            guard step < steps.count else { return }
            steps[step].forEach { session.lineObserver?($0) }
        }
    }

    @MainActor
    struct Fixture {
        let session = GameSession()
        let engine = ReportProbeEngine()
        let record: GameRecord
        let model = DeepReportModel()
        let generator: DeepReportGenerator

        /// The default steps mirror the happy path with the Alternative's
        /// visit-parity probe: snapshot, grace, parity probe (B2), grace,
        /// pass, grace, tenuki 0, grace, tenuki 1, grace.
        init(sgf: String, currentIndex: Int = 0, steps: [[String]]? = nil) {
            record = GameRecord.createGameRecord(sgf: sgf, currentIndex: currentIndex, name: "Report")
            session.useEngine(engine)
            session.board.width = 2
            session.board.height = 2
            session.player.nextColorFromShowBoard = .black
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
            generator = DeepReportGenerator(
                messageList: session.messageList,
                budgets: ReportBudgets(snapshot: 0, pass: 0, tenuki: 0, candidateCount: 2),
                sleeper: { try await script.sleeper($0) }
            )
        }
    }

    /// Steps for a run whose game move needs the forced-allow probe:
    /// snapshot, grace, forced, grace, pass, grace, tenuki 0, grace, tenuki 1, grace.
    static func forcedProbeSteps(forcedFeed: [String]) -> [[String]] {
        [
            ["= ", "=", snapshotLine],
            [],
            forcedFeed,
            [],
            ["= ", "=", passLine],
            [],
            ["= ", "= ", "=", tenukiLine],
            [],
            ["= ", "= ", "= ", "=", tenukiLine],
            [],
        ]
    }

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

    @Test func gameMoveOutsideTopCandidatesRunsForcedProbe() async {
        // Next recorded move A2 is not among the snapshot candidates: one
        // forced-allow probe supplies its candidate info.
        let f = Fixture(sgf: "(;GM[1]FF[4]SZ[2];B[aa])",
                        steps: Self.forcedProbeSteps(forcedFeed: ["= ", "=", Self.forcedLine]))
        await f.generator.generate(model: f.model, gameRecord: f.record)

        #expect(f.model.stage == .complete)
        #expect(f.model.gameMoveVertex == "A2")
        #expect(f.model.alternativeSource == .gameMove)
        #expect(f.model.candidates.map(\.vertex) == ["A1", "A2"])
        #expect(f.engine.sent.contains(
            "kata-analyze b interval 10 allow b A2 1 maxmoves 8 ownership true movesOwnership true rootInfo true"))
        // The alternative's values come from the forced probe's info entry
        // (White 0.50/2.0 → Black 0.50/-2.0), deltas vs the position (0.42/-4.0).
        let alt = f.model.candidates[1]
        #expect(abs(alt.winrate - 0.50) < 1e-4)
        #expect(abs(alt.scoreLead - (-2.0)) < 1e-4)
        #expect(abs(alt.winrateDelta - 0.08) < 1e-4)
        #expect(!alt.ownershipDelta.isEmpty)
        // Tenuki probes run for the best move and the game-move alternative.
        #expect(f.engine.sent.contains("play b A1"))
        #expect(f.engine.sent.contains("play b A2"))
        #expect(!f.engine.sent.contains("play b B2"))
    }

    @Test func forcedProbeSilenceFallsBackToEngineAlternative() async {
        // The forced probe yields no info line → the report silently keeps
        // the engine's #2 candidate and still completes.
        let f = Fixture(sgf: "(;GM[1]FF[4]SZ[2];B[aa])",
                        steps: Self.forcedProbeSteps(forcedFeed: ["= ", "="]))
        await f.generator.generate(model: f.model, gameRecord: f.record)

        #expect(f.model.stage == .complete)
        #expect(f.model.gameMoveVertex == "A2")
        #expect(f.model.alternativeSource == .engine)
        #expect(f.model.candidates.map(\.vertex) == ["A1", "B2"])
    }

    @Test func gameMoveEqualToBestKeepsEngineAlternative() async {
        // Next recorded move A1 IS the best move: the Alternative slot stays
        // the engine's #2, but the vertex is remembered for the picker. The
        // engine-#2 alternative still gets its visit-parity probe.
        let f = Fixture(sgf: "(;GM[1]FF[4]SZ[2];B[ab])")
        await f.generator.generate(model: f.model, gameRecord: f.record)

        #expect(f.model.stage == .complete)
        #expect(f.model.gameMoveVertex == "A1")
        #expect(f.model.alternativeSource == .engine)
        #expect(f.model.candidates.map(\.vertex) == ["A1", "B2"])
        #expect(f.engine.sent.contains { $0.contains("allow b B2") })
        #expect(f.model.candidates[1].visits == 95)
    }

    @Test func passNextMoveYieldsNoGameMove() async {
        let f = Fixture(sgf: "(;GM[1]FF[4]SZ[2];B[])")
        await f.generator.generate(model: f.model, gameRecord: f.record)

        #expect(f.model.stage == .complete)
        #expect(f.model.gameMoveVertex == nil)
        #expect(f.model.alternativeSource == .engine)
    }

    @Test func wrongColorNextMoveYieldsNoGameMove() async {
        // Side to move is Black but the next recorded move is White's — a
        // desynced record must not seed a wrong-colored alternative.
        let f = Fixture(sgf: "(;GM[1]FF[4]SZ[2];W[ba])")
        await f.generator.generate(model: f.model, gameRecord: f.record)

        #expect(f.model.stage == .complete)
        #expect(f.model.gameMoveVertex == nil)
        #expect(f.model.alternativeSource == .engine)
    }

    @Test func gameTipYieldsNoGameMove() async {
        let f = Fixture(sgf: "(;GM[1]FF[4]SZ[2];B[ba])", currentIndex: 1)
        await f.generator.generate(model: f.model, gameRecord: f.record)

        #expect(f.model.stage == .complete)
        #expect(f.model.gameMoveVertex == nil)
        #expect(f.model.alternativeSource == .engine)
    }

    @Test func branchPositionIgnoresGameMove() async {
        // A branch line with a legitimate next move must NOT seed the game-move
        // default — "the game's move" has no clean meaning on a throwaway branch.
        let f = Fixture(sgf: "(;GM[1]FF[4]SZ[2];B[ba])")
        f.session.gobanState.branchSgf = "(;GM[1]FF[4]SZ[2];B[ba])"
        f.session.gobanState.branchIndex = 0
        await f.generator.generate(model: f.model, gameRecord: f.record)

        #expect(f.model.stage == .complete)
        #expect(f.model.gameMoveVertex == nil)
        #expect(f.model.alternativeSource == .engine)
        #expect(f.model.isBranchPosition == true)
    }

    @Test func snapshotCachesEntriesAndOwnership() async {
        let f = Fixture(sgf: "(;GM[1]FF[4]SZ[2];B[ba])")
        await f.generator.generate(model: f.model, gameRecord: f.record)

        #expect(f.model.snapshotEntries.map(\.vertex) == ["A1", "B2"])
        #expect(f.model.snapshotOwnership == [0.5, 0.5, 0.5, 0.5])
    }
}
