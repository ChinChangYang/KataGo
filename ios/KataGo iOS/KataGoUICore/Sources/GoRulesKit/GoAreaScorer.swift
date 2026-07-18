//
//  GoAreaScorer.swift
//  GoRulesKit
//
//  Finished-game scoring: a faithful port of Board::calculateAreaForPla
//  (Benson pass-alive with KataGo's territory extensions),
//  Board::calculateIndependentLifeArea (seki stripping + group tax count),
//  and BoardHistory::countAreaScoreWhiteMinusBlack /
//  countTerritoryAreaScoreWhiteMinusBlack with encorePhase == 0.
//  The caller removes marked-dead stones first; the area-equivalent
//  formulation (with the territory chill accrued in GoGame) makes removal
//  itself carry the Japanese two-point swing, so no separate prisoner
//  accounting exists anywhere.
//

import Foundation
import KataGoGameStore

public struct GoScore: Sendable, Equatable {
    /// Final score including komi and bonuses; positive means White leads.
    public let whiteMinusBlack: Double
    /// Per-point ownership after scoring (the `area` buffer KataGo fills):
    /// .black / .white for counted points, .empty for dame. Row-major.
    public let ownership: [GoColor]

    public var result: GoGameResult {
        GoGameResult(kind: .score(whiteMinusBlack: whiteMinusBlack))
    }
}

public enum GoAreaScorer {
    // MARK: - Public scoring entry

    /// endAndScoreGameNow: board score per the scoring rule, plus the
    /// accrued white bonus (chill/button), handicap bonus, and komi.
    public static func score(
        board: GoBoard,
        rules: GoRules,
        whiteBonusScore: Double,
        whiteHandicapBonus: Double
    ) -> GoScore {
        let boardScore: Int
        let ownership: [GoColor]
        switch rules.scoringRule {
        case .area:
            (boardScore, ownership) = areaScoreWhiteMinusBlack(board: board, rules: rules)
        case .territory:
            (boardScore, ownership) = territoryScoreWhiteMinusBlack(board: board, rules: rules)
        }
        let total = Double(boardScore) + whiteBonusScore + whiteHandicapBonus + rules.komi
        return GoScore(whiteMinusBlack: total, ownership: ownership)
    }

    /// countAreaScoreWhiteMinusBlack.
    static func areaScoreWhiteMinusBlack(board: GoBoard, rules: GoRules) -> (score: Int, area: [GoColor]) {
        var score = 0
        var area: [GoColor]
        switch rules.taxRule {
        case .none:
            area = calculateArea(
                board: board,
                nonPassAliveStones: true, safeBigTerritories: true, unsafeBigTerritories: true,
                multiStoneSuicideLegal: rules.multiStoneSuicideLegal)
        case .seki, .all:
            let independent = calculateIndependentLifeArea(
                board: board,
                keepTerritories: false, keepStones: true,
                multiStoneSuicideLegal: rules.multiStoneSuicideLegal)
            area = independent.area
            if rules.taxRule == .all {
                score -= 2 * independent.whiteMinusBlackRegionCount
            }
        }
        for c in area {
            if c == .white { score += 1 } else if c == .black { score -= 1 }
        }
        return (score, area)
    }

    /// countTerritoryAreaScoreWhiteMinusBlack with encorePhase == 0: stones
    /// on the board always count for their own side.
    static func territoryScoreWhiteMinusBlack(board: GoBoard, rules: GoRules) -> (score: Int, area: [GoColor]) {
        let keepTerritories = rules.taxRule == .none
        let independent = calculateIndependentLifeArea(
            board: board,
            keepTerritories: keepTerritories, keepStones: false,
            multiStoneSuicideLegal: rules.multiStoneSuicideLegal)
        var area = independent.area
        var score = 0
        for i in 0..<area.count {
            if area[i] == .white {
                score += 1
            } else if area[i] == .black {
                score -= 1
            } else if board.grid[i] == .white {
                score += 1
                area[i] = .white
            } else if board.grid[i] == .black {
                score -= 1
                area[i] = .black
            }
        }
        if rules.taxRule == .all {
            score -= 2 * independent.whiteMinusBlackRegionCount
        }
        return (score, area)
    }

    // MARK: - calculateArea

    static func calculateArea(
        board: GoBoard,
        nonPassAliveStones: Bool,
        safeBigTerritories: Bool,
        unsafeBigTerritories: Bool,
        multiStoneSuicideLegal: Bool
    ) -> [GoColor] {
        var result = [GoColor](repeating: .empty, count: board.grid.count)
        calculateAreaForPla(
            board: board, pla: .black,
            safeBigTerritories: safeBigTerritories, unsafeBigTerritories: unsafeBigTerritories,
            multiStoneSuicideLegal: multiStoneSuicideLegal, result: &result)
        calculateAreaForPla(
            board: board, pla: .white,
            safeBigTerritories: safeBigTerritories, unsafeBigTerritories: unsafeBigTerritories,
            multiStoneSuicideLegal: multiStoneSuicideLegal, result: &result)
        if nonPassAliveStones {
            for i in 0..<result.count where result[i] == .empty {
                result[i] = board.grid[i]
            }
        }
        return result
    }

    // MARK: - calculateIndependentLifeArea

    /// Basic area (everything on), then strips "seki" components: any owned
    /// component touching dame or containing an owner's stone in atari.
    /// keepTerritories restores stripped surrounded EMPTY points;
    /// keepStones restores stripped own-stone points.
    static func calculateIndependentLifeArea(
        board: GoBoard,
        keepTerritories: Bool,
        keepStones: Bool,
        multiStoneSuicideLegal: Bool
    ) -> (area: [GoColor], whiteMinusBlackRegionCount: Int) {
        let basicArea = calculateArea(
            board: board,
            nonPassAliveStones: true, safeBigTerritories: true, unsafeBigTerritories: true,
            multiStoneSuicideLegal: multiStoneSuicideLegal)

        var result = [GoColor](repeating: .empty, count: board.grid.count)
        var regionCount = 0
        independentLifeAreaHelper(
            board: board, basicArea: basicArea,
            result: &result, whiteMinusBlackRegionCount: &regionCount)

        if keepTerritories {
            for i in 0..<result.count where basicArea[i] != .empty && basicArea[i] != board.grid[i] {
                result[i] = basicArea[i]
            }
        }
        if keepStones {
            for i in 0..<result.count where basicArea[i] != .empty && basicArea[i] == board.grid[i] {
                result[i] = basicArea[i]
            }
        }
        return (result, regionCount)
    }

    /// Board::calculateIndependentLifeAreaHelper.
    private static func independentLifeAreaHelper(
        board: GoBoard,
        basicArea: [GoColor],
        result: inout [GoColor],
        whiteMinusBlackRegionCount: inout Int
    ) {
        let count = board.grid.count
        var isSeki = [Bool](repeating: false, count: count)

        for loc in 0..<count where basicArea[loc] != .empty && !isSeki[loc] {
            let pla = basicArea[loc]
            let ownerStoneInAtari = board.grid[loc] == pla && board.libertyCount(ofChainAt: loc) == 1
            let touchesDame = board.neighbors(of: loc).contains {
                board.grid[$0] == .empty && basicArea[$0] == .empty
            }
            if ownerStoneInAtari || touchesDame {
                // Flood the whole owned component as seki.
                var stack = [loc]
                isSeki[loc] = true
                while let next = stack.popLast() {
                    for adj in board.neighbors(of: next) where basicArea[adj] == pla && !isSeki[adj] {
                        isSeki[adj] = true
                        stack.append(adj)
                    }
                }
            }
        }

        // Copy non-seki components, counting them for the group tax.
        for loc in 0..<count where basicArea[loc] != .empty && !isSeki[loc] && result[loc] != basicArea[loc] {
            let pla = basicArea[loc]
            whiteMinusBlackRegionCount += pla == .white ? 1 : -1
            result[loc] = pla
            var stack = [loc]
            while let next = stack.popLast() {
                for adj in board.neighbors(of: next) where basicArea[adj] == pla && result[adj] != basicArea[adj] {
                    result[adj] = basicArea[adj]
                    stack.append(adj)
                }
            }
        }
    }

    // MARK: - calculateAreaForPla (Benson)

    /// Marks pass-alive stones and pass-alive territory for `pla`, plus the
    /// big-territory variants. See board.cpp for the geometry of the
    /// overwrite rules; the marking order (black then white) matters and is
    /// preserved by the callers.
    static func calculateAreaForPla(
        board: GoBoard,
        pla: GoColor,
        safeBigTerritories: Bool,
        unsafeBigTerritories: Bool,
        multiStoneSuicideLegal: Bool,
        result: inout [GoColor]
    ) {
        let opp = pla.opponent
        let count = board.grid.count

        // Pla chains: id per stone location, stones per id.
        var chainIndex = [Int](repeating: -1, count: count)
        var chains: [[Int]] = []
        for loc in 0..<count where board.grid[loc] == pla && chainIndex[loc] == -1 {
            let stones = board.chain(at: loc)
            for s in stones { chainIndex[s] = chains.count }
            chains.append(stones)
        }
        let atLeastOnePla = !chains.isEmpty

        // Regions: maximal components of (empty ∪ opp). Every region contains
        // at least one empty point (an opp stone's liberty), so seeding from
        // empty points reaches them all.
        var regionIndex = [Int](repeating: -1, count: count)
        var regionPoints: [[Int]] = []
        var regionVital: [[Int]] = []          // chain ids the region is vital for
        var regionInternalMax2: [Int] = []     // points not adjacent to pla, capped at 2
        var regionContainsOpp: [Bool] = []
        for loc in 0..<count where board.grid[loc] == .empty && regionIndex[loc] == -1 {
            let regionIdx = regionPoints.count
            var points: [Int] = []
            var stack = [loc]
            regionIndex[loc] = regionIdx
            var internalCount = 0
            var containsOpp = false
            // Vital chains: adjacent to every filter point of the region.
            // Filter points are the empty points, or every point when
            // multi-stone suicide is legal (the C++ filter condition).
            var vital: Set<Int>?
            while let cur = stack.popLast() {
                points.append(cur)
                let adjacentPlaChains = Set(board.neighbors(of: cur).compactMap {
                    board.grid[$0] == pla ? chainIndex[$0] : nil
                })
                if adjacentPlaChains.isEmpty {
                    internalCount = min(internalCount + 1, 2)
                }
                if board.grid[cur] == opp { containsOpp = true }
                if multiStoneSuicideLegal || board.grid[cur] == .empty {
                    vital = vital.map { $0.intersection(adjacentPlaChains) } ?? adjacentPlaChains
                }
                for adj in board.neighbors(of: cur)
                where (board.grid[adj] == .empty || board.grid[adj] == opp) && regionIndex[adj] == -1 {
                    regionIndex[adj] = regionIdx
                    stack.append(adj)
                }
            }
            regionPoints.append(points)
            regionVital.append(Array(vital ?? []))
            regionInternalMax2.append(internalCount)
            regionContainsOpp.append(containsOpp)
        }

        // Benson iteration: kill chains with fewer than two vital regions;
        // a killed chain spoils every adjacent region (once), which drops
        // the vitality of the chains those regions were vital for.
        var vitalCountByChain = [Int](repeating: 0, count: chains.count)
        for vital in regionVital {
            for chainId in vital { vitalCountByChain[chainId] += 1 }
        }
        var chainKilled = [Bool](repeating: false, count: chains.count)
        var regionBordersNonPassAlive = [Bool](repeating: false, count: regionPoints.count)
        var killedSomething = true
        while killedSomething {
            killedSomething = false
            for chainId in 0..<chains.count where !chainKilled[chainId] && vitalCountByChain[chainId] < 2 {
                chainKilled[chainId] = true
                killedSomething = true
                for stone in chains[chainId] {
                    for adj in board.neighbors(of: stone) {
                        let regionIdx = regionIndex[adj]
                        guard regionIdx >= 0, !regionBordersNonPassAlive[regionIdx],
                              board.grid[adj] == .empty || board.grid[adj] == opp else { continue }
                        regionBordersNonPassAlive[regionIdx] = true
                        for vitalChain in regionVital[regionIdx] {
                            vitalCountByChain[vitalChain] -= 1
                        }
                    }
                }
            }
        }

        // Pass-alive stones.
        for chainId in 0..<chains.count where !chainKilled[chainId] {
            for stone in chains[chainId] { result[stone] = pla }
        }

        // Territory marking (see the C++ comments for why pass-alive
        // territory overwrites and unsafe big territory does not).
        for regionIdx in 0..<regionPoints.count {
            var shouldMark = regionInternalMax2[regionIdx] <= 1
                && !regionBordersNonPassAlive[regionIdx] && atLeastOnePla
            shouldMark = shouldMark || (safeBigTerritories && !regionContainsOpp[regionIdx]
                && !regionBordersNonPassAlive[regionIdx] && atLeastOnePla)
            if shouldMark {
                for p in regionPoints[regionIdx] { result[p] = pla }
            } else if unsafeBigTerritories && !regionContainsOpp[regionIdx] && atLeastOnePla {
                for p in regionPoints[regionIdx] where result[p] == .empty {
                    result[p] = pla
                }
            }
        }
    }
}
