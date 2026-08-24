//
//  GameSessionReportModeTests.swift
//  KataGo AnytimeTests
//

import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

@MainActor
struct GameSessionReportModeTests {
    private let infoLine = AnalyzeLineFixture.line()

    @Test func reportModeBypassesLiveAnalysis() async {
        let session = GameSession.accepting()
        session.board.width = 19
        session.board.height = 19
        session.gobanState.reportGenerationActive = true
        session.gobanState.waitingForAnalysis = true   // must NOT be cleared mid-report

        await session.maybeCollectAnalysis(message: infoLine)

        #expect(session.analysis.info.isEmpty)
        #expect(session.gobanState.waitingForAnalysis == true)
    }

    @Test func normalModeStillCollects() async {
        let session = GameSession.accepting()
        session.board.width = 19
        session.board.height = 19
        session.gobanState.waitingForAnalysis = true

        await session.maybeCollectAnalysis(message: infoLine)

        #expect(!session.analysis.info.isEmpty)
        #expect(session.gobanState.waitingForAnalysis == false)
    }
}
