//
//  SgfTruncation.swift
//  KataGo iOS
//

import Foundation

/// Truncates a linear SGF to its first N move nodes. Pure and bracket-aware:
/// a comment value containing ';' or an escaped ']' cannot shift the cut.
/// Assumes a linear SGF with no variations, which is what the app saves
/// (printsgf mainline output).
public enum SgfTruncation {
    /// Returns `sgf` containing only the root node plus the first `n` move
    /// nodes, closed with ")". If `sgf` has `n` or fewer moves (or `n < 0`),
    /// returns `sgf` unchanged.
    public static func truncate(_ sgf: String, toMoveCount n: Int) -> String {
        guard n >= 0 else { return sgf }

        let chars = Array(sgf)
        var inBracket = false
        var escaped = false
        var topLevelSemicolons = 0   // 1st = root node; (k+1)-th = move node k

        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inBracket {
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "]" {
                    inBracket = false
                }
            } else if c == "[" {
                inBracket = true
            } else if c == ";" {
                topLevelSemicolons += 1
                // The (n+2)-th top-level ';' starts move node n+1: cut here.
                if topLevelSemicolons == n + 2 {
                    return String(chars[0..<i]) + ")"
                }
            }
            i += 1
        }

        // Fewer than n+1 moves were present — nothing to truncate.
        return sgf
    }

    /// Returns `sgf` with its root node's `PL[]` set to `color`: every root
    /// `PL[]` is removed and one `PL[<color>]` takes the first one's place,
    /// or is added right after the root's ";" when there was none. KataGo's
    /// parser collects every root `PL[]` value into one list and reads it
    /// only when there is exactly one, so exactly one is what is left.
    ///
    /// Bracket-aware like `truncate`, so a comment cannot hide or fake a
    /// property, and a later node's `PL[]` is left alone. Property names read
    /// as the parser reads them: letters of either case, with whitespace
    /// allowed before a value. Returns `sgf` unchanged when it has no root.
    public static func withRootPlayer(_ color: PlayerColor, in sgf: String) -> String {
        guard let side = color.symbol?.uppercased() else { return sgf }
        let chars = Array(sgf)
        var inBracket = false
        var escaped = false
        var rootStart: Int?          // just after the root's ';'
        var identifier = ""
        var identifierStart = 0
        var inRootPL = false
        var rootPLs: [Range<Int>] = []  // each "PL" through its last value's ']'

        var i = 0
        scan: while i < chars.count {
            let c = chars[i]
            if inBracket {
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "]" {
                    inBracket = false
                    if inRootPL, let last = rootPLs.indices.last {
                        rootPLs[last] = rootPLs[last].lowerBound..<(i + 1)
                    }
                }
            } else if c == "[" {
                inBracket = true
                // An identifier names a new property; a bare "[" is another
                // value of the current one.
                if !identifier.isEmpty {
                    inRootPL = identifier == "PL" && rootStart != nil
                    if inRootPL { rootPLs.append(identifierStart..<i) }
                    identifier = ""
                }
            } else if c == ";" || c == "(" || c == ")" {
                if rootStart != nil { break scan }  // the root node has ended
                if c == ";" { rootStart = i + 1 }
                identifier = ""
            } else if c.isASCII && c.isLetter {
                if identifier.isEmpty { identifierStart = i }
                identifier.append(c)
            } else if !c.isWhitespace {
                identifier = ""
            }
            i += 1
        }

        guard let rootStart else { return sgf }
        let property = Array("PL[\(side)]")
        var result = chars
        guard let first = rootPLs.first else {
            result.insert(contentsOf: property, at: rootStart)
            return String(result)
        }
        for range in rootPLs.dropFirst().reversed() {
            result.removeSubrange(range)
        }
        result.replaceSubrange(first, with: property)
        return String(result)
    }
}
