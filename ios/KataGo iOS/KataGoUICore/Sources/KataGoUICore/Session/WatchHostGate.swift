import Foundation
import KataGoGameStore

/// Gate truth for the v1.1 watch write path, computed host-side from live
/// session state. The snapshot carries the result so the watch can show/hide
/// affordances; WatchCommandHandler re-evaluates on receipt (authoritative —
/// the watch's copy can be one relay tick stale).
public struct WatchHostGateState: Equatable, Sendable {
    /// Side to move is human-played (its per-move maxTime == 0); nil when the
    /// next color is unknown (board still loading) or there is no game.
    public var isHumanTurn: Bool?
    public var canScrub: Bool
    public var canPlay: Bool

    public init(isHumanTurn: Bool?, canScrub: Bool, canPlay: Bool) {
        self.isHumanTurn = isHumanTurn; self.canScrub = canScrub; self.canPlay = canPlay
    }
}

public enum WatchHostGate {
    /// Scrub parity with the phone's own toolbar gate
    /// (StatusToolbarItems.isFunctional: no gen-move in flight, not
    /// auto-playing, no showboard in flight) plus mainline-only (no active
    /// branch), no pending human move, and no report probing.
    /// Play additionally requires the spec's hard-block gate: analysis
    /// running, game unlocked (isEditing), at the mainline head (nothing to
    /// overwrite — playing behind the head truncates the record), and the
    /// human's turn.
    @MainActor
    public static func evaluate(session: GameSession, gameRecord: GameRecord?) -> WatchHostGateState {
        guard let gameRecord else {
            return WatchHostGateState(isHumanTurn: nil, canScrub: false, canPlay: false)
        }
        let config = gameRecord.concreteConfig
        let gobanState = session.gobanState

        let isHumanTurn: Bool?
        switch session.player.nextColorForPlayCommand {
        case .black: isHumanTurn = config.blackMaxTime == 0
        case .white: isHumanTurn = config.whiteMaxTime == 0
        case .unknown: isHumanTurn = nil
        }

        let canScrub = !gobanState.shouldGenMove(config: config, player: session.player)
            && !gobanState.isAutoPlaying
            && gobanState.showBoardCount == 0
            && !gobanState.isBranchActive
            && gobanState.pendingMoveTurn == nil
            && !gobanState.reportGenerationActive

        let atMainlineHead = gobanState.getNextMove(gameRecord: gameRecord) == nil
        let canPlay = canScrub
            && gobanState.analysisStatus == .run
            && gobanState.isEditing
            && atMainlineHead
            && isHumanTurn == true

        return WatchHostGateState(isHumanTurn: isHumanTurn, canScrub: canScrub, canPlay: canPlay)
    }
}
