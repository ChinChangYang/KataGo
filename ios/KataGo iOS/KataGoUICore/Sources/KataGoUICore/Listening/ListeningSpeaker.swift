//
//  ListeningSpeaker.swift
//  KataGo Anytime
//
//  Listen's speech seam. Distinct from NarrationSpeaking (the Broadcast's
//  fire-and-poll protocol): a Listening Session is utterance-paced, so its
//  speaker is awaited — the engine's loop resumes when the sentence has been
//  spoken. The AVSpeechSynthesizer conformer stays logic-free and
//  deliberately untested, like AVSpeechNarrationSpeaker; audio-session
//  ownership is the platform shell's job, never handled here.
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

@MainActor
public final class AVSpeechListeningSpeaker: NSObject, ListeningSpeaking, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    public func speak(_ text: String) async {
        // Stop only when something is actually in flight: an unconditional
        // stopSpeaking pokes the synthesizer's XPC service even when idle,
        // which the simulator's asset-less TTS answers slowly.
        if synthesizer.isSpeaking || continuation != nil { cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                let utterance = AVSpeechUtterance(string: text)
                // Narration is English regardless of the device locale.
                utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
                synthesizer.speak(utterance)
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    public func cancel() {
        synthesizer.stopSpeaking(at: .immediate)
        resume()
    }

    private func resume() {
        continuation?.resume()
        continuation = nil
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                              didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resume() }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                              didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resume() }
    }
}
