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
        #expect(dimensions.boardLineStartY == dimensions.capturedStonesHeight)
        #expect(dimensions.stoneLength == 0)
        #expect(dimensions.width == 1)
        #expect(dimensions.height == 1)
        #expect(dimensions.gobanWidth == 0)
        #expect(dimensions.gobanHeight == 0)
        #expect(dimensions.boardLineBoundWidth == 0)
        #expect(dimensions.boardLineBoundHeight == 0)
        #expect(dimensions.gobanStartX == 0)
        #expect(dimensions.gobanStartY == dimensions.capturedStonesHeight)
        #expect(dimensions.coordinate == false)
    }

    @Test func initializeDimensionsWithCoordinate() async throws {
        let size = CGSize(width: 0, height: 0)
        let dimensions = Dimensions(size: size, width: 1, height: 1, showCoordinate: true)
        #expect(dimensions.squareLength == 0)
        #expect(dimensions.squareLengthDiv2 == 0)
        #expect(dimensions.squareLengthDiv4 == 0)
        #expect(dimensions.squareLengthDiv8 == 0)
        #expect(dimensions.squareLengthDiv16 == 0)
        #expect(dimensions.boardLineStartX == 0)
        #expect(dimensions.boardLineStartY == dimensions.capturedStonesHeight)
        #expect(dimensions.stoneLength == 0)
        #expect(dimensions.width == 1)
        #expect(dimensions.height == 1)
        #expect(dimensions.gobanWidth == 0)
        #expect(dimensions.gobanHeight == 0)
        #expect(dimensions.boardLineBoundWidth == 0)
        #expect(dimensions.boardLineBoundHeight == 0)
        #expect(dimensions.gobanStartX == 0)
        #expect(dimensions.gobanStartY == dimensions.capturedStonesHeight)
        #expect(dimensions.coordinate == true)
    }

    @Test func shrinkMessageList() async throws {
        let messageList = MessageList()
        messageList.shrink()
        #expect(messageList.messages.isEmpty)
        for _ in 1...MessageList.defaultMaxMessageLines {
            messageList.messages.append(Message(text: ""))
        }

        messageList.shrink()
        #expect(messageList.messages.count == MessageList.defaultMaxMessageLines)

        messageList.messages.append(Message(text: ""))
        messageList.shrink()
        #expect(messageList.messages.count == MessageList.defaultMaxMessageLines)
    }

    @Test func shouldRequestAnalysisForPlayer() async throws {
        let gobanState = GobanState()
        gobanState.analysisStatus = .run

        #expect(gobanState.shouldRequestAnalysis(config: Config(), nextColorForPlayCommand: .black))
    }

    @Test func requestClearAnalysisData() async throws {
        let gobanState = GobanState()
        gobanState.analysisStatus = .clear
        #expect(!gobanState.requestingClearAnalysis)
        gobanState.maybeRequestClearAnalysisData(config: Config())
        #expect(gobanState.requestingClearAnalysis)
    }

    @Test func getWhiteWinrate() async throws {
        let winrate = Winrate()
        winrate.black = 1/4
        #expect(winrate.white == 3.0/4.0)
    }

    @Test func initializeCoordinate() async throws {
        let invalidXLabel = Coordinate(xLabel: "I", yLabel: "1")
        #expect(invalidXLabel == nil)
        let invalidYLabel = Coordinate(xLabel: "A", yLabel: "A")
        #expect(invalidYLabel == nil)
        let validLabels = Coordinate(xLabel: "AD", yLabel: "28", width: 29, height: 29)
        #expect(validLabels?.x == 28)
        #expect(validLabels?.y == 28)
        #expect(validLabels?.xLabel == "AD")
        #expect(validLabels?.yLabel == "28")
    }
}
