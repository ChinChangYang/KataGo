//
//  SweepPlanner.swift
//  KataGoAnalysisKit
//
//  Pure scheduling state for the whole-game analysis sweep: which position to
//  analyze next (outward from the position the user is looking at, so the
//  visible neighborhood fills first), re-centering when the user navigates,
//  and the seq-numbered outbox that makes pull-based delivery resumable (a
//  lost reply is re-fetched via `sinceSeq`; re-delivery is idempotent because
//  results are keyed by `moveIndex`).
//

import Foundation

/// Chooses the next position of the sweep. Positions are move indices
/// 0...moveCount (0 = empty board, N = after SGF move N).
public struct SweepPlanner: Sendable, Equatable {
    public let moveCount: Int
    public private(set) var center: Int
    private var completed: Set<Int> = []

    public init(moveCount: Int, currentIndex: Int) {
        self.moveCount = max(0, moveCount)
        self.center = Self.clamp(currentIndex, to: self.moveCount)
    }

    public var total: Int { moveCount + 1 }
    public var done: Int { completed.count }
    public var isComplete: Bool { done >= total }

    /// The user navigated: bias the remaining sweep around the new position.
    public mutating func recenter(on index: Int) {
        center = Self.clamp(index, to: moveCount)
    }

    public mutating func markCompleted(_ index: Int) {
        guard (0...moveCount).contains(index) else { return }
        completed.insert(index)
    }

    public func isCompleted(_ index: Int) -> Bool { completed.contains(index) }

    /// Next index to analyze: center, then alternating outward (center+1,
    /// center-1, center+2, …), skipping already-completed positions. Nil when
    /// the sweep is complete.
    public func nextIndex() -> Int? {
        if !completed.contains(center) { return center }
        for distance in 1...max(1, moveCount) {
            for candidate in [center + distance, center - distance]
            where (0...moveCount).contains(candidate) && !completed.contains(candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func clamp(_ value: Int, to moveCount: Int) -> Int {
        min(max(0, value), moveCount)
    }
}

/// Seq-numbered delivery buffer. Seqs start at 1 and are strictly increasing;
/// `entries(after:)` returns everything a poller has not seen yet.
public struct AnalysisOutbox: Sendable, Equatable {
    private var entries: [MoveAnalysis] = []
    private var nextSeq = 1

    public init() {}

    public var lastSeq: Int { nextSeq - 1 }

    /// Latest result per position, for cache replies and drop computation.
    public func latest(forMoveIndex index: Int) -> MoveAnalysis? {
        entries.last { $0.moveIndex == index }
    }

    @discardableResult
    public mutating func append(_ analysis: MoveAnalysis) -> MoveAnalysis {
        var stamped = analysis
        stamped.seq = nextSeq
        nextSeq += 1
        entries.append(stamped)
        return stamped
    }

    public func entries(after seq: Int) -> [MoveAnalysis] {
        entries.filter { $0.seq > seq }
    }
}

/// Perspective math shared by the native service and its tests.
public enum AnalysisMath {
    /// Convert a side-to-move winrate to Black's perspective.
    public static func blackWinrate(_ winrate: Float, toMove: PlayerColor) -> Float {
        toMove == .white ? 1 - winrate : winrate
    }

    /// Convert a side-to-move score lead to Black's perspective.
    public static func blackScoreLead(_ scoreLead: Float, toMove: PlayerColor) -> Float {
        toMove == .white ? -scoreLead : scoreLead
    }

    /// Winrate lost by the player who moved, given Black-perspective winrates
    /// of the positions before and after the move. Positive = the move hurt.
    public static func winrateDrop(beforeB: Float, afterB: Float, mover: PlayerColor) -> Float {
        mover == .white ? afterB - beforeB : beforeB - afterB
    }
}
