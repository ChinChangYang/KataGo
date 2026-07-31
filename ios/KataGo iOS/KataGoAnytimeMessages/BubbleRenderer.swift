//
//  BubbleRenderer.swift
//  KataGoAnytimeMessages
//
//  Renders the message-bubble snapshot (a WidgetBoardView frame via
//  ImageRenderer) and the caption/summary strings. Captions must read the
//  same for both participants, so they name the color to move, never "you".
//

import SwiftUI
import GoRulesKit
import KataGoGameStore

@MainActor
enum BubbleRenderer {
    /// Bubble snapshot: the current position, last move marked.
    static func image(for message: MessageGame) -> UIImage? {
        let board = message.game.board
        var lastMoveVertex: String?
        if case .play(let p) = message.game.moves.last {
            lastMoveVertex = p.gtpVertex(boardHeight: board.height)
        }
        let view = WidgetBoardView(
            width: board.width,
            height: board.height,
            blackVertices: board.gtpVertices(of: .black),
            whiteVertices: board.gtpVertices(of: .white),
            lastMoveVertex: lastMoveVertex,
            showCoordinates: MessagesBoardStyle.showsCoordinates,
            style: MessagesBoardStyle.board)
            .frame(width: 300, height: 300 * CGFloat(board.height) / CGFloat(board.width))
        let renderer = ImageRenderer(content: view)
        renderer.scale = MessagesBoardStyle.bubbleRenderScale
        return renderer.uiImage
    }

    static func caption(for message: MessageGame) -> String {
        let game = message.game
        switch game.phase {
        case .playing:
            if game.moves.isEmpty {
                return "New game — \(game.toMove == .black ? "Black" : "White") to play"
            }
            return "Move \(game.moves.count) — \(game.toMove == .black ? "Black" : "White") to play"
        case .scoring:
            return game.markedDead.isEmpty
                ? "Both passed — mark dead stones"
                : "Score proposed: \(game.scoreNow().result.shortText)"
        case .finished(let result):
            return resultText(result)
        }
    }

    static func subcaption(for message: MessageGame) -> String {
        let board = message.game.board
        let rules = message.game.rules
        let size = "\(board.width)×\(board.height)"
        let ruleset = RulesPreset.matching(rules)?.id ?? "Custom rules"
        return "\(size) · \(ruleset) · Komi \(rules.komi.formatted())"
    }

    static func resultText(_ result: GoGameResult) -> String {
        switch result.kind {
        case .score(let whiteMinusBlack):
            if whiteMinusBlack > 0 {
                return "White wins by \(abs(whiteMinusBlack).formatted())"
            } else if whiteMinusBlack < 0 {
                return "Black wins by \(abs(whiteMinusBlack).formatted())"
            }
            return "Draw"
        case .resignation(let winner):
            return winner == .black ? "Black wins — White resigned" : "White wins — Black resigned"
        }
    }
}
