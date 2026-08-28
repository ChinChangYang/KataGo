//
//  SelfPlayGame.swift
//  KataGoUICore
//
//  The tvOS "KataGo vs KataGo" self-play demo: a factory for the demo game
//  record (both sides engine-played), a parser for the engine's RE[] result
//  tag, and the pure attract-mode policy. Kept in the package so the record
//  shape, result parsing, and policy truth table are unit-testable from the
//  iOS test host (TV-target code is unreachable from tests).
//

import Foundation

public enum SelfPlayGame {
    /// Per-move thinking budget for BOTH sides. The engine paces itself with
    /// `kata-set-param maxTime` per gen-move (GtpCommandBuilder floors it at
    /// 0.5 s); 1 s reads well on a TV — analysis paints, then the stone lands.
    public static let moveTime: Float = 1.0
    /// How long the result interstitial shows before the next game starts.
    public static let interstitialSeconds: Double = 8
    public static let demoName = "KataGo vs KataGo"

    /// A fresh demo record: default 19×19 SGF (carries the RU tag the C++
    /// parser requires) with both per-move times set so the shared gen-move
    /// loop plays both colors. A fresh `Config()` already resolves both
    /// effective human profiles to "AI" — the default play profile for self-play
    /// gen-move on the TV platform.
    ///
    /// `maxBoardLength` (the size the running engine was launched with) caps the
    /// demo board so self-play stays runnable when the user lowers Max Board
    /// Size below 19: at a cap under 19, `createGameRecord` swaps the default
    /// SGF for a `min(cap, 19)`×`min(cap, 19)` board (the same clamp iOS uses
    /// for new games); `nil`/19/37 keep the full 19×19 demo.
    ///
    /// The caller owns keeping the record OUT of the CloudKit store (insert
    /// into an in-memory container only): every move mutates it.
    @MainActor
    public static func makeRecord(maxBoardLength: Int? = nil) -> GameRecord {
        let record = GameRecord.createGameRecord(name: demoName, maxBoardLength: maxBoardLength)
        let config = record.concreteConfig
        config.blackMaxTime = moveTime
        config.whiteMaxTime = moveTime
        return record
    }

    /// A live-continuation record seeded from a reviewed game's final position.
    ///
    /// Built on `createGameRecord` — NOT `GameRecord.clone()`, which copies the
    /// source Config wholesale (human-SL profiles, per-side max times) and would
    /// hand a Human-vs-9d game off as Human-vs-9d, never moving. The fresh
    /// `Config()` inside the factory already resolves both effective human
    /// profiles to "AI"; this only adds the per-move times, the seed's rule
    /// label (the factory derives one from RU[], but component matching snaps
    /// engine-identical twins — Korean/Japanese, BGA/AGA — to the first hit,
    /// and the reviewed game's exact label must survive the hand-off), and
    /// `useLLM = false` (tvOS has no FoundationModels, and `.narrating` is
    /// not a settled report stage).
    ///
    /// The caller owns keeping this record OUT of the CloudKit store — insert it
    /// into an in-memory container only. Every continuation move mutates it.
    @MainActor
    public static func makeRecord(seed: SelfPlaySeed) -> GameRecord {
        let record = GameRecord.createGameRecord(sgf: seed.sgf,
                                                 currentIndex: seed.moveCount,
                                                 name: seed.name,
                                                 scoreLeads: seed.scoreLeads,
                                                 winRates: seed.winRates)
        let config = record.concreteConfig
        config.rule = seed.rule
        config.blackMaxTime = moveTime
        config.whiteMaxTime = moveTime
        config.useLLM = false
        return record
    }

    // MARK: - Result

    /// The parsed RE[] tag. Margins are nil for non-numeric wins (B+R/B+T),
    /// which cannot occur in the demo (resignation is disabled) but must not
    /// crash the parser if they ever do.
    public enum Result: Equatable {
        case black(margin: Float?)
        case white(margin: Float?)
        case draw
        case unknown
    }

    /// Parses the engine's anticipated result from an SGF. After two passes,
    /// the engine embeds RE[B+3.5] / RE[W+0.5] / RE[0] / RE[Void] into the
    /// printsgf reply (cpp/dataio/sgf.cpp writeSgf); RE[B+R]/RE[W+R] are
    /// tolerated for robustness.
    public static func result(fromSgf sgf: String) -> Result {
        guard let match = sgf.firstMatch(of: /RE\[([^\]]*)\]/) else { return .unknown }
        let tag = String(match.1)
        if tag == "0" { return .draw }
        let isBlack = tag.hasPrefix("B+")
        let isWhite = tag.hasPrefix("W+")
        guard isBlack || isWhite else { return .unknown }   // "Void", "?" …
        let margin = Float(tag.dropFirst(2))                // nil for R/T
        return isBlack ? .black(margin: margin) : .white(margin: margin)
    }

    public static func resultText(_ result: Result) -> String {
        switch result {
        case .black(let margin):
            margin.map { "Black wins by \(marginText($0))" } ?? "Black wins"
        case .white(let margin):
            margin.map { "White wins by \(marginText($0))" } ?? "White wins"
        case .draw:
            "Draw"
        case .unknown:
            "Game over"
        }
    }

    /// The interstitial's fallback before the engine's post-pass printsgf
    /// lands RE[…] in the record: anticipate the result from the live score
    /// sign. Shares `ScoreLeadText`'s evenness rule — a score that would
    /// display as 0.0 is a draw, not a Black win.
    public static func anticipatedResultText(blackScore: Float) -> String {
        if ScoreLeadText.isEven(blackScore: blackScore) { return resultText(.draw) }
        return blackScore > 0 ? "Black wins" : "White wins"
    }

    /// "2" for whole points, "3.5" for halves — no trailing ".0".
    private static func marginText(_ margin: Float) -> String {
        String(format: "%g", margin)
    }

    // MARK: - Recorded-game completion

    /// How many of the SGF's LAST moves are passes, clamped at 2. Used to tell
    /// a game that ended from one that was merely abandoned mid-board.
    ///
    /// Not derived from `GobanState.passCount`: that is a running counter
    /// mutated only by `play`/`undo` and is never seeded from an SGF, so it
    /// says nothing about a game the user just opened.
    public static func trailingPassCount(inSgf sgf: String) -> Int {
        let operations = SgfOperations(sgf: sgf)
        guard let moveSize = operations.moveSize, moveSize > 0 else { return 0 }
        var count = 0
        var index = moveSize - 1
        while index >= 0, count < 2, let move = operations.getMove(at: index), move.location.pass {
            count += 1
            index -= 1
        }
        return count
    }

    /// True when the recorded game already ended — two trailing passes, or a
    /// parsed `RE[]` tag (a resignation has no passes at all).
    ///
    /// This is the Auto-Play handoff gate: continuing a finished game would
    /// seed the engine with a position it answers by passing twice, so the
    /// "continuation" would be a flash of the result card. Auto-Play stops on
    /// such a game instead of pushing.
    public static func recordedGameIsFinished(sgf: String) -> Bool {
        if result(fromSgf: sgf) != .unknown { return true }
        return trailingPassCount(inSgf: sgf) >= 2
    }
}

/// Pure attract-mode decisions, separated from the tvOS controller so the
/// truth table is testable: when the library has been idle long enough,
/// should the demo start, and should a running demo stop?
public enum SelfPlayAttract {
    /// Library inactivity before the demo auto-starts.
    public static let idleTimeout: Duration = .seconds(180)

    /// Start only from the library root, with the scene active, the device
    /// cool, and the in-memory demo store working.
    public static func shouldStart(pathIsEmpty: Bool,
                                   sceneIsActive: Bool,
                                   thermalState: ProcessInfo.ThermalState,
                                   storeAvailable: Bool) -> Bool {
        pathIsEmpty
            && sceneIsActive
            && !shouldStop(thermalState: thermalState)
            && storeAvailable
    }

    /// A fanless Apple TV must not loop games while hot — end the demo at
    /// serious/critical thermal pressure (regardless of how it was started).
    public static func shouldStop(thermalState: ProcessInfo.ThermalState) -> Bool {
        switch thermalState {
        case .serious, .critical: true
        default: false
        }
    }
}
