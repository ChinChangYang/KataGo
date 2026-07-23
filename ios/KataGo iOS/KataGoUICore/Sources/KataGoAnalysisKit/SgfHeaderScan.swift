//
//  SgfHeaderScan.swift
//  KataGoAnalysisKit
//
//  Lightweight, engine-free scan of an SGF's root properties and mainline
//  move list. Lets the native service answer `start` immediately (geometry,
//  komi, rules, move count) and gate boards the NN buffer cannot hold BEFORE
//  booting the engine. The engine's own `loadsgf` remains ground truth for
//  positions; this scan only needs to agree on counts and colors along the
//  mainline — the first branch at every fork, which is the line WGo-style
//  viewers play. Textually that is everything up to the FIRST ")" outside a
//  property value (a gametree's sequence continues into its first child
//  subtree, so the deepest first-child chain ends at the first close-paren).
//

import Foundation

public struct SgfHeaderScan: Sendable, Equatable {
    public var boardWidth: Int
    public var boardHeight: Int
    public var komi: Float?
    public var rules: String?
    /// Colors of the mainline moves in order (move 1 first). Handicap games
    /// start with .white here because the scan reads actual B[]/W[] nodes,
    /// not an assumed alternation.
    public var moveColors: [PlayerColor]

    public var moveCount: Int { moveColors.count }

    /// Side to move at position `index` (after `index` moves): the color of
    /// mainline move `index + 1`, or after the last move, the opposite of the
    /// final move's color. An empty game defaults to Black.
    public func toMove(atMoveIndex index: Int) -> PlayerColor {
        if index < moveColors.count { return moveColors[index] }
        return moveColors.last?.other ?? .black
    }

    /// Scan the root property block and mainline moves. Returns nil when the
    /// text has no SGF root node at all.
    public init?(sgf: String) {
        guard let rootStart = sgf.firstIndex(of: ";"), sgf.contains("(") else { return nil }

        // Root properties live between the first ";" and the first move node.
        // Scan the whole text for SZ/KM/RU (they only legally appear in the
        // root), but collect moves in document order along the main line.
        let text = sgf[rootStart...]

        var width = 19
        var height = 19
        if let match = text.firstMatch(of: /SZ\[(\d+)(?::(\d+))?\]/) {
            width = Int(match.1) ?? 19
            height = match.2.flatMap { Int($0) } ?? width
        }
        boardWidth = width
        boardHeight = height
        komi = text.firstMatch(of: /KM\[([-\d.]+)\]/).flatMap { Float($0.1) }
        rules = text.firstMatch(of: /RU\[([^\]]*)\]/).map { String($0.1) }

        // Move nodes are ";B[...]" / ";W[...]" — the node separator prefix
        // distinguishes them from setup AB[]/AW[]. The sanitized walk blanks
        // long property values, so comment text can only forge a move node in
        // the pathological ≤8-char case — acceptable for a header scan whose
        // ground truth is loadsgf.
        moveColors = Self.mainlineForMoveScan(text).matches(of: /;\s*([BW])\[[^\]]*\]/).map {
            $0.1 == "B" ? PlayerColor.black : .white
        }
    }

    /// Mainline text for the move regex: walk until the first ")" OUTSIDE a
    /// property value, honoring "\" escapes inside values, and blank values
    /// longer than a move/size literal so comment bodies cannot smuggle fake
    /// move nodes or a premature ")" into the scan.
    private static func mainlineForMoveScan(_ text: Substring) -> String {
        var out = ""
        var value = ""
        var inValue = false
        var escaped = false
        for character in text {
            if inValue {
                if escaped {
                    escaped = false
                    value.append(character)
                } else if character == "\\" {
                    escaped = true
                } else if character == "]" {
                    inValue = false
                    out.append(value.count <= 8 ? value : "")
                    out.append("]")
                    value = ""
                } else {
                    value.append(character)
                }
                continue
            }
            if character == "[" {
                inValue = true
                out.append(character)
            } else if character == ")" {
                break
            } else {
                out.append(character)
            }
        }
        return out
    }
}
