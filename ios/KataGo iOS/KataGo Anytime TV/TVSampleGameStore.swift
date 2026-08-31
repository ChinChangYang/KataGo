//
//  TVSampleGameStore.swift
//  KataGo Anytime TV
//
//  Owns the bundled sample game (SampleGames.makeEarReddeningRecord) in a
//  dedicated IN-MEMORY SwiftData container. The sample must NEVER enter
//  SharedModelContainer.shared: opening a game mutates its record
//  (updateToLatestVersion, currentIndex rewind, rule/komi writes into
//  concreteConfig — GobanState.loadGame), and in the CloudKit-mirrored store
//  those writes would sync the sample into the user's library on every
//  device. Here they land in the in-memory context and evaporate on quit.
//

import SwiftData
import KataGoUICore

@MainActor
enum TVSampleGameStore {
    /// `SharedModelContainer.inMemoryConfig()` sets `cloudKitDatabase: .none`
    /// EXPLICITLY — a bare in-memory ModelConfiguration defaults to
    /// `.automatic`, which can itself attempt CloudKit.
    private static let container: ModelContainer? =
        try? ModelContainer(for: SharedModelContainer.schema,
                            configurations: SharedModelContainer.inMemoryConfig())

    /// The sample record, built lazily on first use (the first empty-state
    /// render). Optional by design: on any failure the sample card is simply
    /// absent — never a crash, never a fallback into the real store.
    static let sampleGame: GameRecord? = {
        guard let container else { return nil }
        let record = SampleGames.makeEarReddeningRecord()
        container.mainContext.insert(record)
        return record
    }()

    /// Whether the in-memory store opened — gates the self-play entry points
    /// (a demo that cannot have a record has nowhere to play).
    static var isAvailable: Bool { container != nil }

    /// A fresh self-play demo record. One PER GAME: the play loop mutates the
    /// record every move (sgf, currentIndex, scoreLeads, ownership), so each
    /// game starts clean and the finished one is discarded.
    ///
    /// `maxBoardLength` (the running engine's launched NN-buffer size) clamps
    /// the demo board to `min(19, max)` so self-play stays runnable when the
    /// user lowers Max Board Size below 19 — the engine would otherwise abort
    /// on the first move of an oversized board.
    static func newSelfPlayGame(maxBoardLength: Int? = nil) -> GameRecord? {
        guard let container else { return nil }
        let record = SelfPlayGame.makeRecord(maxBoardLength: maxBoardLength)
        container.mainContext.insert(record)
        return record
    }

    /// A live-continuation game seeded from a reviewed position, inserted into
    /// the SAME private in-memory container as the demo — so a continuation of
    /// a CloudKit-synced game can never itself reach iCloud.
    ///
    /// It CANNOT clamp: the seed carries a reviewed position, and shrinking its
    /// board would change that position (`createGameRecord` only swaps in a
    /// smaller default board when the SGF IS `defaultSgf`, which a seeded SGF
    /// never is). So the CALLER refuses instead — `TVAutoPlayPolicy.continuesLive`
    /// returns false for a board the running engine cannot hold, and
    /// `TVReviewScreen` never asks for the handoff. That check replaced the
    /// review screen's old board-too-large SCREEN, which used to make an
    /// oversized record unreachable; the record now opens and reports *Held*,
    /// so this path is the one that had to learn the rule.
    static func newSelfPlayGame(seed: SelfPlaySeed) -> GameRecord? {
        guard let container else { return nil }
        let record = SelfPlayGame.makeRecord(seed: seed)
        container.mainContext.insert(record)
        return record
    }

    /// Deletes a finished (or abandoned) demo or seeded-continuation record so
    /// endless attract-mode looping doesn't accumulate per-game analysis data
    /// in memory.
    static func discard(_ record: GameRecord) {
        container?.mainContext.delete(record)
    }

    #if DEBUG
    /// The README-screenshot game, for the Play screen.
    ///
    /// A VARIANT of the shared seed rather than the seed itself:
    /// `TVPlayability` routes the plain record — finished (`RE[B+2]`), both
    /// sides human — to the read-only REVIEW screen, and the README image is of
    /// PLAY. So `ScreenshotSeed.playVariantSgf` strips the result tag and drops
    /// the last move, leaving Black (the human) on the ear-reddening move, and
    /// White is handed to the engine here.
    ///
    /// Into the SAME private in-memory container as the demo, for this file's
    /// header reason: opening a game mutates its record, and those writes must
    /// never reach the user's CloudKit-synced library.
    static func screenshotSeedGame() -> GameRecord? {
        guard let container else { return nil }
        let index = ScreenshotSeed.playVariantDisplayIndex
        let record = GameRecord.createGameRecord(
            sgf: ScreenshotSeed.playVariantSgf,
            currentIndex: index,
            name: ScreenshotSeed.recordName,
            // The offline-computed leads the sample already carries, trimmed to
            // the truncated game, so the panel and the score chart show real
            // numbers instead of em-dashes.
            scoreLeads: SampleGames.earReddeningScoreLeads.filter { $0.key <= index })
        record.uuid = ScreenshotSeed.uuid
        let config = record.concreteConfig
        // The asymmetry `TVPlayability.isHumanVsAI` reads: Black is the person
        // on move, White is the engine.
        config.blackMaxTime = 0
        config.whiteMaxTime = Config.toggleAIThinkingTime
        container.mainContext.insert(record)
        return record
    }
    #endif
}
