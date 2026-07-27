//
//  RecognizedBoard+Editing.swift
//  GobanRecogKit
//
//  Tap-to-correct editing seam for the photo-import preview: pure,
//  value-semantic transforms over `RecognizedBoard.rows` so the user can fix
//  mis-recognized stones (e.g. a shadow flipping white stones to black)
//  before importing. Deterministic and dependency-light, like the synthesis
//  logic in RecognizedBoard.swift.
//

import Foundation
import KataGoUICore

extension RecognizedBoard {
    /// One correction tap: cycles the intersection at (col, row) through
    /// `.` → `B` → `W` → `.`, with row 0 = top (matching `rows`).
    /// Out-of-range indices return `self`; size/confidence/quadSource are
    /// preserved.
    public func cyclingStone(atCol col: Int, row: Int) -> RecognizedBoard {
        guard (0..<size).contains(col), (0..<size).contains(row) else { return self }
        var chars = Array(rows[row])
        guard col < chars.count else { return self }
        switch chars[col] {
        case ".": chars[col] = "B"
        case "B": chars[col] = "W"
        default: chars[col] = "."
        }
        var newRows = rows
        newRows[row] = String(chars)
        // The quad rides along: a stone edit does not move the grid, and losing
        // it here would drop the seed for a later "Adjust Grid".
        return RecognizedBoard(size: size, rows: newRows,
                               confidence: confidence, quadSource: quadSource,
                               detectedQuad: detectedQuad)
    }

    /// Pure rows → GTP-vertex mapping (row-major), the preview's render input.
    /// Row 0 = top, so grid row `r` is GTP row `size - r`; column letters come
    /// from `Coordinate` (which skips "I"). The
    /// `stoneVerticesMatchEngineFinalStones` test pins this mapping to the
    /// importer's SGF → engine-final-position path, so the preview still shows
    /// exactly what Import produces.
    public var stoneVertices: (black: [String], white: [String]) {
        var black: [String] = []
        var white: [String] = []
        for (row, line) in rows.enumerated() {
            for (col, ch) in line.enumerated() {
                guard ch == "B" || ch == "W",
                      let move = Coordinate(x: col, y: size - row,
                                            width: size, height: size)?.move else { continue }
                if ch == "B" {
                    black.append(move)
                } else {
                    white.append(move)
                }
            }
        }
        return (black, white)
    }
}
