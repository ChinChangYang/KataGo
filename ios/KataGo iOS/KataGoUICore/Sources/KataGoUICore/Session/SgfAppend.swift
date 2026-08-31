//
//  SgfAppend.swift
//  KataGoUICore
//
//  Appends one move to a record in pure Swift. The record owns the board
//  (ADR 0008), so a stone a human plays has to reach the record even when no
//  engine is loaded — it can no longer arrive through the engine's `printsgf`
//  rewrite of the whole SGF. Unlike `SgfTruncation` (linear records only, every
//  top-level node counted as a move), this writer follows the main line through
//  variations and counts only nodes that carry a `B` or `W` property, so a raw
//  import with branches, comment nodes or a setup node cuts at the right place.
//
//  The main line is the one the app's parser shows, NOT the SGF standard's:
//  `SgfOperations` (the C++ `CompactSgf` behind `RecordPositionProjector`)
//  picks, at every fork, the child with the greatest `Sgf::depth()` — the
//  longest node count along any path below it, every `;` node counted — and
//  keeps the first child on a tie (`Sgf::getMovesHelper`,
//  `SgfCpp::traverseSgfHelper`). Following the same rule keeps the record's
//  move indices and the board's in one index space, so move `n + 1` lands after
//  the position the user is looking at. The SGF first-child convention is
//  deliberately not used.
//

import Foundation
import KataGoAnalysisKit
import KataGoGameStore

/// Appends one move to a record in Swift — the record owns the board (ADR 0008),
/// so a played stone must reach the record without an engine's `printsgf`.
public enum SgfAppend {
    /// The record with `color` ("b"/"w", case-insensitive) playing `vertex`
    /// (a GTP vertex such as "Q16", or "pass") as move number `n + 1` on the
    /// main line: everything after the first `n` main-line moves is dropped
    /// (later main-line moves and every variation beyond the cut), the new
    /// move node is appended, and the tree is closed. `n` past the main line's
    /// length appends at its end. Nil when the text has no root node or the
    /// vertex does not fit a `width` × `height` board.
    ///
    /// The main line is the app parser's (see the file comment): the deepest
    /// child at every fork by node count, the first on a tie — index parity
    /// with `SgfOperations`. Variations not on that line are dropped as well,
    /// the ones branching BEFORE the cut included: the output is a single
    /// linear line, so shortening the chosen line can never make the parser
    /// prefer a sibling that was left standing. A node is a move node iff it
    /// has a property whose identifier is exactly `B` or `W`; the root, a setup
    /// node (`AB`/`AW`) and a bare comment node are not counted, and those
    /// standing before the cut are kept. Also nil for a negative `n`, a color
    /// other than b/w, an unterminated property value, and for `n == 0` on a
    /// record whose ROOT node carries the first move (there is no way to cut
    /// before that move without discarding the root's SZ/KM/RU).
    public static func appending(color: String,
                                 vertex: String,
                                 afterMoveCount n: Int,
                                 to sgf: String,
                                 width: Int,
                                 height: Int) -> String? {
        guard n >= 0,
              let tag = moveTag(for: color),
              let point = sgfPoint(vertex: vertex, width: width, height: height)
        else { return nil }
        let bytes = Array(sgf.utf8)
        guard let kept = keptPrefix(in: bytes, afterMoveCount: n) else { return nil }
        // Every splice lands on an ASCII structural byte (or the end), so the
        // kept text is a whole number of UTF-8 scalars.
        return String(decoding: kept.prefix, as: UTF8.self)
            + ";" + tag + "[" + point + "]"
            + String(repeating: ")", count: kept.openParens)
    }

    /// The SGF point for a GTP vertex on a `width` × `height` board; "" for a
    /// pass; nil when the vertex does not fit.
    ///
    /// GTP columns are letters skipping I ("A".."Z", then "AA".."AZ"); the row
    /// is 1-based and counted from the BOTTOM, while SGF's y runs from the top,
    /// so the SGF row is `height - row`. Letters follow `sgfCoordinate`: a–z
    /// for 0..25, then A–Z for 26..51.
    public static func sgfPoint(vertex: String, width: Int, height: Int) -> String? {
        let trimmed = vertex.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare("pass") == .orderedSame { return "" }
        guard width >= 1, height >= 1 else { return nil }
        let letters = trimmed.prefix { $0.isASCII && $0.isLetter }
        let digits = trimmed.dropFirst(letters.count)
        guard !letters.isEmpty, !digits.isEmpty,
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let x = Coordinate.xMap[letters.uppercased()],
              let row = Int(digits),
              x < width, (1...height).contains(row)
        else { return nil }
        return BoardHandicapPoints.sgfCoordinate(x: x, y: height - row)
    }

    // MARK: - Private

    /// The move property identifier for a GTP color; nil for anything else.
    private static func moveTag(for color: String) -> String? {
        switch color.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "b", "black": return "B"
        case "w", "white": return "W"
        default: return nil
        }
    }

    /// One `;` node of the scanned tree.
    private struct Node {
        /// Byte index of its `;`.
        let start: Int
        /// Whether it carries a `B` or `W` property.
        var isMove = false
    }

    /// One variation (game tree) of the scanned text.
    private struct Variation {
        /// Byte index of its `(`.
        let open: Int
        /// Byte index of its `)`; `bytes.count` when the text ends first.
        var close: Int
        var nodes: [Node] = []
        /// Indices into the scanned array, in document order.
        var children: [Int] = []
        /// C++ `Sgf::depth()`: own node count plus the deepest child's depth.
        var depth = 0
    }

    private static let lparen = UInt8(ascii: "(")
    private static let rparen = UInt8(ascii: ")")
    private static let lbracket = UInt8(ascii: "[")
    private static let rbracket = UInt8(ascii: "]")
    private static let semicolon = UInt8(ascii: ";")
    private static let backslash = UInt8(ascii: "\\")
    private static let blackTag: [UInt8] = [UInt8(ascii: "B")]
    private static let whiteTag: [UInt8] = [UInt8(ascii: "W")]

    /// The first game tree of `bytes` as variations in document (pre-order)
    /// order — index 0 is the root, every child follows its parent — with
    /// each variation's depth computed. One pass: inside a property value
    /// (`[`…`]`, `\` escaping the next byte) nothing counts. Outside, `(`
    /// opens a child of the innermost open variation, `)` closes it (the
    /// root's `)` ends the scan; trailing text is ignored), `;` starts a node,
    /// and a node becomes a move node at its first `B[`/`W[`, whose identifier
    /// is the run of ASCII letters (whitespace tolerated) since the last
    /// non-letter — the same reading as the C++ parser's `maybeParseProperty`,
    /// so `AB`, `BL`, `PB` and `Black` are not moves.
    ///
    /// Nil when the text does not start with `(` then `;` (a BOM and
    /// whitespace allowed) or ends inside a property value.
    private static func scanTree(_ bytes: [UInt8]) -> [Variation]? {
        var i = 0
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { i = 3 }
        while i < bytes.count, isWhitespace(bytes[i]) { i += 1 }
        guard i < bytes.count, bytes[i] == lparen else { return nil }
        var afterParen = i + 1
        while afterParen < bytes.count, isWhitespace(bytes[afterParen]) { afterParen += 1 }
        guard afterParen < bytes.count, bytes[afterParen] == semicolon else { return nil }

        var variations: [Variation] = []
        var open: [Int] = []
        var inValue = false
        var escaped = false
        var identifier: [UInt8] = []

        scan: while i < bytes.count {
            let c = bytes[i]
            if inValue {
                if escaped {
                    escaped = false
                } else if c == backslash {
                    escaped = true
                } else if c == rbracket {
                    inValue = false
                }
                i += 1
                continue
            }
            switch c {
            case lbracket:
                inValue = true
                if identifier == blackTag || identifier == whiteTag,
                   let top = open.last, !variations[top].nodes.isEmpty {
                    variations[top].nodes[variations[top].nodes.count - 1].isMove = true
                }
                identifier.removeAll(keepingCapacity: true)
            case lparen:
                variations.append(Variation(open: i, close: bytes.count))
                let index = variations.count - 1
                if let top = open.last { variations[top].children.append(index) }
                open.append(index)
                identifier.removeAll(keepingCapacity: true)
            case rparen:
                if let top = open.popLast() { variations[top].close = i }
                if open.isEmpty { break scan }
                identifier.removeAll(keepingCapacity: true)
            case semicolon:
                if let top = open.last { variations[top].nodes.append(Node(start: i)) }
                identifier.removeAll(keepingCapacity: true)
            default:
                if isAsciiLetter(c) {
                    identifier.append(c)
                } else if !isWhitespace(c) {
                    identifier.removeAll(keepingCapacity: true)
                }
            }
            i += 1
        }
        if inValue { return nil }

        // Children always follow their parent, so a reverse pass sees every
        // child's depth before its parent needs it.
        for index in variations.indices.reversed() {
            let deepestChild = variations[index].children.map { variations[$0].depth }.max() ?? 0
            variations[index].depth = variations[index].nodes.count + deepestChild
        }
        return variations
    }

    /// The child the app's parser descends into: the deepest, the first on a
    /// tie (strict `>` from `children[0]`, as in `Sgf::getMovesHelper`).
    private static func deepestChild(of variation: Variation, in variations: [Variation]) -> Int? {
        var best: Int?
        var bestDepth = 0
        for child in variation.children {
            let depth = variations[child].depth
            if best == nil || depth > bestDepth {
                best = child
                bestDepth = depth
            }
        }
        return best
    }

    /// The text kept in front of the new move node — the main line's
    /// variations spliced together, every other variation left out — and the
    /// number of `(` in it still to be closed after the node.
    ///
    /// Walks the main line variation by variation: the (n+1)-th move node ends
    /// the walk in front of its `;`, or in front of the `(` of its variation
    /// when it is that variation's first node (so no empty variation is left
    /// behind); a main line with `n` or fewer move nodes ends the walk at its
    /// last variation's `)`. Descending into a child keeps the parent's text up
    /// to its first child's `(` — the siblings before the chosen child go with
    /// everything after the cut. Nil when the text is not a game tree, or the
    /// cut would fall in front of a move living in the root node.
    private static func keptPrefix(in bytes: [UInt8], afterMoveCount n: Int) -> (prefix: [UInt8], openParens: Int)? {
        guard let variations = scanTree(bytes), !variations.isEmpty else { return nil }
        var prefix: [UInt8] = []
        prefix.reserveCapacity(bytes.count)
        var openParens = 0
        var moveCount = 0
        var current = 0
        // The root segment starts at the text's start, keeping a BOM or
        // whitespace ahead of its "(".
        var segmentStart = 0
        while true {
            let variation = variations[current]
            for (position, node) in variation.nodes.enumerated() where node.isMove {
                if moveCount == n {
                    if position == 0 {
                        if current == 0 { return nil }
                        return (prefix, openParens)
                    }
                    prefix.append(contentsOf: bytes[segmentStart..<node.start])
                    return (prefix, openParens + 1)
                }
                moveCount += 1
            }
            guard let chosen = deepestChild(of: variation, in: variations) else {
                prefix.append(contentsOf: bytes[segmentStart..<variation.close])
                return (prefix, openParens + 1)
            }
            // Up to the FIRST child's "(": when the chosen child comes later,
            // that is where the dropped earlier siblings begin.
            prefix.append(contentsOf: bytes[segmentStart..<variations[variation.children[0]].open])
            openParens += 1
            current = chosen
            segmentStart = variations[chosen].open
        }
    }

    private static func isWhitespace(_ c: UInt8) -> Bool {
        c == 0x20 || (0x09...0x0D).contains(c)
    }

    private static func isAsciiLetter(_ c: UInt8) -> Bool {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(c) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(c)
    }
}
