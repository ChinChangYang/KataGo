//
//  KataGoModelTests.swift
//  KataGo iOSTests
//
//  Created by Chin-Chang Yang on 2024/8/17.
//

import Testing
import CoreGraphics
@testable import KataGo_iOS

struct KataGoModelTests {

    @Test func compareBoardPoints() async throws {
        let smallBoardPoint = BoardPoint(x: 5, y: 5)
        let bigBoardPoint = BoardPoint(x: 6, y: 5)
        let anotherBigBoardPoint = BoardPoint(x: 0, y: 6)
        #expect(smallBoardPoint < bigBoardPoint)
        #expect(smallBoardPoint < anotherBigBoardPoint)
    }

    @Test func toggleNextPlayerColor() async throws {
        let turn = Turn()
        #expect(turn.nextColorForPlayCommand == .black)
        #expect(turn.nextColorSymbolForPlayCommand == "b")

        turn.toggleNextColorForPlayCommand()
        #expect(turn.nextColorForPlayCommand == .white)
        #expect(turn.nextColorSymbolForPlayCommand == "w")

        turn.toggleNextColorForPlayCommand()
        #expect(turn.nextColorForPlayCommand == .black)
        #expect(turn.nextColorSymbolForPlayCommand == "b")
    }

    @Test func initializeOwnership() async throws {
        let ownership = Ownership(mean: 0, stdev: 0)
        #expect(ownership.mean == 0)
        #expect(ownership.stdev == 0)
    }

    @Test func clearAnalysis() async throws {
        let analysis = Analysis()
        #expect(analysis.info.isEmpty)
        #expect(analysis.ownership.isEmpty)

        let boardPoint = BoardPoint(x: 0, y: 0)

        analysis.info[boardPoint] = AnalysisInfo(visits: 0, winrate: 0, scoreLead: 0, utilityLcb: 0)
        analysis.ownership[boardPoint] = Ownership(mean: 0, stdev: 0)
        #expect(analysis.info[boardPoint] != nil)
        #expect(analysis.ownership[boardPoint] != nil)

        analysis.clear()
        #expect(analysis.info.isEmpty)
        #expect(analysis.ownership.isEmpty)
    }

    @Test func initializeDimensions() async throws {
        let size = CGSize(width: 0, height: 0)
        let dimensions = Dimensions(size: size, width: 1, height: 1)
        #expect(dimensions.squareLength == 0)
        #expect(dimensions.squareLengthDiv2 == 0)
        #expect(dimensions.squareLengthDiv4 == 0)
        #expect(dimensions.squareLengthDiv8 == 0)
        #expect(dimensions.squareLengthDiv16 == 0)
        #expect(dimensions.boardLineStartX == 0)
        #expect(dimensions.boardLineStartY == 0)
        #expect(dimensions.stoneLength == 0)
        #expect(dimensions.width == 1)
        #expect(dimensions.height == 1)
        #expect(dimensions.gobanWidth == 0)
        #expect(dimensions.gobanHeight == 0)
        #expect(dimensions.boardLineBoundWidth == 0)
        #expect(dimensions.boardLineBoundHeight == 0)
        #expect(dimensions.gobanStartX == 0)
        #expect(dimensions.gobanStartY == 0)
        #expect(dimensions.coordinate == false)
    }
}
