//
//  BoardStarPointsTests.swift
//  KataGo AnytimeTests
//
//  The shared star-point (hoshi) rule that drives both the 2D boards
//  (BoardLineView, WidgetBoardView) and the visionOS generated board-top
//  texture. The three legacy hardcoded layouts are the parity contract:
//  9x9 and 13x13 use corners + tengen (five points; the 2D convention won
//  over the asset pipeline's nine for 13x13), 19x19 uses the full 3x3 grid.
//

import Testing
import KataGoGameStore

struct BoardStarPointsTests {
    private func pairs(_ width: Int, _ height: Int) -> [[Int]] {
        BoardStarPoints.points(width: width, height: height).map { [$0.x, $0.y] }
    }

    @Test func legacyNineteenIsFullThreeByThreeGrid() {
        let expected = [3, 9, 15].flatMap { x in [3, 9, 15].map { [x, $0] } }.sorted { ($0[0], $0[1]) < ($1[0], $1[1]) }
        #expect(pairs(19, 19) == expected)
    }

    @Test func legacyThirteenIsCornersPlusTengen() {
        #expect(pairs(13, 13) == [[3, 3], [3, 9], [6, 6], [9, 3], [9, 9]])
    }

    @Test func legacyNineIsCornersPlusTengen() {
        #expect(pairs(9, 9) == [[2, 2], [2, 6], [4, 4], [6, 2], [6, 6]])
    }

    @Test func fiveHasTengenOnly() {
        #expect(pairs(5, 5) == [[2, 2]])
    }

    @Test func sevenAndElevenUseThirdLineCornersPlusTengen() {
        #expect(pairs(7, 7) == [[2, 2], [2, 4], [3, 3], [4, 2], [4, 4]])
        #expect(pairs(11, 11) == [[2, 2], [2, 8], [5, 5], [8, 2], [8, 8]])
    }

    @Test func fifteenAndUpGainSideStars() {
        let fifteen = [3, 7, 11].flatMap { x in [3, 7, 11].map { [x, $0] } }.sorted { ($0[0], $0[1]) < ($1[0], $1[1]) }
        #expect(pairs(15, 15) == fifteen)
        let seventeen = [3, 8, 13].flatMap { x in [3, 8, 13].map { [x, $0] } }.sorted { ($0[0], $0[1]) < ($1[0], $1[1]) }
        #expect(pairs(17, 17) == seventeen)
        #expect(pairs(37, 37).count == 9)
    }

    @Test func evenAndTinyBoardsHaveNone() {
        #expect(pairs(8, 8).isEmpty)
        #expect(pairs(24, 24).isEmpty)
        #expect(pairs(2, 2).isEmpty)
        #expect(pairs(3, 3).isEmpty)
        #expect(pairs(4, 4).isEmpty)
    }

    @Test func rectangularCornersComeFromEachAxisRule() {
        // 19 axis: corners {3, 15} + center 9 (full); 13 axis: corners {3, 9} +
        // center 6 (not full) -> corner crosses + tengen, no mixed side stars.
        #expect(pairs(19, 13) == [[3, 3], [3, 9], [9, 6], [15, 3], [15, 9]])
        #expect(pairs(9, 13) == [[2, 3], [2, 9], [4, 6], [6, 3], [6, 9]])
    }

    @Test func rectangularCenterNeedsBothAxesOdd() {
        #expect(pairs(5, 19) == [[2, 9]])
        #expect(pairs(14, 19).isEmpty)
    }

    @Test func allSupportedSizesStayInBoundsAndSorted() {
        for width in 2...37 {
            for height in 2...37 {
                let points = BoardStarPoints.points(width: width, height: height)
                for point in points {
                    #expect((0..<width).contains(point.x) && (0..<height).contains(point.y))
                }
                let sorted = points.map { [$0.x, $0.y] }.sorted { ($0[0], $0[1]) < ($1[0], $1[1]) }
                #expect(points.map { [$0.x, $0.y] } == sorted)
            }
        }
    }

    @Test func legacyPartnersAgree() {
        // WidgetBoardView.hoshiPoints must keep returning the shared rule's
        // layout for the classic sizes it used to hardcode.
        for size in [9, 13, 19] {
            let widget = WidgetBoardView.hoshiPoints(width: size, height: size).map { [$0.0, $0.1] }
            #expect(widget.sorted { ($0[0], $0[1]) < ($1[0], $1[1]) } == pairs(size, size))
        }
    }
}
