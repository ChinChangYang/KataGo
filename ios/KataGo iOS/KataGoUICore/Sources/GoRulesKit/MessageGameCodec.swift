//
//  MessageGameCodec.swift
//  GoRulesKit
//
//  The iMessage wire format. The MSMessage URL carries the ENTIRE game —
//  setup, every move, scoring marks, result — so any device can rebuild and
//  validate the game from the single selected bubble. The receiver replays
//  the move list through GoGame; a payload that does not replay legally is
//  rejected (tamper/corruption guard). Full history is also what makes
//  superko checks and SGF export possible.
//
//  Encoding: URL query items on katago-anytime://imessage-game.
//    v: format version (1)
//    w,h: board size; ha: handicap; k: komi in half points
//    ko,sc,tx,whb: rule enum raw values; su,bt: 0/1 flags
//    cc: creator's color (b/w)
//    m: moves, two chars each from a 38-char alphabet, "--" = pass
//    ph: phase p/s/f (playing includes a just-disputed resume)
//    dm: dead-stone marks during scoring, same point encoding
//    res: final result: s<whiteMinusBlack half points> | rb | rw
//

import Foundation
import KataGoGameStore

/// A game as it travels through the conversation: the rules-engine state
/// plus the one piece of metadata the wire needs (who created it and which
/// color they took).
public struct MessageGame: Sendable {
    public var game: GoGame
    public var creatorColor: GoColor

    public init(game: GoGame, creatorColor: GoColor) {
        self.game = game
        self.creatorColor = creatorColor
    }
}

public enum MessageGameCodecError: Error, Equatable, Sendable {
    case notAGameURL
    case unsupportedVersion
    case malformedField(String)
    case illegalReplay(moveIndex: Int)
    case inconsistentPhase
}

public enum MessageGameCodec {
    /// MSMessage.url must be an http(s) URL: Messages DROPS custom-scheme
    /// URLs in transit (the receiver sees url == nil), verified in the
    /// harness. The https form also serves as the future web-fallback hook
    /// for recipients without the extension.
    public static let scheme = "https"
    public static let host = "katagoanytime.app"
    public static let path = "/game"
    public static let version = 1

    /// 38 symbols: coordinates 0...36 need 37, one spare. URL-query safe.
    static let coordinateAlphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzAB")
    static let passToken = "--"

    // MARK: - Encode

    public static func url(for messageGame: MessageGame) -> URL {
        let game = messageGame.game
        var items: [URLQueryItem] = [
            URLQueryItem(name: "v", value: String(version)),
            URLQueryItem(name: "w", value: String(game.board.width)),
            URLQueryItem(name: "h", value: String(game.board.height)),
            URLQueryItem(name: "ha", value: String(game.handicap)),
            URLQueryItem(name: "k", value: String(Int((game.rules.komi * 2).rounded()))),
            URLQueryItem(name: "ko", value: String(game.rules.koRule.rawValue)),
            URLQueryItem(name: "sc", value: String(game.rules.scoringRule.rawValue)),
            URLQueryItem(name: "tx", value: String(game.rules.taxRule.rawValue)),
            URLQueryItem(name: "su", value: game.rules.multiStoneSuicideLegal ? "1" : "0"),
            URLQueryItem(name: "bt", value: game.rules.hasButton ? "1" : "0"),
            URLQueryItem(name: "whb", value: String(game.rules.whiteHandicapBonusRule.rawValue)),
            URLQueryItem(name: "cc", value: messageGame.creatorColor == .white ? "w" : "b"),
            URLQueryItem(name: "m", value: encodeMoves(game.moves)),
        ]
        switch game.phase {
        case .playing:
            items.append(URLQueryItem(name: "ph", value: "p"))
        case .scoring:
            items.append(URLQueryItem(name: "ph", value: "s"))
            if !game.markedDead.isEmpty {
                items.append(URLQueryItem(name: "dm", value: encodePoints(
                    game.markedDead.sorted().map { game.board.point(at: $0) })))
            }
        case .finished(let result):
            items.append(URLQueryItem(name: "ph", value: "f"))
            if !game.markedDead.isEmpty {
                items.append(URLQueryItem(name: "dm", value: encodePoints(
                    game.markedDead.sorted().map { game.board.point(at: $0) })))
            }
            switch result.kind {
            case .score(let whiteMinusBlack):
                items.append(URLQueryItem(
                    name: "res", value: "s\(Int((whiteMinusBlack * 2).rounded()))"))
            case .resignation(let winner):
                items.append(URLQueryItem(name: "res", value: winner == .white ? "rw" : "rb"))
            }
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = path
        components.queryItems = items
        return components.url!
    }

    static func encodeMoves(_ moves: [GoMove]) -> String {
        moves.map { move in
            switch move {
            case .pass: passToken
            case .play(let p): String(coordinateAlphabet[p.x]) + String(coordinateAlphabet[p.y])
            }
        }.joined()
    }

    static func encodePoints(_ points: [GoPoint]) -> String {
        points.map { String(coordinateAlphabet[$0.x]) + String(coordinateAlphabet[$0.y]) }.joined()
    }

    // MARK: - Decode

    public static func isGameURL(_ url: URL) -> Bool {
        url.scheme == scheme && url.host == host && url.path == path
    }

    /// Rebuilds the game by replaying every move through the rules engine.
    public static func decode(_ url: URL) throws -> MessageGame {
        guard isGameURL(url),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            throw MessageGameCodecError.notAGameURL
        }
        var fields: [String: String] = [:]
        for item in items { fields[item.name] = item.value }

        guard let versionText = fields["v"], let version = Int(versionText), version == Self.version else {
            throw MessageGameCodecError.unsupportedVersion
        }
        func intField(_ name: String) throws -> Int {
            guard let text = fields[name], let value = Int(text) else {
                throw MessageGameCodecError.malformedField(name)
            }
            return value
        }
        let width = try intField("w")
        let height = try intField("h")
        let handicap = try intField("ha")
        guard let koRule = KoRule(rawValue: try intField("ko")),
              let scoringRule = ScoringRule(rawValue: try intField("sc")),
              let taxRule = TaxRule(rawValue: try intField("tx")),
              let whbRule = WhiteHandicapBonusRule(rawValue: try intField("whb")) else {
            throw MessageGameCodecError.malformedField("rules")
        }
        let rules = GoRules(
            koRule: koRule,
            scoringRule: scoringRule,
            taxRule: taxRule,
            multiStoneSuicideLegal: try intField("su") == 1,
            hasButton: try intField("bt") == 1,
            whiteHandicapBonusRule: whbRule,
            komi: Double(try intField("k")) / 2)
        let creatorColor: GoColor = fields["cc"] == "w" ? .white : .black

        var game: GoGame
        do {
            game = try GoGame(width: width, height: height, rules: rules, handicap: handicap)
        } catch {
            throw MessageGameCodecError.malformedField("setup")
        }

        let moves = try decodeMoves(fields["m"] ?? "", width: width, height: height)
        for (index, move) in moves.enumerated() {
            // A mid-list scoring phase means a dispute resumed play.
            if game.phase == .scoring {
                game.resumePlay()
            }
            do {
                try game.play(move)
            } catch {
                throw MessageGameCodecError.illegalReplay(moveIndex: index)
            }
        }

        let deadMarks = try (fields["dm"]).map { try decodePoints($0, width: width, height: height) } ?? []
        switch fields["ph"] {
        case "p":
            if game.phase == .scoring { game.resumePlay() }
            guard game.phase == .playing else { throw MessageGameCodecError.inconsistentPhase }
        case "s":
            guard game.phase == .scoring else { throw MessageGameCodecError.inconsistentPhase }
            game.setMarkedDead(Set(deadMarks.compactMap { game.board.index(of: $0) }))
        case "f":
            guard let result = fields["res"] else { throw MessageGameCodecError.malformedField("res") }
            if result == "rb" {
                game.resign(by: .white)
            } else if result == "rw" {
                game.resign(by: .black)
            } else if result.hasPrefix("s") {
                guard game.phase == .scoring else { throw MessageGameCodecError.inconsistentPhase }
                game.setMarkedDead(Set(deadMarks.compactMap { game.board.index(of: $0) }))
                game.confirmScore()
            } else {
                throw MessageGameCodecError.malformedField("res")
            }
        default:
            throw MessageGameCodecError.malformedField("ph")
        }
        return MessageGame(game: game, creatorColor: creatorColor)
    }

    static func decodeMoves(_ text: String, width: Int, height: Int) throws -> [GoMove] {
        let chars = Array(text)
        guard chars.count.isMultiple(of: 2) else {
            throw MessageGameCodecError.malformedField("m")
        }
        var moves: [GoMove] = []
        moves.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            if chars[i] == "-", chars[i + 1] == "-" {
                moves.append(.pass)
                continue
            }
            guard let x = coordinateAlphabet.firstIndex(of: chars[i]),
                  let y = coordinateAlphabet.firstIndex(of: chars[i + 1]),
                  x < width, y < height else {
                throw MessageGameCodecError.malformedField("m")
            }
            moves.append(.play(GoPoint(x: x, y: y)))
        }
        return moves
    }

    static func decodePoints(_ text: String, width: Int, height: Int) throws -> [GoPoint] {
        try decodeMoves(text, width: width, height: height).map { move in
            guard case .play(let p) = move else {
                throw MessageGameCodecError.malformedField("dm")
            }
            return p
        }
    }

    // MARK: - SGF emission (for the open-in-app hand-off)

    /// Standard SGF the C++ engine parses directly: SZ (w:h for rectangles),
    /// KM, RU in KataGo's compact format, HA + AB for handicap stones, then
    /// the move list. SGF's y axis matches GoPoint's (row 0 at the top).
    public static func sgf(for messageGame: MessageGame) -> String {
        let game = messageGame.game
        let board = game.board
        var out = "(;GM[1]FF[4]CA[UTF-8]"
        out += board.width == board.height
            ? "SZ[\(board.width)]"
            : "SZ[\(board.width):\(board.height)]"
        let komi = game.rules.komi
        out += komi == komi.rounded() ? "KM[\(Int(komi))]" : "KM[\(komi)]"
        out += "RU[\(game.rules.kataRulesString)]"
        if game.handicap > 0 {
            let points = GoGame.handicapPoints(
                width: board.width, height: board.height, count: game.handicap)
            out += "HA[\(game.handicap)]AB"
            for p in points { out += "[\(sgfCoord(p))]" }
        }
        if case .finished(let result) = game.phase {
            out += "RE[\(result.shortText)]"
        }
        var color = game.firstPlayer
        for move in game.moves {
            let tag = color == .black ? "B" : "W"
            switch move {
            case .pass: out += ";\(tag)[]"
            case .play(let p): out += ";\(tag)[\(sgfCoord(p))]"
            }
            color = color.opponent
        }
        out += ")"
        return out
    }

    /// SGF point letters: a...z then A...Z covers up to 52; 37 fits.
    static func sgfCoord(_ p: GoPoint) -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return String(letters[p.x]) + String(letters[p.y])
    }
}
