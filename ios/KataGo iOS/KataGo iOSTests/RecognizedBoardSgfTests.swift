//
//  RecognizedBoardSgfTests.swift
//  KataGo AnytimeTests
//
//  Pure-logic tests for the photo-import SGF synthesis and default next-to-play
//  rule (GobanRecogKit.RecognizedBoard). No image, no recognizer, no engine —
//  the synthesis is a deterministic string transform, so it is TDD-friendly and
//  fast.
//

import Testing
import GobanRecogKit
import KataGoUICore

struct RecognizedBoardSgfTests {

    // A tiny 3×3 position: black at (row 0, col 1), white at (row 1, col 2).
    private func tinyBoard() -> RecognizedBoard {
        RecognizedBoard(size: 3, rows: [".B.", "..W", "..."], confidence: 0.5, quadSource: "test")
    }

    @Test func synthesizedSgfHasMandatoryHeaderTags() {
        let sgf = tinyBoard().synthesizedSGF(nextToPlay: .black)
        // RU[] is MANDATORY (loadsgf aborts without it); KM[7] matches the bridge
        // default; the rest are the fixed app header.
        #expect(sgf.hasPrefix("(;GM[1]FF[4]CA[UTF-8]AP[KataGo Anytime]SZ[3]RU[Chinese]KM[7]PL[B]"))
        #expect(sgf.hasSuffix(")"))
        #expect(sgf.contains("RU[Chinese]"))
        #expect(sgf.contains("KM[7]"))
        #expect(sgf.contains("SZ[3]"))
    }

    @Test func pointsAreColumnLetterFirst() {
        // Black at (row 0, col 1) must encode column-first as "ba" (column b, row
        // a) — NOT the row-first "ab". This is the load-bearing SGF-orientation
        // invariant.
        let sgf = tinyBoard().synthesizedSGF(nextToPlay: .black)
        #expect(sgf.contains("AB[ba]"))
        #expect(!sgf.contains("AB[ab]"))
        // White at (row 1, col 2) → "cb".
        #expect(sgf.contains("AW[cb]"))
    }

    @Test func abSectionPrecedesAwSection() throws {
        let sgf = tinyBoard().synthesizedSGF(nextToPlay: .white)
        let ab = try #require(sgf.range(of: "AB["))
        let aw = try #require(sgf.range(of: "AW["))
        #expect(ab.lowerBound < aw.lowerBound)
        #expect(sgf.contains("PL[W]"))
    }

    @Test func emptySectionsAreOmitted() {
        let blackOnly = RecognizedBoard(size: 3, rows: ["B..", "...", "..."],
                                        confidence: 0.5, quadSource: "test")
        let sgf = blackOnly.synthesizedSGF(nextToPlay: .black)
        #expect(sgf.contains("AB[aa]"))
        #expect(!sgf.contains("AW"))
    }

    @Test func pointsAreEmittedRowMajor() throws {
        // Two blacks: (row 0, col 2) then (row 2, col 0) → "ca" before "ac".
        let board = RecognizedBoard(size: 3, rows: ["..B", "...", "B.."],
                                    confidence: 0.5, quadSource: "test")
        let sgf = board.synthesizedSGF(nextToPlay: .black)
        let first = try #require(sgf.range(of: "[ca]"))
        let second = try #require(sgf.range(of: "[ac]"))
        #expect(first.lowerBound < second.lowerBound)
    }

    @Test func defaultNextToPlayEqualCountsIsBlack() {
        let board = RecognizedBoard(size: 3, rows: ["B..", "..W", "..."],
                                    confidence: 0.5, quadSource: "test")
        #expect(board.blackCount == 1)
        #expect(board.whiteCount == 1)
        #expect(board.defaultNextToPlay == .black)
    }

    @Test func defaultNextToPlayBlackAheadByOneIsWhite() {
        // 2 black, 1 white → Black has played one more → White to move.
        let board = RecognizedBoard(size: 3, rows: ["BB.", "..W", "..."],
                                    confidence: 0.5, quadSource: "test")
        #expect(board.defaultNextToPlay == .white)
    }

    @Test func defaultNextToPlayOtherwiseIsBlack() {
        // Black ahead by two → ambiguous → default Black.
        let ahead2 = RecognizedBoard(size: 3, rows: ["BBB", "..W", "..."],
                                     confidence: 0.5, quadSource: "test")
        #expect(ahead2.defaultNextToPlay == .black)
        // White ahead → ambiguous → default Black.
        let whiteAhead = RecognizedBoard(size: 3, rows: ["B..", "WW.", "..."],
                                         confidence: 0.5, quadSource: "test")
        #expect(whiteAhead.defaultNextToPlay == .black)
    }

    @Test func synthesizesExpectedSgfForKnownBoard() {
        // The recognized img_00009 position (size 9, 12 B + 12 W). The AB/AW body
        // is byte-identical to the C++ board_to_sgf; synthesis only adds the
        // RU/KM/PL/AP header tags.
        let rows = [
            ".........",
            "......WBB",
            "......WB.",
            "..W...B..",
            "....WW...",
            "....BWW..",
            "..W..BW..",
            ".WW..BB.B",
            "W...BBB..",
        ]
        let board = RecognizedBoard(size: 9, rows: rows, confidence: 0.8, quadSource: "hull")
        #expect(board.blackCount == 12)
        #expect(board.whiteCount == 12)
        #expect(board.defaultNextToPlay == .black)
        let expected = "(;GM[1]FF[4]CA[UTF-8]AP[KataGo Anytime]SZ[9]RU[Chinese]KM[7]PL[B]"
            + "AB[hb][ib][hc][gd][ef][fg][fh][gh][ih][ei][fi][gi]"
            + "AW[gb][gc][cd][ee][fe][ff][gf][cg][gg][bh][ch][ai])"
        #expect(board.synthesizedSGF(nextToPlay: .black) == expected)
    }

    @Test func synthesizedSgfRoundTripsThroughEngineFinalPosition() {
        // The synthesized SGF must parse through the same engine SGF path the
        // importer and the preview use (SgfOperations → SgfCpp.getFinalPosition),
        // and every recognized stone must survive (setup stones are placed
        // as-is, not capture-resolved), so the preview matches the import.
        let rows = [
            ".........",
            "......WBB",
            "......WB.",
            "..W...B..",
            "....WW...",
            "....BWW..",
            "..W..BW..",
            ".WW..BB.B",
            "W...BBB..",
        ]
        let board = RecognizedBoard(size: 9, rows: rows, confidence: 0.8, quadSource: "hull")
        let sgf = board.synthesizedSGF(nextToPlay: .black)
        let stones = SgfOperations(sgf: sgf).finalStones()
        #expect(stones.black.count == board.blackCount)
        #expect(stones.white.count == board.whiteCount)
    }

    @Test func errorMessagesAreUserFacing() {
        let failed = BoardRecognitionError.recognitionFailed(reason: "low_confidence")
        #expect(!failed.userFacingMessage.isEmpty)
        #expect(failed.userFacingMessage.contains("Go board"))
        // Raw reason preserved for logging.
        if case .recognitionFailed(let reason) = failed {
            #expect(reason == "low_confidence")
        } else {
            Issue.record("expected recognitionFailed")
        }
        #expect(!BoardRecognitionError.invalidImage.userFacingMessage.isEmpty)
    }
}

/// Pure-logic tests for the tap-to-correct editing seam
/// (`RecognizedBoard.cyclingStone(atCol:row:)` + `stoneVertices`), which the
/// photo-import preview uses to fix mis-recognized stones before importing.
/// Same file as the synthesis tests to avoid app-target pbxproj churn.
struct RecognizedBoardEditingTests {

    // A tiny 3×3 position: black at (row 0, col 1), white at (row 1, col 2).
    private func tinyBoard() -> RecognizedBoard {
        RecognizedBoard(size: 3, rows: [".B.", "..W", "..."], confidence: 0.5, quadSource: "test")
    }

    // The recognized img_00009 position (size 9, 12 B + 12 W), shared with the
    // synthesis tests above.
    private func knownBoard() -> RecognizedBoard {
        let rows = [
            ".........",
            "......WBB",
            "......WB.",
            "..W...B..",
            "....WW...",
            "....BWW..",
            "..W..BW..",
            ".WW..BB.B",
            "W...BBB..",
        ]
        return RecognizedBoard(size: 9, rows: rows, confidence: 0.8, quadSource: "hull")
    }

    @Test func cyclingEmptyBecomesBlack() {
        let edited = tinyBoard().cyclingStone(atCol: 0, row: 2)
        #expect(edited.rows == [".B.", "..W", "B.."])
        #expect(edited.blackCount == 2)
        #expect(edited.whiteCount == 1)
    }

    @Test func cyclingBlackBecomesWhite() {
        let edited = tinyBoard().cyclingStone(atCol: 1, row: 0)
        #expect(edited.rows == [".W.", "..W", "..."])
        #expect(edited.blackCount == 0)
        #expect(edited.whiteCount == 2)
    }

    @Test func cyclingWhiteBecomesEmpty() {
        let edited = tinyBoard().cyclingStone(atCol: 2, row: 1)
        #expect(edited.rows == [".B.", "...", "..."])
        #expect(edited.blackCount == 1)
        #expect(edited.whiteCount == 0)
    }

    @Test func cyclingThreeTimesRestoresOriginal() {
        // Equatable round-trip is what hides the Reset button after the user
        // cycles a point back to its recognized state.
        let original = tinyBoard()
        let cycled = original
            .cyclingStone(atCol: 1, row: 2)
            .cyclingStone(atCol: 1, row: 2)
            .cyclingStone(atCol: 1, row: 2)
        #expect(cycled == original)
    }

    @Test func cyclingOutOfRangeReturnsSelf() {
        let original = tinyBoard()
        #expect(original.cyclingStone(atCol: -1, row: 0) == original)
        #expect(original.cyclingStone(atCol: 3, row: 0) == original)
        #expect(original.cyclingStone(atCol: 0, row: -1) == original)
        #expect(original.cyclingStone(atCol: 0, row: 3) == original)
    }

    @Test func cyclingPreservesMetadata() {
        let edited = tinyBoard().cyclingStone(atCol: 0, row: 0)
        #expect(edited.size == 3)
        #expect(edited.confidence == 0.5)
        #expect(edited.quadSource == "test")
    }

    @Test func stoneVerticesMapGridToGtp() {
        // Corners and center pin the grid → GTP mapping: row 0 = top ("9" on a
        // 9×9), and column 8 is "J" (GTP skips "I").
        let rows = [
            "B........",
            ".........",
            ".........",
            ".........",
            "....W....",
            ".........",
            ".........",
            ".........",
            "........B",
        ]
        let board = RecognizedBoard(size: 9, rows: rows, confidence: 0.8, quadSource: "test")
        let vertices = board.stoneVertices
        #expect(vertices.black == ["A9", "J1"])
        #expect(vertices.white == ["E5"])
    }

    @Test func stoneVerticesMatchEngineFinalStones() {
        // Parity pin: the pure mapping the preview renders from must agree with
        // the SGF → engine-final-position path the importer uses, so the preview
        // still matches the imported game exactly.
        let board = knownBoard()
        let sgf = board.synthesizedSGF(nextToPlay: .black)
        let stones = SgfOperations(sgf: sgf).finalStones()
        #expect(Set(board.stoneVertices.black) == Set(stones.black))
        #expect(Set(board.stoneVertices.white) == Set(stones.white))
    }

    @Test func synthesizedSgfReflectsEdits() {
        // Empty (row 2, col 0) → "ac" appears as a new AB point.
        let addedBlack = tinyBoard().cyclingStone(atCol: 0, row: 2)
        let addedSgf = addedBlack.synthesizedSGF(nextToPlay: .black)
        #expect(addedSgf.contains("AB[ba][ac]"))
        #expect(addedSgf.contains("PL[B]"))

        // Black (row 0, col 1) → white: "ba" moves from AB to AW; PL untouched.
        let flipped = tinyBoard().cyclingStone(atCol: 1, row: 0)
        let flippedSgf = flipped.synthesizedSGF(nextToPlay: .black)
        #expect(!flippedSgf.contains("AB"))
        #expect(flippedSgf.contains("AW[ba][cb]"))
        #expect(flippedSgf.contains("PL[B]"))
    }
}
