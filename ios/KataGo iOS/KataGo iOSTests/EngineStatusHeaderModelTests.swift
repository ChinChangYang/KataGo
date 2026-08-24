//
//  EngineStatusHeaderModelTests.swift
//  KataGo AnytimeTests
//
//  The remedy surface's engine-status header (ADR 0010): the words the
//  resting states show now that they no longer overlay the board. Pure model,
//  pinned strings.
//

import Testing
@testable import KataGoUICore

struct EngineStatusHeaderModelTests {

    private func make(availability: EngineAvailability,
                      isCompiling: Bool = false,
                      note: String? = nil,
                      actions: [EngineStatusAction] = [],
                      boardWidth: Int = 19,
                      boardHeight: Int = 19,
                      modelBoardCap: Int? = 37,
                      style: EngineStatusHeaderModel.HeldHintStyle = .iosBackendSettings) -> EngineStatusHeaderModel {
        EngineStatusHeaderModel.make(availability: availability,
                                     isCompiling: isCompiling,
                                     note: note,
                                     actions: actions,
                                     boardWidth: boardWidth,
                                     boardHeight: boardHeight,
                                     modelBoardCap: modelBoardCap,
                                     heldHintStyle: style)
    }

    @Test func aReadyEngineWithNothingToSayRendersNothing() {
        let model = make(availability: .ready)
        #expect(model.isEmpty)
    }

    @Test func aReadyEngineStillCarriesItsNote() {
        // The built-in-fallback message is true of a perfectly ready engine,
        // and this header is the only place it shows now.
        let model = make(availability: .ready, note: "X was removed — using the built-in network")
        #expect(!model.isEmpty)
        #expect(model.stateLine == nil)
        #expect(model.note == "X was removed — using the built-in network")
    }

    @Test func absentSaysNoModelChosen() {
        let model = make(availability: .absent)
        #expect(model.stateLine == "No model chosen")
        #expect(model.detail == nil)
        #expect(!model.showsRetry)
    }

    @Test func failedShowsTheReasonVerbatimAndRetryFollowsTheActions() {
        let model = make(availability: .failed(reason: "The engine did not answer in time."),
                         actions: [.retry, .chooseModel])
        #expect(model.stateLine == "Engine failed")
        #expect(model.detail == "The engine did not answer in time.")
        #expect(model.showsRetry)
    }

    @Test func aFailedLastLaunchOffersNoRetry() {
        // The crash-sentinel policy: `[.chooseModel]` only, so the header must
        // not invite a retry loop the controller deliberately withheld.
        let model = make(availability: .failed(reason: "The last launch did not finish loading X"),
                         actions: [.chooseModel])
        #expect(!model.showsRetry)
    }

    @Test func launchingShowsTheCompileCaptionOnlyWhileCompiling() {
        #expect(make(availability: .launching, isCompiling: true).detail == "Compiling Core ML model…")
        #expect(make(availability: .launching, isCompiling: false).detail == nil)
        #expect(make(availability: .launching).stateLine == "Loading engine…")
    }

    @Test func aRaisableHoldPointsAtMaxBoardSize() {
        // Board 21×21 on a 19 buffer, net cap 37: raising the setting fits.
        let model = make(availability: .held(maxBoardLength: 19),
                         boardWidth: 21, boardHeight: 21, modelBoardCap: 37)
        #expect(model.stateLine == "Board larger than Max Board Size 19")
        let hint = try! #require(model.heldHint)
        #expect(hint.contains("21×21"))
        #expect(hint.contains("raise Max Board Size"))
    }

    @Test func aCappedNetSaysSwitchInstead() {
        // Board 25×25 on a net whose own cap is 19: no setting can fix that.
        let model = make(availability: .held(maxBoardLength: 19),
                         boardWidth: 25, boardHeight: 25, modelBoardCap: 19)
        let hint = try! #require(model.heldHint)
        #expect(hint.contains("switch the neural net"))
        #expect(hint.contains("19×19"))
    }

    @Test func theHeldHintWordingFollowsThePlatform() {
        let ios = EngineStatusHeaderModel.heldHint(boardWidth: 21, boardHeight: 21,
                                                   maxBoardLength: 19, modelBoardCap: 37,
                                                   style: .iosBackendSettings)
        #expect(ios.contains("Backend Settings"))
        let mac = EngineStatusHeaderModel.heldHint(boardWidth: 21, boardHeight: 21,
                                                   maxBoardLength: 19, modelBoardCap: 37,
                                                   style: .macDetailPane)
        #expect(mac.contains("settings below"))
    }

    @Test func anUnknownCapReadsAsRaisable() {
        // Nil cap (no active model to ask): the optimistic wording, never a
        // dead-end "switch" instruction with nothing to switch to.
        let model = make(availability: .held(maxBoardLength: 19),
                         boardWidth: 25, boardHeight: 25, modelBoardCap: nil)
        #expect(try! #require(model.heldHint).contains("raise Max Board Size"))
    }
}
