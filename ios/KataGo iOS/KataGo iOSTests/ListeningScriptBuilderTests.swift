//
//  ListeningScriptBuilderTests.swift
//  KataGo AnytimeTests
//
//  Offline. The builder is pure over a GameRecord constructed in-memory —
//  no engine, no bridge, no model container.
//

import Testing
import KataGoUICore

@MainActor
struct ListeningScriptBuilderTests {
    private func record(sgf: String,
                        comments: [Int: String] = [:],
                        winRates: [Int: Float] = [:],
                        scoreLeads: [Int: Float] = [:],
                        bestMoves: [Int: String] = [:]) -> GameRecord {
        GameRecord(sgf: sgf, config: Config(), name: "Test Game",
                   comments: comments, scoreLeads: scoreLeads,
                   bestMoves: bestMoves, winRates: winRates)
    }

    private let twoMoves = "(;GM[1]FF[4]SZ[9];B[cc];W[gg])"

    @Test func bareCallsForAnUnanalyzedGame() {
        let script = ListeningScriptBuilder.script(for: record(sgf: twoMoves))
        #expect(script?.cues.map(\.text) == ["Black plays C7.", "White plays G3."])
        #expect(script?.cues.allSatisfy { $0.source == .bareCall } == true)
        #expect(script?.cues.allSatisfy { !$0.playsCaptureSound } == true)
    }

    @Test func introNamesTheGame() {
        let script = ListeningScriptBuilder.script(for: record(sgf: twoMoves))
        #expect(script?.intro == "Listening to Test Game.")
        #expect(script?.gameName == "Test Game")
    }

    @Test func savedCommentSpeaksVerbatimBehindATerseCall() {
        let script = ListeningScriptBuilder.script(
            for: record(sgf: twoMoves, comments: [2: "  Nice shape.  "]))
        #expect(script?.cues[1].text == "White plays G3. Nice shape.")
        #expect(script?.cues[1].source == .comment)
    }

    @Test func analyzedMoveComposesTheRegisterSentence() {
        let script = ListeningScriptBuilder.script(
            for: record(sgf: twoMoves,
                        winRates: [0: 0.5, 1: 0.6],
                        scoreLeads: [1: 2.0],
                        bestMoves: [0: "C7"]))
        #expect(script?.cues[0].text ==
            "Black number 1 plays a stone at C7. Black win rate is 60%, increased by 10% from 50%. Black leads by 2.0 points. KataGo agrees with this move.")
        #expect(script?.cues[0].source == .commentary)
    }

    @Test func disagreementNamesTheRecommendedMove() {
        let script = ListeningScriptBuilder.script(
            for: record(sgf: twoMoves, bestMoves: [0: "D5"]))
        #expect(script?.cues[0].text.contains("KataGo recommended D5 instead.") == true)
    }

    @Test func passIsCalledAsAPass() {
        let script = ListeningScriptBuilder.script(for: record(sgf: "(;GM[1]SZ[9];B[cc];W[])"))
        #expect(script?.cues[1].text == "White passes.")
    }

    @Test func captureFlagsComeFromTheReplayNotTheRecord() {
        // B A4, W A5, B B5 — Black's third move captures the corner stone.
        let script = ListeningScriptBuilder.script(for: record(sgf: "(;GM[1]SZ[5];B[ab];W[aa];B[ba])"))
        #expect(script?.cues.map(\.playsCaptureSound) == [false, false, true])
    }

    @Test func recordedResultBeatsTheEstimate() {
        let script = ListeningScriptBuilder.script(
            for: record(sgf: "(;GM[1]SZ[9]RE[B+2.5];B[cc];W[gg])", scoreLeads: [2: -3.5]))
        #expect(script?.resultAnnouncement == "Black wins by 2.5. End of game.")
    }

    @Test func finalScoreLeadEstimatesTheResult() {
        let script = ListeningScriptBuilder.script(
            for: record(sgf: twoMoves, scoreLeads: [2: -3.5]))
        #expect(script?.resultAnnouncement == "Black is behind by 3.5 points. End of game after 2 moves.")
        #expect(script?.finalScoreLeadBlack == -3.5)
    }

    @Test func noDataFallsBackToTheMoveCount() {
        let script = ListeningScriptBuilder.script(for: record(sgf: twoMoves))
        #expect(script?.resultAnnouncement == "End of game after 2 moves.")
    }

    @Test func emptyGameHasNoCuesAndSaysSo() {
        let script = ListeningScriptBuilder.script(for: record(sgf: "(;GM[1]SZ[9])"))
        #expect(script?.cues.isEmpty == true)
        #expect(script?.resultAnnouncement == "This game has no moves yet.")
    }

    @Test func refusedMoveGatesTheGameUnlistenable() {
        // White plays on an occupied point: the replay refuses it, and a
        // record the rules refuse is not listenable (the watch's gate).
        let script = ListeningScriptBuilder.script(for: record(sgf: "(;GM[1]SZ[9];B[cc];W[cc])"))
        #expect(script == nil)
    }

    @Test func noSgfMainlineMeansNoScript() {
        #expect(ListeningScriptBuilder.script(for: record(sgf: "not sgf")) == nil)
    }
}
