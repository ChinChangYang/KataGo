//
//  ListeningScriptBuilder.swift
//  KataGo Anytime
//
//  Bakes a GameRecord into a ListeningScript, engine-free: positions and
//  capture flags come from GoRulesKit's SgfReplay (the watch's bridge-free
//  pairing with SgfHeaderScan), words from the record's persisted per-move
//  data through the shared CommentatorPhrasing units. Runs on the MainActor
//  against the live record — that moment is the session's snapshot.
//
//  Per-cue source priority (the design's Q5/Q6 decisions):
//    1. a saved comment, spoken verbatim behind a terse move call;
//    2. a composed commentator-register sentence when the move has analysis;
//    3. the bare move call.
//  Playback never generates anything: an unprepared game simply sounds like
//  a plain move-caller.
//

import Foundation
import GoRulesKit

@MainActor
public enum ListeningScriptBuilder {
    /// Nil when the SGF has no mainline to narrate, or when the replay hit a
    /// move the rules refuse (`anomalyIndex`) — the same gate the watch puts
    /// on unreadable records.
    public static func script(for gameRecord: GameRecord) -> ListeningScript? {
        guard let scan = SgfHeaderScan(sgf: gameRecord.sgf) else { return nil }
        var replay = SgfReplay(scan: scan)

        // Force the whole mainline once so refusals are known up front.
        _ = replay.position(at: scan.moveCount)
        guard replay.anomalyIndex == nil else { return nil }

        var cues: [ListeningCue] = []
        var previous = replay.position(at: 0)
        for k in 1...max(scan.moveCount, 1) where scan.moveCount > 0 {
            let position = replay.position(at: k)
            guard let recorded = replay.move(at: k - 1) else { break }
            let capturedStones = (position.blackCaptures - previous.blackCaptures)
                + (position.whiteCaptures - previous.whiteCaptures)
            cues.append(cue(for: gameRecord, moveNumber: k, recorded: recorded,
                            vertex: position.lastMoveVertex,
                            capturedStones: capturedStones))
            previous = position
        }

        let finalScoreLead = gameRecord.scoreLeads?[scan.moveCount]
        return ListeningScript(gameID: gameRecord.uuid,
                               gameName: gameRecord.name,
                               boardWidth: scan.boardWidth,
                               boardHeight: scan.boardHeight,
                               intro: "Listening to \(gameRecord.name).",
                               cues: cues,
                               resultAnnouncement: resultAnnouncement(
                                   sgf: gameRecord.sgf,
                                   finalScoreLeadBlack: finalScoreLead,
                                   moveCount: scan.moveCount),
                               finalScoreLeadBlack: finalScoreLead)
    }

    // MARK: - One cue

    private static func cue(for gameRecord: GameRecord, moveNumber k: Int,
                            recorded: SgfReplay.RecordedMove, vertex: String?,
                            capturedStones: Int) -> ListeningCue {
        let color = recorded.color
        let isPass = recorded.point == nil
        let playsCaptureSound = capturedStones > 0

        // 1. A saved comment is spoken verbatim, behind a terse call so the
        //    listener stays oriented even when the comment assumes a board.
        let savedComment = gameRecord.comments?[k]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let savedComment, !savedComment.isEmpty {
            return ListeningCue(moveNumber: k,
                                text: "\(bareCall(color: color, vertex: vertex, isPass: isPass)) \(savedComment)",
                                playsCaptureSound: playsCaptureSound,
                                source: .comment)
        }

        // 2. Any analysis at this move earns a composed register sentence.
        let winRate = gameRecord.winRates?[k]
        let scoreLead = gameRecord.scoreLeads?[k]
        let bestMove = gameRecord.bestMoves?[k - 1]
        if winRate != nil || scoreLead != nil || bestMove != nil {
            var text = numberedCall(color: color, moveNumber: k, vertex: vertex, isPass: isPass)
            text += captureSentence(for: gameRecord, moveNumber: k,
                                    capturedStones: capturedStones)
            if let winRate {
                let diff = CommentatorPhrasing.formatWinRateDiff(
                    gameRecord.winRates?[k - 1], winRate, for: color)
                text += " \(color.name) win rate is \(CommentatorPhrasing.formatWinRate(winRate, for: color))\(diff)."
            }
            if scoreLead != nil {
                text += " \(CommentatorPhrasing.formatScore(scoreLead, for: color))."
            }
            if let bestMove {
                let played = isPass ? "pass" : (vertex ?? "")
                if bestMove.caseInsensitiveCompare(played) == .orderedSame {
                    text += " KataGo agrees with this move."
                } else {
                    text += " KataGo recommended \(bestMove) instead."
                }
            }
            return ListeningCue(moveNumber: k, text: text,
                                playsCaptureSound: playsCaptureSound,
                                source: .commentary)
        }

        // 3. Bare move call — what an unprepared game sounds like.
        return ListeningCue(moveNumber: k,
                            text: bareCall(color: color, vertex: vertex, isPass: isPass),
                            playsCaptureSound: playsCaptureSound,
                            source: .bareCall)
    }

    // MARK: - Wording

    private static func bareCall(color: PlayerColor, vertex: String?, isPass: Bool) -> String {
        guard !isPass, let vertex else { return "\(color.name) passes." }
        return "\(color.name) plays \(vertex)."
    }

    private static func numberedCall(color: PlayerColor, moveNumber: Int,
                                     vertex: String?, isPass: Bool) -> String {
        guard !isPass, let vertex else { return "\(color.name) number \(moveNumber) passes." }
        return "\(color.name) number \(moveNumber) plays a stone at \(vertex)."
    }

    /// Vertex list from the record when it has one, replay-counted total
    /// otherwise — the sparse dictionaries name the stones, the replay only
    /// counts them.
    private static func captureSentence(for gameRecord: GameRecord,
                                        moveNumber k: Int,
                                        capturedStones: Int) -> String {
        let black = gameRecord.getCapturedBlackStones(k)
        let white = gameRecord.getCapturedWhiteStones(k)
        var sentence = ""
        if let black, black != "None", black != "Unknown" {
            sentence += " It captures Black stones at \(black)."
        }
        if let white, white != "None", white != "Unknown" {
            sentence += " It captures White stones at \(white)."
        }
        if sentence.isEmpty, capturedStones > 0 {
            sentence = capturedStones == 1
                ? " It captures 1 stone."
                : " It captures \(capturedStones) stones."
        }
        return sentence
    }

    private static func resultAnnouncement(sgf: String, finalScoreLeadBlack: Float?,
                                           moveCount: Int) -> String {
        guard moveCount > 0 else { return "This game has no moves yet." }
        let recorded = SelfPlayGame.result(fromSgf: sgf)
        if recorded != .unknown {
            return "\(SelfPlayGame.resultText(recorded)). End of game."
        }
        if let finalScoreLeadBlack {
            return "\(CommentatorPhrasing.formatScore(finalScoreLeadBlack, for: .black)). End of game after \(moveCount) moves."
        }
        return "End of game after \(moveCount) moves."
    }
}
