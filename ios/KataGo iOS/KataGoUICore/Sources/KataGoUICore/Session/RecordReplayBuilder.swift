//
//  RecordReplayBuilder.swift
//  KataGoUICore
//
//  The ONE construction of a record's engine-free replay (decision 3: one SGF
//  parser for display, feed and navigation). Display goes through
//  `RecordPositionProjector`; the feed and refusal-aware navigation go through
//  `GobanState`. Both build the replay here, out of the same C++ parse, so the
//  two can never disagree about which index holds which move — or about which
//  moves the engine was actually given.
//

import Foundation
import GoRulesKit

public enum RecordReplayBuilder {
    /// The engine-free replay for an already-parsed record.
    ///
    /// Nil when the parser rejected the record: `SgfCpp` reports a 0x0 board
    /// for anything it could not read, and neither a 0-wide board nor
    /// `SgfReplay`'s clamped 1x1 substitute is a board worth drawing — or
    /// feeding to the engine.
    public static func replay(from operations: SgfOperations) -> SgfReplay? {
        guard operations.xSize > 0, operations.ySize > 0 else { return nil }

        let placements = operations.placements()
        func setup(_ kind: Placement.Kind) -> [GoPoint] {
            placements.filter { $0.kind == kind }.map { GoPoint(x: $0.x, y: $0.y) }
        }

        var moves: [SgfReplay.RecordedMove] = []
        let moveCount = operations.moveSize ?? 0
        moves.reserveCapacity(moveCount)
        for index in 0..<moveCount {
            // A nil here would shift every later index, so stop rather than
            // skip: the record is malformed past this point and the shorter
            // replay is the honest one.
            guard let move = operations.getMove(at: index) else { break }
            moves.append(SgfReplay.RecordedMove(
                color: move.player == .black ? .black : .white,
                point: move.location.pass ? nil : GoPoint(x: move.location.x,
                                                          y: move.location.y)))
        }

        return SgfReplay(width: operations.xSize,
                         height: operations.ySize,
                         setupBlack: setup(.black),
                         setupWhite: setup(.white),
                         setupEmpty: setup(.removal),
                         moves: moves)
    }
}
