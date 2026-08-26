//
//  SampleGamesTests.swift
//  KataGo iOSTests
//
//  Gate for the bundled Ear-Reddening Game sample. A malformed checked-in SGF
//  aborts uncatchably in C++ (Sgf::getRulesOrFail) — this suite merely running
//  to completion IS the parse gate; the assertions pin the record's shape
//  against what the tvOS library card and review screen expect.
//

import Testing
@testable import KataGoUICore

struct SampleGamesTests {

    @Test("The checked-in SGF parses to the full 325-move historical record")
    func sgfParses() {
        let ops = SgfOperations(sgf: SampleGames.earReddeningSgf)
        #expect(ops.moveSize == 325)
        #expect(ops.xSize == 19)
        #expect(ops.ySize == 19)
        // The historical game had no komi; rules parsing without aborting is
        // the RU[Japanese] gate.
        #expect(ops.rules.komi == 0)
    }

    @Test("The final position is a plausible finished 19×19 game")
    func finalStonesPlausible() {
        let final = SgfOperations(sgf: SampleGames.earReddeningSgf).finalStones()
        #expect(final.black.count > 100)
        #expect(final.white.count > 100)
        #expect(final.black.count + final.white.count <= 361)
    }

    @Test("The baked score-lead history covers the game and ends near B+2")
    func scoreLeadsShape() {
        let leads = SampleGames.earReddeningScoreLeads
        #expect(leads.count == 326)
        #expect(leads.keys.allSatisfy { (0...325).contains($0) })
        // The chart renders from 2 points; the real curve has all 326.
        #expect(leads.count >= 2)
        // Black won by 2 — the final eval should agree in sign and ballpark.
        let final = leads[325] ?? 0
        #expect(final > 0 && final < 6)
    }

    @MainActor
    @Test("makeEarReddeningRecord builds the shape the TV library expects")
    func recordShape() {
        let record = SampleGames.makeEarReddeningRecord()
        #expect(record.currentIndex == 0)
        #expect(record.config != nil)
        #expect(record.width == 19)
        #expect(record.height == 19)
        #expect(record.name == "Ear-Reddening Game")
        // RU[Japanese]: the rule index must match the SGF, or the engine
        // analyzes the no-komi game under the default Chinese rules.
        #expect(Config.rules[record.concreteConfig.rule] == "japanese")
        // Final position keyed exactly at moveSize. The library card no longer
        // reads these — it draws `TVGameCard.Depiction.finishedGame`, replayed
        // from the SGF — but the record still carries the finished board the
        // way a played-through game does, and the widget's `GameEntity` still
        // resolves through the dictionaries.
        #expect(record.blackStones?.keys.sorted() == [325])
        #expect(record.whiteStones?.keys.sorted() == [325])
        #expect(record.scoreLeads?.count == 326)
        #expect(record.lastModificationDate != nil)
    }
}
