//
//  ListeningEngine.swift
//  KataGo Anytime
//
//  The Listening Session's state machine, platform-free: it drives one baked
//  ListeningScript through injected seams (speaker, sounds, sleeper, cursor
//  store, presenter) and never imports an audio, media, or activity
//  framework — those live in the iOS shell behind ListeningPresenting.
//
//  Pacing is utterance-driven: stone sound, sentence, a short gap, the next
//  move. Every await is bounded — a wedged synthesizer degrades to silent
//  advancement after a per-cue ceiling (the Broadcast's speechCeiling
//  lesson) instead of parking the session.
//

import Foundation
import Observation

@MainActor
public protocol ListeningSoundPlaying: AnyObject {
    func playStoneSound()
    func playCaptureSound()
}

/// The platform shell's window into the session: Now Playing metadata,
/// remote-command availability, and the Live Activity all hang off these.
@MainActor
public protocol ListeningPresenting: AnyObject {
    func sessionDidStart(_ script: ListeningScript)
    /// Fired when the narrated move or the play state changes.
    func sessionDidUpdate(cue: ListeningCue?, isPlaying: Bool)
    func sessionDidEnd(finished: Bool)
}

public enum ListeningPacing {
    /// Silence between one cue's last word and the next cue's stone sound.
    public static let interMoveGapSeconds: TimeInterval = 0.6
    /// Per-cue speech ceiling: past this, the utterance is cancelled and the
    /// session advances on silent pacing. Reuses the Broadcast's wedge
    /// assumption; the floor keeps short cues from racing a slow synthesizer.
    public static func speechCeiling(forCharacterCount count: Int) -> TimeInterval {
        max(4.0, Double(count) / BroadcastConstants.assumedMinimumSpokenCharactersPerSecond)
    }
}

@Observable
@MainActor
public final class ListeningEngine {
    public enum State: Equatable {
        case idle
        case playing
        case paused
        case finished
    }

    public private(set) var state: State = .idle
    public private(set) var script: ListeningScript?
    /// The Listening Cursor: the move number the session is at — the cue
    /// being spoken while playing, the cue to resume with while paused.
    public private(set) var currentMoveNumber: Int = 1

    public var currentCue: ListeningCue? {
        guard let script, state != .idle,
              (1...script.moveCount).contains(currentMoveNumber) else { return nil }
        return script.cues[currentMoveNumber - 1]
    }

    private let speaker: ListeningSpeaking
    private let sounds: ListeningSoundPlaying?
    private let cursorStore: ListeningCursorStoring
    private let sleeper: ReportSleeper
    public weak var presenter: ListeningPresenting?

    private var playbackTask: Task<Void, Never>?
    private var pendingIntro: String?

    public init(speaker: ListeningSpeaking,
                sounds: ListeningSoundPlaying? = nil,
                cursorStore: ListeningCursorStoring,
                sleeper: @escaping ReportSleeper = { try await Task.sleep(for: .seconds($0)) }) {
        self.speaker = speaker
        self.sounds = sounds
        self.cursorStore = cursorStore
        self.sleeper = sleeper
    }

    // MARK: - Session lifecycle

    /// Begin a session on a baked script, resuming from the game's stored
    /// cursor (clamped to the game as it is now) and playing immediately.
    public func start(script: ListeningScript) {
        if self.script != nil { stop() }
        self.script = script
        let stored = script.gameID.flatMap { cursorStore.cursor(for: $0) }
        currentMoveNumber = ListeningReadiness.clampedCursor(stored: stored,
                                                            moveCount: script.moveCount)
        if let gameID = script.gameID { cursorStore.lastSessionGameID = gameID }
        storeCursor()
        pendingIntro = script.intro
        state = .paused
        presenter?.sessionDidStart(script)
        play()
    }

    /// End the session, keeping the cursor for a podcast-style resume.
    public func stop() {
        cancelPlayback()
        guard script != nil else { return }
        script = nil
        pendingIntro = nil
        state = .idle
        presenter?.sessionDidEnd(finished: false)
    }

    // MARK: - Transport

    public func play() {
        guard script != nil, state == .paused else { return }
        state = .playing
        notifyUpdate()
        spawnPlayback()
    }

    /// Stops mid-word; the interrupted cue replays in full on resume.
    public func pause() {
        guard state == .playing else { return }
        cancelPlayback()
        state = .paused
        notifyUpdate()
    }

    public func togglePlayPause() {
        switch state {
        case .playing: pause()
        case .paused: play()
        case .idle, .finished: break
        }
    }

    /// Next/previous-track. Cuts the current utterance and moves the cursor
    /// one move; playback state is preserved.
    public func stepForward() { step(by: 1) }
    public func stepBackward() { step(by: -1) }

    private func step(by delta: Int) {
        guard let script, state == .playing || state == .paused else { return }
        let wasPlaying = state == .playing
        cancelPlayback()
        currentMoveNumber = ListeningReadiness.clampedCursor(
            stored: currentMoveNumber + delta, moveCount: script.moveCount)
        storeCursor()
        if wasPlaying {
            spawnPlayback()
        } else {
            notifyUpdate()
        }
    }

    // MARK: - The loop

    private func spawnPlayback() {
        playbackTask?.cancel()
        playbackTask = Task { [weak self] in
            await self?.run()
        }
    }

    private func cancelPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        speaker.cancel()
    }

    private func run() async {
        guard let script else { return }
        if let intro = pendingIntro {
            pendingIntro = nil
            await speakBounded(intro)
            guard !Task.isCancelled, state == .playing else { return }
        }
        while state == .playing, currentMoveNumber <= script.moveCount {
            let cue = script.cues[currentMoveNumber - 1]
            notifyUpdate()
            sounds?.playStoneSound()
            if cue.playsCaptureSound { sounds?.playCaptureSound() }
            await speakBounded(cue.text)
            guard !Task.isCancelled, state == .playing else { return }
            try? await sleeper(ListeningPacing.interMoveGapSeconds)
            guard !Task.isCancelled, state == .playing else { return }
            currentMoveNumber += 1
            storeCursor()
        }
        guard !Task.isCancelled, state == .playing else { return }
        await speakBounded(script.resultAnnouncement)
        guard !Task.isCancelled, state == .playing else { return }
        finish()
    }

    /// Speech with the wedge escape: a watchdog sized to the text cancels a
    /// wedged utterance, which resumes `speak` and lets the session advance
    /// on silent pacing.
    private func speakBounded(_ text: String) async {
        let ceiling = ListeningPacing.speechCeiling(forCharacterCount: text.count)
        let watchdog = Task { [weak self] in
            try? await self?.sleeper(ceiling)
            guard !Task.isCancelled else { return }
            await self?.speaker.cancel()
        }
        await speaker.speak(text)
        watchdog.cancel()
    }

    private func finish() {
        guard let script else { return }
        if let gameID = script.gameID { cursorStore.clearCursor(for: gameID) }
        currentMoveNumber = script.moveCount
        state = .finished
        presenter?.sessionDidEnd(finished: true)
    }

    private func storeCursor() {
        guard let script, let gameID = script.gameID,
              currentMoveNumber <= script.moveCount else { return }
        cursorStore.storeCursor(currentMoveNumber, for: gameID)
    }

    private func notifyUpdate() {
        presenter?.sessionDidUpdate(cue: currentCue, isPlaying: state == .playing)
    }
}
