//
//  SelfPlayGameTests.swift
//  KataGo iOSTests
//
//  Pins the demo-record shape the tvOS self-play loop depends on, and the
//  RE[] result parsing table.
//

import Testing
@testable import KataGoUICore

struct SelfPlayGameTests {

    @MainActor
    @Test("makeRecord: both sides engine-played, effective profiles AI, default SGF")
    func recordShape() {
        let record = SelfPlayGame.makeRecord()
        let config = record.concreteConfig
        #expect(config.blackMaxTime == SelfPlayGame.moveTime)
        #expect(config.whiteMaxTime == SelfPlayGame.moveTime)
        // Only the "AI" profile can gen-move on tvOS (no human-SL net), and
        // symmetric settings avoid per-move asymmetric human-SL commands.
        #expect(config.effectiveHumanProfileForBlack == "AI")
        #expect(config.effectiveHumanProfileForWhite == "AI")
        #expect(config.isEqualBlackWhiteEffectiveHumanSettings)
        // defaultSgf → loadGame unlocks editing (editingAfterLoad), which is
        // what lets every AI move persist into the (in-memory) record.
        #expect(record.sgf == GameRecord.defaultSgf)
        #expect(record.currentIndex == 0)
        #expect(record.name == SelfPlayGame.demoName)
    }

    @Test("RE[] parsing table")
    func resultParsing() {
        typealias R = SelfPlayGame.Result
        #expect(SelfPlayGame.result(fromSgf: "(;FF[4]RE[B+3.5];B[pd])") == R.black(margin: 3.5))
        #expect(SelfPlayGame.result(fromSgf: "(;FF[4]RE[W+0.5])") == R.white(margin: 0.5))
        #expect(SelfPlayGame.result(fromSgf: "(;FF[4]RE[B+2])") == R.black(margin: 2))
        #expect(SelfPlayGame.result(fromSgf: "(;FF[4]RE[0])") == R.draw)
        #expect(SelfPlayGame.result(fromSgf: "(;FF[4]RE[Void])") == R.unknown)
        #expect(SelfPlayGame.result(fromSgf: "(;FF[4]RE[B+R])") == R.black(margin: nil))
        #expect(SelfPlayGame.result(fromSgf: "(;FF[4]RE[W+R])") == R.white(margin: nil))
        #expect(SelfPlayGame.result(fromSgf: "(;FF[4];B[pd])") == R.unknown)
    }

    @Test("Result text")
    func resultText() {
        #expect(SelfPlayGame.resultText(.black(margin: 3.5)) == "Black wins by 3.5")
        #expect(SelfPlayGame.resultText(.black(margin: 2)) == "Black wins by 2")
        #expect(SelfPlayGame.resultText(.white(margin: 0.5)) == "White wins by 0.5")
        #expect(SelfPlayGame.resultText(.white(margin: nil)) == "White wins")
        #expect(SelfPlayGame.resultText(.draw) == "Draw")
        #expect(SelfPlayGame.resultText(.unknown) == "Game over")
    }
}
