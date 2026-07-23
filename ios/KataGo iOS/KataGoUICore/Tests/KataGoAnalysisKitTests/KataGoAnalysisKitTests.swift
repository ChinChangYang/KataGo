//
//  KataGoAnalysisKitTests.swift
//  KataGoAnalysisKitTests
//
//  Standalone (engine-free) tests for the Safari-extension analysis tier:
//  the JS↔native wire schema (decoded from raw JSON exactly as the browser
//  sends it), the outward-from-center sweep scheduler, the seq-numbered
//  delivery outbox, and the perspective math. Runs via
//  `swift test --filter KataGoAnalysisKitTests` like GoRulesKitTests.
//

import Foundation
import Testing
@testable import KataGoAnalysisKit

private func decodeRequest(_ json: String) throws -> AnalysisRequest {
    let dictionary = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    return try AnalysisWireCoding.request(fromDictionary: dictionary)
}

struct AnalysisWireRequestTests {
    @Test func startDecodesWithExplicitFields() throws {
        let request = try decodeRequest(
            #"{"cmd":"start","sgf":"(;GM[1])","sgfHash":"abc","currentMoveIndex":42,"budget":"deep"}"#)
        #expect(request == .start(sgf: "(;GM[1])", sgfHash: "abc",
                                  currentMoveIndex: 42, budget: .deep))
    }

    @Test func startAppliesDefaultsForOptionalFields() throws {
        let request = try decodeRequest(#"{"cmd":"start","sgf":"(;)","sgfHash":"h"}"#)
        #expect(request == .start(sgf: "(;)", sgfHash: "h",
                                  currentMoveIndex: 0, budget: .normal))
    }

    @Test func queryMapsWantArrayToOwnershipFlag() throws {
        let with = try decodeRequest(
            #"{"cmd":"query","gameId":"g","moveIndex":7,"want":["candidates","ownership"]}"#)
        #expect(with == .query(gameId: "g", moveIndex: 7,
                               wantOwnership: true, budget: .normal))
        let without = try decodeRequest(
            #"{"cmd":"query","gameId":"g","moveIndex":7,"want":["candidates"]}"#)
        #expect(without == .query(gameId: "g", moveIndex: 7,
                                  wantOwnership: false, budget: .normal))
    }

    @Test(arguments: [
        (#"{"cmd":"poll","gameId":"g","sinceSeq":118}"#,
         AnalysisRequest.poll(gameId: "g", sinceSeq: 118)),
        (#"{"cmd":"navigate","gameId":"g","moveIndex":57}"#,
         AnalysisRequest.navigate(gameId: "g", moveIndex: 57)),
        (#"{"cmd":"stop","gameId":"g"}"#, AnalysisRequest.stop(gameId: "g")),
        (#"{"cmd":"ping"}"#, AnalysisRequest.ping),
        (#"{"cmd":"openInApp","sgf":"(;)"}"#, AnalysisRequest.openInApp(sgf: "(;)")),
    ])
    func simpleCommandsDecode(json: String, expected: AnalysisRequest) throws {
        #expect(try decodeRequest(json) == expected)
    }

    @Test func unknownCmdThrows() {
        #expect(throws: DecodingError.self) {
            try decodeRequest(#"{"cmd":"selfDestruct"}"#)
        }
    }

    @Test func requestRoundTripsThroughEncoder() throws {
        let original = AnalysisRequest.query(gameId: "g", moveIndex: 3,
                                             wantOwnership: true, budget: .fast)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnalysisRequest.self, from: data)
        #expect(decoded == original)
    }
}

struct AnalysisWireResponseTests {
    @Test func resultsEncodesDiscriminatorAndNestedSweep() throws {
        let move = MoveAnalysis(
            moveIndex: 57, phase: .sweep, toMove: "b", visits: 152,
            winrateB: 0.483, scoreLeadB: -1.2,
            candidates: [Candidate(move: "Q16", visits: 90, winrateB: 0.49,
                                   scoreLeadB: -0.8, utilityLcb: 0.31,
                                   order: 0, pv: ["Q16", "D4"])],
            played: PlayedAssessment(move: "R14", winrateDrop: 0.06))
        let dictionary = try AnalysisWireCoding.dictionary(
            from: .results(gameId: "g", nextSeq: 131, sweepDone: 118,
                           sweepTotal: 231, moves: [move]))
        #expect(dictionary["type"] as? String == "results")
        let sweep = try #require(dictionary["sweep"] as? [String: Any])
        #expect(sweep["done"] as? Int == 118)
        #expect(sweep["total"] as? Int == 231)
        let moves = try #require(dictionary["moves"] as? [[String: Any]])
        #expect(moves.count == 1)
        #expect(moves[0]["moveIndex"] as? Int == 57)
        // Absent optionals must be omitted, not null (JS truthiness checks).
        #expect(moves[0]["ownership"] == nil)
    }

    @Test func ownershipCellsRoundTripInsideResults() throws {
        let move = MoveAnalysis(
            moveIndex: 3, phase: .deepen, toMove: "w", visits: 800,
            winrateB: 0.5, scoreLeadB: 0, candidates: [],
            ownership: [OwnershipCell(x: 2, y: 16, whiteness: 0.8,
                                      scale: 0.39, opacity: 0.72)])
        let dictionary = try AnalysisWireCoding.dictionary(
            from: .results(gameId: "g", nextSeq: 1, sweepDone: 1,
                           sweepTotal: 4, moves: [move]))
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        let decoded = try JSONDecoder().decode(AnalysisResponse.self, from: data)
        guard case let .results(_, _, _, _, moves) = decoded else {
            Issue.record("expected results")
            return
        }
        #expect(moves[0].ownership?.count == 1)
        #expect(moves[0].ownership?[0].y == 16)
        #expect(moves[0].ownership?[0].whiteness == 0.8)
    }

    @Test func errorRoundTrips() throws {
        let original = AnalysisResponse.error(code: .warmingUp,
                                              message: "compiling CoreML model",
                                              retryable: true)
        let dictionary = try AnalysisWireCoding.dictionary(from: original)
        #expect(dictionary["code"] as? String == "warmingUp")
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        let decoded = try JSONDecoder().decode(AnalysisResponse.self, from: data)
        #expect(decoded == original)
    }

    @Test func gameAcceptedRoundTripsWithOptionalsAbsent() throws {
        let original = AnalysisResponse.gameAccepted(
            gameId: "g", boardWidth: 19, boardHeight: 19, moveCount: 231,
            komi: nil, rules: nil, cached: false)
        let dictionary = try AnalysisWireCoding.dictionary(from: original)
        #expect(dictionary["komi"] == nil)
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        #expect(try JSONDecoder().decode(AnalysisResponse.self, from: data) == original)
    }
}

struct SweepPlannerTests {
    @Test func sweepsOutwardFromCenter() {
        var planner = SweepPlanner(moveCount: 6, currentIndex: 3)
        var order: [Int] = []
        while let next = planner.nextIndex() {
            order.append(next)
            planner.markCompleted(next)
        }
        #expect(order == [3, 4, 2, 5, 1, 6, 0])
        #expect(planner.isComplete)
        #expect(planner.done == 7)
        #expect(planner.total == 7)
    }

    @Test func recenterBiasesRemainingWork() {
        var planner = SweepPlanner(moveCount: 10, currentIndex: 0)
        for _ in 0..<3 {
            let next = planner.nextIndex()!
            planner.markCompleted(next)
        }
        planner.recenter(on: 8)
        #expect(planner.nextIndex() == 8)
        planner.markCompleted(8)
        #expect(planner.nextIndex() == 9)
    }

    @Test func centerClampsToValidRange() {
        var planner = SweepPlanner(moveCount: 5, currentIndex: 99)
        #expect(planner.nextIndex() == 5)
        planner.recenter(on: -7)
        #expect(planner.nextIndex() == 0)
    }

    @Test func emptyGameHasSinglePosition() {
        var planner = SweepPlanner(moveCount: 0, currentIndex: 0)
        #expect(planner.total == 1)
        #expect(planner.nextIndex() == 0)
        planner.markCompleted(0)
        #expect(planner.nextIndex() == nil)
        #expect(planner.isComplete)
    }

    @Test func markCompletedIgnoresOutOfRangeIndices() {
        var planner = SweepPlanner(moveCount: 2, currentIndex: 1)
        planner.markCompleted(-1)
        planner.markCompleted(3)
        #expect(planner.done == 0)
    }
}

struct AnalysisOutboxTests {
    private func makeMove(_ index: Int) -> MoveAnalysis {
        MoveAnalysis(moveIndex: index, phase: .sweep, toMove: "b", visits: 100,
                     winrateB: 0.5, scoreLeadB: 0, candidates: [])
    }

    @Test func seqsAreStrictlyIncreasingFromOne() {
        var outbox = AnalysisOutbox()
        let first = outbox.append(makeMove(0))
        let second = outbox.append(makeMove(1))
        #expect(first.seq == 1)
        #expect(second.seq == 2)
        #expect(outbox.lastSeq == 2)
    }

    @Test func drainAfterSeqReturnsOnlyUnseen() {
        var outbox = AnalysisOutbox()
        for index in 0..<5 { outbox.append(makeMove(index)) }
        let unseen = outbox.entries(after: 3)
        #expect(unseen.map(\.seq) == [4, 5])
        #expect(outbox.entries(after: 5).isEmpty)
        // A lost reply is recoverable: draining from an older seq re-delivers.
        #expect(outbox.entries(after: 0).count == 5)
    }

    @Test func latestForMoveIndexPrefersNewestEntry() {
        var outbox = AnalysisOutbox()
        outbox.append(makeMove(4))
        var deepened = makeMove(4)
        deepened.phase = .deepen
        deepened.visits = 800
        outbox.append(deepened)
        let latest = outbox.latest(forMoveIndex: 4)
        #expect(latest?.phase == .deepen)
        #expect(latest?.visits == 800)
        #expect(outbox.latest(forMoveIndex: 9) == nil)
    }
}

struct AnalysisMathTests {
    @Test func blackPerspectiveFlipsOnlyForWhite() {
        #expect(AnalysisMath.blackWinrate(0.7, toMove: .black) == 0.7)
        #expect(abs(AnalysisMath.blackWinrate(0.7, toMove: .white) - 0.3) < 1e-6)
        #expect(AnalysisMath.blackScoreLead(2.5, toMove: .black) == 2.5)
        #expect(AnalysisMath.blackScoreLead(2.5, toMove: .white) == -2.5)
    }

    @Test func winrateDropIsMoverPerspective() {
        // Black played and Black's winrate fell 0.60 → 0.48: drop 0.12.
        #expect(abs(AnalysisMath.winrateDrop(beforeB: 0.60, afterB: 0.48,
                                             mover: .black) - 0.12) < 1e-6)
        // White played and Black's winrate ROSE 0.48 → 0.60: White dropped 0.12.
        #expect(abs(AnalysisMath.winrateDrop(beforeB: 0.48, afterB: 0.60,
                                             mover: .white) - 0.12) < 1e-6)
        // A good move by the mover is a negative drop.
        #expect(AnalysisMath.winrateDrop(beforeB: 0.5, afterB: 0.6, mover: .black) < 0)
    }
}
