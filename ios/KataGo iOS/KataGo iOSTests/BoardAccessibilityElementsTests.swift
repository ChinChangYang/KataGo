//
//  BoardAccessibilityElementsTests.swift
//  KataGo AnytimeTests
//
//  Created by Chin-Chang Yang on 2026/7/19.
//

import Testing
import KataGoUICore

struct BoardAccessibilityElementsTests {
    @Test func elementCountsMatchBoardArea() {
        #expect(BoardAccessibilityElement.elements(width: 19, height: 19, includePass: false).count == 361)
        #expect(BoardAccessibilityElement.elements(width: 37, height: 37, includePass: false).count == 1369)
        // Rectangular boards enumerate width × height, not a square.
        #expect(BoardAccessibilityElement.elements(width: 13, height: 9, includePass: false).count == 117)
        #expect(BoardAccessibilityElement.elements(width: 19, height: 19, includePass: true).count == 362)
    }

    @Test func labelsUseGoCoordinatesWithASpace() {
        let labels = Set(BoardAccessibilityElement.elements(width: 19, height: 19, includePass: false).map(\.label))
        #expect(labels.contains("A 1"))
        #expect(labels.contains("T 19"))
        #expect(labels.contains("K 10"))
        // Column letter I is skipped in Go coordinates: column index 8 is "J".
        #expect(labels.contains("J 1"))
        #expect(!labels.contains { $0.hasPrefix("I ") })
        // Every label is "<column> <row>" — the space keeps Voice Control and
        // VoiceOver treating column and row as separate spoken tokens.
        #expect(labels.allSatisfy { $0.split(separator: " ").count == 2 })
    }

    @Test func wideBoardsUseTwoLetterColumns() {
        let labels = Set(BoardAccessibilityElement.elements(width: 37, height: 37, includePass: false).map(\.label))
        #expect(labels.contains("AA 26"))
        // Rightmost column on 37×37 is index 36 → "AM" ("AI" skipped like "I").
        #expect(labels.contains("AM 37"))
        #expect(!labels.contains { $0.hasPrefix("AI ") })
    }

    @Test func passElementFollowsTheFlag() {
        let withPass = BoardAccessibilityElement.elements(width: 19, height: 19, includePass: true)
        let passElements = withPass.filter { $0.label == "Pass" }
        #expect(passElements.count == 1)
        // The pass element must resolve to the GTP "pass" move and the shared
        // pass point so `Dimensions.screenCenter` positions it on the tile.
        #expect(passElements.first?.coordinate.move == "pass")
        #expect(passElements.first?.point.isPass(width: 19, height: 19) == true)

        let withoutPass = BoardAccessibilityElement.elements(width: 19, height: 19, includePass: false)
        #expect(!withoutPass.contains { $0.label == "Pass" })
    }

    @Test func identifiersAreUniqueIncludingPass() {
        let elements = BoardAccessibilityElement.elements(width: 19, height: 19, includePass: true)
        #expect(Set(elements.map(\.id)).count == elements.count)

        let rectangular = BoardAccessibilityElement.elements(width: 13, height: 9, includePass: true)
        #expect(Set(rectangular.map(\.id)).count == rectangular.count)
    }
}
