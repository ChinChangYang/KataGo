//
//  NarrationSpeaker.swift
//  KataGoUICore
//
//  Speaks broadcast narration aloud. The protocol is the test seam:
//  BroadcastController's "hold the slide until speech finishes" pacing is
//  driven by a fake; the AVSpeechSynthesizer conformer stays logic-free and
//  deliberately untested. Audio rides the session AudioModel already
//  configures (.playback, .mixWithOthers) — no session code here.
//

import AVFoundation

@MainActor
public protocol NarrationSpeaking: AnyObject {
    /// Enqueue one fact's sentence. Utterances play in submission order.
    func speak(_ text: String)
    /// True while an utterance is speaking or queued.
    var isSpeaking: Bool { get }
    /// Stop mid-word and drop the queue.
    func cancelAll()
}

@MainActor
public final class AVSpeechNarrationSpeaker: NarrationSpeaking {
    private let synthesizer = AVSpeechSynthesizer()

    public init() {}

    public func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        // The narration facts are English regardless of the device locale.
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
    }

    public var isSpeaking: Bool { synthesizer.isSpeaking }

    public func cancelAll() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
