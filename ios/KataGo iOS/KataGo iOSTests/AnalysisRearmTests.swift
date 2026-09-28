//
//  AnalysisRearmTests.swift
//  KataGo AnytimeTests
//
//  The continuous-analysis loop re-arms `kata-analyze` each time a request
//  resolves: the first `info` line after a request turns `waitingForAnalysis`
//  from true to false, and the host then calls `rearmOrStopAnalysis`.
//
//  Off must stop there, not re-arm. Turning analysis Off sends "stop", but a
//  request can still be in flight: the engine prints a line of it before it
//  reads that "stop", and the line resolves the request after the board is
//  already Off. A loop that re-armed on it streamed `kata-analyze` under an
//  "Analysis off" sparkle until the next move.
//
//  Each test resolves its request the way the engine does, with a streamed
//  line through `GameSession.maybeCollectAnalysis`.
//

import Testing
@testable import KataGoUICore

@MainActor
struct AnalysisRearmTests {
    private func makeSession() -> (GameSession, RecordingEngine) {
        let session = GameSession.accepting()
        let engine = RecordingEngine()
        session.useEngine(engine)
        return (session, engine)
    }

    /// Both sides human: no gen-move ever owns the engine, so every resolved
    /// request is the loop's to follow up.
    private func humanVsHuman() -> Config {
        Config(optionalBlackMaxTime: 0, optionalWhiteMaxTime: 0)
    }

    /// Feeds one streamed line, then does what the host does on the edge.
    /// Returns what the loop sent.
    private func resolveRequest(_ session: GameSession,
                                _ engine: RecordingEngine,
                                config: Config) async -> [String] {
        #expect(session.gobanState.waitingForAnalysis, "no request was in flight")
        let sentBefore = engine.sent.count
        await session.maybeCollectAnalysis(message: AnalyzeLineFixture.line())
        #expect(!session.gobanState.waitingForAnalysis, "the line did not resolve the request")
        session.gobanState.rearmOrStopAnalysis(config: config,
                                               nextColorForPlayCommand: .black,
                                               messageList: session.messageList)
        return Array(engine.sent.dropFirst(sentBefore))
    }

    @Test func aLateReplyToABoardThatIsOffStopsTheEngine() async {
        let (session, engine) = makeSession()
        let config = humanVsHuman()
        session.gobanState.requestAnalysis(config: config,
                                           messageList: session.messageList,
                                           nextColorForPlayCommand: .black)
        // Straight to Off before the engine answers, as the macOS Analysis
        // menu's Clear and the iOS AI-overwrite Cancel do.
        session.gobanState.analysisStatus = .clear

        #expect(await resolveRequest(session, engine, config: config) == ["stop"])
    }

    /// Pausing leaves a request pending on purpose, so its line can stop the
    /// stream. Off right after it must keep that line a stop.
    @Test func offRightAfterAPauseStillStops() async {
        let (session, engine) = makeSession()
        let config = humanVsHuman()
        session.gobanState.maybePauseAnalysis()
        session.gobanState.analysisStatus = .clear

        #expect(await resolveRequest(session, engine, config: config) == ["stop"])
    }

    @Test func aPausedBoardStops() async {
        let (session, engine) = makeSession()
        let config = humanVsHuman()
        session.gobanState.maybePauseAnalysis()

        #expect(await resolveRequest(session, engine, config: config) == ["stop"])
    }

    /// Power saving stops a running board: a human-vs-AI game, the overlay
    /// hidden, the human to move.
    @Test func aHiddenOverlayOnTheHumansTurnStops() async {
        let (session, engine) = makeSession()
        let config = Config(optionalBlackMaxTime: 0, optionalWhiteMaxTime: 2)
        session.gobanState.eyeStatus = .closed
        session.gobanState.maybeStopAnalysisForPowerSaving(config: config,
                                                          nextColorForPlayCommand: .black)

        #expect(await resolveRequest(session, engine, config: config) == ["stop"])
    }

    /// The positive control: the same edge on a running board re-arms, at the
    /// config's interval.
    @Test func aRunningBoardKeepsStreaming() async {
        let (session, engine) = makeSession()
        let config = humanVsHuman()
        session.gobanState.requestAnalysis(config: config,
                                           messageList: session.messageList,
                                           nextColorForPlayCommand: .black)

        #expect(await resolveRequest(session, engine, config: config)
                == GtpCommandBuilder.continuousAnalyzeCommands(
                    interval: config.analysisInterval, maxMoves: config.maxAnalysisMoves))
    }
}
