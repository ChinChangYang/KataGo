//
//  PastedSgfTests.swift
//  KataGo Anytime MacTests
//

import Testing

struct PastedSgfTests {

    // MARK: - Rejected clipboards

    @Test func rejectsNilClipboard() {
        #expect(PastedSgf.scan(nil) == nil)
    }

    @Test func rejectsEmptyAndWhitespace() {
        #expect(PastedSgf.scan("") == nil)
        #expect(PastedSgf.scan("   \n\t  ") == nil)
    }

    @Test func rejectsPlainText() {
        #expect(PastedSgf.scan("hello world") == nil)
        #expect(PastedSgf.scan("<html>Not a game</html>") == nil)
        #expect(PastedSgf.scan("https://online-go.com/game/12345") == nil)
    }

    /// An SGF quoted inside prose is rejected on purpose: the C++ `maybeParseSgf`
    /// demands "(" as the first non-BOM, non-whitespace character, so accepting
    /// it here would only move the failure to after the draft prompt.
    @Test func rejectsSgfEmbeddedInProse() {
        #expect(PastedSgf.scan("my game: (;FF[4]GM[1]SZ[19];B[dd])") == nil)
    }

    /// A payload past the byte cap is refused before it is walked, so a copied
    /// log file cannot stall the paste.
    @Test func rejectsOversizedClipboard() {
        let filler = String(repeating: "C[xxxxxxxx]", count: 900_000)
        let huge = "(;FF[4]GM[1]SZ[19]" + filler + ")"
        #expect(huge.utf8.count > PastedSgf.maxByteLength)
        #expect(PastedSgf.scan(huge) == nil)
    }

    // MARK: - Accepted clipboards

    /// A game with no moves is usable: it carries size/komi/rules, exactly like
    /// importing an empty .sgf through ⌘O.
    @Test func acceptsSgfWithNoMoves() {
        let scanned = PastedSgf.scan("(;FF[4]GM[1]SZ[19])")
        #expect(scanned?.boardWidth == 19)
        #expect(scanned?.boardHeight == 19)
        #expect(scanned?.moveCount == 0)
    }

    @Test func acceptsSgfWithMoves() {
        let scanned = PastedSgf.scan("(;FF[4]GM[1]SZ[19];B[dd];W[pp])")
        #expect(scanned?.moveCount == 2)
        #expect(scanned?.boardWidth == 19)
    }

    @Test func acceptsRectangularBoard() {
        let scanned = PastedSgf.scan("(;FF[4]GM[1]SZ[19:9];B[aa])")
        #expect(scanned?.boardWidth == 19)
        #expect(scanned?.boardHeight == 9)
    }

    @Test func defaultsToNineteenWithoutSizeTag() {
        let scanned = PastedSgf.scan("(;FF[4]GM[1];B[aa])")
        #expect(scanned?.boardWidth == 19)
        #expect(scanned?.boardHeight == 19)
    }

    // MARK: - Normalization

    /// The normalized `sgf` is what gets handed to the importer, and the
    /// importer de-dups on an EXACT string match — so trimming has to happen
    /// here for ⌘C → ⌘V to re-select rather than duplicate.
    @Test func trimsSurroundingWhitespace() {
        #expect(PastedSgf.scan("\n  (;FF[4]GM[1]SZ[9])  \n")?.sgf == "(;FF[4]GM[1]SZ[9])")
    }

    /// U+FEFF is category Cf, so `trimmingCharacters(in: .whitespacesAndNewlines)`
    /// leaves it in place. The C++ `peekSgfChar` skips it, so we must too.
    @Test func stripsLeadingByteOrderMark() {
        let scanned = PastedSgf.scan("\u{FEFF}(;FF[4]GM[1]SZ[9])")
        #expect(scanned?.sgf == "(;FF[4]GM[1]SZ[9])")
        #expect(scanned?.boardWidth == 9)
    }

    // MARK: - Multi-game collections

    /// `Sgf::parse` ignores everything after the first game tree, and the move
    /// scan stops at the first unescaped ")" — so a collection imports game 1.
    @Test func takesFirstGameOfACollection() {
        let scanned = PastedSgf.scan("(;FF[4]GM[1]SZ[9];B[aa])(;FF[4]GM[1]SZ[19];B[dd];W[pp])")
        #expect(scanned?.moveCount == 1)
        #expect(scanned?.boardWidth == 9)
    }

    /// KNOWN DIVERGENCE, asserted so it cannot be "fixed" by accident: the
    /// board size is read with a whole-string `firstMatch(of: /SZ…/)` while the
    /// moves stop at the first game tree. On a collection whose FIRST game omits
    /// SZ, this scan reports the SECOND game's size (9) where the C++ parse says
    /// 19. That is why `importAndSelect` re-checks the board size against the
    /// parsed config before inserting, instead of trusting this value.
    @Test func collectionSizeCanDivergeFromTheParser() {
        let scanned = PastedSgf.scan("(;FF[4]GM[1];B[dd])(;FF[4]GM[1]SZ[9];B[aa])")
        #expect(scanned?.boardWidth == 9)
        #expect(scanned?.moveCount == 1)
    }

    // MARK: - Board-size gate

    @Test func fitsAcceptsBoardsWithinTheEngineCap() {
        #expect(PastedSgf.scan("(;GM[1]SZ[19])")?.fits(maxBoardLength: 19) == true)
        #expect(PastedSgf.scan("(;GM[1]SZ[9])")?.fits(maxBoardLength: 13) == true)
        #expect(PastedSgf.scan("(;GM[1]SZ[19:9])")?.fits(maxBoardLength: 19) == true)
        #expect(PastedSgf.scan("(;GM[1]SZ[37])")?.fits(maxBoardLength: 37) == true)
    }

    @Test func fitsRejectsOversizeBoards() {
        #expect(PastedSgf.scan("(;GM[1]SZ[19])")?.fits(maxBoardLength: 13) == false)
        #expect(PastedSgf.scan("(;GM[1]SZ[29])")?.fits(maxBoardLength: 19) == false)
        // Width alone over the cap is enough to refuse.
        #expect(PastedSgf.scan("(;GM[1]SZ[19:9])")?.fits(maxBoardLength: 13) == false)
    }

    /// A malformed SZ[0]/SZ[1] must not reach the engine either.
    @Test func fitsRejectsDegenerateBoards() {
        #expect(PastedSgf.scan("(;GM[1]SZ[1])")?.fits(maxBoardLength: 19) == false)
        #expect(PastedSgf.scan("(;GM[1]SZ[0])")?.fits(maxBoardLength: 19) == false)
    }

    /// A nonsense cap can never make a board "fit".
    @Test func fitsRejectsEverythingWhenTheCapIsBelowTheMinimum() {
        #expect(PastedSgf.scan("(;GM[1]SZ[9])")?.fits(maxBoardLength: 1) == false)
    }
}
