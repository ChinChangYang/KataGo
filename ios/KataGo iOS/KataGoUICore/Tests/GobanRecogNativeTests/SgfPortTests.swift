//
//  SgfPortTests.swift
//  GobanRecogNativeTests
//
//  Native tests for the gr_sgf port of gobanrecog/sgf.py::board_to_sgf (Task 9).
//  Ground truth generated with the reference venv (gobanrecog.sgf.board_to_sgf);
//  the generating snippets are inline. Exercises: the exact header, the
//  column-letter-FIRST point encoding, AB-before-AW ordering, row-major point
//  order, and the omit-empty-section rule.
//

import CGobanRecog
import Testing

// MARK: - Bridge helper

/// board_to_sgf on a BoardState built from (size, rows). Returns "!" if
/// BoardState construction threw.
private func boardToSgf(size: Int, rows: [String]) -> String {
    let joined = rows.joined(separator: "\n")
    return joined.withCString {
        String(gobanrecog.testbridge.sgf_board_to_sgf(Int32(size), $0))
    }
}

// MARK: - board_to_sgf (sgf.py:18-25)

@Test
func sgfEmptyBoardHasHeaderOnly() {
    // venv: board_to_sgf(BoardState.empty(9))
    //   -> "(;GM[1]FF[4]CA[UTF-8]AP[GobanRecog:0.1]SZ[9])"
    // No AB/AW sections when both colors are empty (sgf.py's `if pts`).
    let empty9 = boardToSgf(size: 9, rows: Array(repeating: ".........", count: 9))
    #expect(empty9 == "(;GM[1]FF[4]CA[UTF-8]AP[GobanRecog:0.1]SZ[9])")
}

@Test
func sgfMixedBoardColumnFirstAbThenAw() {
    // venv: 9x9, Black (0,0),(8,0),(1,2); White (2,0),(0,8),(8,8)
    //   points('B') -> [(0,0),(8,0),(1,2)]  (row-major: top-to-bottom, l-to-r)
    //   points('W') -> [(2,0),(0,8),(8,8)]
    //   -> AB[aa][ia][bc]AW[ca][ai][ii]
    // _point(col,row) = chr('a'+col) + chr('a'+row): COLUMN letter first, so
    //   (8,0) -> 'i'+'a' = "ia", (1,2) -> 'b'+'c' = "bc", (0,8) -> 'a'+'i' = "ai".
    var rows = Array(repeating: ".........", count: 9)
    func set(_ col: Int, _ row: Int, _ ch: Character) {
        var chars = Array(rows[row])
        chars[col] = ch
        rows[row] = String(chars)
    }
    set(0, 0, "B"); set(8, 0, "B"); set(1, 2, "B")
    set(2, 0, "W"); set(0, 8, "W"); set(8, 8, "W")
    #expect(boardToSgf(size: 9, rows: rows) ==
            "(;GM[1]FF[4]CA[UTF-8]AP[GobanRecog:0.1]SZ[9]AB[aa][ia][bc]AW[ca][ai][ii])")
}

@Test
func sgfBlackOnlyOmitsAwSection() {
    // venv: 13x13, Black (1,1),(2,1),(7,5) -> AB[bb][cb][hf], NO AW.
    var rows = Array(repeating: String(repeating: ".", count: 13), count: 13)
    func set(_ col: Int, _ row: Int, _ ch: Character) {
        var chars = Array(rows[row]); chars[col] = ch; rows[row] = String(chars)
    }
    set(1, 1, "B"); set(2, 1, "B"); set(7, 5, "B")
    #expect(boardToSgf(size: 13, rows: rows) ==
            "(;GM[1]FF[4]CA[UTF-8]AP[GobanRecog:0.1]SZ[13]AB[bb][cb][hf])")
}

@Test
func sgfWhiteOnlyOmitsAbSection() {
    // venv: 19x19, White at the center (9,9) -> AW[jj], NO AB.
    var rows = Array(repeating: String(repeating: ".", count: 19), count: 19)
    var chars = Array(rows[9]); chars[9] = "W"; rows[9] = String(chars)
    #expect(boardToSgf(size: 19, rows: rows) ==
            "(;GM[1]FF[4]CA[UTF-8]AP[GobanRecog:0.1]SZ[19]AW[jj])")
}
