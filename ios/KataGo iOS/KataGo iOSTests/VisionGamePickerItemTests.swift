//
//  VisionGamePickerItemTests.swift
//  KataGo AnytimeTests
//
//  Pins the pure row-model behind the visionOS ornament's Games picker:
//  selectability (bundled 3D asset AND fits the launched engine's NN buffer)
//  and the "date · size" detail line. Size is optimistic when unknown — the
//  openGame handler re-derives it from the SGF and gates authoritatively.
//

import Foundation
import Testing
@testable import KataGoUICore

struct VisionGamePickerItemTests {
    private func make(name: String = "Game",
                      lastModificationDate: Date? = nil,
                      width: Int? = nil,
                      height: Int? = nil,
                      maxBoardLength: Int = 19,
                      modelBoardCap: Int = 37,
                      now: Date = .now) -> VisionGamePickerItem {
        VisionGamePickerItem.make(name: name,
                                  lastModificationDate: lastModificationDate,
                                  width: width,
                                  height: height,
                                  maxBoardLength: maxBoardLength,
                                  modelBoardCap: modelBoardCap,
                                  now: now)
    }

    @Test func sizesWithinTheEngineCapAreSelectable() {
        #expect(make(width: 9, height: 9).isSelectable)
        #expect(make(width: 19, height: 19).isSelectable)
        #expect(make(width: 13, height: 9).isSelectable)
        #expect(make(width: 7, height: 7).isSelectable)
        #expect(make(width: 21, height: 21, maxBoardLength: 37).isSelectable)
        #expect(make(width: 37, height: 37, maxBoardLength: 37).isSelectable)
    }

    @Test func sizeOverEngineCapNeedsTheSetting() {
        // Renders fine but exceeds the launched NN buffer: not selectable,
        // and the row carries the raise-the-setting caption.
        let blocked = make(width: 25, height: 25, maxBoardLength: 19)
        #expect(!blocked.isSelectable)
        #expect(blocked.needsLargerBoardSetting)
        #expect(!make(width: 19, height: 19, maxBoardLength: 13).isSelectable)
        #expect(make(width: 13, height: 13, maxBoardLength: 13).isSelectable)

        let raised = make(width: 25, height: 25, maxBoardLength: 37)
        #expect(raised.isSelectable)
        #expect(!raised.needsLargerBoardSetting)
    }

    @Test func outOfRangeSizeIsNotSelectableAndNotTheSettingsFault() {
        let item = make(width: 38, height: 38, maxBoardLength: 37)
        #expect(!item.isSelectable)
        #expect(!item.needsLargerBoardSetting)
        #expect(!item.needsDifferentNet)
    }

    @Test func boardOverTheNetCapNeedsADifferentNet() {
        // A capped net (Lionffen class, nnLen 19): no Max Board Size choice
        // can ever fit this board, so the caption must not point at the
        // setting — switching the neural net is the exit.
        let blocked = make(width: 25, height: 25,
                           maxBoardLength: 19, modelBoardCap: 19)
        #expect(!blocked.isSelectable)
        #expect(!blocked.needsLargerBoardSetting)
        #expect(blocked.needsDifferentNet)

        let rectangle = make(width: 37, height: 19,
                             maxBoardLength: 19, modelBoardCap: 19)
        #expect(rectangle.needsDifferentNet)
        #expect(!rectangle.needsLargerBoardSetting)
    }

    @Test func raisableBoardStillPointsAtTheSetting() {
        // The board fits within the net's cap — raising the setting works.
        let item = make(width: 25, height: 25,
                        maxBoardLength: 19, modelBoardCap: 37)
        #expect(item.needsLargerBoardSetting)
        #expect(!item.needsDifferentNet)
    }

    @Test func unknownSizeIsOptimisticallySelectable() {
        let item = make(lastModificationDate: nil, width: nil, height: nil)
        #expect(item.isSelectable)
        #expect(item.detailText.isEmpty)

        // A half-known size is still unknown.
        #expect(make(width: 19, height: nil).isSelectable)
        #expect(!make(width: 19, height: nil).detailText.contains("19"))
    }

    @Test func detailTextComposesDateAndSize() {
        let now = Date.now
        let recent = now.addingTimeInterval(-60 * 60)
        let item = make(lastModificationDate: recent, width: 19, height: 19, now: now)
        let expectedDate = recent.formatted(date: .omitted, time: .shortened)
        #expect(item.detailText == "\(expectedDate) · 19×19")
    }

    @Test func detailTextOmitsMissingParts() {
        let now = Date.now
        let recent = now.addingTimeInterval(-60 * 60)
        let expectedDate = recent.formatted(date: .omitted, time: .shortened)

        #expect(make(lastModificationDate: recent, now: now).detailText == expectedDate)
        #expect(make(width: 13, height: 9).detailText == "13×9")
        #expect(make().detailText.isEmpty)
    }

    @Test func titlePassesThroughName() {
        #expect(make(name: "Friendly Match").title == "Friendly Match")
    }
}
