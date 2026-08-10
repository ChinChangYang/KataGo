//
//  TVPlayability.swift
//  KataGoUICore
//

import Foundation
import KataGoGameStore

/// Classifies a library record as "continue playing" (opens TVPlayScreen)
/// vs "review" (locked spectator). Deliberately config-based — exactly one
/// side with maxTime == 0 marks a human-vs-AI game — so a game started on
/// iPhone/iPad/Mac is continuable on the TV.
public enum TVPlayability {
    public static func isHumanVsAI(blackMaxTime: Float, whiteMaxTime: Float) -> Bool {
        (blackMaxTime == 0) != (whiteMaxTime == 0)
    }

    public static func isPlayable(blackMaxTime: Float, whiteMaxTime: Float, sgf: String) -> Bool {
        isHumanVsAI(blackMaxTime: blackMaxTime, whiteMaxTime: whiteMaxTime)
            && !SelfPlayGame.recordedGameIsFinished(sgf: sgf)
    }

    @MainActor
    public static func isPlayable(_ record: GameRecord) -> Bool {
        let config = record.concreteConfig
        return isPlayable(blackMaxTime: config.blackMaxTime,
                          whiteMaxTime: config.whiteMaxTime,
                          sgf: record.sgf)
    }
}
