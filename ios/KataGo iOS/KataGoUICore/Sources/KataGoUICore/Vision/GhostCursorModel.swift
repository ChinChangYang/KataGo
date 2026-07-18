//
//  GhostCursorModel.swift
//  KataGoUICore
//
//  Controller-driven aiming cursor for the 3D goban: a ghost stone that
//  glides (thumbstick) and steps (D-pad). Pure grid logic; rendering and
//  input live in the app target.
//

import Foundation
import Observation

@Observable
@MainActor
public final class GhostCursorModel {
    /// Current aim, or nil while hidden.
    public private(set) var point: BoardPoint?

    /// Preferred reveal point for the next activation (the board's last
    /// move); nil = board center. Stored unclamped — the board can change
    /// size before it is applied — and clamped at application time. Nothing
    /// renders the anchor itself, so observing it would churn on every move
    /// while the ghost is hidden.
    @ObservationIgnored public private(set) var anchor: BoardPoint?

    // Fractional glide deltas accumulate at render rate; observation would
    // churn per frame with no visible change until a whole step lands.
    @ObservationIgnored private var columnAccumulator: Float = 0
    @ObservationIgnored private var rowAccumulator: Float = 0

    public enum StepDirection: Sendable {
        case up, down, left, right
    }

    public init() {}

    /// Shows the ghost at `origin`, else the stored anchor (the last move),
    /// else the center intersection; no-op while visible. The explicit
    /// `origin` exists so callers needing a deterministic reveal (the DEBUG
    /// autoplay harness) can bypass whatever anchor the game left behind.
    public func activate(width: Int, height: Int, at origin: BoardPoint? = nil) {
        guard point == nil else { return }
        columnAccumulator = 0
        rowAccumulator = 0
        let target = origin ?? anchor ?? BoardPoint(x: width / 2, y: height / 2)
        point = clamped(target, width: width, height: height)
    }

    /// Remembers where the next activation should reveal the ghost (the
    /// board's last move; nil = center). A visible ghost snaps to the new
    /// anchor — the cursor follows the latest move — but a nil anchor leaves
    /// it in place rather than yanking active aim. Never reveals a hidden
    /// ghost.
    public func setAnchor(_ origin: BoardPoint?, width: Int, height: Int) {
        anchor = origin
        guard point != nil, let origin else { return }
        columnAccumulator = 0
        rowAccumulator = 0
        point = clamped(origin, width: width, height: height)
    }

    /// One intersection per press; +row (`.up`) moves away from the viewer.
    /// While hidden, the first press only reveals the ghost (at the anchor,
    /// else the center).
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
        point = clamped(BoardPoint(x: x, y: y), width: width, height: height)
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
        point = clamped(BoardPoint(x: current.x + dx, y: current.y + dy),
                        width: width, height: height)
    }

    /// Hides the ghost and clears any partial glide. Keeps the anchor so the
    /// next reveal still lands on the last move.
    public func reset() {
        point = nil
        columnAccumulator = 0
        rowAccumulator = 0
    }

    private func clamped(_ target: BoardPoint, width: Int, height: Int) -> BoardPoint {
        BoardPoint(
            x: min(max(target.x, 0), width - 1),
            y: min(max(target.y, 0), height - 1)
        )
    }
}
