//
//  EngineExitDispositionTests.swift
//  KataGo iOSTests
//
//  The engine can stop for two reasons, and the board must tell them apart: a
//  restart WE asked for (model switch, Max Board Size, Quit) is expected and
//  says nothing; anything else is a failure the user has to be told about.
//  Shared by the iOS/visionOS/tvOS thread-exit paths and the macOS `Process`
//  termination handler, so the rule lives in one pure function.
//

import Testing
@testable import KataGoUICore

struct EngineExitDispositionTests {

    /// A restart asked for it. Nothing is wrong, so nothing is reported —
    /// every restart path sets `stopRequested` before it sends `quit`.
    @Test func aRequestedStopIsExpected() {
        #expect(EngineExitDisposition.decide(fatalError: nil, stopWasRequested: true) == .expected)
    }

    /// Even a C++ fatal error is expected once WE asked the engine to go: the
    /// teardown races the exception seam, and a restart must not surface a
    /// failure the user did not cause.
    @Test func aRequestedStopStaysExpectedEvenWithAFatalError() {
        #expect(EngineExitDisposition.decide(fatalError: "std::bad_alloc",
                                             stopWasRequested: true) == .expected)
    }

    /// The engine died on its own. That is a failure, and the reason is what
    /// the status line shows.
    @Test func anUnrequestedExitWithAFatalErrorReportsThatReason() {
        #expect(EngineExitDisposition.decide(fatalError: "std::bad_alloc",
                                             stopWasRequested: false)
                == .failed(reason: "std::bad_alloc"))
    }

    /// A jetsam/OOM death is not a C++ exception, so nothing lands in
    /// `KataGoHelper.lastFatalError` — the disposition still has to say
    /// something, and it must not be blank.
    @Test func anUnrequestedExitWithNoReasonStillFails() {
        let disposition = EngineExitDisposition.decide(fatalError: nil, stopWasRequested: false)

        #expect(disposition == .failed(reason: "The engine stopped."))
        if case .failed(let reason) = disposition {
            #expect(!reason.isEmpty)
        } else {
            Issue.record("An unrequested exit must be a failure")
        }
    }

    /// The same default the message loop uses when a subprocess EOFs, so the
    /// two paths cannot drift apart.
    @Test func theDefaultReasonIsShared() {
        #expect(EngineExitDisposition.defaultReason == "The engine stopped.")
    }
}
