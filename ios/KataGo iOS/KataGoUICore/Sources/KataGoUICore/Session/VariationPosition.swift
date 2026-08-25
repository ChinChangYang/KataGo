//
//  VariationPosition.swift
//  KataGoUICore
//
//  A VARIATION is a hypothetical continuation played out on the position under
//  study: the engine's principal variation, or the stones a broadcast beat acts
//  out. It is force-played by `GoRulesKit.ForcePlay` — every liberty-less group
//  lifted, nothing refused — so a variation board is always a position the
//  rules could produce, never the current stones with extra ones laid on top.
//
//  `VariationPosition` is the KataGoUICore-owned value the force-play is
//  projected into, so `GoRulesKit` types never appear on this module's public
//  surface — the same contract `RecordPosition` keeps for the record replay.
//
//  Nothing here moves a capture count. A variation is a picture of what would
//  happen, not something that happened.
//

import Foundation
import GoRulesKit

/// One move of a variation, with its color stated rather than inferred. A
/// principal variation alternates and is adapted by `alternating(_:startingWith:)`;
/// a beat's stones carry their own colors and do not alternate at all.
public struct VariationMove: Sendable, Equatable {
    public let vertex: String
    public let color: PlayerColor

    public init(vertex: String, color: PlayerColor) {
        self.vertex = vertex
        self.color = color
    }
}

/// A resolved variation board: the stones that survive, and the move numbers
/// belonging to the points a variation move still occupies.
public struct VariationPosition: Sendable, Equatable {
    public let blackPoints: [BoardPoint]
    public let whitePoints: [BoardPoint]
    /// The point each input move owns at the end, index-aligned with the moves
    /// passed in; nil when the move placed nothing, or when the stone it placed
    /// did not survive the rest of the line.
    ///
    /// Deliberately per-move rather than a ready-made number map: only the
    /// caller knows which slice of the chain is the numbered part, and reading
    /// a number back to decide that is how a legitimate number gets erased.
    public let survivingPoints: [BoardPoint?]
    /// Moves that asked for a stone and did not get one. Zero for every
    /// well-formed line; see `VariationResolver.resolve`.
    public let skippedCount: Int
}

public enum VariationResolver {

    /// Adapts a principal variation — GTP vertices whose colors alternate from
    /// `startingWith` — into explicit moves. A "pass" entry advances the color
    /// and consumes an index, exactly as the engine's own numbering does.
    public static func alternating(_ vertices: [String],
                                   startingWith: PlayerColor) -> [VariationMove] {
        var color = startingWith
        return vertices.map { vertex in
            defer { color = color == .black ? .white : .black }
            return VariationMove(vertex: vertex, color: color)
        }
    }

    /// Force-plays `moves` onto the base position and projects the result.
    /// Returns nil only for a degenerate board size.
    public static func resolve(width: Int, height: Int,
                               blackVertices: [String], whiteVertices: [String],
                               moves: [VariationMove]) -> VariationPosition? {
        guard let result = forcePlay(width: width, height: height,
                                     blackVertices: blackVertices,
                                     whiteVertices: whiteVertices,
                                     moves: moves) else { return nil }
        let board = result.board

        var blackPoints: [BoardPoint] = []
        var whitePoints: [BoardPoint] = []
        for index in 0..<board.area {
            let color = board.grid[index]
            guard color != .empty else { continue }
            let point = boardPoint(board.point(at: index), height: height)
            if color == .black { blackPoints.append(point) } else { whitePoints.append(point) }
        }

        // A move owns its point only while its own stone still stands there —
        // a later capture, or a replay by the other color, takes it away.
        var survivingPoints: [BoardPoint?] = []
        survivingPoints.reserveCapacity(result.dispositions.count)
        for (offset, disposition) in result.dispositions.enumerated() {
            guard let goPoint = disposition.point,
                  board.color(at: goPoint) == goColor(moves[offset].color) else {
                survivingPoints.append(nil)
                continue
            }
            survivingPoints.append(boardPoint(goPoint, height: height))
        }

        return VariationPosition(blackPoints: blackPoints, whitePoints: whitePoints,
                                 survivingPoints: survivingPoints,
                                 skippedCount: result.skippedCount)
    }

    /// The same force-play, projected back to GTP vertices for callers that
    /// speak in vertices (the broadcast's frame merge).
    ///
    /// Order is preserved deliberately: the base's own order first, minus
    /// whatever the variation captured, then the variation's stones in the
    /// order they were played. Callers compare these lists as arrays.
    public static func resolveVertices(width: Int, height: Int,
                                       blackVertices: [String], whiteVertices: [String],
                                       moves: [VariationMove]) -> (black: [String], white: [String])? {
        guard let result = forcePlay(width: width, height: height,
                                     blackVertices: blackVertices,
                                     whiteVertices: whiteVertices,
                                     moves: moves) else { return nil }
        let board = result.board

        var black: [String] = []
        var white: [String] = []
        var emitted: Set<GoPoint> = []

        func emit(_ vertex: String, _ goPoint: GoPoint) {
            guard emitted.insert(goPoint).inserted else { return }
            switch board.color(at: goPoint) {
            case .black: black.append(vertex)
            case .white: white.append(vertex)
            default: break
            }
        }

        for vertex in blackVertices + whiteVertices {
            guard let goPoint = self.goPoint(vertex, width: width, height: height) else { continue }
            emit(vertex, goPoint)
        }
        for (offset, disposition) in result.dispositions.enumerated() {
            guard let goPoint = disposition.point else { continue }
            emit(moves[offset].vertex, goPoint)
        }
        return (black, white)
    }

    // MARK: - Shared force-play

    private static func forcePlay(width: Int, height: Int,
                                  blackVertices: [String], whiteVertices: [String],
                                  moves: [VariationMove]) -> ForcePlayResult? {
        let forced = moves.map { ForcePlayMove(vertex: $0.vertex, color: goColor($0.color)) }
        guard let result = ForcePlay.resolve(width: width, height: height,
                                             setupBlack: blackVertices,
                                             setupWhite: whiteVertices,
                                             moves: forced) else { return nil }
        report(result, moves: moves, width: width, height: height)
        return result
    }

    /// A skipped move means a variation asked for a point it could not have —
    /// unreachable for a well-formed line, because the move that clears a point
    /// travels ahead of the move that uses it. Reported once per distinct
    /// symptom: a renderer re-resolves on every body evaluation, so an
    /// un-deduped log would drown the console.
    private static func report(_ result: ForcePlayResult, moves: [VariationMove],
                               width: Int, height: Int) {
        guard result.skippedCount > 0 else { return }
        for (offset, disposition) in result.dispositions.enumerated() where disposition.isSkipped {
            let reason = disposition == .skippedUnplaceable
                ? "names no intersection on \(width)x\(height)"
                : "is occupied by the other color"
            skipLog.noteOnce("VariationResolver: move \(offset + 1) "
                             + "(\(moves[offset].vertex)) \(reason); drawing the variation without it")
        }
    }

    // MARK: - Conversions

    private static func goColor(_ color: PlayerColor) -> GoColor {
        color == .black ? .black : .white
    }

    /// `BoardPoint` counts rows from the BOTTOM; `GoPoint` counts them from the
    /// top, as the SGF and the C++ parser do. A pure flip, no string round-trip.
    private static func boardPoint(_ point: GoPoint, height: Int) -> BoardPoint {
        BoardPoint(x: point.x, y: height - 1 - point.y)
    }

    /// The SAME parse `ForcePlay` uses, deliberately: `parseVertex` is a prefix
    /// scan that already bounds-checks both axes and already returns GoPoint's
    /// top-left convention, so there is no flip to get wrong here and no
    /// disagreement possible with the board the force-play just built.
    ///
    /// NOT `BoardPoint(move:)`, which builds a Swift `Regex` per call: this runs
    /// once per base stone on every `resolveVertices`, i.e. per broadcast beat
    /// on Apple TV, where a mid-game 19x19 would mean ~150 regex constructions
    /// for an answer a prefix scan gives for free. It also maps "pass" to a
    /// synthetic off-board point rather than nil, which is a guard this would
    /// then have to remember to write.
    private static func goPoint(_ vertex: String, width: Int, height: Int) -> GoPoint? {
        guard let parsed = parseVertex(vertex, width: width, height: height) else { return nil }
        return GoPoint(x: parsed.x, y: parsed.y)
    }
}

/// Remembers what it has already said, so a "should never happen" that repeats
/// every frame is reported once rather than sixty times a second.
private final class SkipLog: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: Set<String> = []

    func noteOnce(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        guard seen.insert(message).inserted else { return }
        printError(message)
    }
}

private let skipLog = SkipLog()
