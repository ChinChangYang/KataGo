import Testing
import Foundation
@testable import KataGoGameStore

// @MainActor because WatchPeekBuffer is @MainActor (it feeds SwiftUI directly).
@MainActor
struct WatchPeekBufferTests {
    static func snap(black: [String], white: [String], move: Int) -> WatchSnapshot {
        WatchSnapshot(boardWidth: 9, boardHeight: 9, blackStones: black, whiteStones: white,
                      toMove: "B", moveNumber: move, analysisRunning: true,
                      rootWinrateBlack: 0.5, rootScoreLeadBlack: 0, candidates: [],
                      hostTimestamp: Date(timeIntervalSince1970: 1_780_000_000))
    }

    @Test func ingestAppendsOnlyDistinctPositionsAndTracksLive() {
        let buffer = WatchPeekBuffer()
        buffer.ingest(Self.snap(black: ["C3"], white: [], move: 1))
        buffer.ingest(Self.snap(black: ["C3"], white: [], move: 1))      // analysis churn, same position
        buffer.ingest(Self.snap(black: ["C3"], white: ["G7"], move: 2))
        #expect(buffer.entries.count == 2)
        #expect(buffer.isLive)
        #expect(buffer.viewIndex == 1)

        buffer.viewIndex = 0                                             // scrub back
        #expect(!buffer.isLive)
        #expect(buffer.movesBehindLive == 1)
        #expect(buffer.current?.moveNumber == 1)

        // A NEW live frame while scrubbed back must append without yanking the view.
        buffer.ingest(Self.snap(black: ["C3", "E5"], white: ["G7"], move: 3))
        #expect(buffer.entries.count == 3)
        #expect(buffer.viewIndex == 0)
        // Returning to live re-pins: subsequent ingests follow again.
        buffer.viewIndex = buffer.entries.count - 1
        buffer.ingest(Self.snap(black: ["C3", "E5", "E3"], white: ["G7"], move: 4))
        #expect(buffer.isLive && buffer.current?.moveNumber == 4)
    }

    @Test func capacityDropsOldest() {
        let buffer = WatchPeekBuffer()
        for i in 1...(WatchPeekBuffer.capacity + 10) {
            buffer.ingest(Self.snap(black: (1...i).map { "A\(($0 % 9) + 1)" + "\($0)" },
                                    white: [], move: i))
        }
        #expect(buffer.entries.count == WatchPeekBuffer.capacity)
        #expect(buffer.entries.first?.moveNumber == 11)
    }

    @Test func lastMoveVertexIsTheSingleAddedStone() {
        let a = Self.snap(black: ["C3"], white: [], move: 1)
        let b = Self.snap(black: ["C3"], white: ["G7"], move: 2)
        #expect(WatchPeekBuffer.lastMoveVertex(previous: a, current: b) == "G7")
        #expect(WatchPeekBuffer.lastMoveVertex(previous: nil, current: a) == nil)
        // Capture (stone count change ≠ +1) yields nil rather than a wrong ring.
        let c = Self.snap(black: [], white: ["G7", "C4"], move: 3)
        #expect(WatchPeekBuffer.lastMoveVertex(previous: b, current: c) == nil)
    }
}
