//
//  MoveNumbers.swift
//  KataGo iOS
//

import Foundation

/// How the board annotates move numbers. Raw values index
/// `Config.moveNumberStyles` (the picker's display strings) — keep the two in
/// the same order.
public enum MoveNumberStyle: Int {
    case lastThreeMoves = 0
    case lastMove = 1
    case allMoves = 2
    case lastMoveMarker = 3
}

/// Move numbers derived from the active game's SGF, independent of the engine's
/// showboard markers. Numbers are absolute from the game root by default, or
/// relative to `startIndex` when one is supplied (branch mode numbers only the
/// stones past the divergence point, starting from 1). When the same point is
/// played more than once (ko, recapture), the latest move number wins.
/// `lastPoint`/`lastNumber` are nil when no move was played or the last move
/// was a pass.
public struct MoveNumbers: Equatable, Sendable {
    public let numbers: [BoardPoint: Int]
    public let lastPoint: BoardPoint?
    public let lastNumber: Int?

    public static let empty = MoveNumbers(numbers: [:], lastPoint: nil, lastNumber: nil)

    public static func derive(sgf: String, currentIndex: Int, startIndex: Int = 0) -> MoveNumbers {
        let sgfHelper = SgfHelper(sgf: sgf)
        let width = sgfHelper.xSize
        let height = sgfHelper.ySize
        var numbers: [BoardPoint: Int] = [:]
        var lastPoint: BoardPoint?
        var lastNumber: Int?
        let start = max(startIndex, 0)
        var index = start

        while index < currentIndex, let move = sgfHelper.getMove(at: index) {
            let number = index - start + 1
            if move.location.pass {
                lastPoint = nil
                lastNumber = nil
            } else {
                let point = BoardPoint(location: move.location, width: width, height: height)
                numbers[point] = number
                lastPoint = point
                lastNumber = number
            }
            index += 1
        }

        return MoveNumbers(numbers: numbers, lastPoint: lastPoint, lastNumber: lastNumber)
    }

    /// The move played into `currentIndex`, or nil when there is none or it
    /// was a pass.
    ///
    /// Same answer `derive(...).lastPoint` gives — the loop above only ever
    /// keeps the FINAL iteration's point, and a pass clears it — but by
    /// reading one move instead of walking the whole mainline, and without
    /// building the `numbers` dictionary. `startIndex` is irrelevant here: it
    /// only rebases the numbering, never which move is last.
    ///
    /// Exists because the watch snapshot needs the last move at ~2 Hz and must
    /// NOT go through `GobanState.getMoveNumbers`, which returns `.empty`
    /// whenever the user's move-number style is `.lastThreeMoves` — a display
    /// preference on the phone has no business deciding whether the watch
    /// draws a last-move marker.
    /// Returns a GTP vertex rather than a `BoardPoint` because the SGF is the
    /// only thing here that knows the board's dimensions, so converting at the
    /// call site would mean re-deriving them.
    public static func lastPlayedVertex(sgf: String, currentIndex: Int) -> String? {
        guard currentIndex > 0 else { return nil }
        let sgfHelper = SgfHelper(sgf: sgf)
        // Walk back to the last index that HAS a move rather than reading
        // `currentIndex - 1` outright. `derive` stops its walk at the first
        // absent move and keeps whatever point it had reached, so an index
        // past the end of the mainline resolves to the final move there; the
        // two must agree, or the watch's marker could differ from the phone's
        // in exactly the state the caller cannot check. In practice
        // `getCurrentIndex` never overshoots, so this is one lookup.
        var index = currentIndex - 1
        while index >= 0 {
            guard let move = sgfHelper.getMove(at: index) else {
                index -= 1
                continue
            }
            guard !move.location.pass else { return nil }
            let width = sgfHelper.xSize
            let height = sgfHelper.ySize
            let point = BoardPoint(location: move.location, width: width, height: height)
            return BoardPoint.toString([point], width: width, height: height)
        }
        return nil
    }
}
