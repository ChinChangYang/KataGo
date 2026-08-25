//
//  ListeningSessionControllerTests.swift
//  KataGo AnytimeTests
//
//  Interruption and route-change handling, driven with the raw userInfo
//  values the notifications carry — the simulator cannot fake a phone call
//  or a CarPlay unplug, but the handlers are pure over these values.
//

import AVFoundation
import Testing
import KataGoUICore
@testable import KataGo_Anytime

@MainActor
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
}
