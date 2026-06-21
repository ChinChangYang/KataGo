//
//  GobanStateOwnershipPersistenceTests.swift
//  KataGo iOSTests
//
//  Integration coverage for the write-time ownership cap. Where
//  OwnershipBudgetTests pins the pure eviction math, this drives the REAL
//  GobanState.maybeUpdateAnalysisData against a REAL SwiftData-persisted
//  GameRecord through enough analyzed moves to trigger eviction, then saves and
//  re-fetches from a fresh context — proving the cap keeps a persisted record
//  bounded end-to-end (the wiring + SwiftData round-trip a unit test can't reach).
//

import Testing
import SwiftData
@testable import KataGoUICore

@MainActor
@Suite("GobanState ownership persistence cap")
struct GobanStateOwnershipPersistenceTests {

    private static func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([GameRecord.self, Config.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// One `OwnershipUnit` per board point — a full 19×19 ownership grid, exactly
    /// what a real `kata-analyze` response produces for a 19×19 position.
    private func fullBoardUnits(width: Int, height: Int) -> [OwnershipUnit] {
        var units: [OwnershipUnit] = []
        for y in 0..<height {
            for x in 0..<width {
                units.append(OwnershipUnit(point: BoardPoint(x: x, y: y),
                                           whiteness: 0.5, scale: 0.8, opacity: 1.0))
            }
        }
        return units
    }

    @Test("A long analyzed game persists bounded ownership (eviction + SwiftData round-trip)")
    func longGameStaysBounded() throws {
        let container = try Self.makeInMemoryContainer()
        let context = ModelContext(container)

        let gameRecord = GameRecord.createGameRecord(sgf: "(;FF[4]GM[1]SZ[19])")
        context.insert(gameRecord)

        let gobanState = GobanState()
        gobanState.isEditing = true
        gobanState.analysisStatus = .run            // not .clear → the persist gate is open

        let board = BoardSize()                     // defaults to 19×19
        let stones = Stones()
        let analysis = Analysis()
        analysis.ownershipUnits = fullBoardUnits(width: 19, height: 19)
        // `info` left empty on purpose: the scalar paths (scoreLeads/bestMoves/
        // winRates, incl. withAnimation) short-circuit, isolating the ownership
        // write + cap under test.

        let moveCount = 200
        for index in 0..<moveCount {
            gameRecord.currentIndex = index
            gobanState.maybeUpdateAnalysisData(
                gameRecord: gameRecord, analysis: analysis, board: board, stones: stones)
        }

        try context.save()

        let limit = OwnershipBudget.maxRetainedIndices(pointsPerMove: 19 * 19)
        #expect(limit < moveCount)                  // the run actually crossed the cap

        // Live @Model object reflects the cap.
        let whiteness = try #require(gameRecord.ownershipWhiteness)
        let scales = try #require(gameRecord.ownershipScales)
        #expect(whiteness.count == limit)
        #expect(scales.count == limit)
        #expect(whiteness[moveCount - 1] != nil)    // most-recent move retained
        #expect(whiteness[0] == nil)                // oldest move evicted
        #expect(Set(whiteness.keys) == Set(scales.keys))
        #expect(whiteness[moveCount - 1]?.count == 19 * 19)   // values stay full boards

        // SwiftData round-trip: a fresh context reads back the same bounded state.
        let refetched = try #require(
            ModelContext(container).fetch(FetchDescriptor<GameRecord>()).first)
        let rWhiteness = try #require(refetched.ownershipWhiteness)
        let rScales = try #require(refetched.ownershipScales)
        #expect(rWhiteness.count == limit)
        #expect(rScales.count == limit)
        #expect(rWhiteness[0] == nil)
        #expect(rWhiteness[moveCount - 1] != nil)

        // The persisted ownership stays within the CloudKit-safe budget.
        let retainedFloats = (rWhiteness.count + rScales.count) * 19 * 19
        #expect(retainedFloats * OwnershipBudget.estimatedBytesPerFloat
                <= OwnershipBudget.combinedByteBudget)
    }
}
