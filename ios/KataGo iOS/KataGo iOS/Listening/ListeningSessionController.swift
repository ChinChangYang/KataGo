//
//  ListeningSessionController.swift
//  KataGo iOS
//
//  The platform shell around ListeningEngine: audio-session posture,
//  Now Playing metadata, steering-wheel/remote transport, and interruption
//  and route-change handling. The engine stays platform-free; everything
//  MediaPlayer/AVAudioSession-shaped lives here (ADR 0013's split).
//

import ActivityKit
import AVFoundation
import MediaPlayer
import SwiftData
import SwiftUI
import KataGoUICore

@Observable
@MainActor
final class ListeningSessionController: ListeningPresenting {
    let engine: ListeningEngine
    var isPresentingSheet = false

    private let sounds = ListeningSounds()
    private var observers: [NSObjectProtocol] = []
    private var artwork: MPMediaItemArtwork?
    private var activityID: String?

    init() {
        engine = ListeningEngine(speaker: AVSpeechListeningSpeaker(),
                                 sounds: sounds,
                                 cursorStore: UserDefaultsListeningCursorStore())
        engine.presenter = self
    }

    var isSessionActive: Bool {
        engine.state == .playing || engine.state == .paused
    }

    /// Bake the record into a script and start narrating (resuming from the
    /// game's Listening Cursor). Returns false when the record cannot be
    /// narrated — no mainline, or a move the rules refuse. If this game's
    /// session is already running, just re-present the sheet.
    @discardableResult
    func listen(to gameRecord: GameRecord) -> Bool {
        if isSessionActive, engine.script?.gameID != nil,
           engine.script?.gameID == gameRecord.uuid {
            isPresentingSheet = true
            return true
        }
        guard let script = ListeningScriptBuilder.script(for: gameRecord) else { return false }
        // The artwork request handler MUST be @Sendable: MediaPlayer calls
        // it on its own queue, and a closure formed here would otherwise
        // inherit MainActor isolation and trap off-main (the @MainActor-
        // inherited-ObjC-callback trap — compiles clean, dies at runtime).
        // Rendered from the record, once per session — the stored `thumbnail`
        // column is no longer written (ADR 0014), and a session is exactly the
        // right granularity for a raster: one render, not one per cue.
        artwork = RecordBoardImage.render(for: gameRecord, side: 512)
            .map { image in
                MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
            }
        AppAudioSessionPolicy.beginListening()
        configureRemoteCommands()
        observeSessionNotifications()
        engine.start(script: script)
        isPresentingSheet = true
        return true
    }

    func endSession() {
        engine.stop()
    }

    /// The App Intents' entry: resolve the router-latched id against the
    /// shared store and start (or re-present) the session. A stale id —
    /// deleted game, other device — is dropped silently; Siri already
    /// confirmed the intent.
    func listenToGame(withID id: UUID) {
        let descriptor = FetchDescriptor<GameRecord>(predicate: #Predicate { $0.uuid == id })
        guard let record = try? SharedModelContainer.shared.mainContext
            .fetch(descriptor).first else { return }
        listen(to: record)
    }

    // MARK: - ListeningPresenting

    func sessionDidStart(_ script: ListeningScript) {
        updateNowPlaying()
        startActivity(for: script)
    }

    func sessionDidUpdate(cue: ListeningCue?, isPlaying: Bool) {
        updateNowPlaying()
        updateActivity()
    }

    func sessionDidEnd(finished: Bool) {
        tearDownRemoteCommands()
        removeSessionNotificationObservers()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        artwork = nil
        endActivity()
        AppAudioSessionPolicy.endListening()
    }

    // MARK: - Live Activity

    /// The session's one CarPlay surface: iOS 26 mirrors a running Live
    /// Activity onto the CarPlay Dashboard with no entitlement. Session-
    /// scoped — requested at start, ended at stop, never left to linger.
    private func startActivity(for script: ListeningScript) {
        endActivity()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = ListeningActivityAttributes(
            gameID: script.gameID?.uuidString ?? "",
            gameName: script.gameName,
            totalMoves: script.moveCount)
        activityID = try? Activity.request(
            attributes: attributes,
            content: ActivityContent(state: activityState(), staleDate: nil)).id
    }

    // Update/end address the activity BY ID from inside the task's own
    // region: Activity is not Sendable, so it must not cross the hop.

    private func updateActivity() {
        guard let activityID else { return }
        let content = ActivityContent(state: activityState(), staleDate: nil)
        Task.detached {
            await Activity<ListeningActivityAttributes>.activities
                .first { $0.id == activityID }?
                .update(content)
        }
    }

    private func endActivity() {
        guard let activityID else { return }
        self.activityID = nil
        let content = ActivityContent(state: activityState(), staleDate: nil)
        Task.detached {
            await Activity<ListeningActivityAttributes>.activities
                .first { $0.id == activityID }?
                .end(content, dismissalPolicy: .default)
        }
    }

    private func activityState() -> ListeningActivityAttributes.ContentState {
        ListeningActivityAttributes.ContentState(
            moveNumber: engine.currentMoveNumber,
            scoreLeadBlack: engine.state == .finished ? engine.script?.finalScoreLeadBlack : nil,
            isPlaying: engine.state == .playing)
    }

    // MARK: - Now Playing

    private func updateNowPlaying() {
        guard let script = engine.script else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: script.gameName,
            MPMediaItemPropertyArtist: "Move \(engine.currentMoveNumber) of \(script.moveCount)",
            MPNowPlayingInfoPropertyPlaybackRate: engine.state == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Remote transport

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.engine.play(); return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.engine.pause(); return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.engine.togglePlayPause(); return .success
        }
        // Next/previous track IS move navigation (the design's Q8): one move
        // per press, repeat presses to travel.
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.engine.stepForward(); return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.engine.stepBackward(); return .success
        }
        for command in [center.skipForwardCommand, center.skipBackwardCommand,
                        center.seekForwardCommand, center.seekBackwardCommand,
                        center.changePlaybackPositionCommand] {
            command.isEnabled = false
        }
    }

    private func tearDownRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        for command in [center.playCommand, center.pauseCommand,
                        center.togglePlayPauseCommand,
                        center.nextTrackCommand, center.previousTrackCommand] {
            command.removeTarget(nil)
        }
    }

    // MARK: - Interruptions and route changes

    private func observeSessionNotifications() {
        removeSessionNotificationObservers()
        let center = NotificationCenter.default
        // The raw UInts cross the hop, not the (non-Sendable) userInfo.
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] notification in
            let typeRaw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor in
                self?.handleInterruption(typeRaw: typeRaw, optionsRaw: optionsRaw)
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] notification in
            let reasonRaw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in self?.handleRouteChange(reasonRaw: reasonRaw) }
        })
    }

    private func removeSessionNotificationObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    /// Nav prompts and calls: pause on `.began`, and resume on `.ended` only
    /// when the system says the app should — after re-asserting the
    /// listening session, which the interruption deactivated.
    func handleInterruption(typeRaw: UInt?, optionsRaw: UInt?) {
        guard let typeRaw,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            engine.pause()
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw ?? 0)
            if options.contains(.shouldResume) {
                AppAudioSessionPolicy.beginListening()
                engine.play()
            }
        @unknown default:
            break
        }
    }

    /// CarPlay unplug / headphones out: standard unplug semantics — pause,
    /// never blast the speaker; resuming is a deliberate act.
    func handleRouteChange(reasonRaw: UInt?) {
        guard let reasonRaw,
              AVAudioSession.RouteChangeReason(rawValue: reasonRaw) == .oldDeviceUnavailable
        else { return }
        engine.pause()
    }
}

/// Stone/capture sounds inside the narration stream — the app's audio
/// signature, always on during a session regardless of the board's
/// sound-effect setting (the design's Q10).
@MainActor
private final class ListeningSounds: ListeningSoundPlaying {
    private let audioModel = AudioModel()
    func playStoneSound() { audioModel.playPlaySound(soundEffect: true) }
    func playCaptureSound() { audioModel.playCaptureSound(soundEffect: true) }
}
