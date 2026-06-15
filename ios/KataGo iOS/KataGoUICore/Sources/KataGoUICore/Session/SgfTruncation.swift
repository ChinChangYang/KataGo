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
}
