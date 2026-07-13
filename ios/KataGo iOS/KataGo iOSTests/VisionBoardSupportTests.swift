//
//  VisionBoardSupportTests.swift
//  KataGo AnytimeTests
//

import Testing
@testable import KataGoUICore

struct VisionBoardSupportTests {
    @Test func bundledSquareSizesAreSupported() {
        #expect(visionBoardIsSupported(width: 9, height: 9))
        #expect(visionBoardIsSupported(width: 13, height: 13))
        #expect(visionBoardIsSupported(width: 19, height: 19))
    }

    @Test func rectangularBoardsAreUnsupported() {
        #expect(!visionBoardIsSupported(width: 13, height: 9))
        #expect(!visionBoardIsSupported(width: 9, height: 13))
    }

    @Test func unbundledSquareSizesAreUnsupported() {
        #expect(!visionBoardIsSupported(width: 2, height: 2))
        #expect(!visionBoardIsSupported(width: 7, height: 7))
        #expect(!visionBoardIsSupported(width: 21, height: 21))
        #expect(!visionBoardIsSupported(width: 37, height: 37))
    }
}
