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
