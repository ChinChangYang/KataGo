//
//  VisionModelBootResolverTests.swift
//  KataGo AnytimeTests
//
//  Pins the pure boot-time model resolution for visionOS: the shared
//  RecoveryDecision contract (iOS ModelRunnerView / Mac decideRecovery)
//  mapped onto a target with no picker screen — every .showPicker outcome
//  lands on the built-in net, and an auto-restore of a net whose file
//  vanished from Documents falls back to the built-in instead of
//  crash-looping the headless engine boot.
//

import Testing
@testable import KataGoUICore

struct VisionModelBootResolverTests {
    private var official: NeuralNetworkModel {
        NeuralNetworkModel.allCases.first { !$0.builtIn }!
    }

    @Test func survivingSentinelFallsBackToBuiltInAndFlags() {
        let resolution = VisionModelBootResolver.resolve(
            pendingLoadModelTitle: official.title,
            selectedModelTitle: official.title,
            isDebug: false,
            isFileDownloaded: { _ in true })
        #expect(resolution.model.builtIn)
        #expect(resolution.fellBackFromIncompleteLoad)
    }

    @Test func debugAlwaysBootsBuiltIn() {
        // Exact Mac parity: RecoveryDecision returns .showPicker in Debug,
        // and Vision's "picker fallback" is the built-in net.
        let resolution = VisionModelBootResolver.resolve(
            pendingLoadModelTitle: "",
            selectedModelTitle: official.title,
            isDebug: true,
            isFileDownloaded: { _ in true })
        #expect(resolution.model.builtIn)
        #expect(!resolution.fellBackFromIncompleteLoad)
    }

    @Test func emptySelectionBootsBuiltIn() {
        let resolution = VisionModelBootResolver.resolve(
            pendingLoadModelTitle: "",
            selectedModelTitle: "",
            isDebug: false,
            isFileDownloaded: { _ in true })
        #expect(resolution.model.builtIn)
        #expect(!resolution.fellBackFromIncompleteLoad)
    }

    @Test func selectedDownloadedNetAutoRestores() {
        let resolution = VisionModelBootResolver.resolve(
            pendingLoadModelTitle: "",
            selectedModelTitle: official.title,
            isDebug: false,
            isFileDownloaded: { $0.title == official.title })
        #expect(resolution.model.title == official.title)
        #expect(!resolution.fellBackFromIncompleteLoad)
    }

    @Test func missingFileFallsBackToBuiltIn() {
        let resolution = VisionModelBootResolver.resolve(
            pendingLoadModelTitle: "",
            selectedModelTitle: official.title,
            isDebug: false,
            isFileDownloaded: { _ in false })
        #expect(resolution.model.builtIn)
        #expect(!resolution.fellBackFromIncompleteLoad)
    }

    @Test func unknownTitleFallsBackToBuiltIn() {
        let resolution = VisionModelBootResolver.resolve(
            pendingLoadModelTitle: "",
            selectedModelTitle: "No Such Network",
            isDebug: false,
            isFileDownloaded: { _ in true })
        #expect(resolution.model.builtIn)
        #expect(!resolution.fellBackFromIncompleteLoad)
    }

    @Test func builtInSelectionNeverConsultsTheDisk() {
        let builtIn = NeuralNetworkModel.builtInModel!
        let resolution = VisionModelBootResolver.resolve(
            pendingLoadModelTitle: "",
            selectedModelTitle: builtIn.title,
            isDebug: false,
            isFileDownloaded: { _ in
                Issue.record("built-in must not hit the file system")
                return false
            })
        #expect(resolution.model.builtIn)
    }
}
