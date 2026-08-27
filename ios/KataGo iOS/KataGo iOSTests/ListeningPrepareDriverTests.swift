//
//  ListeningPrepareDriverTests.swift
//  KataGo AnytimeTests
//
//  Scripted-engine tests (the DeepReportGeneratorTests pattern): the
//  injectable sleeper acks every command the driver has sent — one "=" per
//  command, FIFO, exactly as GTP replies — and feeds a report line when the
//  last ack was an analyze. Offline, no engine.
//

import Testing
import Foundation
@testable import KataGo_Anytime
@testable import KataGoUICore

@MainActor
struct ListeningPrepareDriverTests {
    // 2x2 board. The wire is White-perspective (reportAnalysisWinratesAs =
    // WHITE), so winrate 0.40 / scoreLead -2.0 land black-positive as
    // 0.60 / +2.0. Root visits 40 clears the default target of 24.
    static let reportLine = "info move B1 visits 30 winrate 0.40 scoreLead -2.0 utilityLcb 0.2 order 0 pv B1 "
        + "rootInfo visits 40 utility 0.1 winrate 0.40 scoreMean -2.0 scoreStdev 1.0 scoreLead -2.0 scoreSelfplay -2.0 weight 40.0"

    @MainActor
    final class Script {
        let session: GameSession
        let engine: ReportProbeEngine
        var silent = false
        private var ackedCount = 0

        init(session: GameSession, engine: ReportProbeEngine) {
            self.session = session
            self.engine = engine
        }

        func sleeper(_ interval: TimeInterval) async throws {
            let sent = engine.sent
            var lastAcked: String?
            while ackedCount < sent.count {
                let command = sent[ackedCount]
                session.lineObserver?(command.hasPrefix("kata-analyze") ? "=" : "= ")
                ackedCount += 1
                lastAcked = command
            }
            if !silent, let lastAcked, lastAcked.hasPrefix("kata-analyze") {
                session.lineObserver?(Self.line)
            }
        }

        static let line = ListeningPrepareDriverTests.reportLine
    }

    @MainActor
    struct Fixture {
        let session = GameSession.accepting()
        let engine = ReportProbeEngine()
        let record: GameRecord
        let model = ListeningPrepareModel()
        let script: Script
        let driver: ListeningPrepareDriver

        init(sgf: String = "(;GM[1]SZ[2];B[aa];W[bb])",
             sleeperOverride: ReportSleeper? = nil) {
            record = GameRecord(sgf: sgf, config: Config(), name: "Prep")
            record.concreteConfig.useLLM = false
            session.useEngine(engine)
            let script = Script(session: session, engine: engine)
            self.script = script
            driver = ListeningPrepareDriver(
                messageList: session.messageList,
                sleeper: sleeperOverride ?? { try await script.sleeper($0) })
        }
    }

    @Test func sweepPersistsBlackPerspectiveAnalysisAtEveryPosition() async {
        let f = Fixture()
        await f.driver.prepare(gameRecord: f.record, model: f.model)

        #expect(f.model.phase == .complete)
        #expect(f.model.totalPositions == 3)
        for index in 0...2 {
            #expect(f.record.winRates?[index] == 0.60)
            #expect(f.record.scoreLeads?[index] == 2.0)
            #expect(f.record.bestMoves?[index] == "B1")
        }
        // The derived ready-to-listen marker holds, and every analyzed move
        // gained a commentator sentence.
        #expect(ListeningReadiness.isReady(moveCount: 2,
                                           analyzedIndices: Set(f.record.winRates?.keys ?? [:].keys)))
        for index in 0...2 {
            #expect(f.record.comments?[index]?.isEmpty == false)
        }
    }

    @Test func sweepFeedsFromAClearBoardAndPlaysEachAcceptedMove() async {
        let f = Fixture()
        await f.driver.prepare(gameRecord: f.record, model: f.model)

        let sent = f.engine.sent
        #expect(sent.contains("clear_board"))
        #expect(sent.contains("play b A2"))
        #expect(sent.contains("play w B1"))
        // Restore re-fed the displayed game and resolved it with showboard.
        #expect(sent.last == "showboard")
        #expect(f.session.gobanState.reportGenerationActive == false)
        #expect(f.session.lineObserver == nil)
    }

    @Test func userCommentsAreNeverOverwritten() async {
        let f = Fixture()
        f.record.comments?[1] = "My own note."
        await f.driver.prepare(gameRecord: f.record, model: f.model)

        #expect(f.record.comments?[1] == "My own note.")
        #expect(f.record.comments?[2]?.isEmpty == false)
    }

    @Test func silenceLeavesHolesAndNoReadyMarker() async {
        let f = Fixture()
        f.script.silent = true
        await f.driver.prepare(gameRecord: f.record, model: f.model)

        #expect(f.model.phase == .complete)
        #expect(f.record.winRates?.isEmpty == true)
        #expect(f.record.comments?.isEmpty == true)
        #expect(!ListeningReadiness.isReady(moveCount: 2,
                                            analyzedIndices: Set(f.record.winRates?.keys ?? [:].keys)))
    }

    @Test func cancellationRestoresTheEngineAndReportsCancelled() async {
        let f = Fixture(sleeperOverride: { _ in throw CancellationError() })
        await f.driver.prepare(gameRecord: f.record, model: f.model)

        #expect(f.model.phase == .cancelled)
        #expect(f.session.gobanState.reportGenerationActive == false)
        #expect(f.session.lineObserver == nil)
        #expect(f.engine.sent.last == "showboard")
    }

    @Test func refusesWhileAnotherReportIsActive() async {
        let f = Fixture()
        f.session.gobanState.reportGenerationActive = true
        await f.driver.prepare(gameRecord: f.record, model: f.model)

        #expect(f.model.phase == .failed("Another analysis task is active."))
        #expect(f.engine.sent.isEmpty)
    }

    @Test func refusesABoardLargerThanTheEngine() async {
        // A game-list row can request Prepare for a record bigger than the
        // launched NN buffer; an oversized kata-analyze aborts the in-process
        // engine, so the sweep must refuse before sending anything.
        let f = Fixture()
        f.session.gobanState.engineMaxBoardLength = 1
        await f.driver.prepare(gameRecord: f.record, model: f.model)

        #expect(f.model.phase == .failed("This board exceeds the engine's Max Board Size."))
        #expect(f.engine.sent.isEmpty)
    }

    @Test func restoreReFeedsTheRestoreTargetNotTheSweptRecord() async {
        // Row-initiated Prepare: the swept record (2x2) is not the displayed
        // one (3x3). Every exit must stand the engine back on the DISPLAYED
        // record's position.
        let f = Fixture()
        let displayed = GameRecord(sgf: "(;GM[1]SZ[3];B[aa])", config: Config(),
                                   name: "Displayed")
        await f.driver.prepare(gameRecord: f.record, model: f.model,
                               restoreTo: displayed)

        #expect(f.model.phase == .complete)
        let sizes = f.engine.sent.filter { $0.hasPrefix("rectangular_boardsize") }
        #expect(sizes.first == "rectangular_boardsize 2 2")  // the sweep's feed
        #expect(sizes.last == "rectangular_boardsize 3 3")   // the restore's
        #expect(f.engine.sent.last == "showboard")
    }
}
