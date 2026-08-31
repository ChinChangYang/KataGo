//
//  SampleGames.swift
//  KataGoUICore
//
//  The bundled sample game the tvOS library offers while the user's own games
//  have not synced (or do not exist): Shusaku's 1846 "Ear-Reddening Game" —
//  Yasuda (Honinbo) Shusaku (B, 4d) vs Inoue Gennan Inseki (W, 8d), B+2, a
//  public-domain historical record. Ships in Release (not a preview fixture).
//
//  The score-lead history is precomputed offline (one KataGo raw-net eval per
//  position, black-positive to match GameRecord.scoreLeads) and baked in so
//  the review screen's chart works without ever analyzing on another device.
//  Regenerate with the engine if the SGF ever changes; the final entry should
//  land near the historical +2 result.
//

import Foundation

public enum SampleGames {
    /// The complete 325-move record.
    ///
    /// The literal itself moved to `ScreenshotSeed.sgf` in KataGoGameStore:
    /// the README-screenshot seed opens this same game on every platform,
    /// and the watch app links only that bridge-free package. This stays as a
    /// forwarding alias so nothing else has to move. `ScreenshotSeed.sgf`
    /// carries the RU[Japanese]/KM[0] rationale that used to live here.
    public static let earReddeningSgf = ScreenshotSeed.sgf

    /// Black's score lead after each move 0...325, from a single KataGo
    /// raw-net eval per position under Japanese rules, komi 0. Index == move
    /// count, matching how live analysis fills `GameRecord.scoreLeads`.
    public static let earReddeningScoreLeads: [Int: Float] = {
        let leads: [Float] = [
        5.4, 7.6, 6.0, 6.3, 7.0, 6.4, 6.8, 6.9, 6.5, 6.9,
        6.8, 7.9, 7.2, 8.0, 8.0, 7.8, 7.4, 7.4, 8.0, 7.3,
        7.1, 7.1, 6.8, 6.4, 7.4, 6.4, 6.0, 6.8, 5.6, 5.2,
        4.6, 1.6, 1.9, 1.5, 2.5, 1.6, 3.5, 2.8, 2.6, 4.2,
        3.3, 4.1, 3.7, 3.7, 4.0, 2.6, 2.6, -0.1, 1.0, 1.9,
        3.8, 2.8, 2.1, 1.7, 1.1, 2.1, 1.8, 1.2, 1.9, 0.4,
        5.7, 3.4, 4.9, 3.8, 5.2, 3.7, 4.9, 3.8, 5.4, 3.0,
        3.2, 2.7, 2.5, 2.4, 2.4, 2.5, 3.1, 4.2, 4.8, 2.2,
        3.3, 3.4, 3.9, 4.0, 5.5, 5.5, 5.6, 6.4, 6.5, 5.8,
        7.6, 6.6, 11.1, 7.6, 12.4, 6.0, 5.2, 2.6, 1.4, 2.6,
        0.4, 2.4, 0.2, 1.6, 0.4, 2.5, 0.3, 3.8, -0.8, 1.3,
        -0.4, 0.5, -0.7, 1.1, 0.4, 0.6, 0.6, 0.0, 0.6, -0.6,
        -0.1, -1.8, -0.9, -0.3, -0.8, -0.7, 0.6, -0.1, -0.0, -0.2,
        0.6, 0.4, 0.5, 0.5, 0.6, 1.0, 1.6, 1.1, 1.3, 1.4,
        1.4, 1.7, 4.4, 3.4, 4.6, 5.2, 4.8, 4.2, 4.5, 5.7,
        6.6, 5.9, 6.3, 4.7, 3.5, 3.0, 2.8, 2.8, 5.1, 4.8,
        5.2, 4.1, 6.3, 4.2, 3.7, 3.2, 3.7, 3.6, 4.4, 4.1,
        4.9, 4.7, 6.5, 5.7, 5.9, 3.5, 3.4, 4.2, 3.7, 3.9,
        3.8, 3.8, 3.8, 4.3, 4.8, 4.4, 6.1, 6.2, 6.8, 6.4,
        7.9, 2.9, 2.0, 1.7, 2.4, 1.4, 3.0, 1.9, 2.7, 1.6,
        1.4, 1.6, 1.7, 1.4, 1.3, 0.3, 0.1, 0.0, 0.4, 0.2,
        0.4, 0.0, 0.2, -0.3, 0.1, -0.3, -0.4, -0.5, -0.0, -0.6,
        -0.1, -0.5, -0.0, -0.5, -0.3, -0.4, -0.1, -0.7, -0.1, -1.0,
        0.2, -0.4, 0.1, -0.7, -0.3, -1.2, 0.1, -0.8, 0.4, -0.4,
        0.3, -0.7, 0.5, -0.5, 0.3, -0.6, 0.2, -0.6, 0.0, -0.7,
        0.3, -0.5, 0.1, -0.7, 0.2, -0.3, 0.4, 0.4, 0.8, 0.7,
        1.1, 0.6, 1.0, 0.9, 1.1, 1.3, 1.3, 0.6, 1.3, 1.1,
        1.2, 1.2, 1.2, 0.9, 1.0, 1.2, 1.1, 1.3, 1.4, 1.0,
        1.0, 0.9, 1.1, 1.3, 1.1, 1.0, 0.8, 1.2, 1.0, 1.1,
        1.1, 0.8, 0.8, 0.9, 0.9, 0.9, 0.9, 0.7, 0.4, 0.6,
        0.7, 0.6, 1.1, 0.9, 0.9, 1.2, 1.1, 1.3, 1.2, 1.2,
        1.3, 1.6, 1.6, 1.6, 1.8, 2.1, 1.6, 2.0, 1.6, 2.1,
        1.8, 1.8, 2.0, 2.2, 2.2, 2.1
        ]
        return Dictionary(uniqueKeysWithValues: leads.enumerated().map { ($0.offset, $0.element) })
    }()

    /// Builds a fresh sample record. The caller owns keeping it OUT of the
    /// CloudKit-synced store (insert into an in-memory container only) —
    /// opening a game mutates its record, and those writes must never sync.
    @MainActor
    public static func makeEarReddeningRecord() -> GameRecord {
        let sgfHelper = SgfOperations(sgf: earReddeningSgf)
        let moveSize = sgfHelper.moveSize ?? 0

        // Final position at the last move index so the library card can draw
        // the finished game (the importGameRecord pattern); currentIndex stays
        // 0 so review starts at the opening.
        let finalStones = sgfHelper.finalStones()
        let blackStones: [Int: String] = [moveSize: finalStones.black.joined(separator: " ")]
        let whiteStones: [Int: String] = [moveSize: finalStones.white.joined(separator: " ")]

        let record = GameRecord.createGameRecord(sgf: earReddeningSgf,
                                                 currentIndex: 0,
                                                 name: "Ear-Reddening Game",
                                                 scoreLeads: earReddeningScoreLeads,
                                                 blackStones: blackStones,
                                                 whiteStones: whiteStones)
        // 1846-09-11 — renders as the card's date line and keeps the sample
        // sorted far below any real game if it ever shares a list.
        record.lastModificationDate = Date(timeIntervalSince1970: -3891196800)
        return record
    }
}
