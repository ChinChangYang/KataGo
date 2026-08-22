//
//  GoRulesKitDifferentialTests.swift
//  KataGo AnytimeTests
//
//  The correctness gate for the pure-Swift rules engine that the Messages
//  extension plays with: seeded random games are generated move-by-move
//  through GoRulesKit (which enforces legality), emitted as SGF, and
//  replayed through the C++ engine's battle-tested board (SgfHelper /
//  SgfCpp). Every ply's stone sets must match exactly — captures, suicide
//  removal, and setup handicap stones included. Runs in the app test target
//  because only the host app links the engine.
//

import Testing
import KataGoUICore
import GoRulesKit
import KataGoAnalysisKit

struct GoRulesKitDifferentialTests {
    struct Scenario: CustomStringConvertible {
        let name: String
        let width: Int
        let height: Int
        let rules: GoRules
        let handicap: Int
        let moveCount: Int
        let seed: UInt64

        var description: String { name }
    }

    static let scenarios: [Scenario] = [
        Scenario(name: "5x5 Chinese", width: 5, height: 5, rules: .chinese,
                 handicap: 0, moveCount: 120, seed: 1),
        Scenario(name: "9x9 Tromp-Taylor suicide", width: 9, height: 9, rules: .trompTaylor,
                 handicap: 0, moveCount: 160, seed: 2),
        Scenario(name: "9x9 Japanese handicap 3", width: 9, height: 9, rules: .japanese,
                 handicap: 3, moveCount: 140, seed: 3),
        Scenario(name: "13x13 AGA", width: 13, height: 13, rules: .aga,
                 handicap: 0, moveCount: 100, seed: 4),
        Scenario(name: "7x5 rectangle Chinese", width: 7, height: 5, rules: .chinese,
                 handicap: 0, moveCount: 90, seed: 5),
        Scenario(name: "19x19 New Zealand handicap 2", width: 19, height: 19, rules: .newZealand,
                 handicap: 2, moveCount: 70, seed: 6),
    ]

    @Test(arguments: scenarios)
    func swiftReplayMatchesEngineReplay(scenario: Scenario) throws {
        var rng = SplitMix64Generator(seed: scenario.seed)
        var game = try GoGame(
            width: scenario.width, height: scenario.height,
            rules: scenario.rules, handicap: scenario.handicap)

        // Per-ply snapshots from the Swift engine, frame 0 = setup position.
        var swiftFrames: [(black: Set<String>, white: Set<String>)] = [snapshot(of: game.board)]
        var lastWasPass = false
        while swiftFrames.count <= scenario.moveCount, game.phase == .playing {
            let candidates = (0..<game.board.area)
                .map { game.board.point(at: $0) }
                .filter { game.isLegal(.play($0)) }
            // An occasional pass exercises ko-point clearing, but never two
            // in a row (that would end the game mid-test).
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
            swiftFrames.append(snapshot(of: game.board))
        }

        // Replay the exact same game through the C++ board via SGF.
        let sgf = MessageGameCodec.sgf(for: MessageGame(game: game, creatorColor: .black))
        let engineFrames = SgfHelper(sgf: sgf).gifFrames()
        try #require(engineFrames.count == swiftFrames.count,
                     "engine replay produced \(engineFrames.count) frames, Swift \(swiftFrames.count)")

        for (index, engineFrame) in engineFrames.enumerated() {
            #expect(Set(engineFrame.blackStones) == swiftFrames[index].black,
                    "black stones diverge at ply \(index) in \(scenario.name)")
            #expect(Set(engineFrame.whiteStones) == swiftFrames[index].white,
                    "white stones diverge at ply \(index) in \(scenario.name)")
        }
    }

    private func snapshot(of board: GoBoard) -> (black: Set<String>, white: Set<String>) {
        (black: Set(board.gtpVertices(of: .black)),
         white: Set(board.gtpVertices(of: .white)))
    }

    // MARK: - Tolerant refusals

    // SgfReplay refuses exactly what KataGo's tolerant `play` refuses: an
    // occupied point, an off-board point, and single-stone suicide. These pin
    // the two rejections a recorded game can actually contain against the C++
    // board, which rejects the same move — CompactSgf::playMovesTolerant
    // throws on it, which is how the rejection is observable from here.
    //
    // Only the Swift replay can carry on past it, and that asymmetry is the
    // point: the engine is fed the record move by move and simply never
    // receives a refused move, so it stays on the position the replay draws.
    // Handing the whole SGF to the C++ parser instead loses the game from the
    // refusal onward, which is why `loadsgf` is not how the board is drawn.

    @Test func refusedOccupiedPointAgreesWithCppTolerantPlay() throws {
        try expectRefusal(
            in: "(;FF[4]GM[1]SZ[9]KM[7];B[cc];W[gg];B[cc];W[dd])",
            at: 2, "replayed occupied point")
    }

    @Test func refusedSingleStoneSuicideAgreesWithCppTolerantPlay() throws {
        // A lone Black stone into the corner between two White stones has no
        // liberty and captures nothing.
        try expectRefusal(
            in: "(;FF[4]GM[1]SZ[9]KM[7]AW[ah][bi];B[ai];W[gg])",
            at: 0, "single-stone suicide")
    }

    private func expectRefusal(in sgf: String, at refusedIndex: Int, _ label: String) throws {
        let scan = try #require(SgfHeaderScan(sgf: sgf), "scan failed for \(label)")
        var replay = SgfReplay(scan: scan)
        let frames = SgfHelper(sgf: sgf).gifFrames()
        try #require(frames.count == replay.moveCount + 1,
                     "frame count mismatch for \(label)")

        // Up to and including the refused index both sides replayed the same
        // accepted moves, so the boards match.
        for index in 0...refusedIndex {
            let position = replay.position(at: index)
            #expect(Set(frames[index].blackStones) == Set(position.blackVertices),
                    "black mismatch at \(index): \(label)")
            #expect(Set(frames[index].whiteStones) == Set(position.whiteVertices),
                    "white mismatch at \(index): \(label)")
        }

        // Past it the C++ SGF replay has thrown and degraded to nothing, while
        // the Swift replay skipped the move and kept the position.
        for index in frames.indices where index > refusedIndex {
            #expect(frames[index].blackStones.isEmpty && frames[index].whiteStones.isEmpty,
                    "C++ replay should have given up at \(index): \(label)")
        }
        let afterRefusal = replay.position(at: refusedIndex + 1)
        let beforeRefusal = replay.position(at: refusedIndex)
        #expect(afterRefusal.blackVertices == beforeRefusal.blackVertices,
                "refused move changed the board: \(label)")
        #expect(afterRefusal.whiteVertices == beforeRefusal.whiteVertices,
                "refused move changed the board: \(label)")
        #expect(afterRefusal.toMove == beforeRefusal.toMove,
                "refused move changed the turn: \(label)")
        #expect(replay.refusedIndices == [refusedIndex], "refusals mismatch: \(label)")
    }
}

/// Deterministic RNG so failures reproduce exactly.
struct SplitMix64Generator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
