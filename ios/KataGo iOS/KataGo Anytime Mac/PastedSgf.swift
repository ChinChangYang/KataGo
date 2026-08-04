//
//  PastedSgf.swift
//  KataGo Anytime Mac
//
//  The pure core of Edit ▸ Paste (⌘V): decide whether a clipboard string is an
//  SGF this app can turn into a game, and report the geometry the caller needs
//  to know whether the running engine can hold it.
//
//  Deliberately free of AppKit, KataGoUICore and the C++ bridge: the macOS test
//  target links only the bridge-free `KataGoGameStore` / `KataGoAnalysisKit`, so
//  keeping the decision logic here is what makes it unit-testable at all. The
//  clipboard I/O and everything that touches the store live in
//  `GameClipboardActions.swift`.
//

import Foundation
import KataGoAnalysisKit

/// A clipboard string that scans as a usable SGF.
struct PastedSgf: Equatable {
    /// The text to hand the importer: BOM-stripped and whitespace-trimmed,
    /// never the raw clipboard string.
    ///
    /// Normalizing HERE rather than at the call site is what makes ⌘C followed
    /// by ⌘V of an untouched game de-duplicate instead of adding a second row:
    /// `GameRecord.findExistingGameRecord(withSgf:)` matches on the EXACT
    /// string, so the copy has to round-trip byte-identically.
    let sgf: String
    let boardWidth: Int
    let boardHeight: Int
    let moveCount: Int

    /// Largest clipboard payload we will scan, in UTF-8 bytes. A scan walks the
    /// string character by character on the main thread, so an unbounded
    /// clipboard (a copied log file, a base64 blob) must not be able to stall
    /// the paste. For scale: a 500-move SGF is ~5 KB and a heavily commented
    /// professional collection ~1 MB.
    static let maxByteLength = 8 * 1024 * 1024

    /// Smallest board KataGo will play, matching `NewGameViewController`'s
    /// `max(2, …)` floor. A malformed `SZ[0]`/`SZ[1]` must not reach the engine.
    static let minBoardLength = 2

    /// Returns nil when `text` is absent, oversized, or does not scan as an SGF.
    ///
    /// The leading-`(` and byte-order-mark rules exist to agree with the C++
    /// parser that `GameRecord.importGameRecord` ultimately runs: `peekSgfChar`
    /// (`cpp/dataio/sgf.cpp`) skips a UTF-8 BOM and leading whitespace but then
    /// demands `(`, and `maybeParseSgf` returns null for anything else. Without
    /// the same rules this scan would accept strings the importer rejects, and
    /// ⌘V would fail after the user had already been asked about their draft.
    ///
    /// NOTE `trimmingCharacters(in: .whitespacesAndNewlines)` does NOT strip
    /// U+FEFF — it is category Cf, not Zs — so the BOM is removed explicitly.
    static func scan(_ text: String?) -> PastedSgf? {
        guard let text, text.utf8.count <= maxByteLength else { return nil }

        var candidate = Substring(text)
        if candidate.first == "\u{FEFF}" {
            candidate = candidate.dropFirst()
        }
        let trimmed = String(candidate).trimmingCharacters(in: .whitespacesAndNewlines)

        // An SGF quoted inside prose ("my game: (;GM[1]…)") is rejected on
        // purpose: the importer would reject it too, and silently slicing the
        // string at the first "(" risks importing a fragment of something the
        // user did not mean to paste.
        guard trimmed.hasPrefix("("), let scan = SgfHeaderScan(sgf: trimmed) else { return nil }

        return PastedSgf(sgf: trimmed,
                         boardWidth: scan.boardWidth,
                         boardHeight: scan.boardHeight,
                         moveCount: scan.moveCount)
    }

    /// Whether an engine launched with `maxBoardLength` as its NN-buffer size
    /// can hold this board.
    ///
    /// Mirrors `KataGoUICore.BackendChoice.boardFits(width:height:maxBoardLength:)`,
    /// which this file cannot import (KataGoUICore is not linked by the macOS
    /// test target). Keep the two in step: a board over the cap makes
    /// `NNEvaluator::evaluate` throw on a search worker thread, which aborts the
    /// whole process on the first analysis — not on load, so the gate has to run
    /// before the game is ever opened.
    /// The guard comes FIRST: a `ClosedRange` whose lower bound exceeds its
    /// upper bound traps at runtime, so a nonsense cap must be rejected before
    /// the range is formed, not after.
    func fits(maxBoardLength: Int) -> Bool {
        guard maxBoardLength >= Self.minBoardLength else { return false }
        let supported = Self.minBoardLength...maxBoardLength
        return supported.contains(boardWidth) && supported.contains(boardHeight)
    }
}
