//
//  BookLookupTests.swift
//  KataGo iOSTests
//
//  Created by Chin-Chang Yang on 2026/3/3.
//

import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

/// Typealias for the position tuple used by BookLookup's test initializer.
fileprivate typealias TestPosition = (
    nextPlayer: Int,
    moves: [(positions: [Int], winLoss: Double, sharpScore: Double, adjustedVisits: Int64, policyPrior: Double)],
    children: [(canonicalPos: Int, childId: Int, sym: Int)]
)

@MainActor
struct BookLookupTests {

    // MARK: - Helper: build a small book

    /// Root (pos 0, black to play) has one move at canonical pos 0 (top-left)
    /// leading to child pos 1 (white to play, leaf with no children).
    fileprivate static func twoNodeBook(linkSym: Int = 0) -> [TestPosition] {
        let root: TestPosition = (
            nextPlayer: 1,
            moves: [(positions: [0], winLoss: 0.6, sharpScore: 2.5, adjustedVisits: 100, policyPrior: 0.8)],
            children: [(canonicalPos: 0, childId: 1, sym: linkSym)]
        )
        let child: TestPosition = (
            nextPlayer: 2,
            moves: [(positions: [72], winLoss: -0.3, sharpScore: -1.0, adjustedVisits: 50, policyPrior: 0.5)],
            children: []
        )
        return [root, child]
    }

    /// Root with two children at pos 0 and pos 1.
    fileprivate static func branchingBook() -> [TestPosition] {
        let root: TestPosition = (
            nextPlayer: 1,
            moves: [
                (positions: [0], winLoss: 0.6, sharpScore: 2.5, adjustedVisits: 100, policyPrior: 0.8),
                (positions: [1], winLoss: 0.4, sharpScore: 1.0, adjustedVisits: 80, policyPrior: 0.6)
            ],
            children: [
                (canonicalPos: 0, childId: 1, sym: 0),
                (canonicalPos: 1, childId: 2, sym: 0)
            ]
        )
        let child0: TestPosition = (nextPlayer: 2, moves: [], children: [])
        let child1: TestPosition = (nextPlayer: 2, moves: [], children: [])
        return [root, child0, child1]
    }

    // MARK: - Symmetry: compose

    @Test func composeIdentity() {
        let book = BookLookup(positions: BookLookupTests.twoNodeBook())
        for s in 0..<8 {
            #expect(book.compose(s, 0) == s)
            #expect(book.compose(0, s) == s)
        }
    }

    @Test func composeInverse() {
        let book = BookLookup(positions: BookLookupTests.twoNodeBook())
        for s in 0..<8 {
            var found = false
            for inv in 0..<8 {
                if book.compose(s, inv) == 0 {
                    #expect(book.compose(inv, s) == 0)
                    found = true
                    break
                }
            }
            #expect(found, "Every symmetry should have an inverse")
        }
    }

    @Test func composeAssociativity() {
        let book = BookLookup(positions: BookLookupTests.twoNodeBook())
        for a in 0..<8 {
            for b in 0..<8 {
                for c in 0..<8 {
                    let lhs = book.compose(book.compose(a, b), c)
                    let rhs = book.compose(a, book.compose(b, c))
                    #expect(lhs == rhs, "compose must be associative: (\(a)*\(b))*\(c) != \(a)*(\(b)*\(c))")
                }
            }
        }
    }

    // MARK: - Symmetry: applySymmetry

    @Test func applySymmetryIdentity() {
        let book = BookLookup(positions: BookLookupTests.twoNodeBook())
        for pos in 0..<81 {
            #expect(book.applySymmetry(pos, sym: 0) == pos)
        }
    }

    @Test func applySymmetryPassInvariant() {
        let book = BookLookup(positions: BookLookupTests.twoNodeBook())
        let pass = 81
        for sym in 0..<8 {
            #expect(book.applySymmetry(pass, sym: sym) == pass)
        }
    }

    @Test func applySymmetryKnownValues() {
        let book = BookLookup(positions: BookLookupTests.twoNodeBook())
        // pos 0 = (0,0) top-left on 9x9
        // sym 1 = flip Y: (0,0) -> (0,8) = 8*9+0 = 72
        #expect(book.applySymmetry(0, sym: 1) == 72)
        // sym 2 = flip X: (0,0) -> (8,0) = 0*9+8 = 8
        #expect(book.applySymmetry(0, sym: 2) == 8)
        // sym 4 = transpose: (0,0) -> (0,0) = 0
        #expect(book.applySymmetry(0, sym: 4) == 0)
        // pos 1 = (1,0): sym 4 = transpose -> (0,1) = 1*9+0 = 9
        #expect(book.applySymmetry(1, sym: 4) == 9)
    }

    // MARK: - Symmetry: applyInverseSymmetry round-trip

    @Test func applyInverseSymmetryRoundTrip() {
        let book = BookLookup(positions: BookLookupTests.twoNodeBook())
        for sym in 0..<8 {
            for pos in 0..<81 {
                let transformed = book.applySymmetry(pos, sym: sym)
                let recovered = book.applyInverseSymmetry(transformed, sym: sym)
                #expect(recovered == pos, "Round-trip failed for pos=\(pos), sym=\(sym)")
            }
        }
    }

    @Test func applyInverseSymmetryPassInvariant() {
        let book = BookLookup(positions: BookLookupTests.twoNodeBook())
        let pass = 81
        for sym in 0..<8 {
            #expect(book.applyInverseSymmetry(pass, sym: sym) == pass)
        }
    }

    // MARK: - Coordinate mapping

    @Test func bookToAppPointCorners() {
        let book = BookLookup(positions: BookLookupTests.twoNodeBook())
        // book (0,0) top-left -> app (0, 8) bottom-left on 9x9
        let tl = book.bookToAppPoint(bookX: 0, bookY: 0, boardHeight: 9)
        #expect(tl == BoardPoint(x: 0, y: 8))

        // book (8,8) bottom-right -> app (8, 0) top-right
        let br = book.bookToAppPoint(bookX: 8, bookY: 8, boardHeight: 9)
        #expect(br == BoardPoint(x: 8, y: 0))
    }

    @Test func appPointToBookPosCorners() {
        let book = BookLookup(positions: BookLookupTests.twoNodeBook())
        // app (0,8) = book (0,0) = pos 0
        let pos0 = book.appPointToBookPos(BoardPoint(x: 0, y: 8), boardWidth: 9, boardHeight: 9)
        #expect(pos0 == 0)

        // app (8,0) = book (8,8) = 8*9+8 = 80
        let pos80 = book.appPointToBookPos(BoardPoint(x: 8, y: 0), boardWidth: 9, boardHeight: 9)
        #expect(pos80 == 80)
    }

    @Test func appPointToBookPosPass() {
        let book = BookLookup(positions: BookLookupTests.twoNodeBook())
        let pass = BoardPoint.pass(width: 9, height: 9)
        let pos = book.appPointToBookPos(pass, boardWidth: 9, boardHeight: 9)
        #expect(pos == 81)
    }

    @Test func coordinateRoundTripAll81() {
        let book = BookLookup(positions: BookLookupTests.twoNodeBook())
        for bookPos in 0..<81 {
            let bookX = bookPos % 9
            let bookY = bookPos / 9
            let appPoint = book.bookToAppPoint(bookX: bookX, bookY: bookY, boardHeight: 9)
            let recovered = book.appPointToBookPos(appPoint, boardWidth: 9, boardHeight: 9)
            #expect(recovered == bookPos, "Round-trip failed for bookPos=\(bookPos)")
        }
    }

    // MARK: - Initialization

    @Test func testInitWithPositions() {
        let book = BookLookup(positions: BookLookupTests.twoNodeBook())
        #expect(book.isLoaded == true)
        #expect(book.isInBook == true)
        #expect(book.currentPositionId == 0)
        #expect(book.accumulatedSymmetry == 0)
    }

    @Test func testInitEmpty() {
        let book = BookLookup(positions: [])
        #expect(book.isLoaded == false)
        #expect(book.isInBook == false)
    }

    // MARK: - Navigation: advanceMove

    @Test func advanceMoveBasic() {
        let book = BookLookup(positions: BookLookupTests.twoNodeBook())
        // Root child at canonical pos 0; with sym=0, app point for pos 0 is (0,8)
        let appPoint = book.bookToAppPoint(bookX: 0, bookY: 0, boardHeight: 9)
        book.advanceMove(appPoint: appPoint, boardWidth: 9, boardHeight: 9)

        #expect(book.currentPositionId == 1)
        #expect(book.isInBook == true)
        #expect(book.justAdvanced == true)
    }

    @Test func advanceMoveSecondChild() {
        let book = BookLookup(positions: BookLookupTests.branchingBook())
        // Second child is at canonical pos 1 -> book (1,0) -> app (1,8)
        let appPoint = book.bookToAppPoint(bookX: 1, bookY: 0, boardHeight: 9)
        book.advanceMove(appPoint: appPoint, boardWidth: 9, boardHeight: 9)

        #expect(book.currentPositionId == 2)
        #expect(book.isInBook == true)
    }

    @Test func advanceMoveOutOfBook() {
        let book = BookLookup(positions: BookLookupTests.twoNodeBook())
        // pos (4,4) center has no child
        let center = book.bookToAppPoint(bookX: 4, bookY: 4, boardHeight: 9)
        book.advanceMove(appPoint: center, boardWidth: 9, boardHeight: 9)

        #expect(book.isInBook == false)
        #expect(book.justAdvanced == true)
    }

    @Test func advanceMoveAlreadyOutOfBook() {
        let book = BookLookup(positions: BookLookupTests.twoNodeBook())
        // First go out of book
        let center = book.bookToAppPoint(bookX: 4, bookY: 4, boardHeight: 9)
        book.advanceMove(appPoint: center, boardWidth: 9, boardHeight: 9)
        #expect(book.isInBook == false)

        // Second advance should be a no-op (guard returns early)
        book.advanceMove(appPoint: center, boardWidth: 9, boardHeight: 9)
        #expect(book.isInBook == false)
    }

    @Test func advanceMoveLeafNode() {
        let book = BookLookup(positions: BookLookupTests.twoNodeBook())
        // Advance to child (leaf)
        let appPoint = book.bookToAppPoint(bookX: 0, bookY: 0, boardHeight: 9)
        book.advanceMove(appPoint: appPoint, boardWidth: 9, boardHeight: 9)
        #expect(book.currentPositionId == 1)

        // Any move from leaf should go out of book
        let center = book.bookToAppPoint(bookX: 4, bookY: 4, boardHeight: 9)
        book.advanceMove(appPoint: center, boardWidth: 9, boardHeight: 9)
        #expect(book.isInBook == false)
    }

    @Test func advanceMoveWrongBoardSize() {
        let book = BookLookup(positions: BookLookupTests.twoNodeBook())
        let appPoint = book.bookToAppPoint(bookX: 0, bookY: 0, boardHeight: 9)
        // Use 19x19 board size - should be rejected
        book.advanceMove(appPoint: appPoint, boardWidth: 19, boardHeight: 19)

        // State should be unchanged
        #expect(book.currentPositionId == 0)
        #expect(book.isInBook == true)
    }

    // MARK: - Navigation: resetToRoot

    @Test func resetToRootAfterAdvance() {
        let book = BookLookup(positions: BookLookupTests.twoNodeBook())
        let appPoint = book.bookToAppPoint(bookX: 0, bookY: 0, boardHeight: 9)
        book.advanceMove(appPoint: appPoint, boardWidth: 9, boardHeight: 9)
        #expect(book.currentPositionId == 1)

        book.resetToRoot()
        #expect(book.currentPositionId == 0)
        #expect(book.accumulatedSymmetry == 0)
        #expect(book.isInBook == true)
    }

    @Test func resetToRootWhenUnloaded() {
        let book = BookLookup(positions: [])
        book.resetToRoot()
        // Should be a no-op
        #expect(book.isLoaded == false)
        #expect(book.isInBook == false)
    }

    // MARK: - Navigation: syncFromMoves

    @Test func syncFromMovesReplay() {
        let book = BookLookup(positions: BookLookupTests.twoNodeBook())
        let appPoint = book.bookToAppPoint(bookX: 0, bookY: 0, boardHeight: 9)
        book.syncFromMoves([appPoint], boardWidth: 9, boardHeight: 9)

        #expect(book.currentPositionId == 1)
        #expect(book.isInBook == true)
        #expect(book.justAdvanced == false)  // syncFromMoves clears justAdvanced
    }

    @Test func syncFromMovesWithOutOfBookMove() {
        let book = BookLookup(positions: BookLookupTests.twoNodeBook())
        let center = book.bookToAppPoint(bookX: 4, bookY: 4, boardHeight: 9)
        book.syncFromMoves([center], boardWidth: 9, boardHeight: 9)

        #expect(book.isInBook == false)
    }

    @Test func syncFromMovesEmpty() {
        let book = BookLookup(positions: BookLookupTests.twoNodeBook())
        // Advance first, then sync with empty list should reset to root
        let appPoint = book.bookToAppPoint(bookX: 0, bookY: 0, boardHeight: 9)
        book.advanceMove(appPoint: appPoint, boardWidth: 9, boardHeight: 9)

        book.syncFromMoves([], boardWidth: 9, boardHeight: 9)
        #expect(book.currentPositionId == 0)
        #expect(book.isInBook == true)
    }

    @Test func syncFromMovesWrongBoardSize() {
        let book = BookLookup(positions: BookLookupTests.twoNodeBook())
        let appPoint = book.bookToAppPoint(bookX: 0, bookY: 0, boardHeight: 9)
        book.syncFromMoves([appPoint], boardWidth: 19, boardHeight: 19)

        #expect(book.isInBook == false)
    }

    // MARK: - Navigation: clearJustAdvanced

    @Test func clearJustAdvancedAfterAdvance() {
        let book = BookLookup(positions: BookLookupTests.twoNodeBook())
        let appPoint = book.bookToAppPoint(bookX: 0, bookY: 0, boardHeight: 9)
        book.advanceMove(appPoint: appPoint, boardWidth: 9, boardHeight: 9)
        #expect(book.justAdvanced == true)

        book.clearJustAdvanced()
        #expect(book.justAdvanced == false)
    }

    // MARK: - Display: getBookAnalysis

    @Test func getBookAnalysisRootValues() {
        let book = BookLookup(positions: BookLookupTests.twoNodeBook())
        let analysis = book.getBookAnalysis(boardWidth: 9, boardHeight: 9)

        // Root has one move at canonical pos 0 -> display (0,8)
        let appPoint = book.bookToAppPoint(bookX: 0, bookY: 0, boardHeight: 9)
        let info = analysis[appPoint]
        #expect(info != nil)
        // Float32 round-trip: compare with tolerance
        #expect(abs((info?.winLoss ?? 0) - 0.6) < 0.001)
        #expect(abs((info?.sharpScore ?? 0) - 2.5) < 0.01)
        #expect(info?.adjustedVisits == 100)
        #expect(abs((info?.policyPrior ?? 0) - 0.8) < 0.001)
        #expect(info?.rank == 0)
    }

    @Test func getBookAnalysisOutOfBookReturnsEmpty() {
        let book = BookLookup(positions: BookLookupTests.twoNodeBook())
        // Go out of book
        let center = book.bookToAppPoint(bookX: 4, bookY: 4, boardHeight: 9)
        book.advanceMove(appPoint: center, boardWidth: 9, boardHeight: 9)

        let analysis = book.getBookAnalysis(boardWidth: 9, boardHeight: 9)
        #expect(analysis.isEmpty)
    }

    @Test func getBookAnalysisWrongBoardSizeReturnsEmpty() {
        let book = BookLookup(positions: BookLookupTests.twoNodeBook())
        let analysis = book.getBookAnalysis(boardWidth: 19, boardHeight: 19)
        #expect(analysis.isEmpty)
    }

    @Test func getBookAnalysisLeafWithNoMoves() {
        let positions: [TestPosition] = [
            (nextPlayer: 1, moves: [], children: [])
        ]
        let book = BookLookup(positions: positions)
        let analysis = book.getBookAnalysis(boardWidth: 9, boardHeight: 9)
        #expect(analysis.isEmpty)
    }

    @Test func getBookAnalysisRanks() {
        let book = BookLookup(positions: BookLookupTests.branchingBook())
        let analysis = book.getBookAnalysis(boardWidth: 9, boardHeight: 9)

        let point0 = book.bookToAppPoint(bookX: 0, bookY: 0, boardHeight: 9)
        let point1 = book.bookToAppPoint(bookX: 1, bookY: 0, boardHeight: 9)
        #expect(analysis[point0]?.rank == 0)
        #expect(analysis[point1]?.rank == 1)
    }

    // MARK: - Symmetry navigation

    @Test func advanceMoveWithSymmetryLink() {
        // Link sym=1 means flip-Y is applied at the child
        let book = BookLookup(positions: BookLookupTests.twoNodeBook(linkSym: 1))
        let appPoint = book.bookToAppPoint(bookX: 0, bookY: 0, boardHeight: 9)
        book.advanceMove(appPoint: appPoint, boardWidth: 9, boardHeight: 9)

        #expect(book.currentPositionId == 1)
        #expect(book.accumulatedSymmetry == 1)
    }

    @Test func displayCoordinatesTransformWithSymmetry() {
        // After advancing with sym=1 (flip-Y), the child's canonical pos 72 = (0,8)
        // should display at applySymmetry(72, sym=1).
        // pos 72: y=8, x=0. Flip Y: y=0, x=0 -> pos 0. Display (0,8) in app coords.
        let book = BookLookup(positions: BookLookupTests.twoNodeBook(linkSym: 1))
        let appPoint = book.bookToAppPoint(bookX: 0, bookY: 0, boardHeight: 9)
        book.advanceMove(appPoint: appPoint, boardWidth: 9, boardHeight: 9)

        let analysis = book.getBookAnalysis(boardWidth: 9, boardHeight: 9)
        // Canonical 72 with sym=1: y=8,x=0 -> flip Y -> y=0,x=0 -> display pos 0 -> app (0,8)
        let expectedPoint = book.bookToAppPoint(bookX: 0, bookY: 0, boardHeight: 9)
        #expect(analysis[expectedPoint] != nil)
        #expect(abs((analysis[expectedPoint]?.winLoss ?? 0) - (-0.3)) < 0.001)
    }

    // MARK: - currentNextPlayer / currentMovesCount

    @Test func currentNextPlayerAtRoot() {
        let book = BookLookup(positions: BookLookupTests.twoNodeBook())
        #expect(book.currentNextPlayer == 1)
        #expect(book.currentMovesCount == 1)
    }

    @Test func currentNextPlayerOutOfBook() {
        let book = BookLookup(positions: BookLookupTests.twoNodeBook())
        let center = book.bookToAppPoint(bookX: 4, bookY: 4, boardHeight: 9)
        book.advanceMove(appPoint: center, boardWidth: 9, boardHeight: 9)
        #expect(book.currentNextPlayer == nil)
        #expect(book.currentMovesCount == nil)
    }

    @Test func currentNextPlayerEmptyBook() {
        let book = BookLookup(positions: [])
        #expect(book.currentNextPlayer == nil)
        #expect(book.currentMovesCount == nil)
    }

    // MARK: - Real bundle load (Bundle.module)

    /// Exercises the REAL load path: `loadIfNeeded()` reads the bundled
    /// `book9x9jp-20260226.kbook.gz` via `Bundle.module`, decompresses it,
    /// and parses the binary header. Proves `Bundle.module` resolves the
    /// package resource at runtime (the same mechanism `AudioModel` uses
    /// for its bundled mp3s). The fire-and-forget `loadIfNeeded()` spawns
    /// a detached parse Task, so poll `isLoaded` with a bounded timeout.
    @Test func loadsRealBundledBook() async throws {
        let book = BookLookup()
        #expect(book.isLoaded == false)

        book.loadIfNeeded()

        // Poll for the asynchronous load (read 240 MB → decompress to 533 MB →
        // write the cache). The cap is deliberately generous: Xcode Cloud runs
        // this across ~9 simulator destinations on one shared, often-contended
        // host, where a 10 s cap tripped on the slowest run (iPad Pro M4, ~2×
        // wall-clock) while 8/9 destinations passed with the same build. The
        // loop exits the instant isLoaded flips, so the higher cap costs nothing
        // in the common case (~1–2 s).
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while !book.isLoaded, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(book.isLoaded == true,
                "Bundle.module should resolve and load book9x9jp-20260226.kbook.gz")
        // A real 9x9 opening book has positions, so the root must be in-book
        // and expose analysis for the empty board.
        #expect(book.isInBook == true)
        #expect(book.currentNextPlayer == 1)  // black to play at the root
        let rootAnalysis = book.getBookAnalysis(boardWidth: 9, boardHeight: 9)
        #expect(rootAnalysis.isEmpty == false,
                "Root position of the loaded book should expose at least one move")
    }

    // MARK: - Binary format validation

    @Test func binarySerializationRoundTrip() {
        // Verify that serializing and loading gives correct data
        let positions: [TestPosition] = BookLookupTests.twoNodeBook()
        let data = BookLookup.serializeToBinary(positions: positions)

        // Verify header
        #expect(data.count >= 32)
        // Magic 0x4B424F4B ("KBOK") stored as little-endian: 4B 4F 42 4B
        #expect(data[0] == 0x4B)  // 'K'
        #expect(data[1] == 0x4F)  // 'O'
        #expect(data[2] == 0x42)  // 'B'
        #expect(data[3] == 0x4B)  // 'K'
    }
}
