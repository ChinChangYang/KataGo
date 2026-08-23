//
//  KataGoModelTests.swift
//  KataGo iOSTests
//
//  Created by Chin-Chang Yang on 2024/8/17.
//

import Testing
import CoreGraphics
import Foundation
import KataGoGameStore
@testable import KataGo_Anytime
@testable import KataGoUICore

struct KataGoModelTests {

    // MARK: - BoardSize Tests

    @Test func testBoardSizeDefaultInitialization() async throws {
        let boardSize = BoardSize()
        #expect(boardSize.width == 19)
        #expect(boardSize.height == 19)
    }

    @Test func testBoardSizeCustomInitialization() async throws {
        let boardSize = BoardSize()
        boardSize.width = 13
        boardSize.height = 13
        #expect(boardSize.width == 13)
        #expect(boardSize.height == 13)
    }

    // MARK: - BoardPoint Tests

    @Test func testBoardPointInitialization() async throws {
        let point = BoardPoint(x: 5, y: 5)
        #expect(point.x == 5)
        #expect(point.y == 5)
    }

    @Test func testBoardPointIsPass() async throws {
        let width = 19
        let height = 19
        let passPoint = BoardPoint.pass(width: width, height: height)
        #expect(passPoint.x == width - 1)
        #expect(passPoint.y == height + 1)
        #expect(passPoint.isPass(width: width, height: height) == true)

        let nonPassPoint = BoardPoint(x: 10, y: 10)
        #expect(nonPassPoint.isPass(width: width, height: height) == false)
    }

    @Test func testBoardPointComparable() async throws {
        let pointA = BoardPoint(x: 5, y: 5)
        let pointB = BoardPoint(x: 6, y: 5)
        let pointC = BoardPoint(x: 0, y: 6)
        let pointD = BoardPoint(x: 5, y: 5)

        #expect(pointA < pointB)
        #expect(pointA < pointC)
        #expect(!(pointB < pointA))
        #expect(!(pointA < pointD))
    }

    @Test func testBoardPointHashable() async throws {
        let pointA = BoardPoint(x: 5, y: 5)
        let pointB = BoardPoint(x: 5, y: 5)
        let pointSet: Set<BoardPoint> = [pointA, pointB]
        #expect(pointSet.count == 1)
    }

    // MARK: - Stones Tests

    @Test func testStonesDefaultInitialization() async throws {
        let stones = Stones()
        #expect(stones.blackPoints.isEmpty)
        #expect(stones.whitePoints.isEmpty)
        #expect(stones.moveOrder.isEmpty)
        #expect(stones.blackStonesCaptured == 0)
        #expect(stones.whiteStonesCaptured == 0)
    }

    @Test func testStonesCustomInitialization() async throws {
        let stones = Stones()
        let point = BoardPoint(x: 3, y: 3)
        stones.blackPoints.append(point)
        stones.whitePoints.append(point)
        stones.moveOrder[point] = "b"
        stones.blackStonesCaptured = 2
        stones.whiteStonesCaptured = 3

        #expect(stones.blackPoints.contains(point))
        #expect(stones.whitePoints.contains(point))
        #expect(stones.moveOrder[point] == "b")
        #expect(stones.blackStonesCaptured == 2)
        #expect(stones.whiteStonesCaptured == 3)
    }

    // MARK: - PlayerColor Tests

    @Test func testPlayerColorSymbol() async throws {
        #expect(PlayerColor.black.symbol == "b")
        #expect(PlayerColor.white.symbol == "w")
        #expect(PlayerColor.unknown.symbol == nil)
    }

    // MARK: - Turn Tests

    @Test func testTurnDefaultInitialization() async throws {
        let turn = Turn()
        #expect(turn.nextColorForPlayCommand == .black)
        #expect(turn.nextColorFromShowBoard == .black)
        #expect(turn.nextColorSymbolForPlayCommand == "b")
    }

    @Test func testTurnToggleNextColorForPlayCommand() async throws {
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

    @Test func testTurnNextColorSymbolForPlayCommand() async throws {
        let turn = Turn()
        #expect(turn.nextColorSymbolForPlayCommand == "b")

        turn.nextColorForPlayCommand = .white
        #expect(turn.nextColorSymbolForPlayCommand == "w")

        turn.nextColorForPlayCommand = .unknown
        #expect(turn.nextColorSymbolForPlayCommand == nil)
    }

    // MARK: - AnalysisInfo Tests

    @Test func testAnalysisInfoInitialization() async throws {
        let analysisInfo = AnalysisInfo(visits: 100, winrate: 0.55, scoreLead: 10.0, utilityLcb: 0.3)
        #expect(analysisInfo.visits == 100)
        #expect(analysisInfo.winrate == 0.55)
        #expect(analysisInfo.scoreLead == 10.0)
        #expect(analysisInfo.utilityLcb == 0.3)
    }

    // MARK: - OwnershipUnit Tests

    @Test func testOwnershipUnitInitialization() async throws {
        let point = BoardPoint(x: 0, y: 0)
        let ownershipUnit = OwnershipUnit(point: point, whiteness: 0.6, scale: 0.5, opacity: 0.4)
        #expect(ownershipUnit.point == point)
        #expect(ownershipUnit.whiteness == 0.6)
        #expect(ownershipUnit.scale == 0.5)
        #expect(ownershipUnit.opacity == 0.4)
    }

    // MARK: - Analysis Tests

    @Test func testAnalysisDefaultInitialization() async throws {
        let analysis = Analysis()
        #expect(analysis.nextColorForAnalysis == .white)
        #expect(analysis.info.isEmpty)
        #expect(analysis.ownershipUnits.isEmpty)
        #expect(analysis.maxWinrate == nil)
    }

    @Test func testAnalysisCustomInitialization() async throws {
        let analysis = Analysis()
        let point = BoardPoint(x: 4, y: 4)
        let info = AnalysisInfo(visits: 200, winrate: 0.65, scoreLead: 15.0, utilityLcb: 0.4)
        let ownershipUnit = OwnershipUnit(point: point, whiteness: 0.7, scale: 0.02, opacity: 0.5)

        analysis.nextColorForAnalysis = .black
        analysis.info[point] = info
        analysis.ownershipUnits.append(ownershipUnit)

        #expect(analysis.nextColorForAnalysis == .black)
        #expect(analysis.info[point]?.visits == 200)
        #expect(analysis.ownershipUnits.first?.whiteness == 0.7)
        #expect(analysis.maxWinrate == 0.65)
    }

    @Test func testAnalysisClear() async throws {
        let analysis = Analysis()
        let point = BoardPoint(x: 4, y: 4)
        let info = AnalysisInfo(visits: 200, winrate: 0.65, scoreLead: 15.0, utilityLcb: 0.4)
        let ownershipUnit = OwnershipUnit(point: point, whiteness: 0.7, scale: 0.02, opacity: 0.5)

        analysis.info[point] = info
        analysis.ownershipUnits.append(ownershipUnit)

        #expect(!analysis.info.isEmpty)
        #expect(!analysis.ownershipUnits.isEmpty)
        #expect(analysis.maxWinrate != nil)

        analysis.clear()

        #expect(analysis.info.isEmpty)
        #expect(analysis.ownershipUnits.isEmpty)
        #expect(analysis.maxWinrate == nil)
    }

    // MARK: - Analysis visits/s Tests

    @Test func testVisitsPerSecondDefaultsToZero() async throws {
        let analysis = Analysis()
        #expect(analysis.visitsPerSecond == 0)
    }

    @Test func testVisitsPerSecondFirstSampleEstablishesBaseline() async throws {
        let analysis = Analysis()
        analysis.updateVisitsPerSecond(rootVisits: 100, at: 10.0)
        #expect(analysis.visitsPerSecond == 0)
    }

    @Test func testVisitsPerSecondTwoSampleRate() async throws {
        let analysis = Analysis()
        analysis.updateVisitsPerSecond(rootVisits: 100, at: 10.0) // session start
        analysis.updateVisitsPerSecond(rootVisits: 300, at: 12.0)
        // (300 - 100) / (12 - 10) = 100
        #expect(analysis.visitsPerSecond == 100)
    }

    @Test func testVisitsPerSecondAveragesOverSession() async throws {
        let analysis = Analysis()
        analysis.updateVisitsPerSecond(rootVisits: 100, at: 10.0) // session start
        analysis.updateVisitsPerSecond(rootVisits: 300, at: 12.0)
        #expect(analysis.visitsPerSecond == 100)
        // Averaged from the session start, not the last delta:
        // (900 - 100) / (14 - 10) = 200  (an instantaneous rate would be 300).
        analysis.updateVisitsPerSecond(rootVisits: 900, at: 14.0)
        #expect(analysis.visitsPerSecond == 200)
    }

    @Test func testVisitsPerSecondIsStableAgainstSingleSampleSwings() async throws {
        let analysis = Analysis()
        analysis.updateVisitsPerSecond(rootVisits: 0, at: 0.0)     // session start
        analysis.updateVisitsPerSecond(rootVisits: 1000, at: 10.0) // 1000 / 10 = 100
        #expect(analysis.visitsPerSecond == 100)
        // A near-stall report would swing an instantaneous rate to ~1/s, but the
        // session average barely moves: 1001 / 11 = 91.
        analysis.updateVisitsPerSecond(rootVisits: 1001, at: 11.0)
        #expect(analysis.visitsPerSecond == 91)
    }

    @Test func testVisitsPerSecondResetsOnNewSession() async throws {
        let analysis = Analysis()
        analysis.updateVisitsPerSecond(rootVisits: 500, at: 10.0)
        analysis.updateVisitsPerSecond(rootVisits: 700, at: 11.0)
        #expect(analysis.visitsPerSecond == 200)
        // A new search drops the cumulative count -> rate clears, session rebaselines.
        analysis.updateVisitsPerSecond(rootVisits: 50, at: 12.0)
        #expect(analysis.visitsPerSecond == 0)
        // Subsequent samples average over the NEW session: (150 - 50) / (13 - 12) = 100.
        analysis.updateVisitsPerSecond(rootVisits: 150, at: 13.0)
        #expect(analysis.visitsPerSecond == 100)
    }

    @Test func testVisitsPerSecondZeroWhenNoTimeElapsedSinceSessionStart() async throws {
        let analysis = Analysis()
        analysis.updateVisitsPerSecond(rootVisits: 100, at: 10.0) // session start
        analysis.updateVisitsPerSecond(rootVisits: 300, at: 10.0) // same instant -> no elapsed time
        #expect(analysis.visitsPerSecond == 0)
    }

    @Test func testVisitsPerSecondClearResets() async throws {
        let analysis = Analysis()
        analysis.updateVisitsPerSecond(rootVisits: 100, at: 10.0)
        analysis.updateVisitsPerSecond(rootVisits: 300, at: 12.0)
        #expect(analysis.visitsPerSecond == 100)
        analysis.clear()
        #expect(analysis.visitsPerSecond == 0)
        // After clear, the next sample is a fresh baseline (no rate yet).
        analysis.updateVisitsPerSecond(rootVisits: 1000, at: 20.0)
        #expect(analysis.visitsPerSecond == 0)
    }

    @Test func testVisitsPerSecondResetSessionReanchorsAfterPause() async throws {
        let analysis = Analysis()
        // Active session: rate settles at 700 / 10 = 70.
        analysis.updateVisitsPerSecond(rootVisits: 0, at: 0.0)
        analysis.updateVisitsPerSecond(rootVisits: 700, at: 10.0)
        #expect(analysis.visitsPerSecond == 70)
        // User pauses, then re-enables 60s later. KataGo kept its tree, so the next
        // sample's cumulative visits are unchanged (700) but the clock has advanced.
        analysis.resetVisitsPerSecondSession()
        #expect(analysis.visitsPerSecond == 0)
        // First sample after enable is a fresh baseline at the resume point.
        analysis.updateVisitsPerSecond(rootVisits: 700, at: 70.0)
        #expect(analysis.visitsPerSecond == 0)
        // Rate is measured from the resume point: (840 - 700) / (72 - 70) = 70 — the
        // 60s idle pause does NOT drag it down (without the reset it would be
        // (840 - 0) / (72 - 0) ≈ 11.7).
        analysis.updateVisitsPerSecond(rootVisits: 840, at: 72.0)
        #expect(analysis.visitsPerSecond == 70)
    }

    @Test func testVisitsPerSecondText() async throws {
        let analysis = Analysis()
        #expect(analysis.visitsPerSecondText == "0 visits/s")
        analysis.updateVisitsPerSecond(rootVisits: 0, at: 0.0)
        analysis.updateVisitsPerSecond(rootVisits: 1500, at: 1.0)
        #expect(analysis.visitsPerSecondText == "1.5k visits/s")
    }

    @Test func testParseRootVisits() async throws {
        let message = "info move A1 visits 10 winrate 0.5 rootInfo visits 12345 utility 0.1 winrate 0.5"
        #expect(Analysis.parseRootVisits(from: message) == 12345)
    }

    @Test func testParseRootVisitsReturnsNilWhenAbsent() async throws {
        let message = "info move A1 visits 10 winrate 0.5 scoreLead 1.0"
        #expect(Analysis.parseRootVisits(from: message) == nil)
    }

    // MARK: - Dimensions Tests

    @Test func testDimensionsDefaultInitialization() async throws {
        let size = CGSize(width: 380, height: 380)
        let dimensions = Dimensions(size: size, width: 19, height: 19)

        // Calculate expected values based on the initializer logic
        let coordinateEntity: CGFloat = 0
        let gobanWidthEntity = CGFloat(19) + coordinateEntity
        let gobanHeightEntity = CGFloat(19) + coordinateEntity
        let passHeightEntity: CGFloat = 1.5
        let squareWidth = size.width / (gobanWidthEntity + 1)
        let squareHeight = max(0, size.height - 20) / (gobanHeightEntity + passHeightEntity + 1)
        let squareLength = min(squareWidth, squareHeight)
        let squareLengthDiv2 = squareLength / 2
        let squareLengthDiv4 = squareLength / 4
        let squareLengthDiv8 = squareLength / 8
        let squareLengthDiv16 = squareLength / 16
        let gobanPadding = squareLength / 2
        let stoneLength = squareLength * 0.95
        let gobanWidthCalculated = (gobanWidthEntity * squareLength) + gobanPadding
        let gobanHeightCalculated = (gobanHeightEntity * squareLength) + gobanPadding
        let gobanStartX = (size.width - gobanWidthCalculated) / 2
        let passHeight = passHeightEntity * squareLength
        let gobanStartY = max(20, (size.height - passHeight - gobanHeightCalculated) / 2)
        let boardLineBoundWidth = (19 - 1) * squareLength
        let boardLineBoundHeight = (19 - 1) * squareLength
        let coordinateLength = coordinateEntity * squareLength
        let boardLineStartX = (size.width - boardLineBoundWidth + coordinateLength) / 2
        let boardLineStartY = 20 + coordinateLength + (squareLength + gobanPadding) / 2
        let capturedStonesStartY = gobanStartY - 20

        #expect(dimensions.squareLength == squareLength)
        #expect(dimensions.squareLengthDiv2 == squareLengthDiv2)
        #expect(dimensions.squareLengthDiv4 == squareLengthDiv4)
        #expect(dimensions.squareLengthDiv8 == squareLengthDiv8)
        #expect(dimensions.squareLengthDiv16 == squareLengthDiv16)
        #expect(dimensions.boardLineStartX == boardLineStartX)
        #expect(dimensions.boardLineStartY == boardLineStartY)
        #expect(dimensions.stoneLength == stoneLength)
        #expect(dimensions.width == 19)
        #expect(dimensions.height == 19)
        #expect(dimensions.gobanWidth == gobanWidthCalculated)
        #expect(dimensions.gobanHeight == gobanHeightCalculated)
        #expect(dimensions.boardLineBoundWidth == boardLineBoundWidth)
        #expect(dimensions.boardLineBoundHeight == boardLineBoundHeight)
        #expect(dimensions.gobanStartX == gobanStartX)
        #expect(dimensions.gobanStartY == gobanStartY)
        #expect(dimensions.coordinate == false)
        #expect(dimensions.capturedStonesStartY == capturedStonesStartY)
    }

    @Test func testDimensionsWithCoordinateInitialization() async throws {
        let size = CGSize(width: 380, height: 380)
        let dimensions = Dimensions(size: size, width: 19, height: 19, showCoordinate: true)

        // Calculate expected values based on the initializer logic
        let coordinateEntity: CGFloat = 1
        let gobanWidthEntity = CGFloat(19) + coordinateEntity
        let gobanHeightEntity = CGFloat(19) + coordinateEntity
        let passHeightEntity: CGFloat = 1.5
        let squareWidth = size.width / (gobanWidthEntity + 1)
        let squareHeight = max(0, size.height - 20) / (gobanHeightEntity + passHeightEntity + 1)
        let squareLength = min(squareWidth, squareHeight)
        let squareLengthDiv2 = squareLength / 2
        let squareLengthDiv4 = squareLength / 4
        let squareLengthDiv8 = squareLength / 8
        let squareLengthDiv16 = squareLength / 16
        let gobanPadding = squareLength / 2
        let stoneLength = squareLength * 0.95
        let gobanWidthCalculated = (gobanWidthEntity * squareLength) + gobanPadding
        let gobanHeightCalculated = (gobanHeightEntity * squareLength) + gobanPadding
        let gobanStartX = (size.width - gobanWidthCalculated) / 2
        let passHeight = passHeightEntity * squareLength
        let gobanStartY = max(20, (size.height - passHeight - gobanHeightCalculated) / 2)
        let boardLineBoundWidth = (19 - 1) * squareLength
        let boardLineBoundHeight = (19 - 1) * squareLength
        let coordinateLength = coordinateEntity * squareLength
        let boardLineStartX = (size.width - boardLineBoundWidth + coordinateLength) / 2
        let boardLineStartY = 20 + coordinateLength + (squareLength + gobanPadding) / 2
        let capturedStonesStartY = gobanStartY - 20

        #expect(dimensions.squareLength == squareLength)
        #expect(dimensions.squareLengthDiv2 == squareLengthDiv2)
        #expect(dimensions.squareLengthDiv4 == squareLengthDiv4)
        #expect(dimensions.squareLengthDiv8 == squareLengthDiv8)
        #expect(dimensions.squareLengthDiv16 == squareLengthDiv16)
        #expect(dimensions.boardLineStartX == boardLineStartX)
        #expect(dimensions.boardLineStartY == boardLineStartY)
        #expect(dimensions.stoneLength == stoneLength)
        #expect(dimensions.width == 19)
        #expect(dimensions.height == 19)
        #expect(dimensions.gobanWidth == gobanWidthCalculated)
        #expect(dimensions.gobanHeight == gobanHeightCalculated)
        #expect(dimensions.boardLineBoundWidth == boardLineBoundWidth)
        #expect(dimensions.boardLineBoundHeight == boardLineBoundHeight)
        #expect(dimensions.gobanStartX == gobanStartX)
        #expect(dimensions.gobanStartY == gobanStartY)
        #expect(dimensions.coordinate == true)
        #expect(dimensions.capturedStonesStartY == capturedStonesStartY)
    }

    @Test func testDimensionsGetCapturedStoneStartX() async throws {
        let size = CGSize(width: 380, height: 380)
        let dimensions = Dimensions(size: size, width: 19, height: 19)
        let xOffset: CGFloat = 2
        let expectedX = dimensions.gobanStartX + (dimensions.gobanWidth / 2) + ((-3 + (6 * xOffset)) * max(dimensions.gobanWidth / 2, dimensions.capturedStonesWidth) / 4)
        #expect(dimensions.getCapturedStoneStartX(xOffset: xOffset) == expectedX)
    }

    // MARK: - Message Tests

    @Test func testMessageDefaultInitialization() async throws {
        let message = Message(text: "Hello, World!")
        #expect(message.text == "Hello, World!")
    }

    @Test func testMessageInitializationWithMaxLength() async throws {
        let longText = String(repeating: "a", count: 6000)
        let message = Message(text: longText)
        #expect(message.text.count == Message.defaultMaxMessageCharacters)
    }

    @Test func testMessageInitializationWithinMaxLength() async throws {
        let text = String(repeating: "b", count: 5000)
        let message = Message(text: text)
        #expect(message.text.count == 5000)
    }

    @Test func testMessageInitializationBelowMaxLength() async throws {
        let text = "Short message"
        let message = Message(text: text)
        #expect(message.text == "Short message")
    }

    @Test func testMessageEquatableAndHashable() async throws {
        let messageA = Message(text: "Test")
        let messageB = Message(text: "Test")
        let messageC = Message(text: "Different")

        #expect(messageA == messageA)
        #expect(messageA != messageB) // Different IDs
        #expect(messageA != messageC)

        let messageSet: Set<Message> = [messageA, messageB, messageC]
        #expect(messageSet.count == 3)
    }

    // MARK: - MessageList Tests

    @Test func testMessageListDefaultInitialization() async throws {
        let messageList = MessageList.accepting()
        #expect(messageList.messages.isEmpty)
    }

    @Test func testMessageListShrinkEmpty() async throws {
        let messageList = MessageList.accepting()
        messageList.shrink()
        #expect(messageList.messages.isEmpty)
    }

    @Test func testMessageListShrinkUnderLimit() async throws {
        let messageList = MessageList.accepting()
        for _ in 1..<MessageList.defaultMaxMessageLines {
            messageList.messages.append(Message(text: "Test"))
        }
        messageList.shrink()
        #expect(messageList.messages.count == MessageList.defaultMaxMessageLines - 1)
    }

    @Test func testMessageListShrinkAtLimit() async throws {
        let messageList = MessageList.accepting()
        for _ in 1...MessageList.defaultMaxMessageLines {
            messageList.messages.append(Message(text: "Test"))
        }
        messageList.shrink()
        #expect(messageList.messages.count == MessageList.defaultMaxMessageLines)
    }

    @Test func testMessageListShrinkOverLimit() async throws {
        let messageList = MessageList.accepting()
        for _ in 1...(MessageList.defaultMaxMessageLines + 10) {
            messageList.messages.append(Message(text: "Test"))
        }
        messageList.shrink()
        #expect(messageList.messages.count == MessageList.defaultMaxMessageLines)
    }

    // MARK: - AnalysisStatus Tests

    @Test func testAnalysisStatusEnum() async throws {
        #expect(AnalysisStatus.clear != AnalysisStatus.pause)
        #expect(AnalysisStatus.pause != AnalysisStatus.run)
        #expect(AnalysisStatus.run != AnalysisStatus.clear)
    }

    // MARK: - GobanState Tests

    @Test func testGobanStateDefaultInitialization() async throws {
        let gobanState = GobanState()
        #expect(gobanState.waitingForAnalysis == false)
        #expect(gobanState.requestingClearAnalysis == false)
        #expect(gobanState.analysisStatus == .run)
    }

    @Test func testGobanStateShouldRequestAnalysis() async throws {
        let gobanState = GobanState()
        let config = Config()
        #expect(gobanState.shouldRequestAnalysis(config: config, nextColorForPlayCommand: .black) == true)
        #expect(gobanState.shouldRequestAnalysis(config: config, nextColorForPlayCommand: .white) == true)
        #expect(gobanState.shouldRequestAnalysis(config: config, nextColorForPlayCommand: .unknown) == false)
    }

    @Test func testGobanStateMaybeRequestAnalysis() async throws {
        let gobanState = GobanState()
        let config = Config()

        gobanState.analysisStatus = .run

        gobanState.maybeRequestAnalysis(
            config: config,
            nextColorForPlayCommand: .black,
            messageList: MessageList.accepting()
        )

        #expect(gobanState.waitingForAnalysis == true)
    }

    @Test func testGobanStateMaybeRequestAnalysisWhenShouldNotRequest() async throws {
        let gobanState = GobanState()
        let config = Config()

        gobanState.analysisStatus = .clear

        gobanState.maybeRequestAnalysis(
            config: config,
            nextColorForPlayCommand: .black,
            messageList: MessageList.accepting()
        )

        #expect(gobanState.waitingForAnalysis == false)
    }

    @Test func testGobanStateMaybeRequestClearAnalysisData() async throws {
        let gobanState = GobanState()
        let config = Config()
        gobanState.analysisStatus = .clear
        gobanState.maybeRequestClearAnalysisData(config: config, nextColorForPlayCommand: .black)
        #expect(gobanState.requestingClearAnalysis == true)
    }

    @Test func testGobanStateMaybeRequestClearAnalysisDataWhenShouldRequest() async throws {
        let gobanState = GobanState()
        let config = Config()
        gobanState.analysisStatus = .run
        gobanState.maybeRequestClearAnalysisData(config: config, nextColorForPlayCommand: .black)
        #expect(gobanState.requestingClearAnalysis == false)
    }

    // MARK: - Winrate Tests

    @Test func testWinrateDefaultInitialization() async throws {
        let winrate = Winrate()
        #expect(winrate.black == 0.5)
        #expect(winrate.white == 0.5)
    }

    @Test func testWinrateBlackUpdatesWhite() async throws {
        let winrate = Winrate()
        winrate.black = 0.7
        #expect(winrate.black == 0.7)
        #expect(winrate.white == 0.3)

        winrate.black = 0.2
        #expect(winrate.black == 0.2)
        #expect(winrate.white == 0.8)
    }

    // MARK: - Coordinate Tests

    @Test func testCoordinateValidInitialization() async throws {
        let coordinate = Coordinate(xLabel: "AD", yLabel: "28", width: 29, height: 29)
        #expect(coordinate?.x == 28)
        #expect(coordinate?.y == 28)
        #expect(coordinate?.xLabel == "AD")
        #expect(coordinate?.yLabel == "28")
        #expect(coordinate?.move == "AD28")
        #expect(coordinate?.point?.x == 28)
        #expect(coordinate?.point?.y == 27)
    }

    @Test func testCoordinateInvalidXLabelInitialization() async throws {
        let invalidCoordinate = Coordinate(xLabel: "I", yLabel: "10")
        #expect(invalidCoordinate == nil)
    }

    @Test func testCoordinateInvalidYLabelInitialization() async throws {
        let invalidCoordinate = Coordinate(xLabel: "A", yLabel: "A")
        #expect(invalidCoordinate == nil)
    }

    @Test func testCoordinatePassMove() async throws {
        let width = 19
        let height = 19
        let passPoint = BoardPoint.pass(width: width, height: height)
        let coordinate = Coordinate(x: width - 1, y: height + 2, width: width, height: height)
        #expect(coordinate?.move == "pass")
        #expect(coordinate?.point == passPoint)
    }

    // MARK: - BoardPoint Tests (Additional)

    @Test func testBoardPointPassCreation() async throws {
        let width = 19
        let height = 19
        let passPoint = BoardPoint.pass(width: width, height: height)
        #expect(passPoint.x == width - 1)
        #expect(passPoint.y == height + 1)
    }

    // MARK: - Additional Tests for Comprehensive Coverage

    @Test func testCoordinatePointIsPass() async throws {
        let width = 19
        let height = 19
        let coordinatePass = Coordinate(x: width - 1, y: height + 2, width: width, height: height)
        #expect(coordinatePass?.point?.isPass(width: width, height: height) == true)

        let coordinateNonPass = Coordinate(x: 10, y: 10, width: width, height: height)
        #expect(coordinateNonPass?.point?.isPass(width: width, height: height) == false)
    }

    // MARK: - Tests for GobanState Functions

    @Test func testMaybeRequestAnalysisWithNextColor() async throws {
        let gobanState = GobanState()
        let config = Config()

        gobanState.analysisStatus = .run

        gobanState.maybeRequestAnalysis(
            config: config,
            nextColorForPlayCommand: .black,
            messageList: MessageList.accepting()
        )

        #expect(gobanState.waitingForAnalysis == true)
    }

    @Test func testMaybeRequestAnalysisWithoutNextColor() async throws {
        let gobanState = GobanState()
        let config = Config()

        gobanState.analysisStatus = .run

        gobanState.maybeRequestAnalysis(
            config: config,
            messageList: MessageList.accepting()
        )

        #expect(gobanState.waitingForAnalysis == true)
    }

    @Test func testShouldRequestAnalysisWithNextColor() async throws {
        let gobanState = GobanState()
        let config = Config()
        gobanState.analysisStatus = .run

        let shouldRequest = gobanState.shouldRequestAnalysis(config: config, nextColorForPlayCommand: .black)
        #expect(shouldRequest == true)
    }

    @Test func testShouldRequestAnalysisWithoutNextColor() async throws {
        let gobanState = GobanState()
        let config = Config()
        gobanState.analysisStatus = .clear

        let shouldRequest = gobanState.shouldRequestAnalysis(config: config, nextColorForPlayCommand: nil)
        #expect(shouldRequest == false)
    }

    @Test func testMaybeRequestClearAnalysisDataWithNextColor() async throws {
        let gobanState = GobanState()
        let config = Config()
        gobanState.analysisStatus = .clear

        gobanState.maybeRequestClearAnalysisData(config: config, nextColorForPlayCommand: .black)
        #expect(gobanState.requestingClearAnalysis == true)
    }

    @Test func testMaybeRequestClearAnalysisDataWithoutNextColor() async throws {
        let gobanState = GobanState()
        let config = Config()
        gobanState.analysisStatus = .clear

        gobanState.maybeRequestClearAnalysisData(config: config)
        #expect(gobanState.requestingClearAnalysis == true)
    }

    // MARK: - GobanState resetPendingStatesOnError Tests

    @Test func testResetPendingStatesOnError() async throws {
        let gobanState = GobanState()
        let stones = Stones()

        // Set all pending states
        gobanState.pendingMoveTurn = "b"
        gobanState.pendingMoveVertex = "D4"
        gobanState.confirmingIllegalMove = true
        gobanState.illegalMoveReason = "Illegal ko recapture"
        gobanState.waitingForAnalysis = true
        gobanState.showBoardCount = 2
        stones.isReady = false

        gobanState.resetPendingStatesOnError(stones: stones)

        #expect(gobanState.pendingMoveTurn == nil)
        #expect(gobanState.pendingMoveVertex == nil)
        #expect(gobanState.confirmingIllegalMove == false)
        #expect(gobanState.illegalMoveReason == nil)
        #expect(gobanState.waitingForAnalysis == false)
        #expect(gobanState.showBoardCount == 2) // showBoardCount is not reset by error handler
        #expect(stones.isReady == true)
    }

    @Test func testResetPendingStatesOnErrorWhenAlreadyClean() async throws {
        let gobanState = GobanState()
        let stones = Stones()

        gobanState.resetPendingStatesOnError(stones: stones)

        #expect(gobanState.pendingMoveTurn == nil)
        #expect(gobanState.pendingMoveVertex == nil)
        #expect(gobanState.confirmingIllegalMove == false)
        #expect(gobanState.illegalMoveReason == nil)
        #expect(gobanState.waitingForAnalysis == false)
        #expect(gobanState.showBoardCount == 0) // Initial value, not reset
        #expect(stones.isReady == true)
    }

    // MARK: - GobanState isPendingMoveStale Tests

    @Test func testIsPendingMoveStaleWhenNoPendingMove() async throws {
        let gobanState = GobanState()
        #expect(gobanState.isPendingMoveStale == false)
    }

    @Test func testIsPendingMoveStaleImmediatelyAfterSend() async throws {
        let gobanState = GobanState()
        let messageList = MessageList.accepting()
        gobanState.sendCheckMoveCommand(turn: "b", move: "D4", messageList: messageList)
        #expect(gobanState.isPendingMoveStale == false)
    }

    @Test func testIsPendingMoveStaleAfterTimeout() async throws {
        let gobanState = GobanState()
        let messageList = MessageList.accepting()
        gobanState.sendCheckMoveCommand(turn: "b", move: "D4", messageList: messageList)
        // Artificially set timestamp beyond GobanState.pendingMoveTimeout
        gobanState.pendingMoveTimestamp = Date().addingTimeInterval(-6.0)
        #expect(gobanState.isPendingMoveStale == true)
    }

    @Test func testIsPendingMoveStaleAfterClear() async throws {
        let gobanState = GobanState()
        let messageList = MessageList.accepting()
        gobanState.sendCheckMoveCommand(turn: "b", move: "D4", messageList: messageList)
        gobanState.clearPendingMove()
        #expect(gobanState.isPendingMoveStale == false)
        #expect(gobanState.pendingMoveTimestamp == nil)
    }

    // MARK: - Tests for Coordinate Struct Initialization

    @Test func testCoordinateInvalidInitialization() async throws {
        let invalidCoordinateX = Coordinate(x: -1, y: 5, width: 19, height: 19)
        let invalidCoordinateY = Coordinate(x: 3, y: 20, width: 19, height: 19)

        #expect(invalidCoordinateX == nil)
        #expect(invalidCoordinateY == nil)
    }

    @Test func boardPointMoveParsesTwoDigitRows() {
        // Regression: a `(\w+)` column group swallowed the row's first digit
        // ("Q16" → xLabel "Q1" → nil), silently dropping rows 10-19 wherever
        // BoardPoint(move:) is used (report boards, book advance).
        #expect(BoardPoint(move: "Q16", width: 19, height: 19) == BoardPoint(x: 15, y: 15))
        #expect(BoardPoint(move: "B19", width: 19, height: 19) == BoardPoint(x: 1, y: 18))
        #expect(BoardPoint(move: "A1", width: 19, height: 19) == BoardPoint(x: 0, y: 0))
        #expect(BoardPoint(move: "pass", width: 19, height: 19) == BoardPoint.pass(width: 19, height: 19))
        // Two-letter columns on big boards keep working.
        #expect(BoardPoint(move: "AB12", width: 37, height: 37) != nil)
    }

    // MARK: - BoardPoint GTP vertex

    @Test func boardPointGtpVertexFormatsCorners() {
        #expect(BoardPoint(x: 0, y: 0).gtpVertex(width: 19, height: 19) == "A1")
        #expect(BoardPoint(x: 18, y: 18).gtpVertex(width: 19, height: 19) == "T19")
        // Letter I is skipped: column index 8 is "J".
        #expect(BoardPoint(x: 8, y: 8).gtpVertex(width: 9, height: 9) == "J9")
        #expect(BoardPoint(x: 15, y: 15).gtpVertex(width: 19, height: 19) == "Q16")
        // Non-square boards use each axis's own bound.
        #expect(BoardPoint(x: 12, y: 8).gtpVertex(width: 13, height: 9) == "N9")
    }

    @Test func boardPointGtpVertexRejectsOffBoardPoints() {
        #expect(BoardPoint(x: 19, y: 0).gtpVertex(width: 19, height: 19) == nil)
        #expect(BoardPoint(x: 0, y: 19).gtpVertex(width: 19, height: 19) == nil)
        #expect(BoardPoint(x: -1, y: 0).gtpVertex(width: 19, height: 19) == nil)
        #expect(BoardPoint(x: 0, y: -1).gtpVertex(width: 19, height: 19) == nil)
    }

    @Test func boardPointGtpVertexPassPoint() {
        let pass = BoardPoint.pass(width: 19, height: 19)
        #expect(pass.gtpVertex(width: 19, height: 19) == "pass")
    }

    @Test func boardPointGtpVertexRoundTripsThroughMoveInit() throws {
        for point in [BoardPoint(x: 0, y: 0), BoardPoint(x: 15, y: 15),
                      BoardPoint(x: 8, y: 12), BoardPoint(x: 18, y: 0)] {
            let vertex = try #require(point.gtpVertex(width: 19, height: 19))
            #expect(BoardPoint(move: vertex, width: 19, height: 19) == point)
        }
    }
}

/// The LIVE board shares `BoardLineView`'s cell-clipped coordinate labels with
/// the Saved Game widget and the GIF exporter, so it inherits the same
/// truncation floor: once the cell pitch drops under
/// `WidgetCoordinateMetrics.requiredCell`, a wide board's "A"+letter column
/// labels clip to "…".
///
/// The widget hides its labels and the GIF raises its raster, but the live
/// board can do neither — its pitch is set by the LAYOUT. So what this pins is
/// the CONTAINER the board must be handed. On iOS `Dimensions` divides a
/// container by (with coordinates, the pass row, and the captured-stone strip
/// all on):
///
///     squareLength = min(W / (n + 2), (H - 20) / (n + 3.5))
///
/// KNOWN, ACCEPTED LIMITATION: a 37x37 needs ~356 x 390 pt. iPhone portrait
/// clears it (386 pt wide, measured off the live board's accessibility
/// elements); iPhone LANDSCAPE cannot — the entire app is 402 pt tall there,
/// before the nav bar, player row, and control row — so a 37x37 truncates its
/// column labels in landscape. Left as-is on purpose: see `drawCoordinate` in
/// `BoardLineView`. These tests guard the sizes people actually play.
struct BoardCoordinateFitTests {
    private func pitch(_ size: CGSize, n: Int) -> CGFloat {
        Dimensions(size: size, width: CGFloat(n), height: CGFloat(n),
                   showCoordinate: true, showPass: true,
                   isDrawingCapturedStones: true).squareLength
    }

    /// The MEASURED iPhone 17 portrait board container. The live board's pitch
    /// was 18.37 pt for a 19x19 — read off the accessibility elements ("A 1" to
    /// "T 19") and confirmed independently against the rendered grid — and
    /// WIDTH is the binding constraint there, so the container is
    /// 21 x 18.37 = 386 pt wide. The height is only known to be large enough
    /// that width binds (>= 434 pt), so this uses that lower bound: if the
    /// worst container consistent with the measurement clears the floor, the
    /// real one does too.
    @Test func measuredIPhonePortraitContainer_fitsEvenTheWidestBoard() {
        let container = CGSize(width: 386, height: 434)
        for n in [9, 19, 37] {
            #expect(pitch(container, n: n)
                    >= WidgetCoordinateMetrics.requiredCell(width: n, height: n))
        }
    }

    /// The threshold itself, so a future layout change that shrinks the board
    /// pane has something to fail against. A 37x37 needs roughly 356 x 390 pt
    /// of container; one point less in either axis stops clearing the floor.
    @Test func widestBoardNeedsAKnownMinimumContainer() {
        let need = WidgetCoordinateMetrics.requiredCell(width: 37, height: 37)
        let minWidth = need * 39
        let minHeight = need * 40.5 + 20
        #expect(minWidth < 356 && minWidth > 355)     // ~355.5 pt
        #expect(minHeight < 390 && minHeight > 389)   // ~389.2 pt

        let exact = CGSize(width: minWidth, height: minHeight)
        #expect(pitch(exact, n: 37) >= need)
        #expect(pitch(CGSize(width: minWidth - 1, height: minHeight), n: 37) < need)
        #expect(pitch(CGSize(width: minWidth, height: minHeight - 1), n: 37) < need)
    }

    /// tvOS is the one platform whose board container is fixed in source rather
    /// than negotiated with a window, so this test IS the check — no Apple TV
    /// required. `TVReviewScreen` and `TVSelfPlayScreen` both pin `BoardView`
    /// to `.frame(width: 1080, height: 1080)`; `TVBroadcastSlideView` pins
    /// `ReportBoardView` to 900 x 900. Nothing about the device can move those
    /// numbers, and `Dimensions` compiles its non-macOS branch here, which is
    /// the branch tvOS takes.
    @Test func tvOSFixedBoardContainers_fitEveryBoardSize() {
        // Review + self-play: the full BoardView (pass row, captured strip).
        let hero = CGSize(width: 1080, height: 1080)
        for n in [9, 13, 19, 37] {
            #expect(pitch(hero, n: n)
                    >= WidgetCoordinateMetrics.requiredCell(width: n, height: n))
        }
        // The tightest case still clears the floor by ~2.9x, so tvOS has no
        // coordinate-legibility exposure at all.
        #expect(pitch(hero, n: 37) > 26)

        // Broadcast slides use ReportBoardView: no pass row, no captured strip.
        let slide = CGSize(width: 900, height: 900)
        for n in [9, 13, 19, 37] {
            let dims = Dimensions(size: slide, width: CGFloat(n), height: CGFloat(n),
                                  showCoordinate: true, showPass: false,
                                  isDrawingCapturedStones: false)
            #expect(dims.squareLength
                    >= WidgetCoordinateMetrics.requiredCell(width: n, height: n))
        }
    }

    /// The field check, so future QA never has to build a 37x37 to answer
    /// "do coordinates fit here?".
    ///
    /// Measuring a 37x37 in situ means raising Max Board Size and restarting the
    /// engine; measuring the DEFAULT 19x19 costs nothing. Knowing only that a
    /// 19x19 renders at pitch `s` pins the container from below — `W >= 21s` and
    /// `H - 20 >= 22.5s` — so
    ///
    ///     pitch(37) >= min(21s/39, 22.5s/40.5) = (7/13) * s
    ///
    /// and a 19x19 at **16.93 pt or better guarantees a 37x37 keeps its
    /// labels** in the same container. One-directional on purpose: below that a
    /// 37x37 may still fit, and the exact container has to be worked out.
    @Test func aNineteenPitchOfSeventeenPointsGuaranteesTheWidestBoardFits() {
        let need = WidgetCoordinateMetrics.requiredCell(width: 37, height: 37)
        let safe19Pitch = need * 13 / 7
        #expect(safe19Pitch < 16.93 && safe19Pitch > 16.92)

        // The bound holds for every container shape, not just the square ones:
        // sweep wide, tall, and square and check the ratio never dips below
        // 7/13. The epsilon is there because the bound is EXACTLY tight whenever
        // width binds both boards (W/39 and (W/21) * 7/13 are the same number),
        // so the two sides differ only by floating-point rounding.
        let epsilon: CGFloat = 1e-9
        for w in stride(from: CGFloat(360), through: 1200, by: 40) {
            for h in stride(from: CGFloat(400), through: 1200, by: 40) {
                let size = CGSize(width: w, height: h)
                let s19 = pitch(size, n: 19)
                #expect(pitch(size, n: 37) >= s19 * 7 / 13 - epsilon)
                if s19 >= safe19Pitch {
                    #expect(pitch(size, n: 37) >= need)
                }
            }
        }
    }

    /// macOS reserves its pass area to the RIGHT of the board instead of below
    /// it (`Dimensions`' `#if os(macOS)` branch), which transposes the demand:
    ///
    ///     squareLength = min(W / (n + 5), (H - 20) / (n + 2))
    ///
    /// so a 37x37 needs **383 pt of width** but only **376 pt of height** — the
    /// mirror image of every other platform. This test runs on iOS, so it
    /// models that branch rather than executing it; the numbers are what the
    /// macOS measurement below is checked against.
    @Test func macOSTransposesTheDemandOntoWidth() {
        let need = WidgetCoordinateMetrics.requiredCell(width: 37, height: 37)
        let macMinWidth = need * 42          // n + 5 = 42
        let macMinHeight = need * 39 + 20    // n + 2 = 39, plus the captured strip
        #expect(macMinWidth < 383 && macMinWidth > 382)    // ~382.8 pt
        #expect(macMinHeight < 376 && macMinHeight > 375)  // ~375.5 pt

        // `MainSplitViewController` floors the board pane at 480 pt
        // (`boardItem.minimumThickness`), which is the only reason the width
        // side is safe. If that floor is ever lowered past ~383, macOS starts
        // truncating 37x37 column labels at every window size.
        #expect(480 > macMinWidth)
    }
}
