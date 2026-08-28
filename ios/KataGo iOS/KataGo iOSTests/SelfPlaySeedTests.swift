//
//  SelfPlaySeedTests.swift
//  KataGo AnytimeTests
//

import Foundation
import Testing
@testable import KataGoUICore

@MainActor
struct SelfPlaySeedTests {
    /// A 9x9 game two moves deep. The RU tag is mandatory — the C++ parser
    /// aborts the process without it.
    private static let sgf =
        "(;FF[4]GM[1]SZ[9]KM[7]RU[koSIMPLEscoreAREAtaxNONEsui0whbN];B[cc];W[gg])"

    private func seed(rule: Int = 1) -> SelfPlaySeed {
        SelfPlaySeed(sgf: Self.sgf,
                     moveCount: 2,
                     rule: rule,
                     name: "Kim vs Lee",
                     scoreLeads: [0: 0.5, 1: 1.5, 2: 2.5],
                     winRates: [0: 0.5, 1: 0.52, 2: 0.55])
    }

    @Test func theSeededRecordCarriesThePositionAtItsTip() {
        let record = SelfPlayGame.makeRecord(seed: seed())
        #expect(record.sgf == Self.sgf)
        // currentIndex MUST equal the SGF's move count: isOverwriting is
        // `currentIndex < moveSize && (isEditing || isBranchActive)`, and the
        // seeded record loads unlocked — a mid-game index would latch the
        // AI-overwrite confirmation, which no tvOS view renders.
        #expect(record.currentIndex == 2)
        #expect(record.name == "Kim vs Lee")
    }

    @Test func boardSizeAndKomiAreInheritedFromTheSgf() {
        let config = SelfPlayGame.makeRecord(seed: seed()).concreteConfig
        #expect(config.boardWidth == 9)
        #expect(config.boardHeight == 9)
        #expect(config.komi == 7)
    }

    /// The factory derives a label from the SGF's components, but the seed's
    /// label is authoritative — engine-identical twins (Korean/Japanese,
    /// BGA/AGA) would otherwise snap to the first component match. The carry
    /// is a plain overwrite, so even a label contradicting the components
    /// survives here (production seeds cannot contradict — the review screen
    /// already reconciled them, and the self-play screen's loadGame would
    /// heal one anyway).
    @Test func theRuleIndexIsCarriedExplicitly() {
        #expect(SelfPlayGame.makeRecord(seed: seed(rule: 1)).concreteConfig.rule == 1)
        #expect(SelfPlayGame.makeRecord(seed: seed(rule: 3)).concreteConfig.rule == 3)
    }

    /// The broadcast invariant: an asymmetric human-SL config makes BoardView's
    /// turn observer inject kata-set-param acks at every cycle start, which
    /// desyncs the ReportCollector FIFO. The continuation must be symmetric AI.
    @Test func bothSidesAreSymmetricFullStrengthAI() {
        let config = SelfPlayGame.makeRecord(seed: seed()).concreteConfig
        #expect(config.blackMaxTime == SelfPlayGame.moveTime)
        #expect(config.whiteMaxTime == SelfPlayGame.moveTime)
        #expect(config.effectiveHumanProfileForBlack == "AI")
        #expect(config.effectiveHumanProfileForWhite == "AI")
        #expect(config.isEqualBlackWhiteEffectiveHumanSettings)
    }

    /// The report generator's narration path is FoundationModels-only and
    /// tvOS has none; `.narrating` is not a settled stage, so leaving this on
    /// would park the broadcast's slide loop polling.
    @Test func theSeededConfigNeverAsksForLLMNarration() {
        #expect(SelfPlayGame.makeRecord(seed: seed()).concreteConfig.useLLM == false)
    }

    /// Chart continuity: the continuation's score chart picks up where the
    /// reviewed game left off instead of starting empty.
    @Test func perMoveHistoryIsInherited() {
        let record = SelfPlayGame.makeRecord(seed: seed())
        #expect(record.scoreLeads?[2] == 2.5)
        #expect(record.winRates?[2] == 0.55)
    }

    /// A seeded SGF never equals GameRecord.defaultSgf, so it loads LOCKED
    /// unless the caller requests the one-shot unlock. Pinning it here is what
    /// makes TVSelfPlayScreen's unconditional `unlockEditingOnReload = true`
    /// load-bearing rather than incidental.
    @Test func aSeededSgfWouldLoadLockedWithoutTheOneShotUnlock() {
        #expect(!GobanState.editingAfterLoad(sgf: Self.sgf, unlockRequested: false))
        #expect(GobanState.editingAfterLoad(sgf: Self.sgf, unlockRequested: true))
    }

    @Test func theSeedIsHashableSoItCanRideInANavigationPath() {
        #expect(seed() == seed())
        #expect(Set([seed(), seed()]).count == 1)
    }
}
