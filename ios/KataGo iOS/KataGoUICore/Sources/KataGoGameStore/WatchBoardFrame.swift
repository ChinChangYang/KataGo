//
//  WatchBoardFrame.swift
//  KataGoGameStore
//
//  What the watch draws, from either of its two worlds: a position mirrored
//  from the iPhone over WCSession, or one the watch replayed itself from its
//  own copy of a saved game. The board and moves pages render a frame and
//  never ask which world produced it.
//
//  Lives here rather than in the watch target because the watch has no test
//  bundle — this is the same reason the visionOS logic lives in the package.
//

import Foundation

public struct WatchBoardFrame: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// Mirrored from the iPhone. `stale` once frames stop arriving.
        case live(stale: Bool)
        /// Replayed from the watch's own SwiftData copy of the game.
        case stored
    }

    public var title: String?
    public var boardWidth: Int
    public var boardHeight: Int
    public var blackStones: [String]
    public var whiteStones: [String]
    public var lastMoveVertex: String?
    /// Vertices to dot on the board, already capped for legibility.
    public var candidateVertices: [String]
    /// The full candidate list for the moves page. Always empty when stored —
    /// nothing analyzes on the watch.
    public var candidates: [WatchSnapshot.Candidate]
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
    public var source: Source

    public init(title: String?, boardWidth: Int, boardHeight: Int,
                blackStones: [String], whiteStones: [String],
                lastMoveVertex: String?, candidateVertices: [String],
                candidates: [WatchSnapshot.Candidate],
                moveIndex: Int?, moveCount: Int?,
                winrateBlack: Float?, scoreLeadBlack: Float?,
                bestMove: String?, comment: String?,
                source: Source) {
        self.title = title
        self.boardWidth = boardWidth
        self.boardHeight = boardHeight
        self.blackStones = blackStones
        self.whiteStones = whiteStones
        self.lastMoveVertex = lastMoveVertex
        self.candidateVertices = candidateVertices
        self.candidates = candidates
        self.moveIndex = moveIndex
        self.moveCount = moveCount
        self.winrateBlack = winrateBlack
        self.scoreLeadBlack = scoreLeadBlack
        self.bestMove = bestMove
        self.comment = comment
        self.source = source
    }

    /// How many candidate dots the board draws at watch size.
    public static let candidateDotLimit = 3

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

    /// A frame from an iPhone snapshot. The caller has already chosen WHICH
    /// snapshot (cursor target, ring entry, or live head) and whether its
    /// candidates are current — that mode logic stays in the board page.
    public static func live(snapshot: WatchSnapshot,
                            stale: Bool,
                            showCandidates: Bool,
                            lastMoveVertex: String?,
                            title: String?) -> WatchBoardFrame {
        WatchBoardFrame(
            title: title,
            boardWidth: snapshot.boardWidth,
            boardHeight: snapshot.boardHeight,
            blackStones: snapshot.blackStones,
            whiteStones: snapshot.whiteStones,
            lastMoveVertex: lastMoveVertex,
            candidateVertices: showCandidates
                ? snapshot.candidates.prefix(candidateDotLimit).map(\.vertex) : [],
            candidates: snapshot.candidates,
            moveIndex: snapshot.hostMoveIndex,
            moveCount: snapshot.hostMoveCount,
            winrateBlack: snapshot.rootWinrateBlack,
            scoreLeadBlack: snapshot.rootScoreLeadBlack,
            bestMove: nil,
            comment: nil,
            source: .live(stale: stale))
    }

    /// A frame the watch replayed from its own copy of a saved game. Analysis
    /// fields come from whatever the record cached at this index; the watch
    /// never computes them.
    public static func stored(title: String?,
                              boardWidth: Int, boardHeight: Int,
                              blackStones: [String], whiteStones: [String],
                              lastMoveVertex: String?,
                              moveIndex: Int, moveCount: Int,
                              winrateBlack: Float?, scoreLeadBlack: Float?,
                              bestMove: String?, comment: String?) -> WatchBoardFrame {
        WatchBoardFrame(
            title: title,
            boardWidth: boardWidth,
            boardHeight: boardHeight,
            blackStones: blackStones,
            whiteStones: whiteStones,
            lastMoveVertex: lastMoveVertex,
            candidateVertices: [],
            candidates: [],
            moveIndex: moveIndex,
            moveCount: moveCount,
            winrateBlack: winrateBlack,
            scoreLeadBlack: scoreLeadBlack,
            bestMove: bestMove,
            comment: comment,
            source: .stored)
    }

    /// "B+3.2" / "W+3.2" from Black's signed score lead.
    public static func scoreText(_ scoreLeadBlack: Float) -> String {
        scoreLeadBlack >= 0 ? String(format: "B+%.1f", scoreLeadBlack)
                            : String(format: "W+%.1f", -scoreLeadBlack)
    }
}
