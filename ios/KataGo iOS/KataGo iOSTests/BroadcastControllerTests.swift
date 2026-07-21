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

        // The engine's play reply consumed the prior cycle's gen-move license
        // and the picker is idle: resume's quiescence gate (F2) now passes.
        f.session.gobanState.broadcastGenMovePending = false
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

    @MainActor
    private final class Box {
        var value = 0
    }

    @Test("A cancelled cycle's late continuation cannot clobber a newer cycle")
    func cancelAllContinuationCannotClobberNewerCycle() async {
        let started = Box()
        let exited = Box()
        let f = Fixture(generate: { model, _ in
            started.value += 1
            model.sideToMove = .black
            model.candidates = [CandidateReport(vertex: "E5", visits: 10, winrate: 0.5,
                                                scoreLead: 0, winrateDelta: 0, scoreLeadDelta: 0,
                                                pv: ["E5"], ownershipDelta: [:], tenuki: nil)]
            while !Task.isCancelled { await Task.yield() }
            model.stage = .cancelled
            exited.value += 1
        })

        f.controller.noteTurnChanged(game: f.record)            // cycle A
        await f.pump(until: { f.controller.isShowingSlides })
        f.controller.cancelAll()
        f.controller.noteTurnChanged(game: f.record)            // cycle B
        await f.pump(until: { started.value == 2 })
        for _ in 0..<500 { await Task.yield() }                 // drain A's cancelled continuation

        // pause must find B's live handle (not a clobbered nil), cancel it,
        // and await it — so every started generation has observed
        // cancellation and exited by the time we're paused.
        await f.controller.pause(game: f.record)
        await f.pump(until: { exited.value == 2 })
        #expect(f.controller.phase == .paused)
    }

    /// A never-settling generator that widens the cancellation-drain window
    /// (so an interleaved cancelAll lands squarely mid-drain).
    private static func slowDrainGenerator(_ model: DeepReportModel) async {
        model.sideToMove = .black
        model.candidates = [CandidateReport(vertex: "E5", visits: 10, winrate: 0.5,
                                            scoreLead: 0, winrateDelta: 0, scoreLeadDelta: 0,
                                            pv: ["E5"], ownershipDelta: [:], tenuki: nil)]
        while !Task.isCancelled { await Task.yield() }
        for _ in 0..<50 { await Task.yield() }   // widen the drain window
        model.stage = .cancelled
    }

    // MARK: - F1: pause task lifecycle

    @Test("Two overlapping pauses re-arm continuous analysis exactly once")
    func pauseIsIdempotentWhileDraining() async {
        let f = Fixture(generate: { model, _ in
            await BroadcastControllerTests.slowDrainGenerator(model)
        })

        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.isShowingSlides })

        // Fire two overlapping pauses; the first arms, the second must
        // early-return while the first is still draining.
        let a = Task { await f.controller.pause(game: f.record) }
        let b = Task { await f.controller.pause(game: f.record) }
        await a.value
        await b.value

        #expect(f.controller.phase == .paused)
        #expect(f.sentCount("kata-analyze") == 1)
    }

    @Test("cancelAll during a pause drain suppresses the re-arm")
    func cancelAllDuringPauseDrainSuppressesRearm() async {
        let f = Fixture(generate: { model, _ in
            await BroadcastControllerTests.slowDrainGenerator(model)
        })

        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.isShowingSlides })

        let pauseCall = Task { await f.controller.pause(game: f.record) }
        for _ in 0..<3 { await Task.yield() }   // let the pause reach its drain
        f.controller.cancelAll()
        await pauseCall.value
        for _ in 0..<200 { await Task.yield() }

        #expect(f.controller.phase == .idle)
        #expect(f.session.gobanState.analysisStatus != .run)
        #expect(!f.sent("kata-analyze"))        // the pause path never re-armed
    }

    // MARK: - F2: resume quiescence gate

    @Test("Resume is dropped while a pick or gen-move reply is still in flight")
    func resumeDroppedWhilePickInFlight() async {
        let gen = Box()
        let f = Fixture(generate: { model, _ in
            gen.value += 1
            BroadcastControllerTests.stageFullReport(model)
        })

        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.phase == .awaitingMove })
        await f.controller.pause(game: f.record)
        let genAfterPause = gen.value
        // The prior cycle's license was consumed by its play reply — isolate
        // each drop condition.
        f.session.gobanState.broadcastGenMovePending = false

        // (a) a pick's legality check is still in flight.
        f.session.gobanState.pendingMoveTurn = "b"
        f.controller.resume(game: f.record)
        for _ in 0..<200 { await Task.yield() }
        #expect(f.controller.phase == .paused)
        #expect(gen.value == genAfterPause)

        // (b) a cancelled gen-move reply is still in flight.
        f.session.gobanState.pendingMoveTurn = nil
        f.session.gobanState.broadcastGenMovePending = true
        f.controller.resume(game: f.record)
        for _ in 0..<200 { await Task.yield() }
        #expect(f.controller.phase == .paused)
        #expect(gen.value == genAfterPause)
    }

    // MARK: - F3: stale license cleared on cancelAll

    @Test("cancelAll clears an armed gen-move license")
    func cancelAllClearsArmedLicense() async {
        let f = Fixture()

        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.phase == .awaitingMove })
        #expect(f.session.gobanState.broadcastGenMovePending)   // armed first

        f.controller.cancelAll()
        #expect(!f.session.gobanState.broadcastGenMovePending)
    }

    // MARK: - F4: skip honored during dwell

    @Test("A skip during a slide never blanks the next slide")
    func skipDuringDwellDoesNotSwallowNextSlide() async {
        let f = Fixture()   // settling full report → three slides
        var seen: Set<Int> = []
        var maxLenSlide2 = 0
        var skipped = false

        f.controller.noteTurnChanged(game: f.record)
        for _ in 0..<20_000 {
            if f.controller.phase == .awaitingMove { break }
            let n = f.controller.slideNumber
            if n > 0 { seen.insert(n) }
            if n == 2 { maxLenSlide2 = max(maxLenSlide2, f.controller.typedText.count) }
            if !skipped && n == 1 {
                f.controller.skipSlide()
                skipped = true
            }
            await Task.yield()
        }

        #expect(seen.contains(1))
        #expect(seen.contains(2))
        #expect(seen.contains(3))
        #expect(maxLenSlide2 > 0)   // slide 2 typed through, never blanked
    }

    // MARK: - F5: turn-quiescence gate at cycle start

    @Test("The cycle waits for showboard turn-quiescence before generating")
    func cycleWaitsForShowboardQuiescence() async {
        let gen = Box()
        let f = Fixture(generate: { model, _ in
            gen.value += 1
            BroadcastControllerTests.stageFullReport(model)
        })
        // showboard has not yet made the reported side authoritative.
        f.session.player.nextColorForPlayCommand = .black
        f.session.player.nextColorFromShowBoard = .white

        f.controller.noteTurnChanged(game: f.record)
        // Pump below the bounded 50-poll cap: the gate holds generation while
        // the sides disagree. (The plan's "~200 yields" would overshoot the
        // cap and let the bounded degradation release it — the point here is
        // to pin the HOLD, so we stay under the cap.)
        for _ in 0..<30 { await Task.yield() }

        #expect(gen.value == 0)
        #expect(f.controller.phase == .generating)

        // The showboard reply lands: the sides agree, generation runs.
        f.session.player.nextColorFromShowBoard = .black
        await f.pump(until: { f.controller.phase == .awaitingMove })
        #expect(gen.value == 1)
    }
}
