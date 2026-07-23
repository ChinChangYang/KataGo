//
//  AnalysisWire.swift
//  KataGoAnalysisKit
//
//  The JSON wire schema between the Safari web extension's JS side and the
//  native analysis service. Every message is self-contained so a freshly
//  relaunched appex process can serve it (Safari may terminate the extension
//  process between any two messages); delivery is pull-based and per-move
//  results are idempotent by `moveIndex`.
//
//  Perspective rule: `winrateB`/`scoreLeadB` are ALWAYS Black's perspective at
//  the wire level, regardless of side to move — one convention end to end so
//  the perspective-flip class of bugs cannot reach the JS side. Ownership
//  grids stay White-positive exactly as the engine emits them (the JS overlay
//  flips for display). `PlayedAssessment.winrateDrop` is the exception by
//  design: it is the drop from the MOVER's perspective (positive = the played
//  move lost winrate for the player who made it), which is what blunder
//  badges need.
//

import Foundation

/// Analysis depth requested by the user (the JS budget picker).
public enum AnalysisBudget: String, Codable, Sendable, Equatable {
    case fast
    case normal
    case deep

    /// Visit budget for one sweep position.
    public var sweepVisits: Int {
        switch self {
        case .fast: 80
        case .normal: 150
        case .deep: 400
        }
    }

    /// Visit budget when deepening the position the page currently shows.
    public var deepenVisits: Int {
        switch self {
        case .fast: 400
        case .normal: 800
        case .deep: 1600
        }
    }
}

/// One analyzed position. `moveIndex` counts moves played from the empty
/// board, so index 0 is the empty board and index N is the position after
/// SGF move N. `seq` is the outbox delivery cursor (see `AnalysisOutbox`).
public struct MoveAnalysis: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        case sweep
        case deepen
    }

    public var seq: Int
    public var moveIndex: Int
    public var phase: Phase
    /// "b" or "w" on the wire.
    public var toMove: String
    public var visits: Int
    public var winrateB: Float
    public var scoreLeadB: Float
    public var candidates: [Candidate]
    public var ownershipW: [Float]?
    public var played: PlayedAssessment?

    public init(seq: Int = 0, moveIndex: Int, phase: Phase, toMove: String,
                visits: Int, winrateB: Float, scoreLeadB: Float,
                candidates: [Candidate], ownershipW: [Float]? = nil,
                played: PlayedAssessment? = nil) {
        self.seq = seq
        self.moveIndex = moveIndex
        self.phase = phase
        self.toMove = toMove
        self.visits = visits
        self.winrateB = winrateB
        self.scoreLeadB = scoreLeadB
        self.candidates = candidates
        self.ownershipW = ownershipW
        self.played = played
    }
}

/// One engine candidate move for a position, GTP vertex coordinates.
public struct Candidate: Codable, Sendable, Equatable {
    public var move: String
    public var visits: Int
    public var winrateB: Float
    public var scoreLeadB: Float
    public var order: Int
    public var pv: [String]

    public init(move: String, visits: Int, winrateB: Float, scoreLeadB: Float,
                order: Int, pv: [String]) {
        self.move = move
        self.visits = visits
        self.winrateB = winrateB
        self.scoreLeadB = scoreLeadB
        self.order = order
        self.pv = pv
    }
}

/// Quality of the move that PRODUCED this position (SGF move `moveIndex`),
/// from adjacent sweep results. `winrateDrop` is mover-perspective.
public struct PlayedAssessment: Codable, Sendable, Equatable {
    public var move: String
    public var winrateDrop: Float

    public init(move: String, winrateDrop: Float) {
        self.move = move
        self.winrateDrop = winrateDrop
    }
}

// MARK: - Requests (JS → native)

/// Discriminated by the `cmd` field on the wire.
public enum AnalysisRequest: Sendable, Equatable {
    case start(sgf: String, sgfHash: String, currentMoveIndex: Int, budget: AnalysisBudget)
    case poll(gameId: String, sinceSeq: Int)
    case navigate(gameId: String, moveIndex: Int)
    case query(gameId: String, moveIndex: Int, wantOwnership: Bool, budget: AnalysisBudget)
    case stop(gameId: String)
    case ping
    case openInApp(sgf: String)
}

extension AnalysisRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case cmd, sgf, sgfHash, currentMoveIndex, budget, gameId, sinceSeq
        case moveIndex, want
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let cmd = try c.decode(String.self, forKey: .cmd)
        switch cmd {
        case "start":
            self = .start(
                sgf: try c.decode(String.self, forKey: .sgf),
                sgfHash: try c.decode(String.self, forKey: .sgfHash),
                currentMoveIndex: try c.decodeIfPresent(Int.self, forKey: .currentMoveIndex) ?? 0,
                budget: try c.decodeIfPresent(AnalysisBudget.self, forKey: .budget) ?? .normal)
        case "poll":
            self = .poll(
                gameId: try c.decode(String.self, forKey: .gameId),
                sinceSeq: try c.decodeIfPresent(Int.self, forKey: .sinceSeq) ?? 0)
        case "navigate":
            self = .navigate(
                gameId: try c.decode(String.self, forKey: .gameId),
                moveIndex: try c.decode(Int.self, forKey: .moveIndex))
        case "query":
            let want = try c.decodeIfPresent([String].self, forKey: .want) ?? []
            self = .query(
                gameId: try c.decode(String.self, forKey: .gameId),
                moveIndex: try c.decode(Int.self, forKey: .moveIndex),
                wantOwnership: want.contains("ownership"),
                budget: try c.decodeIfPresent(AnalysisBudget.self, forKey: .budget) ?? .normal)
        case "stop":
            self = .stop(gameId: try c.decode(String.self, forKey: .gameId))
        case "ping":
            self = .ping
        case "openInApp":
            self = .openInApp(sgf: try c.decode(String.self, forKey: .sgf))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .cmd, in: c, debugDescription: "unknown cmd '\(cmd)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .start(sgf, sgfHash, currentMoveIndex, budget):
            try c.encode("start", forKey: .cmd)
            try c.encode(sgf, forKey: .sgf)
            try c.encode(sgfHash, forKey: .sgfHash)
            try c.encode(currentMoveIndex, forKey: .currentMoveIndex)
            try c.encode(budget, forKey: .budget)
        case let .poll(gameId, sinceSeq):
            try c.encode("poll", forKey: .cmd)
            try c.encode(gameId, forKey: .gameId)
            try c.encode(sinceSeq, forKey: .sinceSeq)
        case let .navigate(gameId, moveIndex):
            try c.encode("navigate", forKey: .cmd)
            try c.encode(gameId, forKey: .gameId)
            try c.encode(moveIndex, forKey: .moveIndex)
        case let .query(gameId, moveIndex, wantOwnership, budget):
            try c.encode("query", forKey: .cmd)
            try c.encode(gameId, forKey: .gameId)
            try c.encode(moveIndex, forKey: .moveIndex)
            try c.encode(wantOwnership ? ["candidates", "ownership"] : ["candidates"],
                         forKey: .want)
            try c.encode(budget, forKey: .budget)
        case let .stop(gameId):
            try c.encode("stop", forKey: .cmd)
            try c.encode(gameId, forKey: .gameId)
        case .ping:
            try c.encode("ping", forKey: .cmd)
        case let .openInApp(sgf):
            try c.encode("openInApp", forKey: .cmd)
            try c.encode(sgf, forKey: .sgf)
        }
    }
}

// MARK: - Responses (native → JS)

/// Wire error codes surfaced to the panel's state machine.
public enum AnalysisErrorCode: String, Codable, Sendable {
    case sgfParse
    case boardTooLarge
    case engineDown
    case busy
    case unknownGame
    case warmingUp
    case spoolWrite
    case openFailed
    case badRequest
}

/// Discriminated by the `type` field on the wire.
public enum AnalysisResponse: Sendable, Equatable {
    case gameAccepted(gameId: String, boardWidth: Int, boardHeight: Int,
                      moveCount: Int, komi: Float?, rules: String?, cached: Bool)
    case results(gameId: String, nextSeq: Int, sweepDone: Int, sweepTotal: Int,
                 moves: [MoveAnalysis])
    case opened
    case pong(engineState: String)
    case error(code: AnalysisErrorCode, message: String, retryable: Bool)
}

extension AnalysisResponse: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, gameId, boardWidth, boardHeight, moveCount, komi, rules, cached
        case nextSeq, sweep, moves, engineState, code, message, retryable
    }

    private struct SweepProgress: Codable {
        var done: Int
        var total: Int
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "gameAccepted":
            self = .gameAccepted(
                gameId: try c.decode(String.self, forKey: .gameId),
                boardWidth: try c.decode(Int.self, forKey: .boardWidth),
                boardHeight: try c.decode(Int.self, forKey: .boardHeight),
                moveCount: try c.decode(Int.self, forKey: .moveCount),
                komi: try c.decodeIfPresent(Float.self, forKey: .komi),
                rules: try c.decodeIfPresent(String.self, forKey: .rules),
                cached: try c.decodeIfPresent(Bool.self, forKey: .cached) ?? false)
        case "results":
            let sweep = try c.decode(SweepProgress.self, forKey: .sweep)
            self = .results(
                gameId: try c.decode(String.self, forKey: .gameId),
                nextSeq: try c.decode(Int.self, forKey: .nextSeq),
                sweepDone: sweep.done,
                sweepTotal: sweep.total,
                moves: try c.decode([MoveAnalysis].self, forKey: .moves))
        case "opened":
            self = .opened
        case "pong":
            self = .pong(engineState: try c.decode(String.self, forKey: .engineState))
        case "error":
            self = .error(
                code: try c.decode(AnalysisErrorCode.self, forKey: .code),
                message: try c.decode(String.self, forKey: .message),
                retryable: try c.decodeIfPresent(Bool.self, forKey: .retryable) ?? false)
        case let type:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "unknown type '\(type)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .gameAccepted(gameId, boardWidth, boardHeight, moveCount, komi, rules, cached):
            try c.encode("gameAccepted", forKey: .type)
            try c.encode(gameId, forKey: .gameId)
            try c.encode(boardWidth, forKey: .boardWidth)
            try c.encode(boardHeight, forKey: .boardHeight)
            try c.encode(moveCount, forKey: .moveCount)
            try c.encodeIfPresent(komi, forKey: .komi)
            try c.encodeIfPresent(rules, forKey: .rules)
            try c.encode(cached, forKey: .cached)
        case let .results(gameId, nextSeq, sweepDone, sweepTotal, moves):
            try c.encode("results", forKey: .type)
            try c.encode(gameId, forKey: .gameId)
            try c.encode(nextSeq, forKey: .nextSeq)
            try c.encode(SweepProgress(done: sweepDone, total: sweepTotal), forKey: .sweep)
            try c.encode(moves, forKey: .moves)
        case .opened:
            try c.encode("opened", forKey: .type)
        case let .pong(engineState):
            try c.encode("pong", forKey: .type)
            try c.encode(engineState, forKey: .engineState)
        case let .error(code, message, retryable):
            try c.encode("error", forKey: .type)
            try c.encode(code, forKey: .code)
            try c.encode(message, forKey: .message)
            try c.encode(retryable, forKey: .retryable)
        }
    }
}

// MARK: - Dictionary bridging

/// Safari native messaging hands payloads across as plist dictionaries
/// (`SFExtensionMessageKey`), not raw JSON data — bridge Codable both ways.
public enum AnalysisWireCoding {
    public static func request(fromDictionary dictionary: [String: Any]) throws -> AnalysisRequest {
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        return try JSONDecoder().decode(AnalysisRequest.self, from: data)
    }

    public static func dictionary(from response: AnalysisResponse) throws -> [String: Any] {
        let data = try JSONEncoder().encode(response)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw EncodingError.invalidValue(response, EncodingError.Context(
                codingPath: [], debugDescription: "response did not encode to an object"))
        }
        return dictionary
    }
}
