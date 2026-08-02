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

/// A point in SGF coordinates, decoded to 0-based indices with the origin at
/// the TOP-LEFT (x right, y down) — the same convention as GoRulesKit's
/// GoPoint, so the two need no translation.
public struct SgfPoint: Sendable, Equatable, Hashable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

/// One mainline move. A nil `point` is a pass — either an explicit empty
/// value (`B[]`) or a value that lands outside the board, which is how the
/// legacy "tt" pass encodes on boards up to 19x19.
public struct SgfMove: Sendable, Equatable {
    public var color: PlayerColor
    public var point: SgfPoint?

    public init(color: PlayerColor, point: SgfPoint?) {
        self.color = color
        self.point = point
    }
}

public struct SgfHeaderScan: Sendable, Equatable {
    public var boardWidth: Int
    public var boardHeight: Int
    public var komi: Float?
    public var rules: String?
    /// The mainline moves in order (move 1 first). Handicap games start with
    /// .white here because the scan reads actual B[]/W[] nodes, not an
    /// assumed alternation.
    public var moves: [SgfMove]
    /// AB[] setup stones (handicap placement and free setup), in document
    /// order. These are positions, not moves. A compressed point range
    /// ("AB[dd:ff]") is expanded to every point in the inclusive rectangle.
    public var setupBlack: [SgfPoint]
    /// AW[] setup stones, in document order. Ranges expand as for setupBlack.
    public var setupWhite: [SgfPoint]
    /// AE[] setup-stone removals, in document order. Ranges expand as for
    /// setupBlack. NOTE (scope limit): like setupBlack/setupWhite, every AE
    /// found anywhere on the mainline is collected here as a single flat list
    /// applied at index 0 — a mid-game AE node is NOT attributed to its node
    /// position. That is a deliberate, documented gap (see SgfReplay); fixing
    /// it is a redesign of this scan's output shape and out of scope.
    public var setupEmpty: [SgfPoint]

    /// Colors of the mainline moves in order. Kept as the scan's original
    /// surface so existing callers (the Safari extension) are unaffected.
    public var moveColors: [PlayerColor] { moves.map(\.color) }

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

        // Walk the sanitized mainline into (identifier, values) properties.
        // A token scan rather than a regex because SGF property identifiers
        // are runs of uppercase letters: "AB" is ONE identifier and must never
        // be read as a Black move. The sanitized walk blanks long property
        // values, so comment text can only forge a node in the pathological
        // <=8-char case — acceptable for a scan whose ground truth is loadsgf.
        var moves: [SgfMove] = []
        var setupBlack: [SgfPoint] = []
        var setupWhite: [SgfPoint] = []
        var setupEmpty: [SgfPoint] = []
        for property in Self.properties(in: Self.mainlineForMoveScan(text)) {
            switch property.identifier {
            case "B", "W":
                let color: PlayerColor = property.identifier == "B" ? .black : .white
                let raw = property.values.first ?? ""
                moves.append(SgfMove(color: color,
                                     point: Self.point(raw, width: width, height: height)))
            case "AB":
                setupBlack += property.values.flatMap {
                    Self.points($0, width: width, height: height)
                }
            case "AW":
                setupWhite += property.values.flatMap {
                    Self.points($0, width: width, height: height)
                }
            case "AE":
                setupEmpty += property.values.flatMap {
                    Self.points($0, width: width, height: height)
                }
            default:
                break
            }
        }
        self.moves = moves
        self.setupBlack = setupBlack
        self.setupWhite = setupWhite
        self.setupEmpty = setupEmpty
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

    /// One SGF property: an identifier and its bracketed values.
    private struct Property {
        var identifier: String
        var values: [String]
    }

    /// Splits a sanitized mainline string into properties. Values are read
    /// verbatim between brackets, so nothing inside a value can be mistaken
    /// for an identifier; identifiers accumulate uppercase letters until a
    /// value block ends, so "AB" never splits into "A" and "B".
    private static func properties(in text: String) -> [Property] {
        var result: [Property] = []
        var identifier = ""
        var values: [String] = []
        var value = ""
        var inValue = false

        func flush() {
            if !identifier.isEmpty {
                result.append(Property(identifier: identifier, values: values))
            }
            identifier = ""
            values = []
        }

        for character in text {
            if inValue {
                if character == "]" {
                    inValue = false
                    values.append(value)
                    value = ""
                } else {
                    value.append(character)
                }
                continue
            }
            if character == "[" {
                inValue = true
            } else if character.isLetter && character.isUppercase {
                // An uppercase letter after a completed value block starts the
                // NEXT property; before one it extends the current identifier.
                if !values.isEmpty { flush() }
                identifier.append(character)
            } else if character == ";" || character == "(" || character == ")" {
                flush()
            }
        }
        flush()
        return result
    }

    /// Decodes an SGF point value. Returns nil for an empty value (an explicit
    /// pass) or for any point outside the board — which is exactly how the
    /// legacy "tt" pass decodes on boards up to 19x19.
    private static func point(_ raw: String, width: Int, height: Int) -> SgfPoint? {
        let letters = Array(raw)
        guard letters.count == 2,
              let x = coordinate(letters[0]),
              let y = coordinate(letters[1]),
              x < width, y < height
        else { return nil }
        return SgfPoint(x: x, y: y)
    }

    /// Decodes an SGF point-LIST value: either a single point ("dd") or a
    /// compressed rectangle ("dd:ff", the FF[4] "compressed point list"
    /// syntax several editors emit for AB/AW/AE). Both corners are inclusive
    /// and may be given in either orientation — each axis is normalised to
    /// its own min/max, more permissive than the C++ parser's
    /// `parseSgfLocRectangle` (which requires x1<=x2, y1<=y2 verbatim and
    /// throws otherwise), matching this scan's general policy of dropping
    /// what it cannot confidently decode rather than failing the whole scan.
    /// A malformed range (bad corner, wrong shape) decodes to no points —
    /// dropped, never a crash. Only used for AB/AW/AE; B/W move values are
    /// never compressed lists in the SGF spec, so `point(_:width:height:)`
    /// covers those unchanged.
    private static func points(_ raw: String, width: Int, height: Int) -> [SgfPoint] {
        guard raw.contains(":") else {
            return point(raw, width: width, height: height).map { [$0] } ?? []
        }
        let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let corner1 = point(String(parts[0]), width: width, height: height),
              let corner2 = point(String(parts[1]), width: width, height: height)
        else { return [] }

        let minX = min(corner1.x, corner2.x), maxX = max(corner1.x, corner2.x)
        let minY = min(corner1.y, corner2.y), maxY = max(corner1.y, corner2.y)
        var result: [SgfPoint] = []
        result.reserveCapacity((maxX - minX + 1) * (maxY - minY + 1))
        for y in minY...maxY {
            for x in minX...maxX {
                result.append(SgfPoint(x: x, y: y))
            }
        }
        return result
    }

    /// SGF coordinate letter: "a"..."z" = 0...25, "A"..."Z" = 26...51.
    private static func coordinate(_ character: Character) -> Int? {
        guard let ascii = character.asciiValue else { return nil }
        switch ascii {
        case UInt8(ascii: "a")...UInt8(ascii: "z"):
            return Int(ascii - UInt8(ascii: "a"))
        case UInt8(ascii: "A")...UInt8(ascii: "Z"):
            return Int(ascii - UInt8(ascii: "A")) + 26
        default:
            return nil
        }
    }
}
