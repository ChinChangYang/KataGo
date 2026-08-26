//
//  ListeningSessionControllerTests.swift
//  KataGo AnytimeTests
//
//  Interruption and route-change handling, driven with the raw userInfo
//  values the notifications carry — the simulator cannot fake a phone call
//  or a CarPlay unplug, but the handlers are pure over these values.
//
//  The same applies to the Now Playing artwork below: the simulator finishes a
//  whole script in seconds with no audio device, so the lock-screen card never
//  survives long enough to photograph. `MPNowPlayingInfoCenter` is what that
//  card reads, and it is readable right here.
//
//  Serialized because that info center is PROCESS-GLOBAL: `listen(to:)` writes
//  it, so two of these running at once would each read the other's session.
//

import AVFoundation
import Foundation
import MediaPlayer
import Testing
import KataGoUICore
@testable import KataGo_Anytime

@MainActor
@Suite(.serialized)
struct ListeningSessionControllerTests {
    private func startedController() -> ListeningSessionController {
        let controller = ListeningSessionController()
        let record = GameRecord(sgf: "(;GM[1]FF[4]SZ[9];B[cc];W[gg])",
                                config: Config(), name: "Interrupted")
        #expect(controller.listen(to: record))
        return controller
    }

    @Test func interruptionBeganPausesTheSession() {
        let controller = startedController()
        #expect(controller.engine.state == .playing)

        controller.handleInterruption(
            typeRaw: AVAudioSession.InterruptionType.began.rawValue, optionsRaw: nil)
        #expect(controller.engine.state == .paused)
    }

    @Test func interruptionEndedWithShouldResumeResumes() {
        let controller = startedController()
        controller.handleInterruption(
            typeRaw: AVAudioSession.InterruptionType.began.rawValue, optionsRaw: nil)
        #expect(controller.engine.state == .paused)

        controller.handleInterruption(
            typeRaw: AVAudioSession.InterruptionType.ended.rawValue,
            optionsRaw: AVAudioSession.InterruptionOptions.shouldResume.rawValue)
        #expect(controller.engine.state == .playing)
    }

    @Test func interruptionEndedWithoutShouldResumeStaysPaused() {
        let controller = startedController()
        controller.handleInterruption(
            typeRaw: AVAudioSession.InterruptionType.began.rawValue, optionsRaw: nil)

        controller.handleInterruption(
            typeRaw: AVAudioSession.InterruptionType.ended.rawValue, optionsRaw: 0)
        #expect(controller.engine.state == .paused)
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

    @Test func unnarratableRecordIsRefused() {
        let controller = ListeningSessionController()
        let record = GameRecord(sgf: "(;GM[1]SZ[9];B[cc];W[cc])",
                                config: Config(), name: "Refused")
        #expect(!controller.listen(to: record))
        #expect(controller.engine.state == .idle)
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
        let first = ListeningSessionController()
        #expect(first.listen(to: GameRecord(sgf: sgf, currentIndex: 2,
                                            config: Config(), name: "Derived")))
        let once = try await lockScreenArtworkPNG()
        first.endSession()

        let second = ListeningSessionController()
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
        let unplayed = ListeningSessionController()
        #expect(unplayed.listen(to: GameRecord(sgf: sgf, config: Config(), name: "Move zero")))
        let atTheStart = try await lockScreenArtworkPNG()
        unplayed.endSession()

        #expect(atTheStart != once)
    }

    /// The regression in one assertion: two games must not share a picture.
    /// The old capture path rendered whatever board was on screen, so opening
    /// B could hand A's session B's board.
    @Test func twoGamesDoNotShareOnePicture() async throws {
        let a = ListeningSessionController()
        #expect(a.listen(to: GameRecord(sgf: "(;GM[1]FF[4]SZ[9];B[cc];W[gg])",
                                        currentIndex: 2, config: Config(), name: "Game A")))
        let pictureOfA = try await lockScreenArtworkPNG()
        a.endSession()

        let b = ListeningSessionController()
        #expect(b.listen(to: GameRecord(sgf: "(;GM[1]FF[4]SZ[9];B[ee];W[cg];B[gc])",
                                        currentIndex: 3, config: Config(), name: "Game B")))
        let pictureOfB = try await lockScreenArtworkPNG()
        b.endSession()

        #expect(pictureOfA != pictureOfB)
    }

    /// Ending a session takes the card down with it — a stale board must not
    /// outlive the game it depicts on the lock screen.
    @Test func endingTheSessionClearsTheCard() {
        let controller = ListeningSessionController()
        #expect(controller.listen(to: GameRecord(sgf: "(;GM[1]FF[4]SZ[9];B[cc];W[gg])",
                                                 currentIndex: 2, config: Config(),
                                                 name: "Transient")))
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] != nil)

        controller.endSession()
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo == nil)
    }
}
