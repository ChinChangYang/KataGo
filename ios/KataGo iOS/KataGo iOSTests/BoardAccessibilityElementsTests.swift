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

/// `VoiceControlHelpView` tells users literal phrases to say. A phrase that no
/// longer matches a real target is worse than no help at all, so both halves are
/// pinned here: the board examples must be labels the overlay actually exposes,
/// and each platform's wording must be that platform's.
struct VoiceControlHelpTests {
    /// Every example the screen prints has to exist in the overlay's element
    /// set for the same board — the property that makes the help text
    /// undriftable rather than merely correct today.
    @Test(arguments: [(19, 19), (9, 9), (37, 37), (13, 9), (2, 2)])
    func boardExamplesAreRealOverlayLabels(size: (Int, Int)) {
        let (width, height) = size
        let examples = VoiceControlBoardExamples(boardWidth: width, boardHeight: height)
        let labels = Set(BoardAccessibilityElement.elements(width: width,
                                                           height: height,
                                                           includePass: false).map(\.label))
        #expect(labels.contains(examples.nearCorner))
        #expect(labels.contains(examples.farCorner))
        #expect(labels.contains(examples.center))
        if let twoLetterColumn = examples.twoLetterColumn {
            #expect(labels.contains(twoLetterColumn))
        }
        #expect(examples.namedPointCount == labels.count)
    }

    @Test func examplesNameTheCornersOfTheBoardInFront() {
        let nineteen = VoiceControlBoardExamples(boardWidth: 19, boardHeight: 19)
        #expect(nineteen.nearCorner == "A 1")
        #expect(nineteen.farCorner == "T 19")
        #expect(nineteen.center == "K 10")
        // 19 columns end at T, so there is nothing two-letter to demonstrate
        // and the screen must not claim otherwise.
        #expect(nineteen.twoLetterColumn == nil)
        #expect(nineteen.namedPointCount == 361)

        let nine = VoiceControlBoardExamples(boardWidth: 9, boardHeight: 9)
        #expect(nine.nearCorner == "A 1")
        #expect(nine.farCorner == "J 9")   // column letter I is skipped
        #expect(nine.center == "E 5")

        // Rectangles: the far corner is the wide axis's last column at the tall
        // axis's top row, not a square's diagonal.
        let wide = VoiceControlBoardExamples(boardWidth: 13, boardHeight: 9)
        #expect(wide.farCorner == "N 9")
        #expect(wide.namedPointCount == 117)
    }

    @Test func wideBoardsDemonstrateTheirTwoLetterColumns() {
        let widest = VoiceControlBoardExamples(boardWidth: 37, boardHeight: 37)
        #expect(widest.twoLetterColumn == "AA 1")
        #expect(widest.farCorner == "AM 37")
        #expect(widest.namedPointCount == 1369)

        // 25 columns is the last width that stays single-letter (A..Z minus I).
        #expect(VoiceControlBoardExamples(boardWidth: 25, boardHeight: 25).twoLetterColumn == nil)
        #expect(VoiceControlBoardExamples(boardWidth: 26, boardHeight: 26).twoLetterColumn == "AA 1")
    }

    /// Callers pass whatever the live game says, including 0 before the first
    /// board arrives and a size past the label map's 50 columns.
    @Test func degenerateBoardSizesClampInsteadOfProducingEmptyExamples() {
        let empty = VoiceControlBoardExamples(boardWidth: 0, boardHeight: 0)
        #expect(empty.boardWidth == 2 && empty.boardHeight == 2)
        #expect(!empty.nearCorner.isEmpty)
        #expect(!empty.farCorner.isEmpty)
        #expect(!empty.center.isEmpty)

        let huge = VoiceControlBoardExamples(boardWidth: 99, boardHeight: 99)
        #expect(huge.boardWidth == 50 && huge.boardHeight == 50)
        #expect(!huge.farCorner.isEmpty)
    }

    /// The macOS wording can never be reached by a test that runs on the iOS
    /// Simulator if it hides behind `#if os(macOS)` — which is exactly why the
    /// phrasebook is data. iOS and macOS genuinely differ on all three strings.
    @Test func eachPlatformGetsItsOwnWording() {
        #expect(VoiceControlPhrasebook.iOS.activate == "Tap")
        #expect(VoiceControlPhrasebook.iOS.listCommands == "Show me what to say")
        #expect(VoiceControlPhrasebook.iOS.commandListPath.contains("Customize Commands"))
        #expect(VoiceControlPhrasebook.iOS.command("K 10") == "Tap K 10")

        #expect(VoiceControlPhrasebook.macOS.activate == "Click")
        #expect(VoiceControlPhrasebook.macOS.listCommands == "Show commands")
        #expect(VoiceControlPhrasebook.macOS.enablePath.hasPrefix("System Settings"))
        #expect(VoiceControlPhrasebook.macOS.command("K 10") == "Click K 10")

        // The failure this guards: Mac copy that says "Tap" (nothing happens on
        // macOS) or repeats the iOS phrase for listing commands.
        #expect(!VoiceControlPhrasebook.macOS.command("Pass").contains("Tap"))
        #expect(!VoiceControlPhrasebook.macOS.listCommands.contains("what to say"))
        #expect(VoiceControlPhrasebook.iOS != VoiceControlPhrasebook.macOS)

        // This suite runs on the iOS Simulator, so `current` must be the iOS
        // one; if that ever flips, the macOS assertions above stop meaning
        // anything about what users actually see.
        #expect(VoiceControlPhrasebook.current == .iOS)
    }
}
