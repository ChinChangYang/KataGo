//
//  ListeningSessionControllerTests.swift
//  KataGo AnytimeTests
//
//  Interruption and route-change handling, driven with the raw userInfo
//  values the notifications carry — the simulator cannot fake a phone call
//  or a CarPlay unplug, but the handlers take nothing else from them.
//
//  The same applies to the Now Playing artwork below: the simulator finishes a
//  whole script in seconds with no audio device, so the lock-screen card never
//  survives long enough to photograph. `MPNowPlayingInfoCenter` is what that
//  card reads, and it is readable right here.
//
//  Serialized because that info center is PROCESS-GLOBAL: `listen(to:)` writes
//  it, so two of these running at once would each read the other's session.
//  So are the audio posture, remote commands and interruption observers a
//  session sets up, which is why no session here outlives its test (see
//  `EndsEveryListeningSession`).
//
//  No controller here puts up a real Live Activity (see `makeController`).
//

import AVFoundation
import Foundation
import MediaPlayer
import Testing
import KataGoUICore
@testable import KataGo_Anytime

@MainActor
@Suite(.serialized, .endsEveryListeningSession)
struct ListeningSessionControllerTests {
    /// Every controller in this suite comes from here, so that its session
    /// ends with its test. It gets a recorder in place of ActivityKit: a
    /// real activity outlives the test host, and a finished session's card
    /// stays up on purpose. At the simulator's next boot the system launches
    /// the app for it, and the first test launch then failed. Its cursor
    /// store keeps the test games out of the app's own defaults.
    private func makeController(
        _ liveActivity: LiveActivityRecorder = LiveActivityRecorder(),
        cursorStore: InMemoryCursorStore = InMemoryCursorStore()
    ) -> ListeningSessionController {
        let controller = ListeningSessionController(liveActivity: liveActivity,
                                                    cursorStore: cursorStore)
        ListeningSessions.started.append(controller)
        return controller
    }

    private func startedController(
        _ liveActivity: LiveActivityRecorder = LiveActivityRecorder()
    ) -> ListeningSessionController {
        let cursorStore = InMemoryCursorStore()
        let controller = makeController(liveActivity, cursorStore: cursorStore)
        let record = GameRecord(sgf: "(;GM[1]FF[4]SZ[9];B[cc];W[gg])",
                                config: Config(), name: "Interrupted")
        #expect(controller.listen(to: record))
        #expect(cursorStore.lastSessionGameID == record.uuid)
        return controller
    }

    private func interruptionBegan(_ controller: ListeningSessionController) {
        controller.handleInterruption(
            typeRaw: AVAudioSession.InterruptionType.began.rawValue, optionsRaw: nil)
    }

    private func interruptionEnded(_ controller: ListeningSessionController,
                                   shouldResume: Bool) {
        controller.handleInterruption(
            typeRaw: AVAudioSession.InterruptionType.ended.rawValue,
            optionsRaw: shouldResume ? AVAudioSession.InterruptionOptions.shouldResume.rawValue : 0)
    }

    @Test func interruptionBeganPausesTheSession() {
        let liveActivity = LiveActivityRecorder()
        let controller = startedController(liveActivity)
        #expect(controller.engine.state == .playing)
        #expect(liveActivity.updates.last?.isPlaying == true)

        interruptionBegan(controller)
        #expect(controller.engine.state == .paused)
        // The card follows: its play/pause glyph reads this.
        #expect(liveActivity.updates.last?.isPlaying == false)
    }

    @Test func interruptionEndedWithShouldResumeResumes() {
        let controller = startedController()
        interruptionBegan(controller)
        #expect(controller.engine.state == .paused)

        interruptionEnded(controller, shouldResume: true)
        #expect(controller.engine.state == .playing)
    }

    @Test func interruptionEndedWithoutShouldResumeStaysPaused() {
        let controller = startedController()
        interruptionBegan(controller)

        interruptionEnded(controller, shouldResume: false)
        #expect(controller.engine.state == .paused)
    }

    /// A pause the user chose outlasts a call: the call's end resumes only
    /// a session its start paused.
    @Test func anInterruptionLeavesAUserPauseAlone() {
        let controller = startedController()
        controller.engine.pause()

        interruptionBegan(controller)
        interruptionEnded(controller, shouldResume: true)
        #expect(controller.engine.state == .paused)
    }

    /// Not every `.began` gets an `.ended`. One left open must not let a
    /// later call resume a pause the user chose after playing again.
    @Test func anInterruptionThatNeverEndedCannotResumeALaterUserPause() {
        let controller = startedController()
        interruptionBegan(controller)
        controller.engine.play()
        controller.engine.pause()

        interruptionBegan(controller)
        interruptionEnded(controller, shouldResume: true)
        #expect(controller.engine.state == .paused)
    }

    /// A second `.began`, the first never ended, finds the session paused
    /// by the first and not by the user: the end still resumes it.
    @Test func anInterruptionOverAnotherStillResumes() {
        let controller = startedController()
        interruptionBegan(controller)
        interruptionBegan(controller)

        interruptionEnded(controller, shouldResume: true)
        #expect(controller.engine.state == .playing)
    }

    /// Left paused by an interruption the system said not to resume from,
    /// the session is as good as paused by the user: the next interruption
    /// must not resume it.
    @Test func anInterruptionEndedWithoutResumeLeavesTheNextAlone() {
        let controller = startedController()
        interruptionBegan(controller)
        interruptionEnded(controller, shouldResume: false)

        interruptionBegan(controller)
        interruptionEnded(controller, shouldResume: true)
        #expect(controller.engine.state == .paused)
    }

    /// An interruption that ends after the session did must not take the
    /// audio session back: nothing is left to play, and other audio would
    /// stay silenced.
    @Test func anInterruptionEndingAfterTheSessionLeavesTheAudioAlone() {
        let controller = startedController()
        interruptionBegan(controller)
        controller.endSession()

        interruptionEnded(controller, shouldResume: true)
        #expect(controller.engine.state == .idle)
        #expect(!AppAudioSessionPolicy.isListeningActive)
    }

    @Test func unplugPausesButOtherRouteChangesDoNot() {
        let controller = startedController()

        controller.handleRouteChange(
            reasonRaw: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue)
        #expect(controller.engine.state == .playing)

        controller.handleRouteChange(
            reasonRaw: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue)
        #expect(controller.engine.state == .paused)
    }

    /// Listen to a second game while the first still plays (a list row's
    /// Listen, or Siri). The first session's teardown must run BEFORE the
    /// second's setup: run after it, it took the second game's artwork,
    /// listening posture, transport and interruption handling with it.
    @Test func aSecondGameKeepsItsOwnSetup() async throws {
        let liveActivity = LiveActivityRecorder()
        let controller = makeController(liveActivity)
        #expect(controller.listen(to: GameRecord(sgf: "(;GM[1]FF[4]SZ[9];B[cc];W[gg])",
                                                 currentIndex: 2, config: Config(),
                                                 name: "First")))
        #expect(controller.listen(to: GameRecord(sgf: "(;GM[1]FF[4]SZ[9];B[ee];W[cg];B[gc])",
                                                 currentIndex: 3, config: Config(),
                                                 name: "Second")))
        #expect(controller.engine.script?.gameName == "Second")
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] != nil)
        #expect(AppAudioSessionPolicy.isListeningActive)
        #expect(liveActivity.startedGameNames == ["First", "Second"])
        #expect(liveActivity.isUp)
        // The first game's card went as a stop, not a finish: it must not
        // linger beside the second's.
        #expect(liveActivity.endings == [false])

        // Through the notification this time, not a direct call: the
        // observer is what a phone call reaches.
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey:
                        AVAudioSession.InterruptionType.began.rawValue])
        for _ in 0..<50 where controller.engine.state != .paused {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(controller.engine.state == .paused)
    }

    @Test func unnarratableRecordIsRefused() {
        let liveActivity = LiveActivityRecorder()
        let controller = makeController(liveActivity)
        let record = GameRecord(sgf: "(;GM[1]SZ[9];B[cc];W[cc])",
                                config: Config(), name: "Refused")
        #expect(!controller.listen(to: record))
        #expect(controller.engine.state == .idle)
        #expect(liveActivity.startedGameNames.isEmpty)
    }

    // MARK: - Now Playing artwork (ADR 0014)

    /// Renders the artwork the lock screen would show, off the main thread —
    /// which is the only place the `@Sendable` requirement can be caught.
    private func lockScreenArtworkPNG(side: CGFloat = 512) async throws -> Data {
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        let artwork = try #require(info?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork,
                                   "a running session must publish artwork")
        nonisolated(unsafe) let requested = artwork
        let png: Data? = await withCheckedContinuation { continuation in
            // MediaPlayer calls the request handler on its OWN queue. A handler
            // that inherited MainActor isolation compiles clean and traps here.
            DispatchQueue.global(qos: .userInitiated).async {
                #expect(!Thread.isMainThread)
                continuation.resume(
                    returning: requested.image(at: CGSize(width: side, height: side))?.pngData())
            }
        }
        return try #require(png, "the artwork handler answered nil off-main")
    }

    /// The picture is a projection of the record (ADR 0014), so the SAME game
    /// yields the same bytes every session — nothing carried over from a
    /// screen capture, a stored column, or whichever game was open before.
    @Test func theArtworkIsDerivedFromTheRecord() async throws {
        let sgf = "(;GM[1]FF[4]SZ[9];B[cc];W[gg])"
        let first = makeController()
        #expect(first.listen(to: GameRecord(sgf: sgf, currentIndex: 2,
                                            config: Config(), name: "Derived")))
        let once = try await lockScreenArtworkPNG()
        first.endSession()

        let second = makeController()
        #expect(second.listen(to: GameRecord(sgf: sgf, currentIndex: 2,
                                             config: Config(), name: "Derived again")))
        let twice = try await lockScreenArtworkPNG()
        second.endSession()

        #expect(once == twice)
        #expect(!once.isEmpty)

        // …and an EMPTY board is a different picture, so the comparison above
        // is not two blanks agreeing. `currentIndex` defaults to 0, which is
        // exactly how a careless version of this test passes while proving
        // nothing.
        let unplayed = makeController()
        #expect(unplayed.listen(to: GameRecord(sgf: sgf, config: Config(), name: "Move zero")))
        let atTheStart = try await lockScreenArtworkPNG()
        unplayed.endSession()

        #expect(atTheStart != once)
    }

    /// The regression in one assertion: two games must not share a picture.
    /// The old capture path rendered whatever board was on screen, so opening
    /// B could hand A's session B's board.
    @Test func twoGamesDoNotShareOnePicture() async throws {
        let a = makeController()
        #expect(a.listen(to: GameRecord(sgf: "(;GM[1]FF[4]SZ[9];B[cc];W[gg])",
                                        currentIndex: 2, config: Config(), name: "Game A")))
        let pictureOfA = try await lockScreenArtworkPNG()
        a.endSession()

        let b = makeController()
        #expect(b.listen(to: GameRecord(sgf: "(;GM[1]FF[4]SZ[9];B[ee];W[cg];B[gc])",
                                        currentIndex: 3, config: Config(), name: "Game B")))
        let pictureOfB = try await lockScreenArtworkPNG()
        b.endSession()

        #expect(pictureOfA != pictureOfB)
    }

    /// Ending a session takes the card down with it — a stale board must not
    /// outlive the game it depicts on the lock screen. The Live Activity goes
    /// with it.
    @Test func endingTheSessionClearsTheCard() {
        let liveActivity = LiveActivityRecorder()
        let controller = makeController(liveActivity)
        #expect(controller.listen(to: GameRecord(sgf: "(;GM[1]FF[4]SZ[9];B[cc];W[gg])",
                                                 currentIndex: 2, config: Config(),
                                                 name: "Transient")))
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] != nil)
        #expect(liveActivity.startedGameNames == ["Transient"])
        #expect(liveActivity.isUp)

        controller.endSession()
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo == nil)
        #expect(!liveActivity.isUp)
        #expect(liveActivity.endings == [false])
    }
}

/// Stands in for ActivityKit, and remembers what the session asked of it.
@MainActor
private final class LiveActivityRecorder: ListeningLiveActivity {
    private(set) var startedGameNames: [String] = []
    private(set) var updates: [ListeningActivityAttributes.ContentState] = []
    /// One entry per end: whether the session finished rather than stopped.
    private(set) var endings: [Bool] = []
    private(set) var isUp = false

    func start(_ attributes: ListeningActivityAttributes,
               state: ListeningActivityAttributes.ContentState) {
        startedGameNames.append(attributes.gameName)
        isUp = true
    }

    func update(_ state: ListeningActivityAttributes.ContentState) {
        updates.append(state)
    }

    func end(_ state: ListeningActivityAttributes.ContentState, finished: Bool) {
        endings.append(finished)
        isUp = false
    }
}

/// Keeps the Listening Cursor in memory.
@MainActor
private final class InMemoryCursorStore: ListeningCursorStoring {
    private var cursors: [UUID: Int] = [:]
    var lastSessionGameID: UUID?

    func cursor(for gameID: UUID) -> Int? { cursors[gameID] }
    func storeCursor(_ moveNumber: Int, for gameID: UUID) { cursors[gameID] = moveNumber }
    func clearCursor(for gameID: UUID) { cursors[gameID] = nil }
}

/// The controllers the running test made.
@MainActor
private enum ListeningSessions {
    static var started: [ListeningSessionController] = []
}

/// Ends every session a test started once the test is over, however it
/// ends: one that throws halfway leaves nothing behind either. A session
/// sets up process-wide state (the listening audio posture, the Now Playing
/// card, the remote command targets, the interruption observers), and one
/// left playing goes on speaking through the tests after it.
///
/// Then checks that the listening posture and the Now Playing card are
/// clear. That catches a controller made outside `makeController` only
/// while its session is the last one running: ending any session clears
/// both.
///
/// A `TestTrait` too: Swift Testing hands a recursive suite trait to each
/// test as one, and traps while planning the run if it is not.
private struct EndsEveryListeningSession: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        let outcome: Result<Void, any Error>
        do {
            try await function()
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        await MainActor.run {
            ListeningSessions.started.forEach { $0.endSession() }
            ListeningSessions.started.removeAll()
            #expect(!AppAudioSessionPolicy.isListeningActive, "a session outlived its test")
            #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo == nil,
                    "a session outlived its test")
        }
        try outcome.get()
    }
}

extension Trait where Self == EndsEveryListeningSession {
    fileprivate static var endsEveryListeningSession: Self { Self() }
}
