//
//  VisionGameDeleteFlowTests.swift
//  KataGo AnytimeTests
//
//  Pins the pure logic behind the visionOS Games-list delete flow: the
//  replacement decision when the OPEN game is deleted (newest remaining,
//  else create fresh — boot's newest-else-create minus the deleted set),
//  the iOS-verbatim bulk confirmation prompt, and the select-mode chrome
//  strings (iOS GameListView/GameSplitView parity).
//

import Testing
@testable import KataGoUICore

struct VisionGameDeleteFlowTests {
    @Test func falloutKeepsCurrentWhenCurrentNotInSet() {
        let fallout = VisionGameDeleteFlow.fallout(orderedNewestFirst: ["a", "b", "c"],
                                                   deleting: ["b"],
                                                   currentID: "a")
        #expect(fallout == .keepCurrent)
    }

    @Test func falloutKeepsCurrentWhenNoCurrentGame() {
        // No open game means nothing to remount, even when the deletion
        // covers the whole library.
        let fallout = VisionGameDeleteFlow.fallout(orderedNewestFirst: ["a", "b"],
                                                   deleting: ["a", "b"],
                                                   currentID: String?.none)
        #expect(fallout == .keepCurrent)
    }

    @Test func falloutSwitchesToNewestRemaining() {
        let fallout = VisionGameDeleteFlow.fallout(orderedNewestFirst: ["a", "b", "c"],
                                                   deleting: ["a"],
                                                   currentID: "a")
        #expect(fallout == .switchTo("b"))
    }

    @Test func falloutSkipsDeletedRecordsWhenPickingReplacement() {
        let skipsNewer = VisionGameDeleteFlow.fallout(orderedNewestFirst: ["a", "b", "c"],
                                                      deleting: ["a", "b"],
                                                      currentID: "a")
        #expect(skipsNewer == .switchTo("c"))

        // The replacement is the newest remaining, which can be NEWER than
        // the deleted current game.
        let picksNewest = VisionGameDeleteFlow.fallout(orderedNewestFirst: ["a", "b", "c"],
                                                       deleting: ["b"],
                                                       currentID: "b")
        #expect(picksNewest == .switchTo("a"))
    }

    @Test func falloutCreatesFreshWhenEverythingIsDeleted() {
        let fallout = VisionGameDeleteFlow.fallout(orderedNewestFirst: ["a", "b"],
                                                   deleting: ["a", "b"],
                                                   currentID: "a")
        #expect(fallout == .createFresh)
    }

    @Test func bulkPromptPluralizes() {
        #expect(VisionGameDeleteFlow.bulkDeletePrompt(count: 1)
                == "Are you sure you want to delete 1 game? THIS ACTION IS IRREVERSIBLE!")
        #expect(VisionGameDeleteFlow.bulkDeletePrompt(count: 3)
                == "Are you sure you want to delete 3 games? THIS ACTION IS IRREVERSIBLE!")
    }

    @Test func selectionImagesAndToggleTitles() {
        #expect(VisionGameDeleteFlow.selectionImage(isSelected: true) == "checkmark.circle.fill")
        #expect(VisionGameDeleteFlow.selectionImage(isSelected: false) == "circle")
        #expect(VisionGameDeleteFlow.selectToggleTitle(isSelecting: true) == "Done")
        #expect(VisionGameDeleteFlow.selectToggleTitle(isSelecting: false) == "Select")
        #expect(VisionGameDeleteFlow.selectToggleImage(isSelecting: true) == "checkmark.circle.fill")
        #expect(VisionGameDeleteFlow.selectToggleImage(isSelecting: false) == "checkmark.circle")
    }

    @Test func trashCountLabelFormatsAndDisablesAtZero() {
        #expect(VisionGameDeleteFlow.trashCountLabel(count: 0) == "(0)")
        #expect(VisionGameDeleteFlow.trashCountLabel(count: 12) == "(12)")
        #expect(VisionGameDeleteFlow.bulkTrashDisabled(count: 0))
        #expect(!VisionGameDeleteFlow.bulkTrashDisabled(count: 1))
    }
}
