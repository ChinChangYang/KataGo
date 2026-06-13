//
//  BoardTextParserTests.swift
//  KataGo AnytimeTests
//

import Testing
@testable import KataGo_Anytime

struct BoardTextParserTests {
    // A 3x3 showboard sample. First line is the column header (skipped for
    // parsing). Row numbers are right-aligned to 2 chars; each cell is one
    // glyph + one space, so x = charIndex / 2 over line.dropFirst(3).
    //   row 3: white at column B (x=1)
    //   row 2: black at column A (x=0), move marker "1" at column B (x=1)
    //   row 1: empty
    static let board = [
        "   A B C",
        " 3 . O .",
        " 2 X 1 .",
        " 1 . . .",
    ]

    @Test func parsesStonesDimensionsAndMoveOrder() {
        let r = BoardTextParser.parse(Self.board)
        #expect(r.width == 3)
        #expect(r.height == 3)
        #expect(r.blackStones == [BoardPoint(x: 0, y: 1)])
        #expect(r.whiteStones == [BoardPoint(x: 1, y: 2)])
        #expect(r.moveOrder == [BoardPoint(x: 1, y: 1): "1"])
    }

    @Test func headerOnlyYieldsNoStones() {
        // dropFirst() leaves no rows, so no stones/moves; height = count-1 = 0;
        // width derives from the last line ("   A B C").
        let r = BoardTextParser.parse(["   A B C"])
        #expect(r.height == 0)
        #expect(r.width == 3)
        #expect(r.blackStones.isEmpty)
        #expect(r.whiteStones.isEmpty)
        #expect(r.moveOrder.isEmpty)
    }
}
