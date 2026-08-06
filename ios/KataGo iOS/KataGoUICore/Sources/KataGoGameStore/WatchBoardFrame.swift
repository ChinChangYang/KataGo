//
//  WatchBoardFrame.swift
//  KataGoGameStore
//
//  What the watch draws: one position it replayed itself from its own copy of
//  a saved game.
//
//  This used to carry a `Source` discriminator because a frame could also
//  arrive mirrored from the iPhone over WatchConnectivity. That channel is
//  gone, and with it the candidate list — nothing analyzes on the watch, so a
//  frame's analysis fields are only ever whatever the record already cached.
//
//  Lives here rather than in the watch target because the watch has no test
//  bundle — this is the same reason the visionOS logic lives in the package.
//

import Foundation

public struct WatchBoardFrame: Equatable, Sendable {
    public var title: String?
    public var boardWidth: Int
    public var boardHeight: Int
    public var blackStones: [String]
    public var whiteStones: [String]
    public var lastMoveVertex: String?
    public var moveIndex: Int?
    public var moveCount: Int?
    /// Black's win rate, 0...1. Nil where nothing has been analyzed — hidden,
    /// never zeroed, so the watch does not invent a number.
    public var winrateBlack: Float?
    /// Black's score lead in points. Nil where nothing has been analyzed.
    public var scoreLeadBlack: Float?
    /// The engine's best move at this index, as the record cached it.
    public var bestMove: String?
    /// The commentary the record cached at this index.
    public var comment: String?

    public init(title: String?, boardWidth: Int, boardHeight: Int,
                blackStones: [String], whiteStones: [String],
                lastMoveVertex: String?,
                moveIndex: Int?, moveCount: Int?,
                winrateBlack: Float?, scoreLeadBlack: Float?,
                bestMove: String?, comment: String?) {
        self.title = title
        self.boardWidth = boardWidth
        self.boardHeight = boardHeight
        self.blackStones = blackStones
        self.whiteStones = whiteStones
        self.lastMoveVertex = lastMoveVertex
        self.moveIndex = moveIndex
        self.moveCount = moveCount
        self.winrateBlack = winrateBlack
        self.scoreLeadBlack = scoreLeadBlack
        self.bestMove = bestMove
        self.comment = comment
    }

    /// What the Review toggle can actually do with this frame's cached best
    /// move.
    public enum BestMoveMark: Equatable, Sendable {
        /// Nothing to show: the toggle is off, or the record cached no best
        /// move at this index (coverage is whatever the phone happened to
        /// analyze, so most indices land here).
        case none
        /// A vertex the board can draw.
        case drawable(String)
        /// A vertex the board CANNOT draw, carried so the caller can say so in
        /// words instead of showing an unchanged board.
        ///
        /// This is not hypothetical: `Coordinate.move` returns the literal
        /// string `"pass"`, `GobanState.maybeUpdateAnalysisData` stores
        /// whatever `getBestMove` returned, and near the end of a scored game
        /// passing IS the engine's best move — so any well-reviewed game has
        /// cached passes at exactly the indices a user scrubs to last.
        case unrenderable(String)
    }

    /// Classifies the cached best move for the Review page's toggle.
    ///
    /// Renderability is decided with `parseVertex` — the same function the
    /// board itself parses with — so the classification and the drawing can
    /// never disagree about what "drawable" means.
    public func bestMoveMark(showBestMove: Bool) -> BestMoveMark {
        guard showBestMove, let bestMove else { return .none }
        guard parseVertex(bestMove, width: boardWidth, height: boardHeight) != nil else {
            return .unrenderable(bestMove)
        }
        return .drawable(bestMove)
    }

    /// The vertex to hand `WidgetBoardView`, or nil.
    public func bestMoveVertex(showBestMove: Bool) -> String? {
        guard case .drawable(let vertex) = bestMoveMark(showBestMove: showBestMove) else {
            return nil
        }
        return vertex
    }

    /// "B+3.2" / "W+3.2" from Black's signed score lead.
    public static func scoreText(_ scoreLeadBlack: Float) -> String {
        scoreLeadBlack >= 0 ? String(format: "B+%.1f", scoreLeadBlack)
                            : String(format: "W+%.1f", -scoreLeadBlack)
    }

    /// "62%" from Black's win rate.
    ///
    /// Black-perspective to agree with the gutter bar beside the board, which
    /// fills from the bottom for Black, and with that bar's accessibility
    /// label — the number and the picture must never disagree about whose win
    /// rate is being shown.
    public static func winratePercentText(_ winrateBlack: Float) -> String {
        "\(Int((winrateBlack * 100).rounded()))%"
    }
}
