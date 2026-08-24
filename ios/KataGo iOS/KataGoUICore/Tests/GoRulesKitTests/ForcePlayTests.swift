//
//  ForcePlayTests.swift
//  GoRulesKitTests
//
//  Force-play is the rules layer for HYPOTHETICAL lines — an engine principal
//  variation, a broadcast beat's acted-out stones. It refuses nothing, so these
//  tests pin the two halves of that promise: every liberty-less group comes off
//  (including the played stone's own), and the cases GoBoard.play would throw on
//  degrade to a skip or a no-op instead of a refusal.
//

import Foundation
import Testing
@testable import GoRulesKit
import KataGoGameStore

struct ForcePlayTests {

    // MARK: - Helpers

    private func resolve(width: Int = 9, height: Int = 9,
                         black: [String] = [], white: [String] = [],
                         _ moves: [(String, GoColor)]) -> ForcePlayResult? {
        ForcePlay.resolve(width: width, height: height,
                          setupBlack: black, setupWhite: white,
                          moves: moves.map { ForcePlayMove(vertex: $0.0, color: $0.1) })
    }

    private func color(_ board: GoBoard, _ vertex: String) -> GoColor? {
        guard let parsed = parseVertex(vertex, width: board.width, height: board.height) else { return nil }
        return board.color(at: GoPoint(x: parsed.x, y: parsed.y))
    }

    // MARK: - Captures

    @Test("A variation move captures the base stones it surrounds")
    func capturesBaseStones() throws {
        // White A9's liberties are B9 (Black already) and A8.
        let result = try #require(resolve(black: ["B9"], white: ["A9"], [("A8", .black)]))
        #expect(result.dispositions.count == 1)
        #expect(color(result.board, "A9") == .empty)
        #expect(color(result.board, "A8") == .black)
        #expect(result.skippedCount == 0)
    }

    @Test("A variation move captures a stone the variation itself played")
    func capturesVariationStones() throws {
        // Black D3 takes White C3, then White retakes at C3 and Black's D3 —
        // a stone this same line placed — comes off with it.
        let result = try #require(resolve(width: 5, height: 5,
                                          black: ["C4", "B3", "C2"],
                                          white: ["C3", "D4", "E3", "D2"],
                                          [("D3", .black), ("C3", .white)]))
        #expect(color(result.board, "D3") == .empty)
        #expect(color(result.board, "C3") == .white)
    }

    // MARK: - What GoBoard.play would refuse

    @Test("Ko is never consulted, so an immediate recapture just happens")
    func koRecaptureIsAccepted() throws {
        let result = try #require(resolve(width: 5, height: 5,
                                          black: ["C4", "B3", "C2"],
                                          white: ["C3", "D4", "E3", "D2"],
                                          [("D3", .black), ("C3", .white)]))
        // GoBoard.play throws .simpleKoBanned on the second move; force-play
        // places it, because the engine that proposed the line already vetted it.
        for disposition in result.dispositions {
            guard case .placed = disposition else {
                Issue.record("ko recapture was refused: \(disposition)")
                return
            }
        }
    }

    @Test("Single-stone suicide is an ordinary capture of your own stone")
    func singleStoneSuicideSelfRemoves() throws {
        // A9's only neighbours are B9 and A8, both White and both alive.
        let result = try #require(resolve(white: ["B9", "A8"], [("A9", .black)]))
        #expect(result.dispositions == [.placed(GoPoint(x: 0, y: 0))])
        #expect(color(result.board, "A9") == .empty)   // placed, then lifted
        #expect(color(result.board, "B9") == .white)
        #expect(result.skippedCount == 0)             // a self-capture is not a skip
    }

    @Test("Multi-stone suicide lifts the whole group, exactly like the single case")
    func multiStoneSuicideSelfRemoves() throws {
        let result = try #require(resolve(white: ["C9", "A8", "B8"],
                                          [("A9", .black), ("B9", .black)]))
        #expect(color(result.board, "A9") == .empty)
        #expect(color(result.board, "B9") == .empty)
        #expect(color(result.board, "C9") == .white)
    }

    @Test("The opponent's groups die first, so a capture can save the played stone")
    func opponentCapturesResolveBeforeSelfCapture() throws {
        // Black B9 would have no liberties of its own, but it takes White A9
        // first and inherits that point as a liberty.
        let result = try #require(resolve(black: ["A8", "C9"], white: ["A9", "B8"],
                                          [("B9", .black)]))
        #expect(color(result.board, "A9") == .empty)
        #expect(color(result.board, "B9") == .black)
    }

    // MARK: - Nothing is refused

    @Test("A point already holding this color is a no-op that still owns its number")
    func occupiedBySameColorIsANoOp() throws {
        let result = try #require(resolve(black: ["E3"], [("E3", .black)]))
        #expect(result.dispositions == [.alreadyThere(GoPoint(x: 4, y: 6))])
        #expect(result.skippedCount == 0)
        #expect(color(result.board, "E3") == .black)
    }

    @Test("A point holding the other color is skipped, never overwritten")
    func occupiedByOpponentIsSkipped() throws {
        let result = try #require(resolve(white: ["E3"], [("E3", .black), ("G7", .white)]))
        #expect(result.dispositions.first?.isSkipped == true)
        #expect(result.skippedCount == 1)
        #expect(color(result.board, "E3") == .white)   // the live stone stays
        #expect(color(result.board, "G7") == .white)   // and the line continues
    }

    @Test("A vertex naming no intersection is skipped, and the line continues")
    func offBoardVertexIsSkipped() throws {
        let result = try #require(resolve([("T19", .black), ("E5", .white)]))
        #expect(result.dispositions.first == .skippedUnplaceable)
        #expect(result.skippedCount == 1)
        #expect(color(result.board, "E5") == .white)
    }

    @Test("A pass places nothing and skips nothing")
    func passPlacesNothing() throws {
        let result = try #require(resolve([("pass", .black), ("PASS", .white), ("E5", .black)]))
        #expect(result.dispositions[0] == .passed)
        #expect(result.dispositions[1] == .passed)
        #expect(result.skippedCount == 0)
        #expect(color(result.board, "E5") == .black)
    }

    @Test("A degenerate board size returns nil rather than trapping")
    func degenerateBoardReturnsNil() {
        #expect(resolve(width: 0, height: 9, [("E5", .black)]) == nil)
        #expect(resolve(width: 9, height: 0, [("E5", .black)]) == nil)
    }

    // MARK: - Order

    @Test("Moves resolve in order, so a stone can play into the shape its predecessor cleared")
    func orderedChainClearsTheWayForItsSuccessor() throws {
        // tenukiPhase's exact shape: the capturing stone travels ahead of the
        // stone that needs the point it clears. Resolving these independently —
        // or per color — would find A9 occupied and drop the second move.
        let result = try #require(resolve(black: ["B9"], white: ["A9"],
                                          [("A8", .black), ("A9", .black)]))
        #expect(result.skippedCount == 0)
        #expect(color(result.board, "A9") == .black)
        #expect(color(result.board, "A8") == .black)
    }

    @Test("Reversing that order really would drop the stone — the ordering is load-bearing")
    func reversedOrderIsSkipped() throws {
        let result = try #require(resolve(black: ["B9"], white: ["A9"],
                                          [("A9", .black), ("A8", .black)]))
        #expect(result.skippedCount == 1)
        #expect(color(result.board, "A9") == .empty)   // White A9 captured by A8 after all
    }

    @Test("A base position stays as given when the line is empty")
    func emptyLineLeavesTheBaseAlone() throws {
        let result = try #require(resolve(black: ["B9"], white: ["A9"], []))
        #expect(result.dispositions.isEmpty)
        #expect(color(result.board, "B9") == .black)
        #expect(color(result.board, "A9") == .white)
    }
}
