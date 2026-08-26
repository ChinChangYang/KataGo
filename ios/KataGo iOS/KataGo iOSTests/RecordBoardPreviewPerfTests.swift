//
//  RecordBoardPreviewPerfTests.swift
//  KataGo AnytimeTests
//
//  Cost guard for the library row's derived board (ADR 0014). A stored bitmap
//  was O(1) per row forever; a derived board is O(moves) per CACHE MISS, and
//  the expensive half is not the draw — it is the C++ `CompactSgf` parse. The
//  game list's query is unbounded and every realized row re-evaluates on any
//  save, so the cache in `RecordBoardPreviewSource` is what keeps that from
//  becoming a scroll stutter.
//
//  Two tiers, deliberately:
//
//   • `cacheSpares...` is ALWAYS ON and counts parses instead of timing them.
//     A miss count is deterministic, costs microseconds, and cannot be
//     perturbed by a loaded machine.
//   • `rowResolutionScalingBenchmark` is OPT-IN (set KATAGO_RUN_PERF=1), like
//     `GamePickerPerformanceTests.pickerFetchScalingBenchmark`. Resolution is
//     main-actor-bound (`SgfOperations` wraps the non-Sendable C++ parser), so
//     a long synchronous benchmark BLOCKS the main actor — which is how an
//     earlier always-on version of it pushed three deadline-sensitive tests in
//     `EngineRestartRulesTests` past their 5 s bound by ~200 ms. A benchmark
//     that fails its neighbours is not measuring the app, it is measuring
//     itself.
//
//  NOTE: the fixture below builds ONE game tree of N moves. Do not reach for
//  `GamePickerPerformanceTests.heavySgf()` — that is 80 *complete* trees, so a
//  parser sees a single root of four moves and the replay cost would be
//  under-measured by nearly two orders of magnitude.
//

import Testing
import Foundation
@testable import KataGoUICore

@MainActor
@Suite(.serialized)
struct RecordBoardPreviewPerfTests {

    /// A realistically long single game: `moveCount` alternating moves over a
    /// 19x19, in scan order with a stride so groups form, get surrounded and
    /// get lifted — the replay does real capture work, not just placement.
    /// `salt` shifts the starting point so each game is a DIFFERENT SGF string,
    /// which is what makes the cache key miss the way distinct library rows do.
    private func longSgf(moveCount: Int, salt: Int = 0) -> String {
        let letters = Array("abcdefghijklmnopqrs")   // 19 SGF coordinates
        var sgf = "(;FF[4]GM[1]SZ[19]KM[7.5]"
        var used = Set<Int>()
        var cursor = salt
        var placed = 0
        while placed < moveCount {
            // Stride 7 over 361 points: coprime, so it visits every point once
            // before repeating, and consecutive stones land apart.
            let cell = cursor % 361
            cursor += 7
            if used.contains(cell) { continue }
            used.insert(cell)
            let color = placed.isMultiple(of: 2) ? "B" : "W"
            sgf += ";\(color)[\(letters[cell % 19])\(letters[cell / 19])]"
            placed += 1
        }
        return sgf + ")"
    }

    /// A screenful of library rows, each a different game.
    private func librarySgfs(count: Int, moves: Int) -> [String] {
        (0..<count).map { longSgf(moveCount: moves, salt: $0 * 13 + 1) }
    }

    private func seconds(_ body: () -> Void) -> Double {
        let start = ContinuousClock.now
        body()
        let elapsed = start.duration(to: .now)
        return Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) * 1e-18
    }

    /// The fixture has to be a real game tree, or the benchmark measures
    /// nothing. Cheap: one short game.
    @Test func theFixtureIsOneLongGameNotManyShortOnes() throws {
        let moves = 60
        let preview = try #require(RecordBoardPreviewSource.preview(sgf: longSgf(moveCount: moves),
                                                                    index: moves))
        #expect(preview.width == 19)
        #expect(preview.height == 19)
        // A 60-move game leaves a well-populated board even after captures.
        #expect(preview.blackVertices.count + preview.whiteVertices.count > 25)
        #expect(preview.lastMoveVertex != nil)
    }

    /// The case that decides whether deriving the picture was the right trade:
    /// rows re-evaluate on every body pass, and a CloudKit sync burst or a
    /// `modelContext.save()` re-evaluates every realized row at once. That pass
    /// must cost NO parses.
    ///
    /// Counted, not timed — see the file header.
    @Test func aReEvaluatedScreenfulCostsNoFurtherParses() {
        let sgfs = librarySgfs(count: 8, moves: 40)
        RecordBoardPreviewSource.resetCacheForTesting()

        for sgf in sgfs { _ = RecordBoardPreviewSource.preview(sgf: sgf, index: 40) }
        let afterFirstPass = RecordBoardPreviewSource.resolveCountForTesting
        #expect(afterFirstPass == sgfs.count, "each distinct row should parse exactly once")

        // Five more passes over the same screenful — scrolling, and saving.
        for _ in 0..<5 {
            for sgf in sgfs { _ = RecordBoardPreviewSource.preview(sgf: sgf, index: 40) }
        }
        #expect(RecordBoardPreviewSource.resolveCountForTesting == afterFirstPass,
                "a re-evaluation pass re-parsed rows the cache should have served")
    }

    /// Scrubbing the open game invalidates only that row: its SGF is rewritten
    /// in place by a played move, so its key changes and its neighbours' do not.
    @Test func aPlayedMoveInvalidatesOnlyItsOwnRow() {
        let others = librarySgfs(count: 4, moves: 40)
        let before = "(;FF[4]GM[1]SZ[9]KM[7];B[cc];W[dd])"
        let after = "(;FF[4]GM[1]SZ[9]KM[7];B[cc];W[dd];B[gg])"

        RecordBoardPreviewSource.resetCacheForTesting()
        for sgf in others { _ = RecordBoardPreviewSource.preview(sgf: sgf, index: 40) }
        _ = RecordBoardPreviewSource.preview(sgf: before, index: 2)
        let baseline = RecordBoardPreviewSource.resolveCountForTesting

        _ = RecordBoardPreviewSource.preview(sgf: after, index: 3)
        for sgf in others { _ = RecordBoardPreviewSource.preview(sgf: sgf, index: 40) }

        #expect(RecordBoardPreviewSource.resolveCountForTesting == baseline + 1,
                "a move in one game should cost exactly one re-parse")
    }

    // MARK: - Opt-in scaling benchmark

    /// Absolute cost of a cold library row at a realistic game length. Opt-in:
    /// it blocks the main actor long enough to disturb deadline-sensitive tests
    /// running beside it (see the file header).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KATAGO_RUN_PERF"] != nil),
          .timeLimit(.minutes(10)))
    func rowResolutionScalingBenchmark() {
        let rows = 12
        let moves = 240
        let sgfs = librarySgfs(count: rows, moves: moves)

        // Warm-up: first-use costs that are not per-row.
        RecordBoardPreviewSource.resetCacheForTesting()
        _ = RecordBoardPreviewSource.preview(sgf: sgfs[0], index: moves)

        RecordBoardPreviewSource.resetCacheForTesting()
        let cold = seconds {
            for sgf in sgfs { _ = RecordBoardPreviewSource.preview(sgf: sgf, index: moves) }
        }
        let warm = seconds {
            for _ in 0..<5 {
                for sgf in sgfs { _ = RecordBoardPreviewSource.preview(sgf: sgf, index: moves) }
            }
        } / 5.0

        let perColdRow = cold / Double(rows)
        print("[perf] cold row: \(perColdRow * 1000) ms | "
              + "warm screenful of \(rows): \(warm * 1000) ms")

        // Bounded absolutely, so an outright pathological regression (a
        // re-parse per stone, a quadratic replay) fails rather than merely
        // slowing down.
        #expect(perColdRow < 0.050,
                "a cold library row costs \(perColdRow * 1000) ms to resolve")
        #expect(warm < 0.005,
                "a re-evaluation of \(rows) rows costs \(warm * 1000) ms")
    }
}
