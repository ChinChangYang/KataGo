//
//  VisionBoardSupportTests.swift
//  KataGo AnytimeTests
//

import Testing
@testable import KataGoUICore

struct VisionBoardSupportTests {
    @Test func classicSquareSizesAreSupported() {
        #expect(visionBoardIsSupported(width: 9, height: 9))
        #expect(visionBoardIsSupported(width: 13, height: 13))
        #expect(visionBoardIsSupported(width: 19, height: 19))
    }

    @Test func rectangularBoardsAreSupported() {
        #expect(visionBoardIsSupported(width: 13, height: 9))
        #expect(visionBoardIsSupported(width: 9, height: 13))
        #expect(visionBoardIsSupported(width: 37, height: 2))
    }

    @Test func fullRangeIsSupported() {
        #expect(visionBoardIsSupported(width: 2, height: 2))
        #expect(visionBoardIsSupported(width: 7, height: 7))
        #expect(visionBoardIsSupported(width: 21, height: 21))
        #expect(visionBoardIsSupported(width: 37, height: 37))
    }

    @Test func outOfRangeIsUnsupported() {
        #expect(!visionBoardIsSupported(width: 1, height: 5))
        #expect(!visionBoardIsSupported(width: 5, height: 1))
        #expect(!visionBoardIsSupported(width: 38, height: 38))
        #expect(!visionBoardIsSupported(width: 19, height: 38))
    }
}
