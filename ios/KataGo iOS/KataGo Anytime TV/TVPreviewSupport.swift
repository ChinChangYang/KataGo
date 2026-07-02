//
//  TVPreviewSupport.swift
//  KataGo Anytime TV
//
//  Shared fixtures for the tvOS #Previews: an in-memory SwiftData container and
//  sample GameRecords engineered to hit every UI branch (named/dated card vs
//  untitled/undated fallback, both TVGameCard displayIndex branches, Human vs AI
//  player labels). DEBUG-only — previews never ship.
//

#if DEBUG
import Foundation
import SwiftData
import KataGoUICore

@MainActor
enum TVPreviewData {
    /// A fresh in-memory container (never the CloudKit store) holding `games`.
    static func container(games: [GameRecord]) -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: GameRecord.self, Config.self,
                                            configurations: config)
        for game in games {
            container.mainContext.insert(game)
        }
        return container
    }

    /// The five-move 19×19 opening every fixture shares. Vertices are the GTP
    /// coordinates of the SGF moves so the card thumbnail matches the record.
    /// The RU tag is REQUIRED: `loadGame` reads rules via the C++
    /// `Sgf::getRulesOrFail`, which throws (→ abort, uncatchable from Swift)
    /// on an SGF without one — app-canonical SGFs always carry it.
    static let openingSgf =
        "(;FF[4]GM[1]SZ[19]KM[7.5]RU[koSIMPLEscoreAREAtaxNONEsui0whbN];B[pd];W[dp];B[pp];W[dd];B[qf])"

    /// A named, dated game whose `currentIndex` HAS stones — TVGameCard's
    /// primary `displayIndex` branch — with cumulative per-move position dicts
    /// and a short score-lead history that crosses zero (both chart tones).
    static func openingGame(name: String = "Opening study") -> GameRecord {
        GameRecord(sgf: openingSgf,
                   currentIndex: 5,
                   config: Config(),
                   name: name,
                   lastModificationDate: Date(timeIntervalSince1970: 1_780_000_000),
                   scoreLeads: [0: 2.5, 1: 8.0, 2: -4.0, 3: -12.0, 4: 6.0, 5: 3.5],
                   blackStones: [1: "Q16", 2: "Q16", 3: "Q16 Q4",
                                 4: "Q16 Q4", 5: "Q16 Q4 R14"],
                   whiteStones: [2: "D4", 3: "D4", 4: "D4 D16", 5: "D4 D16"],
                   width: 19,
                   height: 19)
    }

    /// A long analyzed game: 61 score-lead points swinging across zero several
    /// times (deterministic sine — no randomness), exercising the dual-tone
    /// area fills and the mid-game current-move marker in the chart previews.
    static func denseAnalyzedGame() -> GameRecord {
        var leads: [Int: Float] = [:]
        for i in 0...60 {
            leads[i] = Float(sin(Double(i) / 7.0) * 15.0)
        }
        return GameRecord(sgf: openingSgf,
                          currentIndex: 23,
                          config: Config(),
                          name: "Analyzed game",
                          lastModificationDate: Date(timeIntervalSince1970: 1_780_100_000),
                          scoreLeads: leads,
                          width: 19,
                          height: 19)
    }

    /// An untitled, never-dated game whose `currentIndex` points PAST the stone
    /// dicts — TVGameCard's fallback `displayIndex` branch (highest visited
    /// move), the "Untitled" name branch, and the hidden-date branch.
    static func untitledFallbackGame() -> GameRecord {
        GameRecord(sgf: openingSgf,
                   currentIndex: 99,
                   config: Config(),
                   name: "",
                   lastModificationDate: nil,
                   blackStones: [1: "Q16", 2: "Q16", 3: "Q16 Q4"],
                   whiteStones: [2: "D4", 3: "D4"],
                   width: 19,
                   height: 19)
    }

    /// A 9×9 game so the library grid shows a non-19×19 thumbnail.
    static func smallBoardGame() -> GameRecord {
        GameRecord(sgf: "(;FF[4]GM[1]SZ[9]KM[7]RU[koSIMPLEscoreAREAtaxNONEsui0whbN];B[ee];W[cc];B[gc])",
                   currentIndex: 3,
                   config: Config(boardWidth: 9, boardHeight: 9),
                   name: "Small board",
                   lastModificationDate: Date(timeIntervalSince1970: 1_779_000_000),
                   blackStones: [1: "E5", 2: "E5", 3: "E5 G7"],
                   whiteStones: [2: "C7", 3: "C7"],
                   width: 9,
                   height: 9)
    }

    /// A GameSession whose models are pre-staged for the review screen: stones
    /// on the board, captures, a decided win rate/score, and per-color
    /// Human-vs-AI thinking times so both `playerLabel` branches render.
    /// The engine is never launched — GTP sends land in a dead buffer.
    static func reviewSession(game: GameRecord,
                              blackWinrate: Float,
                              blackScore: Float) -> GameSession {
        let session = GameSession()
        session.board.width = 19
        session.board.height = 19
        session.stones.blackPoints = [BoardPoint(x: 15, y: 15),
                                      BoardPoint(x: 15, y: 3),
                                      BoardPoint(x: 16, y: 13)]
        session.stones.whitePoints = [BoardPoint(x: 3, y: 3),
                                      BoardPoint(x: 3, y: 15)]
        session.stones.blackStonesCaptured = 2
        session.stones.whiteStonesCaptured = 5
        session.rootWinrate.black = blackWinrate
        session.rootScore.black = blackScore
        // Black = Human (no thinking time), White = AI (0.5 s per move).
        game.concreteConfig.optionalBlackMaxTime = 0
        game.concreteConfig.optionalWhiteMaxTime = 0.5
        return session
    }
}
#endif
