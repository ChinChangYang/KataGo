//
//  GameSession+CustomParameters.swift
//  KataGoUICore
//
//  The person's custom engine parameters reach the engine twice: every value
//  at launch, as -override-config entries, and the live ones again once the
//  engine answers, so a value edited while it was launching is not lost.
//

import Foundation

extension GameSession {
    /// Sends `parameters`' live values to the engine with `kata-set-param`.
    /// Call it once the handshake has opened the command gate; before that the
    /// gate drops them.
    public func sendLiveCustomParameters(_ parameters: CustomParameters) {
        for command in parameters.liveCommands {
            messageList.appendAndSend(command: command)
        }
    }
}

extension EngineStatus {
    /// Offers "Relaunch Without Custom Parameters" alongside a failure's other
    /// ways out, when the failed launch used any.
    public func offerCustomParameterRemedy() {
        guard launchedCustomParameterCount > 0,
              !actions.contains(.relaunchWithoutCustomParameters) else { return }
        actions.append(.relaunchWithoutCustomParameters)
    }
}
