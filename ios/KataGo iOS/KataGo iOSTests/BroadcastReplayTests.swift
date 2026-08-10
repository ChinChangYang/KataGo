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
        let session = GameSession()
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

    @Test("Fast pacing caps a replay cycle at the Best Move slide")
    func fastPacingCapsSlides() async {
        let f = Fixture(pacing: TVAutoPlaySpeed.fast.broadcastPacing,
                        replayAdvance: { nil })
        var maxSlide = 0
        f.controller.noteTurnChanged(game: f.record)
        for _ in 0..<20_000 {
            if f.controller.phase == .awaitingMove { break }
            if f.controller.currentSlide?.kind != .comment {
                maxSlide = max(maxSlide, f.controller.slideNumber)
            }
            await Task.yield()
        }
        #expect(maxSlide == 1)
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
}
