//
//  GhostCursorModel.swift
//  KataGoUICore
//
//  Controller-driven aiming cursor for the 3D goban: a ghost stone that
//  glides (thumbstick), steps (D-pad), and cycles through analysis
//  candidates. Pure grid logic; rendering and input live in the app target.
//

import Foundation
import Observation

@Observable
@MainActor
public final class GhostCursorModel {
    /// Current aim, or nil while hidden.
    public private(set) var point: BoardPoint?

    // Fractional glide deltas accumulate at render rate; observation would
    // churn per frame with no visible change until a whole step lands.
    @ObservationIgnored private var columnAccumulator: Float = 0
    @ObservationIgnored private var rowAccumulator: Float = 0

    public enum StepDirection: Sendable {
        case up, down, left, right
    }

    public init() {}

    /// Shows the ghost at the center intersection; no-op while visible.
    public func activate(width: Int, height: Int) {
        guard point == nil else { return }
        columnAccumulator = 0
        rowAccumulator = 0
        point = BoardPoint(x: width / 2, y: height / 2)
    }

    /// One intersection per press; +row (`.up`) moves away from the viewer.
    /// While hidden, the first press only reveals the ghost at the center.
    /// `verticalFlip` mirrors the 2D board's rendering flag: a flipped board
    /// draws +BoardPoint.y downward, so `.up`/`.down` swap to keep the D-pad
    /// matching what the viewer sees. Defaults false (the visionOS goban and
    /// the unflipped tvOS board).
    public func step(_ direction: StepDirection, width: Int, height: Int,
                     verticalFlip: Bool = false) {
        guard let current = point else {
            activate(width: width, height: height)
            return
        }
        var x = current.x
        var y = current.y
        let dy = verticalFlip ? -1 : 1
        switch direction {
        case .up: y += dy
        case .down: y -= dy
        case .left: x -= 1
        case .right: x += 1
        }
        point = BoardPoint(
            x: min(max(x, 0), width - 1),
            y: min(max(y, 0), height - 1)
        )
    }

    /// Accumulates fractional intersections; whole steps snap the ghost,
    /// clamped to the board. +dRow moves away from the viewer (+BoardPoint.y).
    public func glide(dColumn: Float, dRow: Float, width: Int, height: Int) {
        if point == nil {
            activate(width: width, height: height)
        }
        guard let current = point else { return }
        columnAccumulator += dColumn
        rowAccumulator += dRow
        let dx = Int(columnAccumulator)
        let dy = Int(rowAccumulator)
        columnAccumulator -= Float(dx)
        rowAccumulator -= Float(dy)
        guard dx != 0 || dy != 0 else { return }
        point = BoardPoint(
            x: min(max(current.x + dx, 0), width - 1),
            y: min(max(current.y + dy, 0), height - 1)
        )
    }

    /// Jumps to the next/previous candidate (wrapping); from off-list or
    /// hidden, jumps to the first candidate. No-op when there are none.
    public func cycle(through candidates: [BoardPoint], forward: Bool) {
        guard !candidates.isEmpty else { return }
        guard let current = point, let index = candidates.firstIndex(of: current) else {
            point = candidates.first
            return
        }
        let offset = forward ? 1 : candidates.count - 1
        point = candidates[(index + offset) % candidates.count]
    }

    /// Hides the ghost and clears any partial glide.
    public func reset() {
        point = nil
        columnAccumulator = 0
        rowAccumulator = 0
    }
}
