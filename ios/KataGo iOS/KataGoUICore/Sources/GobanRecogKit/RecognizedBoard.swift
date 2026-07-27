//
//  RecognizedBoard.swift
//  GobanRecogKit
//
//  The Swift-native result of recognizing a Go board from a photo, plus the
//  pure SGF-synthesis contract that turns it into a saved-game-ready SGF.
//
//  Everything here is deterministic, dependency-light (Foundation + the
//  PlayerColor enum re-exported from KataGoUICore) and side-effect free, so the
//  synthesis logic is unit-testable without the recognizer, OpenCV, or the
//  engine.
//

import Foundation
import KataGoUICore

/// A recognized Go position: a square board of `size`, its rows top-to-bottom
/// (row 0 = the topmost image row, matching the C++ seam and SGF `aa` = top
/// left), the recognizer's confidence, and which quad proposer found the board.
///
/// `rows[r]` is a `size`-length string of `.` (empty), `B` (black), `W` (white).
public struct RecognizedBoard: Equatable, Sendable {
    public let size: Int
    public let rows: [String]
    public let confidence: Double
    public let quadSource: String
    /// Where the recognizer decided the board's four OUTER GRID-LINE
    /// INTERSECTIONS are — not the wooden edge — in normalized [0,1]²
    /// top-left-origin coordinates of the upright image. nil when no detection
    /// produced corners.
    ///
    /// Carried so the manual-grid editor can open on what the app found instead
    /// of a blank rectangle, which turns the interaction from "place the four
    /// corners" into "correct the two that are wrong".
    public let detectedQuad: BoardQuad?

    public init(size: Int,
                rows: [String],
                confidence: Double,
                quadSource: String,
                detectedQuad: BoardQuad? = nil) {
        self.size = size
        self.rows = rows
        self.confidence = confidence
        self.quadSource = quadSource
        self.detectedQuad = detectedQuad
    }

    /// Number of black stones on the board.
    public var blackCount: Int { count(of: "B") }

    /// Number of white stones on the board.
    public var whiteCount: Int { count(of: "W") }

    private func count(of stone: Character) -> Int {
        rows.reduce(0) { $0 + $1.reduce(0) { $1 == stone ? $0 + 1 : $0 } }
    }

    /// The default side to move, from the on-board stone counts:
    ///   - Black == White              → Black (even position, Black started)
    ///   - Black == White + 1          → White (Black has played one more)
    ///   - otherwise                   → Black
    ///
    /// A physical position is usually reached after alternating play from an
    /// empty board, so equal counts mean it is Black's turn and one extra black
    /// stone means White's; anything else (handicap, captures, a half-finished
    /// setup) is ambiguous, so we fall back to Black and let the user override
    /// with the picker.
    public var defaultNextToPlay: PlayerColor {
        if blackCount == whiteCount { return .black }
        if blackCount == whiteCount + 1 { return .white }
        return .black
    }

    /// Synthesizes a saved-game-ready SGF for this position.
    ///
    /// Contract (see task brief / plan):
    ///   `(;GM[1]FF[4]CA[UTF-8]AP[KataGo Anytime]SZ[n]RU[Chinese]KM[7]PL[B|W]AB[…]AW[…])`
    ///
    /// - `RU[Chinese]` is MANDATORY: the engine's `loadsgf` reads rules via
    ///   `Sgf::getRulesOrFail`, which aborts (uncatchable) on an SGF with no
    ///   rules tag. `Chinese` is KataGo's safe default (parsed case-insensitively).
    /// - `KM[7]` matches the bridge's default komi so the displayed komi is
    ///   consistent after import.
    /// - `PL[B|W]` is the chosen next-to-play.
    /// - Points are column-letter first (`chr('a'+col)+chr('a'+row)`), `aa` =
    ///   top-left = a direct map from `rows` (row 0 = topmost). `AB` (black)
    ///   then `AW` (white), each row-major, each section omitted when empty.
    public func synthesizedSGF(nextToPlay: PlayerColor) -> String {
        var black = ""
        var white = ""
        for (row, line) in rows.enumerated() {
            for (col, ch) in line.enumerated() {
                switch ch {
                case "B": black += "[\(Self.point(col: col, row: row))]"
                case "W": white += "[\(Self.point(col: col, row: row))]"
                default: break
                }
            }
        }

        let pl = nextToPlay == .white ? "W" : "B"
        var sgf = "(;GM[1]FF[4]CA[UTF-8]AP[KataGo Anytime]SZ[\(size)]RU[Chinese]KM[7]PL[\(pl)]"
        if !black.isEmpty { sgf += "AB" + black }
        if !white.isEmpty { sgf += "AW" + white }
        sgf += ")"
        return sgf
    }

    /// SGF coordinate for a (col, row) intersection: column letter first, then
    /// row letter, both `a`-based. `col`/`row` are 0-based; only sizes ≤ 25 are
    /// produced by the recognizer, so single lowercase letters always suffice.
    static func point(col: Int, row: Int) -> String {
        let colChar = Character(UnicodeScalar(UInt8(97 + col)))
        let rowChar = Character(UnicodeScalar(UInt8(97 + row)))
        return "\(colChar)\(rowChar)"
    }
}

/// Thrown by `BoardRecognizer.recognize` when a photo cannot be turned into a
/// board.
public enum BoardRecognitionError: Error, Equatable, Sendable {
    /// The image data could not be decoded into a pixel buffer.
    case invalidImage
    /// The recognizer abstained. `reason` is the raw `failed:<reason>` tail from
    /// the C++ pipeline (e.g. `low_confidence`, `ambiguous board size …`,
    /// `all quad proposers failed: …`), preserved for logging; use
    /// `userFacingMessage` for display.
    case recognitionFailed(reason: String)

    /// A single friendly, coaching message for the terminal failure sheet.
    /// `.invalidImage` is the sheet's only real audience — undecodable data,
    /// nothing to crop. `.recognitionFailed`'s copy here is just the fallback
    /// used if the crop-phase's own display decode fails after ingestion
    /// already succeeded; ordinarily a `.recognitionFailed` opens the crop
    /// phase instead of reaching this message. The pipeline's abstention
    /// reasons (board-not-found / low-confidence / ambiguous-size) all map to
    /// the same guidance, since the fix is the same: reshoot the board.
    public var userFacingMessage: String {
        switch self {
        case .invalidImage:
            return "That image couldn't be opened. Try a different photo."
        case .recognitionFailed:
            return "Couldn't find a Go board. Take the photo from directly above, "
                + "with the whole board in frame and even lighting."
        }
    }
}
