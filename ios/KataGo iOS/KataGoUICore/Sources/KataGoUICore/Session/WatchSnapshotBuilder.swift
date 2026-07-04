import Foundation
import KataGoGameStore

/// Projects the live GameSession observables into one WatchSnapshot frame.
/// Pure read — never mutates session state. Candidate winrate/scoreLead stay
/// in side-to-move perspective (matching the host's candidate list UI); root
/// values are Black-perspective straight from rootWinrate/rootScore.
/// `gameRecord`/`moveCount`, when supplied, enrich the snapshot with the
/// v1.1 write-path fields (hostGameID/hostMoveIndex/hostMoveCount/canScrub/
/// canPlay); omit them for read-only (v0) callers.
public enum WatchSnapshotBuilder {
    @MainActor
    public static func makeSnapshot(session: GameSession,
                                    gameRecord: GameRecord? = nil,
                                    moveCount: Int? = nil,
                                    now: Date = .now) -> WatchSnapshot {
        let width = Int(session.board.width)
        let height = Int(session.board.height)
        let running = session.gobanState.analysisStatus == .run
        // Guard against a one-tick lag between the analysis engine's
        // perspective and the current position right after a move: without
        // this, stale candidates could get paired with the new
        // hostMoveIndex, and a watch tap in that window could race the
        // engine's legality check (worst case: a ko/superko prompt on the
        // phone). See Finding 5.
        let analysisMatchesTurn =
            session.analysis.nextColorForAnalysis == session.player.nextColorForPlayCommand

        let candidates: [WatchSnapshot.Candidate]
        if running && analysisMatchesTurn {
            candidates = session.analysis
                .candidateMoves(width: width, height: height, limit: 10)
                .map { c in
                    WatchSnapshot.Candidate(
                        vertex: c.vertex, winrate: c.winrate, scoreLead: c.scoreLead,
                        visits: c.visits,
                        pv: Array((session.analysis.info[c.point]?.pv ?? []).prefix(6)))
                }
        } else {
            candidates = []
        }

        func vertices(_ points: [BoardPoint]) -> [String] {
            // toString/refillString are static on BoardPoint (see
            // KataGoModel.swift), not on Stones.
            (BoardPoint.toString(points, width: width, height: height) ?? "")
                .split(separator: " ").map(String.init)
        }

        let stones = session.stones
        var snapshot = WatchSnapshot(
            boardWidth: width, boardHeight: height,
            blackStones: vertices(stones.blackPoints),
            whiteStones: vertices(stones.whitePoints),
            toMove: session.player.nextColorForPlayCommand == .black ? "B" : "W",
            moveNumber: stones.blackPoints.count + stones.whitePoints.count
                + stones.blackStonesCaptured + stones.whiteStonesCaptured,
            analysisRunning: running,
            rootWinrateBlack: session.rootWinrate.black,
            rootScoreLeadBlack: session.rootScore.black,
            candidates: candidates,
            hostTimestamp: now)

        if let gameRecord {
            let gate = WatchHostGate.evaluate(session: session, gameRecord: gameRecord)
            snapshot.hostGameID = gameRecord.uuid?.uuidString
            snapshot.hostMoveIndex = session.gobanState.getCurrentIndex(gameRecord: gameRecord)
            snapshot.hostMoveCount = moveCount
            snapshot.isHumanTurn = gate.isHumanTurn
            snapshot.canScrub = gate.canScrub
            snapshot.canPlay = gate.canPlay
        }
        return snapshot
    }
}
