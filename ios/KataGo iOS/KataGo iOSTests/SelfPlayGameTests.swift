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

    @MainActor
    @Test("makeRecord clamps the demo board to min(19, maxBoardLength)")
    func recordBoardSizeClamp() {
        // Below 19 → clamped square board + matching small-board SGF (the same
        // clamp iOS uses for new games) so self-play stays runnable when the
        // user lowers Max Board Size.
        let nine = SelfPlayGame.makeRecord(maxBoardLength: 9)
        #expect(nine.concreteConfig.boardWidth == 9)
        #expect(nine.concreteConfig.boardHeight == 9)
        #expect(nine.sgf == GameRecord.makeDefaultSgf(boardSize: 9))

        let thirteen = SelfPlayGame.makeRecord(maxBoardLength: 13)
        #expect(thirteen.concreteConfig.boardWidth == 13)
        #expect(thirteen.concreteConfig.boardHeight == 13)

        // 19 and 37 keep the full 19×19 demo (default SGF, not clamped).
        for cap in [19, 37] {
            let record = SelfPlayGame.makeRecord(maxBoardLength: cap)
            #expect(record.concreteConfig.boardWidth == 19)
            #expect(record.concreteConfig.boardHeight == 19)
            #expect(record.sgf == GameRecord.defaultSgf)
        }

        // Both sides stay engine-played regardless of the clamped size.
        #expect(nine.concreteConfig.blackMaxTime == SelfPlayGame.moveTime)
        #expect(nine.concreteConfig.whiteMaxTime == SelfPlayGame.moveTime)
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

    // The interstitial's pre-RE[] fallback anticipates the result from the
    // live score sign. A dead-even score is a draw — the old `>= 0` sign
    // check attributed it to Black (user-reported on a drawn live game).
    @Test("Anticipated result from live score: sign wins, even is a draw")
    func anticipatedResultText() {
        #expect(SelfPlayGame.anticipatedResultText(blackScore: 3.5) == "Black wins")
        #expect(SelfPlayGame.anticipatedResultText(blackScore: 0.1) == "Black wins")
        #expect(SelfPlayGame.anticipatedResultText(blackScore: -0.5) == "White wins")
        #expect(SelfPlayGame.anticipatedResultText(blackScore: 0) == "Draw")
        // Same evenness rule as the score label: anything that would display
        // as 0.0 is a draw, either side of zero.
        #expect(SelfPlayGame.anticipatedResultText(blackScore: 0.04) == "Draw")
        #expect(SelfPlayGame.anticipatedResultText(blackScore: -0.04) == "Draw")
    }

    @Test("Side-annotated score lead: B+/W+ one decimal, Even at zero")
    func sideAnnotatedScoreLead() {
        #expect(ScoreLeadText.sideAnnotated(blackScore: 2.34) == "B+2.3")
        #expect(ScoreLeadText.sideAnnotated(blackScore: 0.06) == "B+0.1")
        #expect(ScoreLeadText.sideAnnotated(blackScore: -0.51) == "W+0.5")
        #expect(ScoreLeadText.sideAnnotated(blackScore: -12) == "W+12.0")
        // A lead that would display as 0.0 must not claim a side (the old
        // `>= 0` check rendered a drawn position as "B+0.0").
        #expect(ScoreLeadText.sideAnnotated(blackScore: 0) == "Even")
        #expect(ScoreLeadText.sideAnnotated(blackScore: 0.04) == "Even")
        #expect(ScoreLeadText.sideAnnotated(blackScore: -0.04) == "Even")
    }

    // Why TVSelfPlayScreen must set unlockEditingOnReload before loading the
    // demo: editingAfterLoad only auto-unlocks the 19×19 defaultSgf, so a
    // Max-Board-Size-clamped (9/13) demo record would load LOCKED — the first
    // AI move then silently activates a branch and every printsgf reply
    // (including the final RE[…]) routes into branchSgf, never game.sgf: the
    // interstitial's score-sign fallback persists for the whole 8 s.
    @MainActor
    @Test("Clamped demo SGF does not auto-unlock — the demo must request it")
    func clampedDemoNeedsUnlockRequest() {
        let clamped = SelfPlayGame.makeRecord(maxBoardLength: 9)
        #expect(!GobanState.editingAfterLoad(sgf: clamped.sgf, unlockRequested: false))
        #expect(GobanState.editingAfterLoad(sgf: clamped.sgf, unlockRequested: true))
        // The full-size demo keeps auto-unlocking with or without the request.
        let full = SelfPlayGame.makeRecord(maxBoardLength: 19)
        #expect(GobanState.editingAfterLoad(sgf: full.sgf, unlockRequested: false))
    }
}
