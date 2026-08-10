//
//  GoGame.swift
//  GoRulesKit
//
//  Full game state: setup, move history, superko enforcement, the
//  play → scoring → finished phase machine, and the KataGo-equivalent
//  score bonuses (territory "chill", button, white handicap bonus).
//  Ported from cpp/game/boardhistory.cpp with encorePhase pinned to 0 —
//  the iMessage flow replaces KataGo's cleanup encore with manual
//  dead-stone marking.
//

import Foundation
import KataGoGameStore

public enum GoGamePhase: Hashable, Sendable {
    /// Normal alternating play.
    case playing
    /// Two consecutive ending passes happened; players mark dead stones.
    case scoring
    /// Result agreed (score) or forced (resignation).
    case finished(GoGameResult)
}

public struct GoGameResult: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case score(whiteMinusBlack: Double)
        case resignation(winner: GoColor)
    }
    public var kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }

    /// "W+3.5", "B+R", "Draw".
    public var shortText: String {
        switch kind {
        case .score(let whiteMinusBlack):
            if whiteMinusBlack > 0 {
                return "W+\(Self.trimmed(whiteMinusBlack))"
            } else if whiteMinusBlack < 0 {
                return "B+\(Self.trimmed(-whiteMinusBlack))"
            } else {
                return "Draw"
            }
        case .resignation(let winner):
            return winner == .white ? "W+R" : "B+R"
        }
    }

    private static func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

public struct GoGameError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

public struct GoGame: Sendable {
    public let rules: GoRules
    public let handicap: Int
    public private(set) var board: GoBoard
    public private(set) var moves: [GoMove] = []
    public private(set) var phase: GoGamePhase = .playing
    /// Indices of stones currently marked dead during scoring.
    public private(set) var markedDead: Set<Int> = []

    /// Ko-hash history including the initial position (koHashHistory).
    /// Positional koRule stores posHash; situational folds in the player to
    /// move. Simple ko keeps the list but never consults it.
    private var koHashHistory: [UInt64]
    /// The button, if the rules have one and nobody has taken it yet.
    private var buttonAvailable: Bool
    /// Passes that count toward the two-pass game end (a button-taking pass
    /// does not, mirroring consecutiveEndingPasses).
    private var consecutiveEndingPasses: Int = 0
    /// Accrued white bonus: territory chill per move + button half point.
    private var whiteBonusScore: Double

    // MARK: - Setup

    /// Creates a game. Handicap stones (0 or 2...9) go on star points in the
    /// conventional order; with handicap, White moves first and each setup
    /// stone chills one point under territory scoring (the initial-position
    /// loop in BoardHistory's constructor).
    public init(width: Int, height: Int, rules: GoRules, handicap: Int = 0) throws {
        guard width >= 2, height >= 2, width <= 37, height <= 37 else {
            throw GoGameError("board size must be 2...37")
        }
        guard handicap == 0 || (2...9).contains(handicap) else {
            throw GoGameError("handicap must be 0 or 2...9")
        }
        self.rules = rules
        self.handicap = handicap
        var board = GoBoard(width: width, height: height)
        if handicap > 0 {
            let points = Self.handicapPoints(width: width, height: height, count: handicap)
            guard points.count == handicap else {
                throw GoGameError("board has no star-point layout for handicap \(handicap)")
            }
            for p in points {
                board.placeSetupStone(at: p, color: .black)
            }
        }
        self.board = board
        self.buttonAvailable = rules.hasButton
        self.whiteBonusScore = rules.scoringRule == .territory ? Double(handicap) : 0
        self.koHashHistory = []
        self.koHashHistory.append(koHash(of: board, toMove: firstPlayer))
    }

    public var firstPlayer: GoColor { handicap > 0 ? .white : .black }

    /// Player to move (meaningful in .playing; after a dispute-resume the
    /// history parity still holds because resume rewinds nothing).
    public var toMove: GoColor {
        moves.count.isMultiple(of: 2) ? firstPlayer : firstPlayer.opponent
    }

    /// Conventional handicap order on the star grid: corners (opposing pairs
    /// first), then sides, center joins for odd counts >= 5. Returns fewer
    /// points than requested when the board's star layout can't seat them.
    public static func handicapPoints(width: Int, height: Int, count: Int) -> [GoPoint] {
        BoardHandicapPoints.points(width: width, height: height, count: count)
            .map { GoPoint(x: $0.x, y: $0.y) }
    }

    /// Largest handicap the board's star layout can seat (0 when < 2).
    public static func maxHandicap(width: Int, height: Int) -> Int {
        BoardHandicapPoints.maxCount(width: width, height: height)
    }

    // MARK: - Ko hashing

    private func koHash(of board: GoBoard, toMove: GoColor) -> UInt64 {
        switch rules.koRule {
        case .situational:
            return board.situationalHash(toMove: toMove)
        case .simple, .positional:
            return board.posHash
        }
    }

    /// Board-level legality plus superko for the current player.
    public func isLegal(_ move: GoMove) -> Bool {
        (try? validated(move)) != nil
    }

    /// Returns the board after `move`, throwing the specific illegality.
    private func validated(_ move: GoMove) throws -> GoBoard {
        guard phase == .playing else { throw GoPlayError.wrongPhase }
        switch move {
        case .pass:
            var next = board
            next.playPass()
            return next
        case .play(let p):
            var next = board
            try next.play(at: p, color: toMove, multiStoneSuicideLegal: rules.multiStoneSuicideLegal)
            if rules.koRule != .simple {
                let hash = koHash(of: next, toMove: toMove.opponent)
                if koHashHistory.contains(hash) {
                    throw GoPlayError.superKoBanned
                }
            }
            return next
        }
    }

    // MARK: - Play

    public mutating func play(_ move: GoMove) throws {
        let next = try validated(move)
        let mover = toMove
        board = next
        moves.append(move)

        switch move {
        case .play:
            consecutiveEndingPasses = 0
            if rules.scoringRule == .territory {
                // Chill one point per move played (main phase).
                whiteBonusScore += mover == .black ? 1 : -1
            }
        case .pass:
            if buttonAvailable {
                // First pass takes the button and does not count toward the
                // two-pass ending; taking it clears the ko history.
                buttonAvailable = false
                whiteBonusScore += mover == .white ? 0.5 : -0.5
                consecutiveEndingPasses = 0
                koHashHistory.removeAll()
            } else {
                consecutiveEndingPasses += 1
            }
        }

        koHashHistory.append(koHash(of: board, toMove: toMove))

        if consecutiveEndingPasses >= 2 {
            phase = .scoring
        }
    }

    public mutating func resign(by color: GoColor) {
        phase = .finished(GoGameResult(kind: .resignation(winner: color.opponent)))
    }

    // MARK: - Scoring phase

    /// Stones toggled dead together: every stone of the tapped stone's color
    /// reachable through empty points and that color (the usual client UX —
    /// one tap marks the whole dragon).
    public func deadGroup(at p: GoPoint) -> Set<Int> {
        guard let start = board.index(of: p), board.grid[start] != .empty else { return [] }
        let color = board.grid[start]
        var seen = [Bool](repeating: false, count: board.grid.count)
        var stack = [start]
        seen[start] = true
        var result: Set<Int> = []
        while let loc = stack.popLast() {
            if board.grid[loc] == color { result.insert(loc) }
            for adj in board.neighbors(of: loc) where !seen[adj] && (board.grid[adj] == color || board.grid[adj] == .empty) {
                seen[adj] = true
                stack.append(adj)
            }
        }
        return result
    }

    public mutating func toggleDead(at p: GoPoint) {
        guard phase == .scoring else { return }
        let group = deadGroup(at: p)
        guard !group.isEmpty else { return }
        if markedDead.isSuperset(of: group) {
            markedDead.subtract(group)
        } else {
            markedDead.formUnion(group)
        }
    }

    public mutating func setMarkedDead(_ indices: Set<Int>) {
        guard phase == .scoring else { return }
        markedDead = indices.filter { $0 >= 0 && $0 < board.grid.count && board.grid[$0] != .empty }
    }

    /// Scores the position with the current dead marks (endAndScoreGameNow).
    public func scoreNow() -> GoScore {
        var bonus = whiteBonusScore
        if buttonAvailable {
            // Game ended with the button untaken: it goes to the player to move.
            bonus += toMove == .white ? 0.5 : -0.5
        }
        let cleaned = board.removingStones(at: markedDead)
        return GoAreaScorer.score(
            board: cleaned,
            rules: rules,
            whiteBonusScore: bonus,
            whiteHandicapBonus: whiteHandicapBonus)
    }

    private var whiteHandicapBonus: Double {
        switch rules.whiteHandicapBonusRule {
        case .zero: return 0
        case .n: return Double(handicap)
        case .n_minus_one: return handicap > 1 ? Double(handicap - 1) : 0
        }
    }

    /// Locks in the score both players agreed on.
    public mutating func confirmScore() {
        guard phase == .scoring else { return }
        phase = .finished(GoGameResult(kind: .score(whiteMinusBlack: scoreNow().whiteMinusBlack)))
    }

    /// A dispute resumes play. The two ending passes stay in the history, so
    /// alternation continues from them; dead marks are discarded.
    public mutating func resumePlay() {
        guard phase == .scoring else { return }
        markedDead = []
        consecutiveEndingPasses = 0
        phase = .playing
    }
}
