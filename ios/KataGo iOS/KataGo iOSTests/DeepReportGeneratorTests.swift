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
