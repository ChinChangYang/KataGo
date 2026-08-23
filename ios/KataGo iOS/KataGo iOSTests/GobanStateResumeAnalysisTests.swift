//
//  GobanStateResumeAnalysisTests.swift
//  KataGo iOSTests
//
//  Pins resumeAnalysisAfterReport: the Deep Report leaves the engine idle
//  (its restore doesn't re-arm), and on dismissal analysis is re-armed only
//  when it was running (.run) — reviving live analysis and a human-vs-AI
//  opponent — and left idle when paused/off. The report never changes
//  analysisStatus, so the status here is what it was when the report opened.
//

import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

@MainActor
struct GobanStateResumeAnalysisTests {

    @MainActor
    private func makeSession() -> (GameSession, ReportProbeEngine) {
        let session = GameSession.accepting()
        let engine = ReportProbeEngine()
        session.useEngine(engine)
        session.board.width = 2
        session.board.height = 2
        return (session, engine)
    }

    @Test func resumesWhenAnalysisRunning() {
        let (session, engine) = makeSession()
        session.gobanState.analysisStatus = .run
        session.gobanState.resumeAnalysisAfterReport(
            config: Config(), nextColorForPlayCommand: nil, messageList: session.messageList)
        #expect(engine.sent.contains { $0.hasPrefix("kata-analyze") })
    }

    @Test func doesNotResumeWhenPaused() {
        let (session, engine) = makeSession()
        session.gobanState.analysisStatus = .pause
        session.gobanState.resumeAnalysisAfterReport(
            config: Config(), nextColorForPlayCommand: nil, messageList: session.messageList)
        #expect(engine.sent.allSatisfy { !$0.hasPrefix("kata-analyze") && !$0.hasPrefix("kata-search") })
    }

    @Test func doesNotResumeWhenCleared() {
        let (session, engine) = makeSession()
        session.gobanState.analysisStatus = .clear
        session.gobanState.resumeAnalysisAfterReport(
            config: Config(), nextColorForPlayCommand: nil, messageList: session.messageList)
        #expect(engine.sent.isEmpty)
    }
}
