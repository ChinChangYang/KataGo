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
    /// Board edge lengths this app can hold: the engine is compiled with
    /// `COMPILE_MAX_BOARD_LEN=37`, and `cpp/dataio/sgf.cpp`'s `getXYSize`
    /// refuses anything <= 1.
    public static let supportedBoardLengths: ClosedRange<Int> = 2...37

    /// Board width from the ROOT node's `SZ[]` (19 when absent, as in
    /// `Sgf::getXYSize`). Always clamped into `supportedBoardLengths`, so no
    /// reader can be steered into allocating a huge board; check
    /// `boardSizeIsSupported` to learn whether the clamp changed anything.
    public var boardWidth: Int
    /// Board height; see `boardWidth`.
    public var boardHeight: Int
    /// Whether the root's `SZ[]` is one the engine's own `loadsgf` would load
    /// as exactly `boardWidth` x `boardHeight`: absent (19x19), or a single
    /// value whose dimensions parse and lie in `supportedBoardLengths`. False
    /// for an unparseable, out-of-range, or repeated/multi-valued root `SZ`
    /// (the C++ parser requires a singleton); `boardWidth`/`boardHeight` are
    /// then a clamped stand-in, and a caller about to hand the SGF to an
    /// engine must refuse it.
    public var boardSizeIsSupported: Bool
    public var komi: Float?
    public var rules: String?
    /// The root's `PL[...]` property, decoded (case-insensitively) from the
    /// four spellings the C++ parser's `getPLSpecifiedColor` accepts: `w`,
    /// `white`, `b`, `black`. `nil` when absent or unrecognized.
    public var nextPlayerOverride: PlayerColor?
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
    /// final move's color. With no moves at all, falls back to the same
    /// ladder the C++ engine's `CompactSgf::setupInitialBoardAndHist` uses:
    /// `PL[...]` override, else White when the setup is all-Black (a fresh
    /// classic-handicap root), else Black.
    public func toMove(atMoveIndex index: Int) -> PlayerColor {
        if index < moveColors.count { return moveColors[index] }
        if let last = moveColors.last { return last.other }
        if let nextPlayerOverride { return nextPlayerOverride }
        if !setupBlack.isEmpty && setupWhite.isEmpty { return .white }
        return .black
    }

    /// Scan the root property block and mainline moves. Returns nil when the
    /// text has no SGF root node at all.
    public init?(sgf: String) {
        guard let rootStart = sgf.firstIndex(of: ";"), sgf.contains("(") else { return nil }

        // SZ/KM/RU/PL are read from the ROOT node's properties only — the
        // node the engine's `loadsgf` reads them from (`nodes[0]` in
        // cpp/dataio/sgf.cpp) — with bracketed values skipped as values, so a
        // comment such as C[SZ[100000]] can never be mistaken for the board
        // size. Moves are still collected in document order along the main
        // line.
        let text = sgf[rootStart...]
        let root = Self.rootProperties(of: sgf)

        let size = Self.boardSize(fromRootValues: root["SZ"])
        let width = size.width
        let height = size.height
        boardWidth = width
        boardHeight = height
        boardSizeIsSupported = size.isSupported
        if let rawKomi = root["KM"]?.first,
           let value = Float(rawKomi.trimmingCharacters(in: .whitespacesAndNewlines)),
           value.isFinite {
            komi = value
        } else {
            komi = nil
        }
        rules = root["RU"]?.first
        // Matches getPLSpecifiedColor's accepted spellings exactly: w/white/
        // b/black, case-insensitively.
        switch root["PL"]?.first?.lowercased() {
        case "w"?, "white"?: nextPlayerOverride = .white
        case "b"?, "black"?: nextPlayerOverride = .black
        default: nextPlayerOverride = nil
        }

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

    /// The root node's properties, read the way cpp/dataio/sgf.cpp's
    /// `maybeParseNode`/`maybeParseProperty` read them: starting at the first
    /// ";" after the first "(", an identifier is a run of ASCII letters
    /// (whitespace between tokens is skipped), each "[...]" is one value with
    /// "\" escaping the next character, and the node ends at the first
    /// character that is none of those (";", "(", ")"). Repeated identifiers
    /// accumulate their values, as `SgfNode::addProperty` does. An
    /// unterminated value ends the scan without recording it.
    static func rootProperties(of sgf: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        guard let openParen = sgf.firstIndex(of: "("),
              let semicolon = sgf[openParen...].firstIndex(of: ";")
        else { return result }

        var index = sgf.index(after: semicolon)
        var key = ""
        var keyHasValue = false
        while index < sgf.endIndex {
            let character = sgf[index]
            if character.isASCII && character.isLetter {
                // A letter after a completed value starts the NEXT property.
                if keyHasValue {
                    key = ""
                    keyHasValue = false
                }
                key.append(character)
                index = sgf.index(after: index)
            } else if character.isWhitespace {
                index = sgf.index(after: index)
            } else if character == "[" && !key.isEmpty {
                index = sgf.index(after: index)
                var value = ""
                var escaped = false
                var closed = false
                while index < sgf.endIndex {
                    let valueCharacter = sgf[index]
                    index = sgf.index(after: index)
                    if escaped {
                        escaped = false
                        value.append(valueCharacter)
                    } else if valueCharacter == "\\" {
                        escaped = true
                    } else if valueCharacter == "]" {
                        closed = true
                        break
                    } else {
                        value.append(valueCharacter)
                    }
                }
                guard closed else { break }
                result[key, default: []].append(value)
                keyHasValue = true
            } else {
                break
            }
        }
        return result
    }

    /// Board geometry from the root's `SZ` values, following
    /// `Sgf::getXYSize`: absent is 19x19; "N" is NxN; "W:H" is WxH; integers
    /// may carry surrounding whitespace (`Global::tryStringToInt` trims).
    /// The returned dimensions are always inside `supportedBoardLengths`.
    static func boardSize(fromRootValues values: [String]?)
        -> (width: Int, height: Int, isSupported: Bool) {
        guard let values else { return (19, 19, true) }
        guard let first = values.first, let parsed = parseBoardSize(first) else {
            return (19, 19, false)
        }
        let range = supportedBoardLengths
        let width = min(max(parsed.width, range.lowerBound), range.upperBound)
        let height = min(max(parsed.height, range.lowerBound), range.upperBound)
        let isSupported = values.count == 1
            && range.contains(parsed.width) && range.contains(parsed.height)
        return (width, height, isSupported)
    }

    private static func parseBoardSize(_ raw: String) -> (width: Int, height: Int)? {
        func integer(_ part: Substring) -> Int? {
            Int(part.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            guard let side = integer(parts[0]) else { return nil }
            return (side, side)
        case 2:
            guard let width = integer(parts[0]), let height = integer(parts[1]) else { return nil }
            return (width, height)
        default:
            return nil
        }
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
