//
//  VisionModelBootResolverTests.swift
//  KataGo AnytimeTests
//
//  Pins the pure boot-time model resolution for visionOS: the shared
//  RecoveryDecision contract (iOS ModelRunnerView / Mac decideRecovery)
//  mapped onto ornament-based UI. A surviving load sentinel resolves to
//  .chooseModel — the iOS picker design: NO engine boots and the Models
//  card presents as a neutral chooser (never auto-restoring a net whose
//  load just crashed). Everything else boots headlessly: Debug and empty
//  selections boot the built-in, an auto-restore whose downloaded file
//  vanished from Documents falls back to the built-in.
//

import Testing
@testable import KataGoUICore

struct VisionModelBootResolverTests {
    private var official: NeuralNetworkModel {
        NeuralNetworkModel.allCases.first { !$0.builtIn }!
    }

    private func bootedModel(
        _ resolution: VisionModelBootResolver.Resolution
    ) -> NeuralNetworkModel? {
        if case .boot(let model) = resolution { return model }
        return nil
    }

    @Test func survivingSentinelShowsTheChooser() {
        let resolution = VisionModelBootResolver.resolve(
            pendingLoadModelTitle: official.title,
            selectedModelTitle: official.title,
            isDebug: false,
            isFileDownloaded: { _ in true })
        guard case .chooseModel = resolution else {
            Issue.record("expected .chooseModel, got \(resolution)")
            return
        }
    }

    @Test func survivingSentinelShowsTheChooserEvenInDebug() {
        // RecoveryDecision checks the sentinel before the Debug clause.
        let resolution = VisionModelBootResolver.resolve(
            pendingLoadModelTitle: official.title,
            selectedModelTitle: "",
            isDebug: true,
            isFileDownloaded: { _ in true })
        guard case .chooseModel = resolution else {
            Issue.record("expected .chooseModel, got \(resolution)")
            return
        }
    }

    @Test func debugBootsBuiltIn() {
        // Mac parity for a clean Debug boot: headless built-in, no chooser
        // (keeps the sim QA tooling boot-to-board).
        let resolution = VisionModelBootResolver.resolve(
            pendingLoadModelTitle: "",
            selectedModelTitle: official.title,
            isDebug: true,
            isFileDownloaded: { _ in true })
        #expect(bootedModel(resolution)?.builtIn == true)
    }

    @Test func emptySelectionBootsBuiltIn() {
        let resolution = VisionModelBootResolver.resolve(
            pendingLoadModelTitle: "",
            selectedModelTitle: "",
            isDebug: false,
            isFileDownloaded: { _ in true })
        #expect(bootedModel(resolution)?.builtIn == true)
    }

    @Test func selectedDownloadedNetAutoRestores() {
        let resolution = VisionModelBootResolver.resolve(
            pendingLoadModelTitle: "",
            selectedModelTitle: official.title,
            isDebug: false,
            isFileDownloaded: { $0.title == official.title })
        #expect(bootedModel(resolution)?.title == official.title)
    }

    @Test func missingFileFallsBackToBuiltIn() {
        let resolution = VisionModelBootResolver.resolve(
            pendingLoadModelTitle: "",
            selectedModelTitle: official.title,
            isDebug: false,
            isFileDownloaded: { _ in false })
        #expect(bootedModel(resolution)?.builtIn == true)
    }

    @Test func unknownTitleFallsBackToBuiltIn() {
        let resolution = VisionModelBootResolver.resolve(
            pendingLoadModelTitle: "",
            selectedModelTitle: "No Such Network",
            isDebug: false,
            isFileDownloaded: { _ in true })
        #expect(bootedModel(resolution)?.builtIn == true)
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
        #expect(bootedModel(resolution)?.builtIn == true)
    }
}
