import Testing
@testable import KataGoUICore
import KataGoGameStore

struct OpponentLadderTests {
    @Test("the ladder runs weakest to strongest and ends at Full Strength")
    func ladderOrder() {
        #expect(OpponentLadder.kinds.first == "25k")
        #expect(OpponentLadder.kinds.last == RankCatalog.aiProfile)
        #expect(OpponentLadder.kinds.count == RankCatalog.kyu.count + RankCatalog.dan.count + 1)
        // 1k sits directly below 1d: the kyu and dan runs meet without a gap.
        let oneKyu = OpponentLadder.kinds.firstIndex(of: "1k")
        let oneDan = OpponentLadder.kinds.firstIndex(of: "1d")
        #expect(oneKyu != nil && oneDan == oneKyu.map { $0 + 1 })
        #expect(Set(OpponentLadder.kinds).count == OpponentLadder.kinds.count)
    }

    @Test("every rung is a kind the form can choose")
    func everyRungIsChoosable() {
        for kind in OpponentLadder.kinds {
            var form = TVNewGameForm(maxBoardLength: 19)
            form.chooseKind(kind)
            #expect(form.rankKind == kind)
        }
    }

    @Test("a stored kind or a full profile key finds its rung")
    func indexOfKindOrProfile() {
        #expect(OpponentLadder.kind(at: OpponentLadder.index(of: "5k")) == "5k")
        #expect(OpponentLadder.kind(at: OpponentLadder.index(of: "5k 2019")) == "5k")
        #expect(OpponentLadder.kind(at: OpponentLadder.index(of: "AI")) == "AI")
    }

    @Test("a kind that is not on the ladder lands on the default, not an end")
    func offLadderKindsUseTheDefault() {
        let fallback = OpponentLadder.index(of: OpponentLadder.defaultKind)
        #expect(OpponentLadder.kinds.contains(OpponentLadder.defaultKind))
        #expect(OpponentLadder.index(of: "Pro 1997") == fallback)
        #expect(OpponentLadder.index(of: "") == fallback)
        #expect(OpponentLadder.index(of: "not a rank") == fallback)
    }

    @Test("positions outside the ladder clamp onto it")
    func kindClamps() {
        #expect(OpponentLadder.kind(at: -3) == "25k")
        #expect(OpponentLadder.kind(at: 999) == RankCatalog.aiProfile)
    }

    @Test("titles spell the rank out")
    func titles() {
        #expect(OpponentLadder.title(forKind: "15k") == "15 kyu")
        #expect(OpponentLadder.title(forKind: "3d") == "3 dan")
        #expect(OpponentLadder.title(forKind: RankCatalog.aiProfile) == "Full Strength")
    }

    @Test("every rung has a summary, and the tiers change along the ladder")
    func summaries() {
        let summaries = OpponentLadder.kinds.map(OpponentLadder.summary(forKind:))
        #expect(summaries.allSatisfy { !$0.isEmpty })
        #expect(OpponentLadder.summary(forKind: "25k") != OpponentLadder.summary(forKind: "12k"))
        #expect(OpponentLadder.summary(forKind: "12k") != OpponentLadder.summary(forKind: "4k"))
        #expect(OpponentLadder.summary(forKind: "4k") != OpponentLadder.summary(forKind: "2d"))
        #expect(OpponentLadder.summary(forKind: "2d") != OpponentLadder.summary(forKind: "7d"))
        #expect(OpponentLadder.summary(forKind: "7d") != OpponentLadder.summary(forKind: "AI"))
    }
}
