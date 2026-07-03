import Testing
import Foundation
@testable import KataGoGameStore

struct WatchSnapshotTests {
    static func makeSnapshot() -> WatchSnapshot {
        WatchSnapshot(
            boardWidth: 19, boardHeight: 19,
            blackStones: ["Q16", "D4"], whiteStones: ["D16"],
            toMove: "W", moveNumber: 3, analysisRunning: true,
            rootWinrateBlack: 0.62, rootScoreLeadBlack: 3.5,
            candidates: [
                .init(vertex: "Q3", winrate: 0.55, scoreLead: 2.1, visits: 312,
                      pv: ["Q3", "R4", "R3"]),
                .init(vertex: "C16", winrate: 0.52, scoreLead: 1.4, visits: 120, pv: []),
            ],
            hostTimestamp: Date(timeIntervalSince1970: 1_780_000_000))
    }

    @Test func roundTripPreservesAllFields() throws {
        let original = Self.makeSnapshot()
        let decoded = try WatchSnapshot.decode(original.encodedData())
        #expect(decoded == original)
    }

    @Test func positionKeyTracksStonesOnly() {
        var a = Self.makeSnapshot()
        var b = Self.makeSnapshot()
        b.rootWinrateBlack = 0.10          // analysis churn must NOT change the key
        b.candidates = []
        #expect(a.positionKey == b.positionKey)
        b.blackStones.append("K10")        // a new stone MUST change the key
        #expect(a.positionKey != b.positionKey)
        // Stone ORDER must not matter (GTP replay order can differ after undo/redo).
        a.blackStones = ["D4", "Q16"]
        #expect(a.positionKey == Self.makeSnapshot().positionKey)
    }

    @Test func fullBoardPayloadStaysSmall() throws {
        // Worst realistic case: 19x19 midgame, 10 candidates with 6-deep PVs.
        var s = Self.makeSnapshot()
        s.blackStones = (1...19).flatMap { r in ["A\(r)", "B\(r)"] }        // 38 stones
        s.whiteStones = (1...19).flatMap { r in ["C\(r)", "D\(r)"] }        // 38 stones
        s.candidates = (0..<10).map { i in
            .init(vertex: "Q\(i + 1)", winrate: 0.5, scoreLead: 0.1, visits: 1_000,
                  pv: ["Q16", "D4", "D16", "Q4", "K10", "C3"])
        }
        let bytes = try s.encodedData().count
        #expect(bytes < 16_384, "payload was \(bytes) bytes")
    }

    @Test func stalenessRule() {
        let t0 = Date(timeIntervalSince1970: 1_780_000_000)
        #expect(WatchSnapshot.isStale(receivedAt: nil, now: t0, threshold: 10))
        #expect(!WatchSnapshot.isStale(receivedAt: t0, now: t0 + 9, threshold: 10))
        #expect(WatchSnapshot.isStale(receivedAt: t0, now: t0 + 11, threshold: 10))
    }
}
