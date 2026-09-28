//
//  ListeningSpeakerTests.swift
//  KataGo AnytimeTests
//
//  AVSpeechListeningSpeaker's wait belongs to one line. AVSpeechSynthesizer
//  reports a stopped line from the main queue some time after the stop,
//  and by then the next line is already queued behind it. So on every skip,
//  line A's report (a didCancel, or as often a didFinish) arrives while
//  line B waits. That report must not end B's wait. If it does, the session
//  moves on after the 0.6 s gap and the line after B cuts B off
//  mid-sentence.
//
//  A fake synthesizer stands in for AVSpeechSynthesizer, and each test calls
//  the speaker's delegate methods itself, in the order the race produces.
//  The fake keeps every utterance alive, so these tests cannot catch a switch
//  to matching by ObjectIdentifier; the comment on the speaker's `end(_:)`
//  says why that is wrong.
//

import AVFoundation
import Testing
@testable import KataGoUICore

@MainActor
private final class SynthesizerFake: ListeningSynthesizing {
    private(set) var spoken: [AVSpeechUtterance] = []
    private(set) var isSpeaking = false
    private(set) var stops = 0

    func speak(_ utterance: AVSpeechUtterance) {
        spoken.append(utterance)
        isSpeaking = true
    }

    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        stops += 1
        defer { isSpeaking = false }
        return isSpeaking
    }
}

@MainActor
private final class Harness {
    let synthesizer = SynthesizerFake()
    let speaker: AVSpeechListeningSpeaker
    /// The texts whose `speak` call has returned, in order.
    var returned: [String] = []
    /// The callbacks' first argument. The speaker ignores it, and it never
    /// speaks.
    private let callbackSource = AVSpeechSynthesizer()

    init() {
        speaker = AVSpeechListeningSpeaker(synthesizer: synthesizer)
    }

    /// Speaks `text` in a task of its own, and returns once the synthesizer
    /// has its utterance.
    func start(_ text: String) async throws -> (task: Task<Void, Never>, utterance: AVSpeechUtterance) {
        let count = synthesizer.spoken.count
        let task = Task {
            await speaker.speak(text)
            returned.append(text)
        }
        await pump { self.synthesizer.spoken.count > count }
        return (task, try #require(synthesizer.spoken.dropFirst(count).first))
    }

    func report(_ report: ListeningSpeakerTests.Report, for utterance: AVSpeechUtterance) {
        switch report {
        case .finished: speaker.speechSynthesizer(callbackSource, didFinish: utterance)
        case .cancelled: speaker.speechSynthesizer(callbackSource, didCancel: utterance)
        }
    }

    func pump(until condition: () -> Bool) async {
        for _ in 0..<20_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("pump timed out")
    }

    /// Lets the jobs already queued on the main actor run: a callback's hop
    /// there, the wait it ends, and the task that wait resumes. The positive
    /// controls show this is long enough for a report to end a wait.
    func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }
}

@MainActor
struct ListeningSpeakerTests {
    /// How the synthesizer reports that a line ended.
    enum Report: CaseIterable {
        case finished
        case cancelled
    }

    /// A skip or a pause cuts line A, and line B starts before the
    /// synthesizer reports A's end.
    @Test(arguments: Report.allCases)
    func aLateReportForACutLineLeavesTheNextLineWaiting(_ report: Report) async throws {
        let h = Harness()
        let a = try await h.start("A")
        h.speaker.cancel()
        await h.pump { h.returned == ["A"] }
        let b = try await h.start("B")

        h.report(report, for: a.utterance)
        await h.settle()
        #expect(h.returned == ["A"], "A's report ended B's wait")

        h.report(.finished, for: b.utterance)
        await h.pump { h.returned == ["A", "B"] }
    }

    /// A new line cuts the one in flight, and the cut line's report comes
    /// after the new one has started.
    @Test func aLineThatCutsInIsNotEndedByTheReportOfTheLineItCut() async throws {
        let h = Harness()
        let a = try await h.start("A")
        let b = try await h.start("B")
        await h.pump { h.returned == ["A"] }

        h.report(.cancelled, for: a.utterance)
        await h.settle()
        #expect(h.returned == ["A"], "A's report ended B's wait")

        h.report(.finished, for: b.utterance)
        await h.pump { h.returned == ["A", "B"] }
    }

    /// Two quick skips: B is queued behind A, which is still stopping, and
    /// the second stop drops B unspoken. The synthesizer never reports B,
    /// and A's report comes while C waits.
    @Test func aDoubleSkipLeavesTheThirdLineWaiting() async throws {
        let h = Harness()
        let a = try await h.start("A")
        h.speaker.cancel()
        _ = try await h.start("B")
        h.speaker.cancel()
        let c = try await h.start("C")
        await h.pump { h.returned == ["A", "B"] }

        h.report(.cancelled, for: a.utterance)
        await h.settle()
        #expect(h.returned == ["A", "B"], "A's report ended C's wait")

        h.report(.finished, for: c.utterance)
        await h.pump { h.returned == ["A", "B", "C"] }
    }

    /// Cancelling a line's task stops that line. A caller that cancels one
    /// line's task and speaks the next in the same turn must not have the
    /// cancellation stop the next line.
    @Test func cancellingALinesTaskLeavesTheNextLineSpeaking() async throws {
        let h = Harness()
        let a = try await h.start("A")
        Task {
            a.task.cancel()
            h.speaker.cancel()
            await h.speaker.speak("B")
            h.returned.append("B")
        }
        await h.pump { h.synthesizer.spoken.count == 2 }
        let b = try #require(h.synthesizer.spoken.dropFirst().first)

        await h.settle()
        #expect(h.returned == ["A"], "A's cancellation ended B's wait")
        #expect(h.synthesizer.stops == 1, "A's cancellation stopped B")

        h.report(.finished, for: b)
        await h.pump { h.returned == ["A", "B"] }
    }

    // MARK: - Positive controls

    @Test(arguments: Report.allCases)
    func aLinesOwnReportEndsItsWait(_ report: Report) async throws {
        let h = Harness()
        let a = try await h.start("A")

        h.report(report, for: a.utterance)
        await h.settle()
        #expect(h.returned == ["A"])
    }

    @Test func cancellingALinesTaskStopsItAndEndsItsWait() async throws {
        let h = Harness()
        let a = try await h.start("A")

        a.task.cancel()
        await h.settle()
        #expect(h.returned == ["A"])
        #expect(h.synthesizer.stops == 1)
    }

    /// A caller whose task is already cancelled when it calls `speak`: the
    /// cancellation hop is queued before the line exists, and must still
    /// find it and stop it. ListeningEngine.run() returns before this point,
    /// but the protocol promises it.
    @Test func aTaskCancelledBeforeItSpeaksStopsItsLine() async {
        let h = Harness()
        let task = Task {
            await h.speaker.speak("A")
            h.returned.append("A")
        }
        task.cancel()

        await h.settle()
        #expect(h.synthesizer.spoken.count == 1)
        #expect(h.returned == ["A"])
        #expect(h.synthesizer.stops == 1)
    }
}
