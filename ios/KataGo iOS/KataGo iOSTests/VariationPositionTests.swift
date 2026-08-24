//
//  VariationPositionTests.swift
//  KataGo AnytimeTests
//
//  The KataGoUICore-side projection of a force-played variation: which stones
//  survive, and which move numbers survive with them. The rules themselves are
//  pinned by GoRulesKitTests/ForcePlayTests (`swift test`); these cover the
//  projection — coordinate flip, numbering, vertex ordering — plus a
//  differential pass against the C++ board, which only the app target links.
//

import Testing
import KataGoUICore
import GoRulesKit
import KataGoAnalysisKit

struct VariationPositionTests {

    private func vertices(_ points: [BoardPoint], width: Int = 9, height: Int = 9) -> [String] {
        points.compactMap { $0.gtpVertex(width: width, height: height) }.sorted()
    }

    /// Move numbers the way a renderer reads them: by POSITION in the chain,
    /// for the moves whose stones survived. Assigning in order means a replayed
    /// point keeps the latest number.
    private func numbers(_ position: VariationPosition,
                         width: Int = 9, height: Int = 9) -> [String: Int] {
        var result: [String: Int] = [:]
        for (index, point) in position.survivingPoints.enumerated() {
            guard let point, let vertex = point.gtpVertex(width: width, height: height) else { continue }
            result[vertex] = index + 1
        }
        return result
    }

    private func resolve(width: Int = 9, height: Int = 9,
                         black: [String] = [], white: [String] = [],
                         pv: [String], startingWith: PlayerColor = .black) -> VariationPosition? {
        VariationResolver.resolve(width: width, height: height,
                                  blackVertices: black, whiteVertices: white,
                                  moves: VariationResolver.alternating(pv, startingWith: startingWith))
    }

    // MARK: - Stones

    @Test("A captured stone leaves the board, and its number leaves with it")
    func captureRemovesStoneAndNumber() throws {
        // The GIF export's capture fixture, played as a variation: A9 goes down
        // as move 1 and is taken by move 4.
        let position = try #require(resolve(pv: ["A9", "B9", "G3", "A8"]))
        #expect(vertices(position.blackPoints) == ["G3"])
        #expect(vertices(position.whitePoints) == ["A8", "B9"])
        #expect(numbers(position) == ["B9": 2, "G3": 3, "A8": 4])
        #expect(position.skippedCount == 0)
    }

    @Test("A variation captures the BASE stones it surrounds")
    func captureRemovesBaseStones() throws {
        let position = try #require(resolve(black: ["B9"], white: ["A9"], pv: ["A8"]))
        #expect(vertices(position.whitePoints).isEmpty)
        #expect(vertices(position.blackPoints) == ["A8", "B9"])
        // Only the variation's own move is numbered; base stones are not.
        #expect(numbers(position) == ["A8": 1])
    }

    @Test("Numbers are the engine's own indices, so a pass leaves a gap")
    func numbersKeepEngineIndices() throws {
        let position = try #require(resolve(pv: ["E5", "pass", "C3"]))
        #expect(numbers(position) == ["E5": 1, "C3": 3])
        #expect(vertices(position.blackPoints) == ["C3", "E5"])
        #expect(position.whitePoints.isEmpty)
    }

    @Test("A point replayed after a capture carries the LATEST number")
    func replayedPointKeepsTheLatestNumber() throws {
        // Black D3 takes White C3 (move 1); White retakes C3 (move 2).
        let position = try #require(resolve(width: 5, height: 5,
                                            black: ["C4", "B3", "C2"],
                                            white: ["C3", "D4", "E3", "D2"],
                                            pv: ["D3", "C3"]))
        let labels = numbers(position, width: 5, height: 5)
        #expect(labels["C3"] == 2)      // the retake, not the stone it replaced
        #expect(labels["D3"] == nil)    // captured by move 2 — no stone, no number
    }

    @Test("The coordinate flip round-trips: a variation stone lands where it was named")
    func coordinateFlipIsCorrect() throws {
        let position = try #require(resolve(width: 19, height: 19, pv: ["Q16", "D4"]))
        #expect(vertices(position.blackPoints, width: 19, height: 19) == ["Q16"])
        #expect(vertices(position.whitePoints, width: 19, height: 19) == ["D4"])
    }

    // MARK: - Nothing is refused

    @Test("An unplaceable vertex is skipped and counted, and the line continues")
    func unplaceableVertexIsSkippedNotRefused() throws {
        let position = try #require(resolve(pv: ["T19", "E5"]))
        #expect(position.skippedCount == 1)
        #expect(vertices(position.whitePoints) == ["E5"])   // move 2 still landed
        #expect(numbers(position) == ["E5": 2])             // and kept its index
    }

    @Test("A degenerate board size returns nil rather than trapping")
    func degenerateBoardReturnsNil() {
        #expect(resolve(width: 0, height: 9, pv: ["E5"]) == nil)
    }

    // MARK: - A marked move leading a PV

    @Test("A marked move that repeats the PV's first move does not steal its point")
    func markedMoveSharingThePVsFirstPointIsANoOp() throws {
        // ReportBoardView plays the move under study first, then its
        // continuation — and in the Deep Report the PV's first move IS the
        // candidate, so the two name the same point. The second must resolve as
        // a no-op that still owns the point, or the PV's own number 1 vanishes.
        let position = try #require(
            VariationResolver.resolve(
                width: 9, height: 9, blackVertices: [], whiteVertices: [],
                moves: [VariationMove(vertex: "E5", color: .black)]
                     + VariationResolver.alternating(["E5", "G7"], startingWith: .black)))
        #expect(position.skippedCount == 0)
        // Index 0 is the marked move; the PV occupies 1... — and its first move
        // still owns E5 despite placing nothing.
        #expect(position.survivingPoints.count == 3)
        #expect(position.survivingPoints[1] == position.survivingPoints[0])
        #expect(vertices(position.blackPoints) == ["E5"])
        #expect(vertices(position.whitePoints) == ["G7"])
    }

    @Test("A PV plays into the shape the marked move ahead of it cleared")
    func markedMoveCaptureClearsTheWayForThePV() throws {
        let position = try #require(
            VariationResolver.resolve(
                width: 9, height: 9, blackVertices: ["B9"], whiteVertices: ["A9"],
                moves: [VariationMove(vertex: "A8", color: .black)]
                     + VariationResolver.alternating(["A9"], startingWith: .black)))
        #expect(position.skippedCount == 0)
        #expect(position.whitePoints.isEmpty)
        #expect(vertices(position.blackPoints) == ["A8", "A9", "B9"])
    }

    // MARK: - Vertex projection

    @Test("resolveVertices keeps base order first, then the variation's own order")
    func vertexOrderIsBaseThenVariation() throws {
        let resolved = try #require(
            VariationResolver.resolveVertices(
                width: 19, height: 19,
                blackVertices: ["D4", "Q16"], whiteVertices: ["D16"],
                moves: [VariationMove(vertex: "C3", color: .white)]))
        #expect(resolved.black == ["D4", "Q16"])
        #expect(resolved.white == ["D16", "C3"])
    }

    @Test("resolveVertices drops what the variation captured")
    func vertexProjectionDropsCapturedStones() throws {
        let resolved = try #require(
            VariationResolver.resolveVertices(
                width: 9, height: 9,
                blackVertices: ["B9"], whiteVertices: ["A9"],
                moves: [VariationMove(vertex: "A8", color: .black)]))
        #expect(resolved.white.isEmpty)
        #expect(resolved.black.sorted() == ["A8", "B9"])
    }

    // MARK: - Differential against the C++ board

    struct Scenario: CustomStringConvertible {
        let name: String
        let width: Int
        let height: Int
        let moveCount: Int
        let seed: UInt64
        var description: String { name }
    }

    static let scenarios: [Scenario] = [
        Scenario(name: "5x5", width: 5, height: 5, moveCount: 90, seed: 11),
        Scenario(name: "9x9", width: 9, height: 9, moveCount: 140, seed: 12),
        Scenario(name: "7x5 rectangle", width: 7, height: 5, moveCount: 80, seed: 13),
        Scenario(name: "13x13", width: 13, height: 13, moveCount: 90, seed: 14),
    ]

    /// A legal alternating line played from an empty board IS a game, so the
    /// C++ replay is an oracle for it. This covers the subset force-play shares
    /// with the rules; the force-only cases (suicide, skips, ko recapture) have
    /// no C++ analogue on this path and stay unit-tested in GoRulesKitTests.
    @Test(arguments: scenarios)
    func forcePlayMatchesEngineReplay(scenario: Scenario) throws {
        var rng = SplitMix64Generator(seed: scenario.seed)
        var game = try GoGame(width: scenario.width, height: scenario.height,
                              rules: .trompTaylor, handicap: 0)
        var lastWasPass = false
        while game.moves.count < scenario.moveCount, game.phase == .playing {
            let candidates = (0..<game.board.area)
                .map { game.board.point(at: $0) }
                .filter { game.isLegal(.play($0)) }
            let passNow = !lastWasPass && UInt64.random(in: 0..<20, using: &rng) == 0
            if passNow {
                try game.play(.pass)
                lastWasPass = true
            } else if let choice = candidates.randomElement(using: &rng) {
                try game.play(.play(choice))
                lastWasPass = false
            } else {
                break
            }
        }

        let line = game.moves.map { move -> String in
            switch move {
            case .pass: "pass"
            case .play(let point): point.gtpVertex(boardHeight: scenario.height)
            }
        }
        let position = try #require(
            VariationResolver.resolve(width: scenario.width, height: scenario.height,
                                      blackVertices: [], whiteVertices: [],
                                      moves: VariationResolver.alternating(line, startingWith: .black)))
        #expect(position.skippedCount == 0, "a legal line should never skip: \(scenario.name)")

        let sgf = MessageGameCodec.sgf(for: MessageGame(game: game, creatorColor: .black))
        let engineFinal = try #require(SgfHelper(sgf: sgf).gifFrames().last)

        #expect(Set(vertices(position.blackPoints, width: scenario.width, height: scenario.height))
                == Set(engineFinal.blackStones),
                "black stones diverge in \(scenario.name)")
        #expect(Set(vertices(position.whitePoints, width: scenario.width, height: scenario.height))
                == Set(engineFinal.whiteStones),
                "white stones diverge in \(scenario.name)")
    }
}
