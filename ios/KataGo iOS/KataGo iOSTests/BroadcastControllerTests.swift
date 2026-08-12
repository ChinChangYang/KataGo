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
import Foundation
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

        /// Exact "stop" commands on the wire. Message texts carry a "> "
        /// display prefix, so match the suffix (no other command in these
        /// fixtures ends in "stop").
        var stopCommandCount: Int {
            session.messageList.messages.filter { $0.text.hasSuffix("stop") }.count
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

    /// The game-ending double pass used to die silently: the guard flipped to
    /// .idle and a replay just stopped dead. It now says so ONCE — and only
    /// once, because the guard is re-entered on every later poke.
    @Test("Game over: one terminal slide, presented exactly once")
    func gameOverPresentsTheTerminalSlideExactlyOnce() async {
        let f = Fixture()
        f.session.gobanState.passCount = 2

        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.currentSlide?.kind == .gameOver })
        // Standalone (the Comment-slide treatment): no choreography frame, so
        // the live board underneath stays mounted while the caption types.
        #expect(f.controller.currentFrame == nil)
        #expect(f.controller.currentSlide?.facts
                == ["Both players passed. The game is over."])
        #expect(f.controller.phase == .idle)          // idle, exactly as before
        #expect(!f.sent("kata-search_analyze_cancellable"))

        // Every later poke re-enters the guard; none may start a second
        // caption. Count nil → .gameOver edges across the whole window.
        var reentries = 0
        var wasShowing = true
        for step in 0..<5_000 {
            let isShowing = f.controller.currentSlide?.kind == .gameOver
            if isShowing && !wasShowing { reentries += 1 }
            wasShowing = isShowing
            if step % 50 == 0 { f.controller.noteTurnChanged(game: f.record) }
            await Task.yield()
        }
        #expect(reentries == 0)
        #expect(f.controller.currentSlide == nil)     // it finished and cleared
        #expect(f.controller.phase == .idle)
    }

    /// "Exactly once" is per GAME, not per controller lifetime: a new game (or
    /// an undo taking a pass back) makes the caption earnable again.
    @Test("A live position again re-arms the terminal slide")
    func terminalSlideRearmsAfterTheGameResumes() async {
        let f = Fixture()
        f.session.gobanState.passCount = 2
        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.currentSlide?.kind == .gameOver })
        f.controller.cancelAll()

        // Back on a live board: a full cycle runs...
        f.session.gobanState.passCount = 0
        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.phase == .awaitingMove })
        // ...and .awaitingMove is published from inside runCycle, so let its
        // continuation clear cycleTask before poking again (startCycle drops a
        // poke while the handle is live).
        for _ in 0..<200 { await Task.yield() }

        f.session.gobanState.passCount = 2
        f.session.player.nextColorForPlayCommand = .white
        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.currentSlide?.kind == .gameOver })
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

    /// The root's stop observer fires one MainActor pass AFTER
    /// issueGenMove's .run→.clear flip — with the license armed in the
    /// same synchronous job, the gate must keep its "stop" off the wire
    /// (an ungated stop cancels the licensed search: the engine prints
    /// "play cancelled" and the broadcast parks in .awaitingMove forever —
    /// the pause→resume stall).
    @Test("Resumed cycle: license armed at the flip; the gated root stop stays silent")
    func resumedCycleKeepsLicenseArmedAtTheFlipAndGatesTheRootStop() async {
        let f = Fixture()

        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.phase == .awaitingMove })
        await f.controller.pause(game: f.record)
        // The prior cycle's reply consumed the license while paused.
        f.session.gobanState.broadcastGenMovePending = false
        let stopsBefore = f.stopCommandCount

        f.controller.resume(game: f.record)
        await f.pump(until: { f.controller.phase == .awaitingMove })

        // The flip and the license arm are one synchronous MainActor job:
        // whenever the observer later fires for this flip, the license is
        // armed — the invariant the gate depends on.
        #expect(f.session.gobanState.analysisStatus == .clear)
        #expect(f.session.gobanState.broadcastGenMovePending)

        // TVRootView's observer body, verbatim: gated, it sends nothing.
        if f.session.gobanState.analysisStatus == .clear,
           f.session.gobanState.shouldStopEngineOnAnalysisClear {
            f.session.messageList.appendAndSend(command: "stop")
        }
        #expect(f.stopCommandCount == stopsBefore)
    }

    /// A pass picked while paused routes resume through the endgame
    /// formality (startCycle → immediate issueGenMove, no report) — same
    /// .run→.clear flip, same gate.
    @Test("Resumed endgame formality: license armed; the gated root stop stays silent")
    func resumedEndgameFormalityGatesTheRootStop() async {
        let f = Fixture()

        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.phase == .awaitingMove })
        await f.controller.pause(game: f.record)
        f.session.gobanState.broadcastGenMovePending = false
        f.session.gobanState.passCount = 1
        let stopsBefore = f.stopCommandCount

        f.controller.resume(game: f.record)
        await f.pump(until: { f.controller.phase == .awaitingMove })

        #expect(f.session.gobanState.analysisStatus == .clear)
        #expect(f.session.gobanState.broadcastGenMovePending)
        if f.session.gobanState.analysisStatus == .clear,
           f.session.gobanState.shouldStopEngineOnAnalysisClear {
            f.session.messageList.appendAndSend(command: "stop")
        }
        #expect(f.stopCommandCount == stopsBefore)
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

    // MARK: - Choreography: lockstep frames

    @Test("The slide opens on its first frame; the PV stone waits for its fact")
    func frameAppearsWhenItsFactStartsTyping() async {
        let f = Fixture()
        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.currentFrame != nil })
        // Slide entry: the bare-position frame (fact 0's), synchronously with
        // currentSlide.
        #expect(f.controller.currentSlide != nil)
        #expect(f.controller.currentFrame?.overlay == ReportBoardOverlay.none)
        #expect(f.controller.currentFrame?.placedStones.isEmpty == true)
        // The first PV frame appears only once the best-move fact starts —
        // by then both position facts are fully typed.
        await f.pump(until: {
            if let overlay = f.controller.currentFrame?.overlay,
               case .pv = overlay { return true }
            return false
        })
        #expect(f.controller.typedText.contains("visits."))
    }

    @Test("Beat frames drain before the next fact: the tenuki phase never starts mid-PV")
    func afterPreviousFramesDrainBeforeNextFact() async {
        let f = Fixture()
        var sawFullPV = false
        var pvCompleteBeforeTenuki = false
        f.controller.noteTurnChanged(game: f.record)
        for _ in 0..<20_000 {
            if f.controller.phase == .awaitingMove { break }
            if let overlay = f.controller.currentFrame?.overlay,
               case .pv(let vertices, _) = overlay, vertices.count == 2 {
                sawFullPV = true
            }
            if f.controller.currentFrame?.placedStones.first?.vertex == "E5",
               f.controller.currentFrame?.overlay == ReportBoardOverlay.none,
               f.controller.slideNumber == 1 {
                pvCompleteBeforeTenuki = sawFullPV   // tenuki phase began
                break
            }
            await Task.yield()
        }
        #expect(sawFullPV)
        #expect(pvCompleteBeforeTenuki)
    }

    @Test("Skip during a beat drain ends the slide; the next slide still types")
    func skipSlideAbortsFrameDrain() async {
        let f = Fixture()
        var maxLenSlide2 = 0
        var skipped = false
        f.controller.noteTurnChanged(game: f.record)
        for _ in 0..<20_000 {
            if f.controller.phase == .awaitingMove { break }
            if f.controller.slideNumber == 2 {
                maxLenSlide2 = max(maxLenSlide2, f.controller.typedText.count)
            }
            // Skip the FIRST slide the moment a PV frame is up (mid-drain).
            if !skipped, f.controller.slideNumber == 1,
               let overlay = f.controller.currentFrame?.overlay,
               case .pv = overlay {
                f.controller.skipSlide()
                skipped = true
            }
            await Task.yield()
        }
        #expect(skipped)
        #expect(maxLenSlide2 > 0)   // slide 2 typed through — no stale skip flag
    }

    @Test("Pause lands while a beat frame is draining and returns")
    func pauseDuringBeatDrainReturns() async {
        let f = Fixture()
        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: {
            if let overlay = f.controller.currentFrame?.overlay,
               case .pv = overlay { return true }
            return false
        })
        await f.controller.pause(game: f.record)   // hangs here if a drain loop misses Task.isCancelled
        #expect(f.controller.phase == .paused)
        #expect(f.controller.currentFrame == nil)
        #expect(f.controller.currentSlide == nil)
    }

    @Test("currentFrame clears at cycle end and on cancelAll")
    func currentFrameClearsAtCycleEndAndOnCancelAll() async {
        let f = Fixture()
        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.phase == .awaitingMove })
        #expect(f.controller.currentFrame == nil)

        f.session.player.nextColorForPlayCommand = .white
        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.currentFrame != nil })
        f.controller.cancelAll()
        #expect(f.controller.currentFrame == nil)
    }

    @Test("A late tenuki fact grows the frozen frame list and acts out its phase")
    func lateTenukiFactProducesItsFramesWhenItLands() async {
        let f = Fixture(generate: { model, _ in
            BroadcastControllerTests.stageFullReport(model)
            model.candidates[0].tenuki = nil
            model.stage = .tenuki(0)                  // best slide's facts may grow
            for _ in 0..<300 { await Task.yield() }   // land mid-typewriter
            model.candidates[0].tenuki = TenukiFollowUp(vertex: "C3", winrate: 0.65,
                                                        scoreLead: 3.0, visits: 40,
                                                        pv: ["C3"])
            model.stage = .complete
        })
        var sawTenukiChip = false
        f.controller.noteTurnChanged(game: f.record)
        for _ in 0..<20_000 {
            if f.controller.phase == .awaitingMove { break }
            if f.controller.currentFrame?.caption == BeatCaption.playsElsewhere(.white) {
                sawTenukiChip = true
            }
            await Task.yield()
        }
        #expect(sawTenukiChip)
    }

    @Test("Pass slide: the punish stone lands only after its sentence typed")
    func passSlidePunishStoneWaitsForItsSentence() async {
        let f = Fixture()
        var sawPunishFrame = false
        var textPrecededStone = false
        f.controller.noteTurnChanged(game: f.record)
        for _ in 0..<20_000 {
            if f.controller.phase == .awaitingMove { break }
            if !sawPunishFrame,
               f.controller.currentFrame?.placedStones
                   .contains(PlacedStone(vertex: "E5", color: .white)) == true {
                sawPunishFrame = true
                textPrecededStone = f.controller.typedText.contains("would punish at E5")
            }
            await Task.yield()
        }
        #expect(sawPunishFrame)
        #expect(textPrecededStone)
    }

    @Test("Frames freeze at slide entry: a mid-slide candidate swap cannot reshape the choreography")
    func framesFrozenAtSlideEntryAdoptOnlyPrefixExtensions() async {
        let settle = Box()
        let f = Fixture(generate: { model, _ in
            BroadcastControllerTests.stageFullReport(model)
            model.stage = .passProbe                  // keep generation open
            while settle.value == 0 { await Task.yield() }
            model.stage = .complete
        })
        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.isShowingSlides })
        f.controller.skipSlide()
        await f.pump(until: { f.controller.slideNumber == 2 })

        // The setAlternative window: wholesale candidate swap while the
        // Alternative slide is showing — flips the Δ branch to Δ-empty.
        let model = f.controller.reportModel!
        model.candidates[1] = CandidateReport(vertex: "G7", visits: 5, winrate: 0.5,
                                              scoreLead: 0, winrateDelta: 0,
                                              scoreLeadDelta: 0, pv: ["G7"],
                                              ownershipDelta: [:], tenuki: nil)
        var sawFrozenDelta = false
        for _ in 0..<20_000 {
            if f.controller.phase == .awaitingMove { break }
            if f.controller.slideNumber == 2,
               let overlay = f.controller.currentFrame?.overlay,
               case .ownershipDelta = overlay {
                sawFrozenDelta = true
                if settle.value == 0 { settle.value = 1 }   // release the generator
            }
            await Task.yield()
        }
        #expect(sawFrozenDelta)   // the frozen C3 Δ frame still showed
    }

    // MARK: - Live captions

    /// A LIVE controller (no replayAdvance) whose position can be advanced the
    /// way an engine reply does. `GobanState.play` raises passCount for a pass
    /// (and zeroes it for a stone) and the turn toggles immediately after —
    /// both in one synchronous block, which is precisely why a live pass is
    /// observed with the turn ALREADY flipped away from the passer, and why
    /// the self-play screen used to see `isGameOver` on the closing poke.
    @MainActor
    private final class LiveHarness {
        let session = GameSession()
        let record: GameRecord
        let speaker = FakeSpeaker()
        let recordedDelays = DelayBox()
        var controller: BroadcastController!

        init(startingPassCount: Int = 0, speechEnabled: Bool = true) {
            record = SelfPlayGame.makeRecord()
            session.board.width = 9
            session.board.height = 9
            session.player.nextColorForPlayCommand = .black
            session.gobanState.suppressesGenMove = true
            session.gobanState.analysisStatus = .clear
            // Set BEFORE construction: the controller baselines its pass count
            // at init, which is what a seeded continuation (entering with the
            // SGF's trailing passes already counted) depends on.
            session.gobanState.passCount = startingPassCount
            controller = BroadcastController(
                messageList: session.messageList,
                gobanState: session.gobanState,
                player: session.player,
                rootWinrate: session.rootWinrate,
                rootScore: session.rootScore,
                generateReport: { model, _ in BroadcastControllerTests.stageFullReport(model) },
                sleeper: { [recordedDelays] delay in
                    recordedDelays.delays.append(delay)
                    await Task.yield()
                },
                speaker: speaker,
                isSpeechEnabled: { speechEnabled })
        }

        /// What an engine reply does to shared state, in the engine's order.
        func land(pass: Bool) {
            session.gobanState.passCount = pass ? session.gobanState.passCount + 1 : 0
            session.player.toggleNextColorForPlayCommand()
        }

        /// Land a move and poke the controller, exactly as the screen's
        /// (now ungated) turn observer does.
        func landAndPoke(pass: Bool) {
            land(pass: pass)
            controller.noteTurnChanged(game: record)
        }

        func sentCount(_ fragment: String) -> Int {
            session.messageList.messages.filter { $0.text.contains(fragment) }.count
        }

        func pump(until condition: () -> Bool) async {
            for _ in 0..<20_000 {
                if condition() { return }
                await Task.yield()
            }
            Issue.record("pump timed out")
        }

        /// A SHORT quiescence window. The sleeper is yield-only, so one yield
        /// is one 0.1 s poll of simulated time — settle long enough and the
        /// hold's wedged-synthesizer ceiling (dwell + 10 s ≈ 156 polls) fires
        /// and ends the caption on its own. Anything this proves absent would
        /// have appeared synchronously anyway: startCycle flips `phase` in the
        /// same turn as the poke.
        func settle() async {
            for _ in 0..<20 { await Task.yield() }
        }

        /// Drive one ordinary cycle to its end so the tests below start from
        /// a realistic "the gen-move is out, awaiting the reply" state.
        func runFirstCycle() async {
            controller.noteTurnChanged(game: record)
            await pump(until: { self.controller.phase == .awaitingMove })
        }
    }

    @Test("A live played pass gets its own caption, naming the side that moved")
    func livePlayedPassGetsItsOwnCaption() async {
        let h = LiveHarness()
        await h.runFirstCycle()

        // Black was to move, so Black is the passer — even though the turn
        // has already flipped to White by the time this is observed.
        h.landAndPoke(pass: true)
        await h.pump(until: { h.controller.currentSlide?.kind == .playedPass })

        #expect(h.controller.currentSlide?.title == "Black Passes")
        #expect(h.controller.currentSlide?.facts == ["Black passes."])
        // Standalone: no choreography frame, so the live board underneath
        // stays mounted while the caption types.
        #expect(h.controller.currentFrame == nil)
        #expect(h.speaker.spoken.contains("Black passes."))
    }

    /// The positive control for the test above: the same harness, the same
    /// poke, a stone instead of a pass.
    @Test("An ordinary live move gets no caption")
    func liveOrdinaryMoveGetsNoCaption() async {
        let h = LiveHarness()
        await h.runFirstCycle()

        var sawCaption = false
        h.landAndPoke(pass: false)
        for _ in 0..<20_000 {
            if h.controller.currentSlide?.kind == .playedPass { sawCaption = true }
            if h.controller.isShowingSlides { break }   // the next cycle began
            await Task.yield()
        }
        #expect(!sawCaption)
    }

    /// Q4(c): the answer is asked for FIRST, so the stone lands whenever the
    /// engine replies; only the next cycle's slides wait for the caption.
    @Test("The answering move is requested before the caption finishes")
    func liveAnswerIsRequestedWhileTheCaptionIsStillShowing() async {
        let h = LiveHarness()
        await h.runFirstCycle()
        #expect(h.sentCount("kata-search_analyze_cancellable") == 1)

        h.speaker.autoFinishes = false            // hold the caption open
        h.landAndPoke(pass: true)
        await h.pump(until: { h.controller.currentSlide?.kind == .playedPass })

        // Still captioning, and the endgame formality has ALREADY asked for
        // the reply — it is not queued behind the narration.
        #expect(h.controller.currentSlide?.kind == .playedPass)
        #expect(h.sentCount("kata-search_analyze_cancellable") == 2)
        #expect(h.controller.phase == .awaitingMove)
    }

    /// The hazard that kept live captions out of the last round: a turn change
    /// arriving while a caption holds must be REMEMBERED, not dropped, or the
    /// live loop stalls forever.
    @Test("A turn change during a caption is deferred, then honored")
    func liveTurnChangeDuringACaptionIsDeferredNotDropped() async {
        let h = LiveHarness()
        await h.runFirstCycle()

        h.speaker.autoFinishes = false
        h.landAndPoke(pass: true)
        await h.pump(until: { h.controller.currentSlide?.kind == .playedPass })

        // The opponent answers with a stone while the caption is still up.
        h.landAndPoke(pass: false)
        await h.settle()
        // Held: no new cycle has started underneath the caption.
        #expect(h.controller.currentSlide?.kind == .playedPass)
        #expect(h.controller.phase == .awaitingMove)

        // Release the narration; the deferred change now starts its cycle.
        h.speaker.finishAll()
        // isShowingSlides is true DURING the caption too (a caption is a
        // slide) — wait for the next cycle's first analysis slide by kind.
        await h.pump(until: { h.controller.currentSlide?.kind == .best })
        #expect(h.controller.currentSlide?.kind == .best)
    }

    @Test("Skip cuts a live caption short and releases the held cycle")
    func liveSkipCutsTheCaptionAndReleasesTheHold() async {
        let h = LiveHarness()
        await h.runFirstCycle()

        h.speaker.autoFinishes = false
        h.landAndPoke(pass: true)
        await h.pump(until: { h.controller.currentSlide?.kind == .playedPass })
        h.landAndPoke(pass: false)
        await h.settle()
        #expect(h.controller.currentSlide?.kind == .playedPass)   // still held

        h.controller.skipSlide()
        // isShowingSlides is true DURING the caption too (a caption is a
        // slide) — wait for the next cycle's first analysis slide by kind.
        await h.pump(until: { h.controller.currentSlide?.kind == .best })
        #expect(h.controller.currentSlide?.kind == .best)
    }

    @Test("Pause silences a live caption instead of talking over a paused screen")
    func livePauseCancelsACaption() async {
        let h = LiveHarness()
        await h.runFirstCycle()

        h.speaker.autoFinishes = false
        h.landAndPoke(pass: true)
        await h.pump(until: { h.controller.currentSlide?.kind == .playedPass })

        await h.controller.pause(game: h.record)
        #expect(h.controller.phase == .paused)
        #expect(h.controller.currentSlide == nil)
        #expect(h.speaker.cancelCount > 0)

        // And it stays gone — a late-draining caption must not resurrect
        // itself over the paused, interactive screen.
        await h.settle()
        #expect(h.controller.currentSlide == nil)
        #expect(h.controller.phase == .paused)
    }

    /// The closing sequence, in the order it happened.
    @Test("A closing double pass narrates the pass, then the game over")
    func liveClosingDoublePassNarratesBothCaptions() async {
        let h = LiveHarness(startingPassCount: 1)
        // passCount 1 ⇒ the endgame formality: no report, answer immediately.
        h.controller.noteTurnChanged(game: h.record)
        await h.pump(until: { h.controller.phase == .awaitingMove })

        var kinds: [BroadcastSlideKind] = []
        h.landAndPoke(pass: true)                  // the second pass
        for _ in 0..<20_000 {
            if let kind = h.controller.currentSlide?.kind, kinds.last != kind {
                kinds.append(kind)
            }
            if kinds.count == 2, h.controller.currentSlide == nil { break }
            await Task.yield()
        }
        #expect(kinds == [.playedPass, .gameOver])
        #expect(h.controller.phase == .idle)
        #expect(h.speaker.spoken.contains("Black passes."))
        #expect(h.speaker.spoken.contains("Both players passed. The game is over."))
    }

    /// The *caption hold*: once the game-over card covers the panel there is
    /// no board left to absorb, so a covered caption holds for its narration
    /// and nothing more. Its uncovered twin is the positive control — without
    /// one, "it was quick" proves nothing.
    @Test("A covered caption holds for its narration; an uncovered one dwells")
    func liveCoveredCaptionSkipsTheDwell() async {
        func holdCost(startingPassCount: Int) async -> TimeInterval {
            let h = LiveHarness(startingPassCount: startingPassCount,
                                speechEnabled: false)
            h.controller.noteTurnChanged(game: h.record)
            await h.pump(until: { h.controller.phase == .awaitingMove })
            h.landAndPoke(pass: true)
            await h.pump(until: { h.controller.currentSlide?.kind == .playedPass })
            h.recordedDelays.delays.removeAll()
            await h.pump(until: { h.controller.currentSlide == nil })
            return h.recordedDelays.delays.reduce(0, +)
        }

        // Starting at 0 ⇒ the pass makes it 1: visible, ONE caption, and it
        // dwells up to the 6 s minimum-slide floor.
        let uncovered = await holdCost(startingPassCount: 0)
        // Starting at 1 ⇒ the pass makes it 2: the card is up. This figure
        // covers BOTH closing captions, because the drain runs them
        // back-to-back and never surfaces a nil slide between them — so the
        // whole closing sequence is being compared against a single
        // uncovered caption, and still costs a fraction of it. What remains
        // is typing time; the dwell is gone entirely.
        let covered = await holdCost(startingPassCount: 1)

        #expect(uncovered > 4.0)
        #expect(covered < 2.0)
        // Comfortably inside self-play's 8 s interstitial, which the 6 s
        // floor applied twice would have overrun.
        #expect(covered * 2 < uncovered)
    }

    /// The covered rule is live-self-play-specific: replay has no game-over
    /// card, so its terminal caption must keep the full dwell.
    @Test("A replay terminal caption keeps its dwell — there is no card over it")
    func replayTerminalCaptionStillDwells() async {
        let delays = DelayBox()
        let session = GameSession()
        let record = SelfPlayGame.makeRecord()
        session.board.width = 9
        session.board.height = 9
        session.player.nextColorForPlayCommand = .black
        session.gobanState.suppressesGenMove = true
        session.gobanState.analysisStatus = .clear
        session.gobanState.passCount = 2
        let controller = BroadcastController(
            messageList: session.messageList,
            gobanState: session.gobanState,
            player: session.player,
            rootWinrate: session.rootWinrate,
            rootScore: session.rootScore,
            generateReport: { model, _ in BroadcastControllerTests.stageFullReport(model) },
            sleeper: { [delays] delay in
                delays.delays.append(delay)
                await Task.yield()
            },
            isSpeechEnabled: { false },
            replayAdvance: { nil })

        controller.noteTurnChanged(game: record)
        for _ in 0..<20_000 where controller.currentSlide?.kind != .gameOver {
            await Task.yield()
        }
        delays.delays.removeAll()
        for _ in 0..<20_000 where controller.currentSlide != nil {
            await Task.yield()
        }
        #expect(delays.delays.reduce(0, +) > 4.0)
    }

    /// A seeded self-play continuation enters with the SGF's trailing passes
    /// already counted. Entry must not read that standing count as a pass
    /// somebody just played.
    @Test("A seeded position's trailing passes do not caption on entry")
    func liveSeededTrailingPassesDoNotCaptionOnEntry() async {
        let h = LiveHarness(startingPassCount: 1)
        var sawCaption = false
        h.controller.noteTurnChanged(game: h.record)
        for _ in 0..<5_000 {
            if h.controller.currentSlide?.kind == .playedPass { sawCaption = true }
            await Task.yield()
        }
        #expect(!sawCaption)
        #expect(h.controller.phase == .awaitingMove)   // the formality answered

        // Positive control: the very next pass on that same position DOES
        // caption, so the silence above is the baseline working, not a
        // controller that simply never captions from a seeded entry.
        h.landAndPoke(pass: true)
        await h.pump(until: { h.controller.currentSlide?.kind == .playedPass })
    }

    /// The early gen-move means a live stone usually lands DURING the last
    /// slide, chaining the next cycle from inside the cycle task rather than
    /// from the turn observer. A pass on that path must caption too.
    @Test("A pass landing mid-slideshow is still captioned")
    func livePassLandingMidSlideshowIsCaptioned() async {
        let h = LiveHarness()
        h.controller.noteTurnChanged(game: h.record)
        // The gen-move goes out as the FINAL slide starts; land the pass then,
        // so the turn change is consumed as `moveLanded` and the cycle chains.
        await h.pump(until: { h.sentCount("kata-search_analyze_cancellable") == 1 })
        #expect(h.controller.isShowingSlides)         // still mid-slideshow
        h.landAndPoke(pass: true)

        await h.pump(until: { h.controller.currentSlide?.kind == .playedPass })
        #expect(h.controller.currentSlide?.facts == ["Black passes."])
    }
}
