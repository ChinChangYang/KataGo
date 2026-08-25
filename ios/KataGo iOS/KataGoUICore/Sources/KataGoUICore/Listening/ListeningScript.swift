//
//  ListeningScript.swift
//  KataGo Anytime
//
//  The fully-baked narration for one Listening Session. The script IS the
//  session's snapshot (ADR 0013): every cue's text is composed at build time
//  from the record as it was at that moment, so playback holds an immutable
//  value and concurrent record edits can never reach a session in flight.
//

import Foundation

/// One move's worth of narration: the stone sound, then one spoken text.
public struct ListeningCue: Sendable, Equatable {
    /// Where the cue's words came from — a saved comment spoken verbatim,
    /// a composed commentator-register sentence, or a bare move call.
    public enum Source: Sendable, Equatable {
        case comment
        case commentary
        case bareCall
    }

    /// 1-based move number; also the Listening Cursor's unit.
    public let moveNumber: Int
    public let text: String
    /// True when this move removed stones from the board, judged by the
    /// replay's capture counts — full coverage, unlike the record's sparse
    /// per-index stone dictionaries.
    public let playsCaptureSound: Bool
    public let source: Source

    public init(moveNumber: Int, text: String, playsCaptureSound: Bool, source: Source) {
        self.moveNumber = moveNumber
        self.text = text
        self.playsCaptureSound = playsCaptureSound
        self.source = source
    }
}

public struct ListeningScript: Sendable, Equatable {
    /// The record's identity, for the Listening Cursor and the Live Activity.
    /// Nil for a record whose identity repair has not run; such a session
    /// plays but leaves no cursor behind.
    public let gameID: UUID?
    public let gameName: String
    public let boardWidth: Int
    public let boardHeight: Int
    /// Spoken once when a session starts.
    public let intro: String
    public let cues: [ListeningCue]
    /// Spoken after the last cue, before the session ends itself.
    public let resultAnnouncement: String
    /// The final score lead from Black's perspective when the record has one,
    /// for the Live Activity's score readout.
    public let finalScoreLeadBlack: Float?

    public var moveCount: Int { cues.count }

    public init(gameID: UUID?, gameName: String, boardWidth: Int, boardHeight: Int,
                intro: String, cues: [ListeningCue], resultAnnouncement: String,
                finalScoreLeadBlack: Float?) {
        self.gameID = gameID
        self.gameName = gameName
        self.boardWidth = boardWidth
        self.boardHeight = boardHeight
        self.intro = intro
        self.cues = cues
        self.resultAnnouncement = resultAnnouncement
        self.finalScoreLeadBlack = finalScoreLeadBlack
    }
}
