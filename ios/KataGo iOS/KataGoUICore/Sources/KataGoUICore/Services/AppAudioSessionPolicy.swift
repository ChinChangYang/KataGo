//
//  AppAudioSessionPolicy.swift
//  KataGo Anytime
//
//  The one owner of the app's AVAudioSession category. AudioModel used to
//  assert `.playback + .mixWithOthers` in its OWN init — and it is
//  constructed per-view (ContentView, StatusToolbarItems, previews), so any
//  view rebuild re-asserted mixable and would silently clobber the
//  NON-mixable spoken-audio session a Listening Session depends on for
//  background playback. Every assertion now routes through this latch: while
//  listening is active, stone-sound constructions leave the session alone.
//

import AVFoundation

@MainActor
public enum AppAudioSessionPolicy {
    public private(set) static var isListeningActive = false

#if os(macOS)
    public static func assertSharedPlayback() {}
    public static func beginListening() {}
    public static func endListening() {}
#else
    /// The app's resting posture: mixable playback, so stone sounds ride
    /// on top of whatever else is playing. What AudioModel.init has always
    /// asserted — now skipped while a Listening Session owns the session.
    public static func assertSharedPlayback() {
        guard !isListeningActive else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: .mixWithOthers)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    /// A Listening Session's posture: non-mixable spoken audio — what earns
    /// Now Playing ownership and keeps the process alive in the background.
    /// Also re-asserted when an interruption ends.
    public static func beginListening() {
        isListeningActive = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    /// Back to the resting posture, telling other audio it may resume.
    public static func endListening() {
        guard isListeningActive else { return }
        isListeningActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        assertSharedPlayback()
    }
#endif
}
