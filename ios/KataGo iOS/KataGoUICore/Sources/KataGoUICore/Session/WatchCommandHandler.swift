import Foundation
import KataGoGameStore

/// Executes a decoded WatchCommand against the live session, re-validating
/// the gate authoritatively (the watch's snapshot-derived gate can be a relay
/// tick stale). Dispatches into the SAME seams the phone UI uses — goTo →
/// GobanState.go(to:), play → GobanState.sendCheckMoveCommand (the board-tap
/// path; GameSession.maybeCollectCheckMove consumes the engine's reply and
/// completes the play). UIKit-free so it compiles on every platform and stays
/// unit-testable; the iOS relay supplies `hostIsActive`.
public enum WatchCommandHandler {
    @MainActor
    public static func handle(data: Data?,
                              session: GameSession,
                              gameRecord: GameRecord?,
                              moveCount: Int?,
                              audioModel: AudioModel?,
                              hostIsActive: Bool) -> WatchCommandReply {
        // sendMessage can background-wake the app; the engine's timing there
        // is unreliable (about to suspend), so refuse rather than half-run.
        guard hostIsActive else {
            return WatchCommandReply(accepted: false, reason: "Open the app on iPhone")
        }
        guard let data, let command = try? WatchCommand.decode(data) else {
            return WatchCommandReply(accepted: false, reason: "Unrecognized command")
        }
        guard let gameRecord, gameRecord.uuid?.uuidString == command.gameID else {
            return WatchCommandReply(accepted: false, reason: "Game changed on iPhone")
        }
        let gate = WatchHostGate.evaluate(session: session, gameRecord: gameRecord)

        switch command.kind {
        case .goTo:
            guard gate.canScrub else {
                return WatchCommandReply(accepted: false, reason: "iPhone is busy")
            }
            guard let target = command.targetIndex, target >= 0,
                  let moveCount, target <= moveCount else {
                return WatchCommandReply(accepted: false, reason: "Position out of range")
            }
            session.gobanState.go(to: target, gameRecord: gameRecord,
                                  board: session.board,
                                  messageList: session.messageList,
                                  player: session.player,
                                  audioModel: audioModel,
                                  stones: session.stones)
            return WatchCommandReply(accepted: true)

        case .play:
            guard gate.canPlay else {
                return WatchCommandReply(accepted: false, reason: "Play not available")
            }
            // Position binding: the candidate was computed against boundIndex
            // for toMove — reject if either moved (spec: the gate carries the
            // bound move number; never play onto a changed board).
            guard let vertex = command.vertex,
                  command.boundIndex == session.gobanState.getCurrentIndex(gameRecord: gameRecord),
                  let turn = session.player.nextColorSymbolForPlayCommand,
                  command.toMove?.lowercased() == turn else {
                return WatchCommandReply(accepted: false, reason: "Position changed")
            }
            session.gobanState.sendCheckMoveCommand(turn: turn, move: vertex,
                                                    messageList: session.messageList)
            return WatchCommandReply(accepted: true)
        }
    }
}
