//
//  BroadcastReplayTests.swift
//  KataGo AnytimeTests
//
//  The replay move source, spoken narration, and pacing seams of the
//  broadcast cycle — all timing-free (the BroadcastControllerTests pattern:
//  scripted generator, yield-only sleeper, bounded MainActor pumps).
//

import Foundation
import Testing
import SwiftData
@testable import KataGoUICore

@MainActor
final class FakeSpeaker: NarrationSpeaking {
    var spoken: [String] = []
    var cancelCount = 0
    /// true = utterances finish instantly (ordering tests);
    /// false = the queue holds until finishAll() (pacing tests).
    var autoFinishes = true
    private var queueDepth = 0

    func speak(_ text: String) {
        spoken.append(text)
        if !autoFinishes { queueDepth += 1 }
    }

    var isSpeaking: Bool { queueDepth > 0 }

    func cancelAll() {
        queueDepth = 0
        cancelCount += 1
    }

    func finishAll() { queueDepth = 0 }
}

/// Records every delay the controller requests of its sleeper, in order —
/// the seam for proving `pacing()` (not the hard-coded BroadcastConstants)
/// drives the typewriter reveal rate.
@MainActor
final class DelayBox {
    var delays: [TimeInterval] = []
}

@MainActor
struct BroadcastReplayTests {

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
        let session = GameSession.accepting()
        let record: GameRecord
        let controller: BroadcastController
        let speaker = FakeSpeaker()
        /// Every delay requested of the sleeper, in order (empty unless a
        /// test reads it — recording costs nothing the other fixtures care
        /// about).
        let recordedDelays = DelayBox()

        init(speechEnabled: Bool = true,
             pacing: BroadcastPacing = .live,
             replayAdvance: (@MainActor () -> String?)? = nil,
             generate: @escaping @MainActor (DeepReportModel, GameRecord) async -> Void
                = { model, _ in BroadcastReplayTests.stageFullReport(model) }) {
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
                                             sleeper: { [recordedDelays] delay in
                                                 recordedDelays.delays.append(delay)
                                                 await Task.yield()
                                             },
                                             speaker: speaker,
                                             isSpeechEnabled: { speechEnabled },
                                             pacing: { pacing },
                                             replayAdvance: replayAdvance)
        }

        func sent(_ fragment: String) -> Bool {
            session.messageList.messages.contains { $0.text.contains(fragment) }
        }

        func pump(until condition: () -> Bool) async {
            for _ in 0..<20_000 {
                if condition() { return }
                await Task.yield()
            }
            Issue.record("pump timed out")
        }
    }

    // MARK: - Speech

    @Test("Enabled speech speaks every fact of every slide, in order")
    func speaksAllFactsInOrder() async {
        let f = Fixture()
        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.phase == .awaitingMove })
        let allFacts = BroadcastScript.slides(from: f.controller.reportModel!)
            .flatMap { $0.facts }
        #expect(!allFacts.isEmpty)
        #expect(f.speaker.spoken == allFacts)
    }

    @Test("Disabled speech speaks nothing")
    func disabledSpeaksNothing() async {
        let f = Fixture(speechEnabled: false)
        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.phase == .awaitingMove })
        #expect(f.speaker.spoken.isEmpty)
    }

    @Test("An unfinished utterance holds the slide; finishing releases it")
    func slideWaitsForSpeech() async {
        let f = Fixture()
        f.speaker.autoFinishes = false
        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.slideNumber == 1 })
        // Pump until the typewriter has genuinely finished slide 1 — its
        // LAST fact fully typed — before starting the fixed-yield window
        // below. Without this, that window could end while slide 1 is still
        // typing, which would weaken "the queue holds the slide" into
        // nothing more than "the typewriter hasn't caught up yet".
        let slide1LastFact = BroadcastScript.slides(from: f.controller.reportModel!)[0].facts.last!
        await f.pump(until: { f.controller.typedText.contains(slide1LastFact) })
        // Let the typewriter and dwell run out; the speech queue still holds.
        // Bounded well below the wedge ceiling (BroadcastConstants.
        // speechHoldFloorSeconds) so this proves the QUEUE is holding the
        // slide, not the ceiling eventually releasing it on its own.
        var yields = 0
        while f.controller.slideNumber == 1 && yields < 200 {
            await Task.yield()
            yields += 1
        }
        #expect(f.controller.slideNumber == 1)
        f.speaker.finishAll()
        await f.pump(until: { f.controller.slideNumber >= 2 })
    }

    /// A wedged synthesizer (isSpeaking that never goes false and no
    /// finishAll) must not park the broadcast forever: the speech-hold
    /// ceiling (BroadcastConstants.speechHoldFloorSeconds /
    /// assumedMinimumSpokenCharactersPerSecond) degrades to silent pacing —
    /// cancelling the stuck utterance and letting the cycle complete.
    @Test("A wedged synthesizer degrades to silent pacing; the broadcast completes")
    func wedgedSynthesizerDegradesToSilentPacing() async {
        let f = Fixture()
        f.speaker.autoFinishes = false   // never calls finishAll(): isSpeaking stays true
        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.slideNumber == 2 })
        await f.pump(until: { f.controller.phase == .awaitingMove })
        #expect(f.speaker.cancelCount >= 1)
    }

    @Test("Skip cancels speech immediately")
    func skipCancelsSpeech() async {
        let f = Fixture()
        f.speaker.autoFinishes = false
        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.slideNumber == 1 })
        f.controller.skipSlide()
        await f.pump(until: { f.speaker.cancelCount >= 1 })
        await f.pump(until: { f.controller.slideNumber >= 2 })
    }

    @Test("Pause and cancelAll cancel speech")
    func pauseAndCancelAllCancelSpeech() async {
        let f = Fixture()
        f.speaker.autoFinishes = false
        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.isShowingSlides })
        await f.controller.pause(game: f.record)
        #expect(f.speaker.cancelCount >= 1)

        let g = Fixture()
        g.speaker.autoFinishes = false
        g.controller.noteTurnChanged(game: g.record)
        await g.pump(until: { g.controller.isShowingSlides })
        g.controller.cancelAll()
        #expect(g.speaker.cancelCount >= 1)
    }

    // MARK: - Pacing

    /// Proves pacing() (not the hard-coded BroadcastConstants) drives the
    /// typewriter reveal rate: a recording sleeper captures every requested
    /// delay, and a tight (.fast) profile's per-chunk delays must appear —
    /// the .live-rate delay for the same chunk must NOT.
    @Test("pacing() drives the typewriter reveal rate")
    func pacingDrivesTypewriterRate() async {
        let f = Fixture(pacing: TVAutoPlaySpeed.fast.broadcastPacing)
        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.phase == .awaitingMove })

        let firstFact = BroadcastScript.slides(from: f.controller.reportModel!)
            .flatMap { $0.facts }.first!
        let chunks = BroadcastScript.typewriterChunks(firstFact)
        #expect(!chunks.isEmpty)
        // Any non-empty chunk discriminates 60 cps from 30 cps; guard
        // defensively against a degenerate chunk where they'd collide.
        let chunk = chunks.first {
            Double($0.count) / TVAutoPlaySpeed.fast.broadcastPacing.charactersPerSecond
                != Double($0.count) / BroadcastPacing.live.charactersPerSecond
        } ?? chunks[0]
        let fastDelay = Double(chunk.count) / TVAutoPlaySpeed.fast.broadcastPacing.charactersPerSecond
        let liveDelay = Double(chunk.count) / BroadcastPacing.live.charactersPerSecond

        #expect(f.recordedDelays.delays.contains(fastDelay))
        if fastDelay != liveDelay {
            #expect(!f.recordedDelays.delays.contains(liveDelay))
        }
    }

    // MARK: - Replay move source

    @MainActor
    private final class Counter {
        var advances = 0
        var comment: String?
    }

    @Test("A replay cycle advances the record once, never gen-moves, never chains")
    func replayCycleAdvancesOnceWithoutGenMove() async {
        let counter = Counter()
        let f = Fixture(replayAdvance: { counter.advances += 1; return nil })
        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.phase == .awaitingMove })
        for _ in 0..<500 { await Task.yield() }   // would-be chain window
        #expect(counter.advances == 1)
        #expect(!f.sent("kata-search_analyze_cancellable"))
        #expect(!f.session.gobanState.broadcastGenMovePending)
        #expect(f.controller.phase == .awaitingMove)
    }

    @Test("A synced comment shows as a frameless Comment slide, typed and spoken")
    func commentSlideShowsOverLiveBoard() async {
        let counter = Counter()
        counter.comment = "A synced note about this move."
        let f = Fixture(replayAdvance: { counter.advances += 1; return counter.comment })
        var sawComment = false
        var frameWasNilDuringComment = false
        f.controller.noteTurnChanged(game: f.record)
        for _ in 0..<20_000 {
            if f.controller.phase == .awaitingMove { break }
            if f.controller.currentSlide?.kind == .comment {
                sawComment = true
                frameWasNilDuringComment = (f.controller.currentFrame == nil)
            }
            await Task.yield()
        }
        #expect(sawComment)
        #expect(frameWasNilDuringComment)
        #expect(f.speaker.spoken.contains("A synced note about this move."))
    }

    @Test("No comment means no Comment slide")
    func nilCommentSkipsTheSlide() async {
        let f = Fixture(replayAdvance: { nil })
        var sawComment = false
        f.controller.noteTurnChanged(game: f.record)
        for _ in 0..<20_000 {
            if f.controller.phase == .awaitingMove { break }
            if f.controller.currentSlide?.kind == .comment { sawComment = true }
            await Task.yield()
        }
        #expect(!sawComment)
    }

    /// Fast used to cap the cycle at the Best Move slide, silently dropping
    /// Alternative and Playing-vs-Passing: a speed control deleting analysis.
    /// Fast now means faster text and a shorter dwell, never less analysis —
    /// all three slides play, in order, at every profile.
    @Test("Fast pacing still shows every slide")
    func fastPacingStillShowsEverySlide() async {
        let f = Fixture(pacing: TVAutoPlaySpeed.fast.broadcastPacing,
                        replayAdvance: { nil })
        var kinds: [BroadcastSlideKind] = []
        f.controller.noteTurnChanged(game: f.record)
        for _ in 0..<20_000 {
            if f.controller.phase == .awaitingMove { break }
            if let kind = f.controller.currentSlide?.kind, kinds.last != kind {
                kinds.append(kind)
            }
            await Task.yield()
        }
        #expect(kinds == [.best, .alternative, .pass])
        #expect(f.controller.phase == .awaitingMove)
    }

    @Test("Replay never writes the synced record's dictionaries")
    func replayNeverWritesRecordDictionaries() async {
        let f = Fixture(replayAdvance: { nil })
        let winRatesBefore = f.record.winRates
        let scoreLeadsBefore = f.record.scoreLeads
        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.phase == .awaitingMove })
        #expect(f.record.winRates == winRatesBefore)
        #expect(f.record.scoreLeads == scoreLeadsBefore)
        // The panel headline still gets the snapshot.
        #expect(f.session.rootWinrate.black == 0.6)
    }

    @MainActor
    private final class Box {
        var value = 0
    }

    /// The removed pacing cap used to end a fast cycle early and CANCEL the
    /// still-running generation. With the cap gone, fast waits out the report
    /// like every other profile: the generator is never cancelled, and the
    /// sections that land late still become slides.
    @Test("Fast pacing waits the generation out instead of cancelling it")
    func fastPacingNeverCancelsTheGeneration() async {
        let sawCancellation = Box()
        let f = Fixture(pacing: TVAutoPlaySpeed.fast.broadcastPacing,
                        replayAdvance: { nil },
                        generate: { model, _ in
                            BroadcastReplayTests.stageFullReport(model)
                            model.passComparison = nil        // the pass section is late
                            model.stage = .passProbe          // keep generation OPEN
                            for _ in 0..<200 { await Task.yield() }
                            if Task.isCancelled { sawCancellation.value += 1 }
                            BroadcastReplayTests.stageFullReport(model)
                        })
        var sawPassSlide = false
        f.controller.noteTurnChanged(game: f.record)
        for _ in 0..<20_000 {
            if f.controller.phase == .awaitingMove { break }
            if f.controller.currentSlide?.kind == .pass { sawPassSlide = true }
            await Task.yield()
        }
        #expect(sawCancellation.value == 0)
        #expect(sawPassSlide)        // the late section still got its slide
        #expect(f.controller.phase == .awaitingMove)
    }

    // MARK: - Played passes

    /// Builds a replay controller whose `replayAdvance` can raise passCount
    /// the way the real one does — GobanState.play() bumps it SYNCHRONOUSLY
    /// inside forwardMoves, so the controller's before/after comparison
    /// straddles the call. Fixture can't express this (its closure would have
    /// to capture a session it doesn't own yet), so this wires one by hand.
    @MainActor
    private final class ReplayPassHarness {
        let session = GameSession.accepting()
        let record: GameRecord
        let speaker = FakeSpeaker()
        var controller: BroadcastController!
        var advances = 0

        init(playsPass: Bool) {
            record = SelfPlayGame.makeRecord()
            session.board.width = 9
            session.board.height = 9
            session.player.nextColorForPlayCommand = .black
            session.gobanState.suppressesGenMove = true
            session.gobanState.analysisStatus = .clear
            controller = BroadcastController(
                messageList: session.messageList,
                gobanState: session.gobanState,
                player: session.player,
                rootWinrate: session.rootWinrate,
                rootScore: session.rootScore,
                generateReport: { model, _ in BroadcastReplayTests.stageFullReport(model) },
                sleeper: { _ in await Task.yield() },
                speaker: speaker,
                isSpeechEnabled: { true },
                pacing: { .live },
                replayAdvance: { [weak self] in
                    guard let self else { return nil }
                    self.advances += 1
                    // What GobanState.play does for a recorded move: a pass
                    // raises passCount, anything else resets it to 0.
                    self.session.gobanState.passCount = playsPass
                        ? self.session.gobanState.passCount + 1 : 0
                    self.session.player.toggleNextColorForPlayCommand()
                    return nil
                })
        }

        func pump(until condition: () -> Bool) async {
            for _ in 0..<20_000 {
                if condition() { return }
                await Task.yield()
            }
            Issue.record("pump timed out")
        }
    }

    @Test("A replayed pass gets its own standalone slide, naming who passed")
    func playedPassGetsItsOwnSlide() async {
        let h = ReplayPassHarness(playsPass: true)
        h.controller.noteTurnChanged(game: h.record)
        await h.pump(until: { h.controller.currentSlide?.kind == .playedPass })

        // Black was to move before the advance, so Black is the passer.
        #expect(h.controller.currentSlide?.title == "Black Passes")
        #expect(h.controller.currentSlide?.facts == ["Black passes."])
        // Standalone, like the Comment slide: no choreography frame, so the
        // live board (already showing the pass) stays mounted.
        #expect(h.controller.currentFrame == nil)

        await h.pump(until: { h.controller.phase == .awaitingMove })
        #expect(h.advances == 1)
        #expect(h.speaker.spoken.contains("Black passes."))
    }

    @Test("A replayed board move gets no played-pass slide")
    func ordinaryReplayedMoveGetsNoPlayedPassSlide() async {
        let h = ReplayPassHarness(playsPass: false)
        var sawPlayedPass = false
        h.controller.noteTurnChanged(game: h.record)
        for _ in 0..<20_000 {
            if h.controller.phase == .awaitingMove { break }
            if h.controller.currentSlide?.kind == .playedPass { sawPlayedPass = true }
            await Task.yield()
        }
        #expect(!sawPlayedPass)
        #expect(h.advances == 1)
    }

    /// The stop path's ordering seam: a screen that stops a replay mid-cycle
    /// must be able to sequence engine traffic AFTER the cancelled generator
    /// has unwound. `cancelAll` alone returns while the generator is still
    /// draining — its deferred restore then sends "stop" plus an undo tail,
    /// which kills any kata-analyze armed before that lands (the review
    /// screen's "analysis reads ON but nothing streams" stop bug).
    @Test("cancelAllAndDrain awaits the cancelled generator's unwind")
    func cancelAllAndDrainAwaitsTheUnwind() async {
        let exited = Box()
        let f = Fixture(replayAdvance: { nil },
                        generate: { model, _ in
                            BroadcastReplayTests.stageFullReport(model)
                            model.stage = .passProbe          // keep generation OPEN
                            while !Task.isCancelled { await Task.yield() }
                            model.stage = .cancelled
                            exited.value += 1
                        })
        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.isShowingSlides })
        // Positive control: the generator really is parked, so the assertion
        // after the drain cannot pass vacuously.
        #expect(exited.value == 0)
        await f.controller.cancelAllAndDrain()
        #expect(exited.value == 1)   // returned only AFTER the unwind
        #expect(f.controller.phase == .idle)
    }

    @Test("A replayed one-pass position runs the full replay cycle, never the live gen-move shortcut")
    func onePassReplayNeverGenMoves() async {
        let counter = Counter()
        let f = Fixture(replayAdvance: { counter.advances += 1; return nil })
        f.session.gobanState.passCount = 1
        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.phase == .awaitingMove })
        #expect(counter.advances == 1)
        #expect(!f.sent("kata-search_analyze_cancellable"))
        #expect(!f.session.gobanState.broadcastGenMovePending)
    }

    // MARK: - Asymmetric human-SL suppression

    @Test("The replay flag silences asymmetric human-SL turn commands")
    func suppressionFlagSilencesAsymmetricSends() {
        let session = GameSession.accepting()
        let record = SelfPlayGame.makeRecord()
        let config = record.concreteConfig
        config.blackMaxTime = 1.0
        config.humanSLProfile = "9d"     // black: a 9d engine profile
        config.whiteMaxTime = 0          // white: Human → effective "AI" (asymmetric)
        #expect(!config.isEqualBlackWhiteEffectiveHumanSettings)

        session.gobanState.suppressesHumanSLTurnCommands = true
        session.gobanState.maybeSendAsymmetricHumanAnalysisCommands(
            nextColorForPlayCommand: .black, config: config,
            messageList: session.messageList)
        #expect(session.messageList.messages.isEmpty)

        session.gobanState.suppressesHumanSLTurnCommands = false
        session.gobanState.maybeSendAsymmetricHumanAnalysisCommands(
            nextColorForPlayCommand: .black, config: config,
            messageList: session.messageList)
        #expect(!session.messageList.messages.isEmpty)
    }
}
