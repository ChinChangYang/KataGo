//
//  VisionModelListItemTests.swift
//  KataGo AnytimeTests
//
//  Pins the pure row view-model behind the visionOS Models card list —
//  the Vision mirror of iOS ModelPickerView rows: every visible,
//  platform-eligible registry model in order, the active indicator keyed
//  by title, and the green Core ML cache-ready checkmark keyed by
//  fileName.
//

import Testing
@testable import KataGoUICore

struct VisionModelListItemTests {
    @Test func everyRegistryModelGetsARow() {
        let items = VisionModelListItem.makeAll(activeTitle: "",
                                                readyFileNames: [])
        // The full registry: visionOS (like iOS) restricts nothing.
        #expect(items.count == NeuralNetworkModel.allCases.count)
        #expect(items.map(\.title) == NeuralNetworkModel.allCases.map(\.title))
        #expect(items.allSatisfy { !$0.isActive && !$0.showsReadyCheckmark })
    }

    @Test func activeFlagKeysOnTheTitle() {
        let official = NeuralNetworkModel.allCases.first { !$0.builtIn }!
        let items = VisionModelListItem.makeAll(activeTitle: official.title,
                                                readyFileNames: [])
        #expect(items.first { $0.isActive }?.title == official.title)
        #expect(items.filter(\.isActive).count == 1)
    }

    @Test func readyCheckmarkKeysOnTheFileName() {
        let builtIn = NeuralNetworkModel.builtInModel!
        let items = VisionModelListItem.makeAll(
            activeTitle: "",
            readyFileNames: [builtIn.fileName])
        #expect(items.first { $0.showsReadyCheckmark }?.title == builtIn.title)
        #expect(items.filter(\.showsReadyCheckmark).count == 1)
    }

    @Test func rowIdentityIsTheTitle() {
        let items = VisionModelListItem.makeAll(activeTitle: "",
                                                readyFileNames: [])
        #expect(items.allSatisfy { $0.id == $0.title })
    }
}
