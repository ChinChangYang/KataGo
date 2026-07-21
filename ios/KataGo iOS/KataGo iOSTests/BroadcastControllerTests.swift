//
//  BroadcastControllerTests.swift
//  KataGo AnytimeTests
//
//  The broadcast cycle state machine, with a scripted report generator and a
//  yield-only sleeper so every path runs timing-free. Spin-waits are bounded
//  MainActor yield loops (the controller's tasks are MainActor too, so
//  yielding drives them deterministically forward).
//

import Testing
import SwiftData
@testable import KataGoUICore

@MainActor
struct BroadcastControllerTests {

    private static func stageFullReport(_ model: DeepReportModel) {
        model.sideToMove = .black
        model.boardWidth = 9
        model.boardHeight = 9
        model.moveNumber = 3
        model.position = PositionSummary(winrate: 0.6, scoreLead: 2.0, visits: 200)
        model.candidates = [
            CandidateReport(vertex: "E5", visits: 120, winrate: 0.6, scoreLead: 2.0,
                            winrateDelta: 0, scoreLeadDelta: 0, pv: ["E5", "C3"],
                            ownershipDelta: [:],
                            tenuki: TenukiFollowUp(vertex: "C3", winrate: 0.65,
                                                   scoreLead: 3.0, visits: 40, pv: ["C3"])),
            CandidateReport(vertex: "C3", visits: 60, winrate: 0.58, scoreLead: 1.5,
                            winrateDelta: -0.02, scoreLeadDelta: -0.5, pv: ["C3"],
                            ownershipDelta: [BoardPoint(x: 2, y: 2): -0.4],
                            tenuki: TenukiFollowUp(vertex: "E5", winrate: 0.6,
                                                   scoreLead: 2.0, visits: 30, pv: ["E5"])),
        ]
        model.passComparison = PassComparison(punishmentVertex: "E5", winrate: 0.35,
                                              scoreLead: -3.0, winrateDeltaVsBest: 0.25,
                                              scoreLeadDeltaVsBest: 5.0,
                                              ownershipDelta: [:], contestedPoints: [])
        model.stage = .complete
    }

    @MainActor
    private struct Fixture {
        let session = GameSession()
        let record: GameRecord
        let controller: BroadcastController

        init(generate: @escaping @MainActor (DeepReportModel, GameRecord) async -> Void
                = { model, _ in BroadcastControllerTests.stageFullReport(model) }) {
            // The real broadcast record: createGameRecord + both maxTimes 1.0
            // (requestBroadcastGenMove is a no-op for a side with maxTime 0).
            record = SelfPlayGame.makeRecord()
            session.board.width = 9
            session.board.height = 9
            session.player.nextColorForPlayCommand = .black
            session.gobanState.suppressesGenMove = true
            session.gobanState.analysisStatus = .clear
            controller = BroadcastController(messageList: session.messageList,
                                             gobanState: session.gobanState,
                                             player: session.player,
                                             rootWinrate: session.rootWinrate,
                                             rootScore: session.rootScore,
                                             generateReport: generate,
                                             sleeper: { _ in await Task.yield() })
        }

        func sent(_ fragment: String) -> Bool {
            session.messageList.messages.contains { $0.text.contains(fragment) }
        }

        func sentCount(_ fragment: String) -> Int {
            session.messageList.messages.filter { $0.text.contains(fragment) }.count
        }

        /// Bounded MainActor pump: yields until the condition holds.
        func pump(until condition: () -> Bool) async {
            for _ in 0..<20_000 {
                if condition() { return }
                await Task.yield()
            }
            Issue.record("pump timed out")
        }
    }

    @Test("A full cycle: slides in order, gen-move at the last slide, awaitingMove")
    func fullCycleRunsSlidesAndIssuesGenMove() async {
        let f = Fixture()

        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.phase == .awaitingMove })

        #expect(f.sent("kata-search_analyze_cancellable"))
        #expect(f.session.gobanState.broadcastGenMovePending)
        #expect(f.controller.currentSlide == nil)
        #expect(f.controller.typedText.isEmpty)
        // Snapshot stats were written black-positive at slideshow start.
        #expect(f.session.rootWinrate.black == 0.6)
        #expect(f.session.rootScore.black == 2.0)
        #expect(f.record.scoreLeads?[f.record.currentIndex] == 2.0)
        #expect(f.record.winRates?[f.record.currentIndex] == 0.6)
    }

    @Test("Turn change mid-slides chains straight into the next cycle")
    func moveLandedMidSlidesChains() async {
        let f = Fixture()

        f.controller.noteTurnChanged(game: f.record)
        // The gen-move goes out when the LAST slide starts; simulate its
        // reply landing while a slide is still typing.
        await f.pump(until: { f.session.gobanState.broadcastGenMovePending })
        f.session.player.nextColorForPlayCommand = .white
        f.controller.noteTurnChanged(game: f.record)

        // The finished cycle chains into a second one whose own gen-move
        // makes two sends total (the transient awaitingMove between cycles
        // is too brief to pump on), then the second cycle parks.
        await f.pump(until: { f.sentCount("kata-search_analyze_cancellable") >= 2 })
        await f.pump(until: { f.controller.phase == .awaitingMove })
    }

    @Test("Skip fast-forwards slides; skipping the last slide issues the gen-move")
    func skipAdvancesSlides() async {
        let f = Fixture()

        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.isShowingSlides })
        f.controller.skipSlide()
        await f.pump(until: { f.controller.slideNumber >= 2 })
        f.controller.skipSlide()
        await f.pump(until: { f.controller.slideNumber >= 3 })
        f.controller.skipSlide()
        await f.pump(until: { f.controller.phase == .awaitingMove })
        #expect(f.sent("kata-search_analyze_cancellable"))
    }

    @Test("First pass: no report segment, immediate gen-move")
    func firstPassSkipsReport() async {
        let f = Fixture()
        f.session.gobanState.passCount = 1

        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.phase == .awaitingMove })

        #expect(f.controller.reportModel == nil)
        #expect(f.sent("kata-search_analyze_cancellable"))
    }

    @Test("Game over: the cycle trigger goes idle")
    func gameOverGoesIdle() async {
        let f = Fixture()
        f.session.gobanState.passCount = 2

        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.phase == .idle })
        #expect(!f.sent("kata-search_analyze_cancellable"))
    }

    @Test("Failed generation: no slides, the move still plays")
    func failureDegradesToPlainMove() async {
        let f = Fixture(generate: { model, _ in model.stage = .failed("no analysis") })

        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.phase == .awaitingMove })

        #expect(f.controller.currentSlide == nil)
        #expect(f.sent("kata-search_analyze_cancellable"))
    }

    @Test("Pause cancels the cycle and re-arms continuous analysis for the interactive screen")
    func pauseCancelsAndRearms() async {
        let f = Fixture(generate: { model, _ in
            model.sideToMove = .black
            model.candidates = [CandidateReport(vertex: "E5", visits: 10, winrate: 0.5,
                                                scoreLead: 0, winrateDelta: 0, scoreLeadDelta: 0,
                                                pv: ["E5"], ownershipDelta: [:], tenuki: nil)]
            while !Task.isCancelled { await Task.yield() }
            model.stage = .cancelled
        })

        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.isShowingSlides })
        await f.controller.pause(game: f.record)

        #expect(f.controller.phase == .paused)
        #expect(f.controller.currentSlide == nil)
        #expect(f.session.gobanState.analysisStatus == .run)
        #expect(f.sent("kata-analyze"))                        // continuous re-arm
        #expect(f.session.gobanState.suppressesGenMove)        // invariant holds
        #expect(!f.sent("kata-search_analyze_cancellable"))    // no gen-move while paused
    }

    @Test("Resume runs a fresh full cycle and restores the .clear protocol at gen-move time")
    func resumeRestoresProtocol() async {
        let f = Fixture()

        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.phase == .awaitingMove })
        await f.controller.pause(game: f.record)
        #expect(f.session.gobanState.analysisStatus == .run)

        f.controller.resume(game: f.record)
        await f.pump(until: { f.controller.phase == .awaitingMove })
        #expect(f.session.gobanState.analysisStatus == .clear)
    }

    @Test("cancelAll abandons everything and returns to idle")
    func cancelAllReturnsToIdle() async {
        let f = Fixture()

        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.isShowingSlides })
        f.controller.cancelAll()

        #expect(f.controller.phase == .idle)
        #expect(f.controller.currentSlide == nil)
    }
}
