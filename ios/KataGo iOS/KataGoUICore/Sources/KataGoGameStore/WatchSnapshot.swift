import Foundation

/// Wire payload for the watch live mirror: one self-contained frame of the
/// host's current position + analysis, small enough (~2 KB typical, hard test
/// bound 16 KB) to ride `WCSession.updateApplicationContext` at ~2 Hz.
/// Lives in KataGoGameStore so both the iOS app (sender) and the watch app
/// (receiver) share one definition without touching the engine-linked
/// KataGoUICore product. Version the schema — application contexts persist
/// across app updates, so a watch build may decode a frame written by an
/// older/newer phone build.
public struct WatchSnapshot: Codable, Equatable, Sendable {
    public struct Candidate: Codable, Equatable, Sendable {
        public var vertex: String        // GTP vertex, e.g. "Q16" / "pass"
        public var winrate: Float        // side-to-move perspective (same as host's list UI)
        public var scoreLead: Float      // side-to-move perspective
        public var visits: Int
        public var pv: [String]          // principal variation, capped at 6 plies

        public init(vertex: String, winrate: Float, scoreLead: Float,
                    visits: Int, pv: [String]) {
            self.vertex = vertex; self.winrate = winrate; self.scoreLead = scoreLead
            self.visits = visits; self.pv = pv
        }
    }

    /// The WCSession applicationContext dictionary key both the iPhone relay
    /// and the watch receiver use to store/retrieve the encoded snapshot.
    public static let contextKey = "watchSnapshot"

    public var version: Int = 1
    public var boardWidth: Int
    public var boardHeight: Int
    public var blackStones: [String]     // GTP vertices
    public var whiteStones: [String]
    public var toMove: String            // "B" / "W"
    /// Stones placed so far (on-board + captured). A display/peek key, not an
    /// SGF index — passes don't advance it.
    public var moveNumber: Int
    public var analysisRunning: Bool
    public var rootWinrateBlack: Float   // Black perspective, 0…1
    public var rootScoreLeadBlack: Float // Black perspective, points
    public var candidates: [Candidate]   // strongest first, ≤ 10
    public var hostTimestamp: Date

    // v1.1 write path — ALL optional so a v0 payload (persisted in
    // receivedApplicationContext across app updates) still decodes; nil means
    // "v0 phone", which the watch treats as read-only mirror mode.
    /// GameRecord.uuid.uuidString of the game on screen; commands bind to it.
    public var hostGameID: String?
    /// Host's current mainline SGF index (GobanState.getCurrentIndex).
    public var hostMoveIndex: Int?
    /// Mainline move count (SgfOperations.moveSize) — the crown's upper bound.
    public var hostMoveCount: Int?
    /// Side to move is human-played (its maxTime == 0); nil when unknown.
    public var isHumanTurn: Bool?
    /// Host would accept a goTo command right now.
    public var canScrub: Bool?
    /// Host would accept a play command right now (hard-block gate result).
    public var canPlay: Bool?
    /// Analysis is paused on the host (.pause): candidates are retained and
    /// position-fresh but not streaming. nil = older phone build (treat as
    /// false). Distinct from `analysisRunning`, which stays strictly "live
    /// stream" so the AI-turn hourglass never shows for a paused engine.
    public var analysisPaused: Bool?

    // v1.2 — also optional, same reason: an older phone simply omits it and
    // the watch falls back to inferring the move by diffing snapshots.
    /// GTP vertex of the move played into this position, from the host's own
    /// SGF — the point the phone's board draws its last-move marker on. Nil
    /// for the start of a game, after a pass, or from a pre-v1.2 phone.
    ///
    /// On the wire rather than inferred watch-side because inference cannot
    /// cover the two cases that matter most. The watch's differ
    /// (`WatchPeekBuffer.lastMoveVertex`) needs the immediately preceding
    /// snapshot, which the peek buffer is not guaranteed to hold once the user
    /// scrubs to an arbitrary index; and it requires `cur.count == prev.count
    /// + 1`, so it silently gives up on any move that CAPTURES — often the
    /// move you most want to find on a wrist.
    public var lastMoveVertex: String?

    // v1.3 — optional for the same reason every field after v1 is: WCSession
    // persists the last application context across app updates, and on
    // TestFlight the watch and the phone update independently, so
    // watch-1.3 + phone-1.2 is a normal multi-day state.
    /// The game's name, so the complication can name it without a lookup.
    /// The watch backfills from its own library when this is nil, which is
    /// what keeps the tile correct against an older phone.
    public var gameName: String?
    /// The comment stored at `hostMoveIndex`, already capped to the wire
    /// limit by `WatchWidgetSnapshot.cappedComment`.
    public var positionComment: String?
    /// True while the host is on a branch. `hostMoveIndex` is then a BRANCH
    /// index while `hostMoveCount` still describes the saved mainline, so a
    /// consumer must neither pair the two nor look a mainline comment up by
    /// that index.
    public var isBranch: Bool?

    public init(boardWidth: Int, boardHeight: Int,
                blackStones: [String], whiteStones: [String],
                toMove: String, moveNumber: Int, analysisRunning: Bool,
                rootWinrateBlack: Float, rootScoreLeadBlack: Float,
                candidates: [Candidate], hostTimestamp: Date) {
        self.boardWidth = boardWidth; self.boardHeight = boardHeight
        self.blackStones = blackStones; self.whiteStones = whiteStones
        self.toMove = toMove; self.moveNumber = moveNumber
        self.analysisRunning = analysisRunning
        self.rootWinrateBlack = rootWinrateBlack
        self.rootScoreLeadBlack = rootScoreLeadBlack
        self.candidates = candidates; self.hostTimestamp = hostTimestamp
    }

    /// Identity of the board POSITION alone (not analysis churn), independent
    /// of stone-array order. The peek buffer appends a frame only when this
    /// changes.
    public var positionKey: String {
        "\(boardWidth)x\(boardHeight)|"
            + blackStones.sorted().joined(separator: ",")
            + "|" + whiteStones.sorted().joined(separator: ",")
    }

    public func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> WatchSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(WatchSnapshot.self, from: data)
    }

    /// Shared staleness rule so the app (10 s threshold) and the complication
    /// (600 s) agree on semantics: nil receipt time is always stale.
    public static func isStale(receivedAt: Date?, now: Date,
                               threshold: TimeInterval) -> Bool {
        guard let receivedAt else { return true }
        return now.timeIntervalSince(receivedAt) > threshold
    }
}
