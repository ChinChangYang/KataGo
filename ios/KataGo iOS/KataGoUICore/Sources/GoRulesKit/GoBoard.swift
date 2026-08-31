//
//  GoBoard.swift
//  GoRulesKit
//
//  Board position with capture resolution, simple-ko point, and Zobrist
//  position hashing. Ported from cpp/game/board.cpp (playMoveAssumeLegal,
//  isIllegalSuicide, isLegal); chains and liberties are computed by flood
//  fill on demand rather than incrementally — boards cap at 37x37 and the
//  extension replays at most one game per bubble tap, so clarity wins.
//

import Foundation

public struct GoBoard: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// Row-major grid, index = y * width + x.
    public private(set) var grid: [GoColor]
    /// Simple-ko banned point (the point just captured), if any.
    public private(set) var koLoc: Int?
    /// Zobrist hash of the position (stones only — no ko point, no player to
    /// move), mirroring Board::pos_hash.
    public private(set) var posHash: UInt64
    public private(set) var numBlackCaptures: Int
    public private(set) var numWhiteCaptures: Int

    public init(width: Int, height: Int) {
        precondition(width >= 1 && height >= 1)
        self.width = width
        self.height = height
        self.grid = Array(repeating: .empty, count: width * height)
        self.koLoc = nil
        self.posHash = 0
        self.numBlackCaptures = 0
        self.numWhiteCaptures = 0
    }

    public var area: Int { width * height }

    public func index(of p: GoPoint) -> Int? {
        guard p.x >= 0, p.x < width, p.y >= 0, p.y < height else { return nil }
        return p.y * width + p.x
    }

    public func point(at index: Int) -> GoPoint {
        GoPoint(x: index % width, y: index / width)
    }

    public func color(at p: GoPoint) -> GoColor? {
        index(of: p).map { grid[$0] }
    }

    /// Orthogonal on-board neighbors of a flat index.
    public func neighbors(of index: Int) -> [Int] {
        let x = index % width
        let y = index / width
        var result: [Int] = []
        result.reserveCapacity(4)
        if x > 0 { result.append(index - 1) }
        if x < width - 1 { result.append(index + 1) }
        if y > 0 { result.append(index - width) }
        if y < height - 1 { result.append(index + width) }
        return result
    }

    // MARK: - Zobrist

    /// Deterministic per-(location, color) Zobrist key via splitMix64. Values
    /// need not match KataGo's — only self-consistency matters (superko
    /// compares hashes produced by this same function).
    static func zobristKey(index: Int, color: GoColor) -> UInt64 {
        splitMix64(UInt64(index) &* 2 &+ UInt64(color == .black ? 0 : 1) &+ 0x9E37_79B9_7F4A_7C15)
    }

    /// Key folded in for the player to move (situational superko).
    static func playerKey(_ color: GoColor) -> UInt64 {
        splitMix64(color == .black ? 0xB1AC_0000_0000_0001 : 0x3717_E000_0000_0002)
    }

    static func splitMix64(_ input: UInt64) -> UInt64 {
        var z = input &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Situational hash: position + player to move.
    public func situationalHash(toMove: GoColor) -> UInt64 {
        posHash ^ Self.playerKey(toMove)
    }

    // MARK: - Chains and liberties

    /// All indices of the chain containing `index` (which must hold a stone).
    public func chain(at index: Int) -> [Int] {
        let color = grid[index]
        precondition(color != .empty)
        var seen = [Bool](repeating: false, count: grid.count)
        var stack = [index]
        seen[index] = true
        var result: [Int] = []
        while let loc = stack.popLast() {
            result.append(loc)
            for adj in neighbors(of: loc) where !seen[adj] && grid[adj] == color {
                seen[adj] = true
                stack.append(adj)
            }
        }
        return result
    }

    public func libertyCount(ofChainAt index: Int) -> Int {
        let color = grid[index]
        precondition(color != .empty)
        var seen = [Bool](repeating: false, count: grid.count)
        var libertySeen = [Bool](repeating: false, count: grid.count)
        var stack = [index]
        seen[index] = true
        var liberties = 0
        while let loc = stack.popLast() {
            for adj in neighbors(of: loc) {
                if grid[adj] == color {
                    if !seen[adj] {
                        seen[adj] = true
                        stack.append(adj)
                    }
                } else if grid[adj] == .empty, !libertySeen[adj] {
                    libertySeen[adj] = true
                    liberties += 1
                }
            }
        }
        return liberties
    }

    // MARK: - Legality

    /// Port of Board::isIllegalSuicide: a play is illegal suicide when every
    /// neighbor is a full-liberty friendly chain we may not sacrifice, or an
    /// opponent chain we do not capture. Connecting to ANY friendly chain
    /// makes suicide legal when the rules allow multi-stone suicide;
    /// single-stone suicide is always illegal.
    func isIllegalSuicide(at index: Int, color: GoColor, multiStoneSuicideLegal: Bool) -> Bool {
        let opp = color.opponent
        for adj in neighbors(of: index) {
            if grid[adj] == .empty {
                return false
            } else if grid[adj] == color {
                if multiStoneSuicideLegal || libertyCount(ofChainAt: adj) > 1 {
                    return false
                }
            } else if grid[adj] == opp {
                if libertyCount(ofChainAt: adj) == 1 {
                    return false
                }
            }
        }
        return true
    }

    /// Board-level legality (Board::isLegal): empty point, not the simple-ko
    /// point, not illegal suicide. Superko is the game's job (GoGame).
    public func isLegal(at p: GoPoint, color: GoColor, multiStoneSuicideLegal: Bool) -> Bool {
        guard let index = index(of: p) else { return false }
        return grid[index] == .empty
            && koLoc != index
            && !isIllegalSuicide(at: index, color: color, multiStoneSuicideLegal: multiStoneSuicideLegal)
    }

    // MARK: - Mutation

    /// Places a setup stone (handicap) without capture logic or ko effects.
    /// The target must be empty.
    public mutating func placeSetupStone(at p: GoPoint, color: GoColor) {
        guard let index = index(of: p), grid[index] == .empty, color != .empty else {
            preconditionFailure("invalid setup stone")
        }
        grid[index] = color
        posHash ^= Self.zobristKey(index: index, color: color)
        koLoc = nil
    }

    /// Port of Board::playMoveAssumeLegal for stone plays. Validates
    /// board-level legality and throws instead of assuming. Resolves
    /// captures, suicide removal, capture counters, ko point, and hash.
    ///
    /// Returns every point this move CLEARED: the opponent chains it captured,
    /// or — on a multi-stone suicide — the mover's own chain. The board's
    /// removal animation needs to know which stones a move took (ADR 0015) and
    /// the capture counters cannot say: they are running totals that name no
    /// points.
    ///
    /// Deliberately a RETURN VALUE and not a stored property. `GoBoard`'s
    /// `Equatable` is synthesized, and `SgfReplay.Position` equality and the
    /// differential tests both rest on it — a per-move annotation stored here
    /// would make two identical positions compare unequal.
    @discardableResult
    public mutating func play(at p: GoPoint, color: GoColor, multiStoneSuicideLegal: Bool) throws -> [GoPoint] {
        guard let index = index(of: p) else { throw GoPlayError.offBoard }
        guard grid[index] == .empty else { throw GoPlayError.occupied }
        guard koLoc != index else { throw GoPlayError.simpleKoBanned }
        guard !isIllegalSuicide(at: index, color: color, multiStoneSuicideLegal: multiStoneSuicideLegal) else {
            throw GoPlayError.suicideIllegal
        }

        let opp = color.opponent
        grid[index] = color
        posHash ^= Self.zobristKey(index: index, color: color)

        var captured = 0
        var cleared: [GoPoint] = []
        var possibleKoLoc: Int?
        var oppChainsSeen: [Int] = []
        for adj in neighbors(of: index) where grid[adj] == opp {
            let oppChain = chain(at: adj)
            guard !oppChainsSeen.contains(oppChain[0]) else { continue }
            oppChainsSeen.append(oppChain[0])
            if libertyCount(ofChainAt: adj) == 0 {
                for loc in oppChain {
                    grid[loc] = .empty
                    posHash ^= Self.zobristKey(index: loc, color: opp)
                    cleared.append(point(at: loc))
                }
                captured += oppChain.count
                possibleKoLoc = adj
            }
        }
        if color == .black {
            numWhiteCaptures += captured
        } else {
            numBlackCaptures += captured
        }

        // Ko: exactly one stone captured by a lone stone that itself has
        // exactly one liberty (playMoveAssumeLegal's condition).
        let ownChain = chain(at: index)
        if captured == 1, ownChain.count == 1, libertyCount(ofChainAt: index) == 1 {
            koLoc = possibleKoLoc
        } else {
            koLoc = nil
        }

        // Multi-stone suicide (only reachable when the rules allow it). It is
        // mutually exclusive with the captures above: a captured chain is by
        // construction adjacent to the played stone, so it hands that stone a
        // liberty and this branch cannot run. Callers rely on that to tell
        // whose stones `cleared` names.
        if libertyCount(ofChainAt: index) == 0 {
            let suicided = chain(at: index)
            for loc in suicided {
                grid[loc] = .empty
                posHash ^= Self.zobristKey(index: loc, color: color)
                cleared.append(point(at: loc))
            }
            if color == .black {
                numBlackCaptures += suicided.count
            } else {
                numWhiteCaptures += suicided.count
            }
            koLoc = nil
        }

        return cleared
    }

    /// A pass clears the simple-ko point (playMoveAssumeLegal PASS branch).
    public mutating func playPass() {
        koLoc = nil
    }

    /// Removes stones (marked dead at scoring time). No capture accounting —
    /// the area-equivalent scoring makes removal itself carry the points.
    public func removingStones(at indices: some Sequence<Int>) -> GoBoard {
        var board = self
        for index in indices where board.grid[index] != .empty {
            board.posHash ^= Self.zobristKey(index: index, color: board.grid[index])
            board.grid[index] = .empty
        }
        board.koLoc = nil
        return board
    }

    /// Stones of a color as GTP vertices, for WidgetBoardView.
    public func gtpVertices(of color: GoColor) -> [String] {
        var result: [String] = []
        for (i, c) in grid.enumerated() where c == color {
            result.append(point(at: i).gtpVertex(boardHeight: height))
        }
        return result
    }
}
