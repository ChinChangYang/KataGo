//
//  ListeningEngineTests.swift
//  KataGo AnytimeTests
//
//  Fake-driven, offline. The sleeper fake distinguishes the wedge watchdog
//  from the inter-move gap by duration: a ceiling (>= 1 s) parks until the
//  watchdog is cancelled, a gap yields once — so speech-paced order is
//  deterministic under Task.yield pumping.
//

import Foundation
import Testing
import KataGoUICore

@MainActor
private final class ListeningSpeakerFake: ListeningSpeaking {
    var spoken: [String] = []
    /// Texts asked for by an already-cancelled task. The real speaker cuts
    /// those at once, so nobody hears them.
    var cut: [String] = []
    /// Texts with this prefix park until cancel(); "" parks everything.
    var stallPrefix: String?
    private var cancelRequested = false

    func speak(_ text: String) async {
        if Task.isCancelled {
            cut.append(text)
            return
        }
        spoken.append(text)
        guard let stallPrefix, text.hasPrefix(stallPrefix) else { return }
        while !cancelRequested, !Task.isCancelled { await Task.yield() }
        cancelRequested = false
    }

    func cancel() { cancelRequested = true }
}

@MainActor
private final class ListeningSoundsFake: ListeningSoundPlaying {
    var stones = 0
    var captures = 0
    func playStoneSound() { stones += 1 }
    func playCaptureSound() { captures += 1 }
}

@MainActor
private final class ListeningCursorStoreFake: ListeningCursorStoring {
    var cursors: [UUID: Int] = [:]
    var lastSessionGameID: UUID?
    func cursor(for gameID: UUID) -> Int? { cursors[gameID] }
    func storeCursor(_ moveNumber: Int, for gameID: UUID) { cursors[gameID] = moveNumber }
    func clearCursor(for gameID: UUID) { cursors[gameID] = nil }
}

@MainActor
private final class ListeningPresenterFake: ListeningPresenting {
    var started: [String] = []
    var updates: [(Int?, Bool)] = []
    var ended: [Bool] = []
    func sessionDidStart(_ script: ListeningScript) { started.append(script.gameName) }
    func sessionDidUpdate(cue: ListeningCue?, isPlaying: Bool) {
        updates.append((cue?.moveNumber, isPlaying))
    }
    func sessionDidEnd(finished: Bool) { ended.append(finished) }
}

@MainActor
struct ListeningEngineTests {
    private static let gameID = UUID()

    private static func script(moveCount: Int = 2) -> ListeningScript {
        let cues = (1...moveCount).map {
            ListeningCue(moveNumber: $0, text: "Cue \($0).",
                         playsCaptureSound: $0 == 2, source: .bareCall)
        }
        return ListeningScript(gameID: gameID, gameName: "G", boardWidth: 9, boardHeight: 9,
                               intro: "Intro.", cues: cues,
                               resultAnnouncement: "Result.", finalScoreLeadBlack: nil)
    }

    private struct Fixture {
        let speaker = ListeningSpeakerFake()
        let sounds = ListeningSoundsFake()
        let cursorStore = ListeningCursorStoreFake()
        let presenter = ListeningPresenterFake()
        let engine: ListeningEngine

        @MainActor
        init(instantCeiling: Bool = false) {
            engine = ListeningEngine(
                speaker: speaker, sounds: sounds, cursorStore: cursorStore,
                sleeper: { seconds in
                    if seconds >= 1, !instantCeiling {
                        while !Task.isCancelled { await Task.yield() }
                    } else {
                        await Task.yield()
                    }
                })
            engine.presenter = presenter
        }

        @MainActor
        func pump(until condition: () -> Bool) async {
            for _ in 0..<20_000 {
                if condition() { return }
                await Task.yield()
            }
            Issue.record("pump timed out")
        }
    }

    @Test func fullPlaythroughSpeaksEverythingAndClearsTheCursor() async {
        let f = Fixture()
        f.engine.start(script: Self.script())
        await f.pump(until: { f.engine.state == .finished })

        #expect(f.speaker.spoken == ["Intro.", "Cue 1.", "Cue 2.", "Result."])
        #expect(f.sounds.stones == 2)
        #expect(f.sounds.captures == 1)
        #expect(f.cursorStore.cursors[Self.gameID] == nil)
        #expect(f.cursorStore.lastSessionGameID == Self.gameID)
        #expect(f.presenter.started == ["G"])
        #expect(f.presenter.ended == [true])
    }

    @Test func resumeStartsAtTheStoredCursor() async {
        let f = Fixture()
        f.cursorStore.cursors[Self.gameID] = 2
        f.engine.start(script: Self.script())
        await f.pump(until: { f.engine.state == .finished })

        #expect(f.speaker.spoken == ["Intro.", "Cue 2.", "Result."])
    }

    @Test func aCursorPastAShrunkenGameClampsToTheLastMove() async {
        let f = Fixture()
        f.cursorStore.cursors[Self.gameID] = 42
        f.engine.start(script: Self.script(moveCount: 2))
        await f.pump(until: { f.engine.state == .finished })

        #expect(f.speaker.spoken == ["Intro.", "Cue 2.", "Result."])
    }

    @Test func pauseKeepsTheCursorAndResumeReplaysTheCue() async {
        let f = Fixture()
        f.speaker.stallPrefix = "Cue"
        f.engine.start(script: Self.script())
        await f.pump(until: { f.speaker.spoken.contains("Cue 1.") })

        f.engine.pause()
        #expect(f.engine.state == .paused)
        #expect(f.engine.currentMoveNumber == 1)

        f.speaker.stallPrefix = nil
        f.engine.play()
        await f.pump(until: { f.engine.state == .finished })
        #expect(f.speaker.spoken == ["Intro.", "Cue 1.", "Cue 1.", "Cue 2.", "Result."],
                "the intro, once spoken, must not come back on resume")
    }

    @Test func stopMidGameLeavesAResumableCursor() async {
        let f = Fixture()
        f.speaker.stallPrefix = "Cue"
        f.engine.start(script: Self.script())
        await f.pump(until: { f.speaker.spoken.contains("Cue 1.") })

        f.engine.stop()
        #expect(f.engine.state == .idle)
        #expect(f.cursorStore.cursors[Self.gameID] == 1)
        #expect(f.presenter.ended == [false])
    }

    @Test func stepForwardCutsTheUtteranceAndAdvances() async {
        let f = Fixture()
        f.speaker.stallPrefix = "Cue"
        f.engine.start(script: Self.script())
        await f.pump(until: { f.speaker.spoken.contains("Cue 1.") })

        f.engine.stepForward()
        await f.pump(until: { f.speaker.spoken.contains("Cue 2.") })
        #expect(f.engine.currentMoveNumber == 2)
        #expect(f.cursorStore.cursors[Self.gameID] == 2)
    }

    /// A pause cuts the intro as it cuts a cue, and resuming replays it in
    /// full before the move the session is at.
    @Test func pausingDuringTheIntroReplaysItOnResume() async {
        let f = Fixture()
        f.speaker.stallPrefix = "Intro"
        f.engine.start(script: Self.script())
        await f.pump(until: { f.speaker.spoken.contains("Intro.") })

        f.engine.pause()
        f.speaker.stallPrefix = nil
        f.engine.play()
        await f.pump(until: { f.engine.state == .finished })
        #expect(f.speaker.spoken == ["Intro.", "Intro.", "Cue 1.", "Cue 2.", "Result."])
    }

    /// A pause in the same turn as start() cancels the first playback task
    /// before it runs. That task must not speak, and the intro waits for
    /// the task that resumes.
    @Test func aPauseBeforeTheFirstTurnKeepsTheIntro() async {
        let f = Fixture()
        f.engine.start(script: Self.script())
        f.engine.pause()
        f.engine.play()
        await f.pump(until: { f.engine.state == .finished })

        #expect(f.speaker.spoken == ["Intro.", "Cue 1.", "Cue 2.", "Result."])
        #expect(f.speaker.cut.isEmpty)
    }

    /// A skip moves on from the intro as it does from a cue: the intro is
    /// not replayed before the move the skip lands on.
    @Test func aSkipDuringTheIntroMovesOnWithoutIt() async {
        let f = Fixture()
        f.speaker.stallPrefix = "Intro"
        f.engine.start(script: Self.script())
        await f.pump(until: { f.speaker.spoken.contains("Intro.") })

        f.engine.stepForward()
        f.speaker.stallPrefix = nil
        await f.pump(until: { f.engine.state == .finished })
        #expect(f.speaker.spoken == ["Intro.", "Cue 2.", "Result."])
    }

    /// Pausing keeps the intro for the resume, but a skip made while paused
    /// still moves on from it.
    @Test func aSkipWhilePausedInTheIntroMovesOnWithoutIt() async {
        let f = Fixture()
        f.speaker.stallPrefix = "Intro"
        f.engine.start(script: Self.script())
        await f.pump(until: { f.speaker.spoken.contains("Intro.") })

        f.engine.pause()
        f.engine.stepForward()
        f.speaker.stallPrefix = nil
        f.engine.play()
        await f.pump(until: { f.engine.state == .finished })
        #expect(f.speaker.spoken == ["Intro.", "Cue 2.", "Result."])
    }

    /// A skip in the same turn as start() cancels the first playback task
    /// before it runs. That task must not speak, and the skip moves on from
    /// the intro as any skip does.
    @Test func aSkipBeforeTheFirstTurnSpeaksOnlyTheCueItLandsOn() async {
        let f = Fixture()
        f.engine.start(script: Self.script())
        f.engine.stepForward()
        await f.pump(until: { f.engine.state == .finished })

        #expect(f.speaker.spoken == ["Cue 2.", "Result."])
        #expect(f.speaker.cut.isEmpty)
        #expect(f.sounds.stones == 1)
    }

    /// The first skip's playback task is cancelled by the second before it
    /// ever runs, and must not speak.
    @Test func twoSkipsInOneTurnSpeakOnlyTheCueTheyLandOn() async {
        let f = Fixture()
        f.speaker.stallPrefix = "Cue"
        f.engine.start(script: Self.script(moveCount: 3))
        await f.pump(until: { f.speaker.spoken.contains("Cue 1.") })

        f.engine.stepForward()
        f.engine.stepForward()
        f.speaker.stallPrefix = nil
        await f.pump(until: { f.engine.state == .finished })
        #expect(f.speaker.spoken == ["Intro.", "Cue 1.", "Cue 3.", "Result."])
        #expect(f.sounds.stones == 2)
    }

    @Test func stepBackwardFromTheFirstMoveStaysPut() async {
        let f = Fixture()
        f.speaker.stallPrefix = "Cue"
        f.engine.start(script: Self.script())
        await f.pump(until: { f.speaker.spoken.contains("Cue 1.") })

        f.engine.stepBackward()
        await f.pump(until: { f.speaker.spoken.filter { $0 == "Cue 1." }.count == 2 })
        #expect(f.engine.currentMoveNumber == 1)
    }

    @Test func aWedgedSynthesizerAdvancesOnSilentPacing() async {
        let f = Fixture(instantCeiling: true)
        f.speaker.stallPrefix = ""
        f.engine.start(script: Self.script())
        await f.pump(until: { f.engine.state == .finished })

        #expect(f.speaker.spoken.contains("Result."))
        #expect(f.presenter.ended == [true])
    }

    @Test func startingANewSessionEndsThePriorOne() async {
        let f = Fixture()
        f.speaker.stallPrefix = "Cue"
        f.engine.start(script: Self.script())
        await f.pump(until: { f.speaker.spoken.contains("Cue 1.") })

        f.speaker.stallPrefix = nil
        f.engine.start(script: Self.script())
        await f.pump(until: { f.engine.state == .finished })
        #expect(f.presenter.ended == [false, true])
        #expect(f.presenter.started.count == 2)
    }
}
