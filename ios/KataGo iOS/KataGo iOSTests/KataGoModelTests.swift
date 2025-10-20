//
//  KataGoModelTests.swift
//  KataGo iOSTests
//
//  Created by Chin-Chang Yang on 2024/8/17.
//

import Testing
import CoreGraphics
@testable import KataGo_Anytime

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
        let messageList = MessageList()
        #expect(messageList.messages.isEmpty)
    }

    @Test func testMessageListShrinkEmpty() async throws {
        let messageList = MessageList()
        messageList.shrink()
        #expect(messageList.messages.isEmpty)
    }

    @Test func testMessageListShrinkUnderLimit() async throws {
        let messageList = MessageList()
        for _ in 1..<MessageList.defaultMaxMessageLines {
            messageList.messages.append(Message(text: "Test"))
        }
        messageList.shrink()
        #expect(messageList.messages.count == MessageList.defaultMaxMessageLines - 1)
    }

    @Test func testMessageListShrinkAtLimit() async throws {
        let messageList = MessageList()
        for _ in 1...MessageList.defaultMaxMessageLines {
            messageList.messages.append(Message(text: "Test"))
        }
        messageList.shrink()
        #expect(messageList.messages.count == MessageList.defaultMaxMessageLines)
    }

    @Test func testMessageListShrinkOverLimit() async throws {
        let messageList = MessageList()
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
        let gameRecord = GameRecord(config: config)

        gobanState.analysisStatus = .run

        gobanState.maybeRequestAnalysis(
            config: config,
            nextColorForPlayCommand: .black,
            messageList: MessageList(),
            gameRecord: gameRecord
        )

        #expect(gobanState.waitingForAnalysis == true)
    }

    @Test func testGobanStateMaybeRequestAnalysisWhenShouldNotRequest() async throws {
        let gobanState = GobanState()
        let config = Config()
        let gameRecord = GameRecord(config: config)

        gobanState.analysisStatus = .clear

        gobanState.maybeRequestAnalysis(
            config: config,
            nextColorForPlayCommand: .black,
            messageList: MessageList(),
            gameRecord: gameRecord
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
        let gameRecord = GameRecord(config: config)

        gobanState.analysisStatus = .run

        gobanState.maybeRequestAnalysis(
            config: config,
            nextColorForPlayCommand: .black,
            messageList: MessageList(),
            gameRecord: gameRecord
        )

        #expect(gobanState.waitingForAnalysis == true)
    }

    @Test func testMaybeRequestAnalysisWithoutNextColor() async throws {
        let gobanState = GobanState()
        let config = Config()
        let gameRecord = GameRecord(config: config)

        gobanState.analysisStatus = .run

        gobanState.maybeRequestAnalysis(
            config: config,
            messageList: MessageList(),
            gameRecord: gameRecord
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

    // MARK: - Tests for Coordinate Struct Initialization

    @Test func testCoordinateInvalidInitialization() async throws {
        let invalidCoordinateX = Coordinate(x: -1, y: 5, width: 19, height: 19)
        let invalidCoordinateY = Coordinate(x: 3, y: 20, width: 19, height: 19)

        #expect(invalidCoordinateX == nil)
        #expect(invalidCoordinateY == nil)
    }
}
