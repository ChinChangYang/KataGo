//
//  ListeningSpeaker.swift
//  KataGo Anytime
//
//  Listen's speech seam. Distinct from NarrationSpeaking (the Broadcast's
//  fire-and-poll protocol): a Listening Session is utterance-paced, so its
//  speaker is awaited — the engine's loop resumes when the sentence has been
//  spoken. The AVSpeechSynthesizer conformer has one rule: a line's end
//  report, or its task's cancellation, ends that line's wait and never a
//  later line's. ListeningSpeakerTests pins it through a fake synthesizer.
//  Audio-session ownership is the platform shell's job, never handled here.
//

import AVFoundation

@MainActor
public protocol ListeningSpeaking: AnyObject {
    /// Speak one cue's text and return when it has finished — or when the
    /// calling task is cancelled, in which case speech stops mid-word.
    func speak(_ text: String) async
    /// Stop mid-word and drop anything queued.
    func cancel()
}

/// The synthesizer calls the speaker makes: the seam that lets a test play
/// the delegate's callbacks in any order, late ones included.
@MainActor
protocol ListeningSynthesizing: AnyObject {
    var isSpeaking: Bool { get }
    func speak(_ utterance: AVSpeechUtterance)
    @discardableResult func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
}

extension AVSpeechSynthesizer: ListeningSynthesizing {}

@MainActor
public final class AVSpeechListeningSpeaker: NSObject, ListeningSpeaking, AVSpeechSynthesizerDelegate {
    private let synthesizer: ListeningSynthesizing
    /// The line being spoken and the `speak` call waiting on it.
    private var line: (utterance: AVSpeechUtterance, wait: CheckedContinuation<Void, Never>)?

    public convenience override init() {
        let synthesizer = AVSpeechSynthesizer()
        self.init(synthesizer: synthesizer)
        synthesizer.delegate = self
    }

    /// Tests pass a fake and call the delegate methods themselves.
    init(synthesizer: ListeningSynthesizing) {
        self.synthesizer = synthesizer
        super.init()
    }

    public func speak(_ text: String) async {
        // Stop only when something is actually in flight: an unconditional
        // stopSpeaking pokes the synthesizer's XPC service even when idle,
        // which the simulator's asset-less TTS answers slowly.
        if synthesizer.isSpeaking || line != nil { cancel() }
        let utterance = AVSpeechUtterance(string: text)
        // Narration is English regardless of the device locale.
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        // Sent to the cancellation hop, which only compares its identity.
        nonisolated(unsafe) let own = utterance
        await withTaskCancellationHandler {
            await withCheckedContinuation { wait in
                line = (utterance, wait)
                synthesizer.speak(utterance)
            }
        } onCancel: {
            // The hop can land after the next line has started.
            Task { @MainActor in self.cancel(own) }
        }
    }

    public func cancel() {
        synthesizer.stopSpeaking(at: .immediate)
        endLine()
    }

    /// Cancels `utterance` if it is still the line being spoken.
    private func cancel(_ utterance: AVSpeechUtterance) {
        if line?.utterance === utterance { cancel() }
    }

    /// Ends the wait on `utterance` if it is still the line being spoken.
    ///
    /// The synthesizer reports a stopped line after the stop, once the next
    /// line is queued, so a report can name a line that a skip already cut.
    /// The hop here carries the utterance itself, not an `ObjectIdentifier`:
    /// once a cut line is freed, the next one can be allocated at its address.
    private func end(_ utterance: AVSpeechUtterance) {
        if line?.utterance === utterance { endLine() }
    }

    private func endLine() {
        let wait = line?.wait
        line = nil
        wait?.resume()
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                              didFinish utterance: AVSpeechUtterance) {
        nonisolated(unsafe) let utterance = utterance
        Task { @MainActor in self.end(utterance) }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                              didCancel utterance: AVSpeechUtterance) {
        nonisolated(unsafe) let utterance = utterance
        Task { @MainActor in self.end(utterance) }
    }
}
