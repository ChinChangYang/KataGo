//
//  VisionModelDetailStateTests.swift
//  KataGo AnytimeTests
//
//  Pins the pure detail-page state behind the visionOS model detail view —
//  the Vision mirror of iOS ModelDetailView: the tri-state primary button
//  (activate / download / stop-with-progress), the trash affordance for
//  downloaded non-built-in nets, and the size line (empty for the
//  built-in, humanFileSize otherwise — ported here because iOS's
//  formatter is app-target-private).
//

import Testing
@testable import KataGoUICore

struct VisionModelDetailStateTests {
    private func make(isBuiltIn: Bool = false,
                      fileSize: Int = 863_846_339,
                      isDownloaded: Bool = false,
                      isDownloading: Bool = false,
                      isActive: Bool = false,
                      engineIsRunning: Bool = true) -> VisionModelDetailState {
        VisionModelDetailState.make(isBuiltIn: isBuiltIn,
                                    fileSize: fileSize,
                                    isDownloaded: isDownloaded,
                                    isDownloading: isDownloading,
                                    isActive: isActive,
                                    engineIsRunning: engineIsRunning)
    }

    @Test func downloadedModelOffersActivate() {
        let state = make(isDownloaded: true)
        #expect(state.primary == .activate)
        #expect(state.primarySystemImage == "play.fill")
        #expect(!state.primaryDisabled)
        #expect(state.showsTrash)
    }

    @Test func builtInCountsAsDownloaded() {
        let state = make(isBuiltIn: true)
        #expect(state.primary == .activate)
        #expect(!state.showsTrash)
        #expect(state.sizeText.isEmpty)
    }

    @Test func notDownloadedOffersDownload() {
        let state = make()
        #expect(state.primary == .download)
        #expect(state.primarySystemImage == "arrow.down")
        #expect(!state.primaryDisabled)
        #expect(!state.showsTrash)
    }

    @Test func downloadingOffersStop() {
        let state = make(isDownloading: true)
        #expect(state.primary == .stopDownload)
        #expect(state.primarySystemImage == "stop.circle")
        #expect(!state.primaryDisabled)
    }

    @Test func activateDisablesForTheActiveModel() {
        let state = make(isDownloaded: true, isActive: true)
        #expect(state.primary == .activate)
        #expect(state.primaryDisabled)
    }

    @Test func activateDisablesWhileTheEngineIsDown() {
        // R8: a restart's teardown can take minutes; activation must wait
        // for phase == .running (matching the Settings pickers).
        let state = make(isDownloaded: true, engineIsRunning: false)
        #expect(state.primary == .activate)
        #expect(state.primaryDisabled)
    }

    @Test func downloadNeverWaitsForTheEngine() {
        let state = make(engineIsRunning: false)
        #expect(state.primary == .download)
        #expect(!state.primaryDisabled)
    }

    @Test func sizeTextMatchesTheiOSFormatter() {
        #expect(VisionModelDetailState.humanFileSize(0) == "0 B")
        #expect(VisionModelDetailState.humanFileSize(1023) == "1023.00 B")
        #expect(VisionModelDetailState.humanFileSize(1024) == "1.00 kB")
        #expect(VisionModelDetailState.humanFileSize(1536) == "1.50 kB")
        #expect(VisionModelDetailState.humanFileSize(1_048_576) == "1.00 MB")
        #expect(make(fileSize: 1_048_576).sizeText == "1.00 MB")
    }
}
