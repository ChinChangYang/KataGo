//
//  BackendSettingsTests.swift
//  KataGo AnytimeTests
//
//  BackendSettings drives a per-model backend choice (MLX/GPU, CoreML/NE, or a
//  GPU+ANE mux) plus a per-model search-thread count. The effective NN-buffer
//  board length keys off the single `mlxBoardSize`, and `requireExactNNLen` is
//  always false. The device assignment (one NN-server-thread device code per
//  element) is derived from the selected backend.
//

import Foundation
import Testing
import KataGoUICore

struct BackendSettingsTests {
    /// A throwaway model with a unique fileName so each test owns its own
    /// per-model UserDefaults keys (`BackendSettings` keys off `model.fileName`).
    /// Avoids cross-test contamination under Swift Testing's parallel runner.
    private func uniqueModel(nnLen: Int = 37) -> NeuralNetworkModel {
        NeuralNetworkModel(title: "Test", description: "", url: "",
                           fileName: "backend-settings-test-\(UUID().uuidString).bin.gz",
                           fileSize: 0, builtIn: false, nnLen: nnLen)
    }

    /// The engine-wide NN buffer geometry keys off the single `mlxBoardSize`
    /// regardless of the selected backend.
    @Test func effectiveMaxBoardLengthTracksMaxBoardSize() {
        var settings = BackendSettings(model: uniqueModel(nnLen: 37))
        settings.mlxBoardSize = .thirteen
        #expect(settings.effectiveMaxBoardLength == 13)
        settings.mlxBoardSize = .nineteen
        #expect(settings.effectiveMaxBoardLength == 19)
    }

    /// The board size is clamped to the model's neural-net length.
    @Test func effectiveMaxBoardLengthClampsToModelNNLen() {
        var settings = BackendSettings(model: uniqueModel(nnLen: 9))
        settings.mlxBoardSize = .thirtySevenMax
        #expect(settings.effectiveMaxBoardLength == 9)
    }

    /// Every backend path uses a non-exact NN length, so this is always false.
    @Test func requireExactNNLenIsAlwaysFalse() {
        let settings = BackendSettings(model: uniqueModel())
        #expect(settings.requireExactNNLen == false)
    }

    /// A fresh model defaults to single CoreML/ANE (verified best on an iPad
    /// A17 Pro run); the user can opt into MLX/GPU or the GPU+ANE mux.
    @Test func backendDefaultsToCoreMLNE() {
        let settings = BackendSettings(model: uniqueModel())
        #expect(settings.backend == .coremlNE)
    }

    /// The chosen backend persists per model.
    @Test func backendPersists() {
        let model = uniqueModel()
        var settings = BackendSettings(model: model)
        settings.backend = .coremlNE
        #expect(BackendSettings(model: model).backend == .coremlNE)
        settings.backend = .mlxGPU
        #expect(BackendSettings(model: model).backend == .mlxGPU)
    }

    /// Search threads default to the platform starting point.
    @Test func numSearchThreadsDefaultsToPlatformValue() {
        let settings = BackendSettings(model: uniqueModel())
        #expect(settings.numSearchThreads == KataGoHelper.mlxNumSearchThreads)
    }

    /// On iOS/visionOS (where the test suite runs) the platform starting point
    /// is 2 search threads — the value verified best on an iPad A17 Pro run.
    @Test func numSearchThreadsDefaultsToTwoOnIOS() {
        let settings = BackendSettings(model: uniqueModel())
        #expect(settings.numSearchThreads == 2)
    }

    /// The chosen search-thread count persists per model.
    @Test func numSearchThreadsPersists() {
        let model = uniqueModel()
        var settings = BackendSettings(model: model)
        settings.numSearchThreads = 4
        #expect(BackendSettings(model: model).numSearchThreads == 4)
    }

    /// Out-of-range search-thread values are clamped into `1...maxSearchThreads`.
    @Test func numSearchThreadsClampsOutOfRange() {
        let model = uniqueModel()
        var settings = BackendSettings(model: model)
        settings.numSearchThreads = 999
        #expect(BackendSettings(model: model).numSearchThreads == BackendChoice.maxSearchThreads)
        settings.numSearchThreads = 0
        #expect(BackendSettings(model: model).numSearchThreads == 1)
    }

    /// The device assignment mirrors the selected backend's mapping.
    @Test func deviceAssignmentsFollowBackendChoice() {
        let model = uniqueModel()
        var settings = BackendSettings(model: model)
        settings.backend = .mux
        #expect(settings.deviceAssignments == BackendChoice.mux.deviceAssignments)
        settings.backend = .coremlNE
        #expect(settings.deviceAssignments == BackendChoice.coremlNE.deviceAssignments)
    }
}

/// `BackendChoice` maps each user-facing backend to the NN-server-thread device
/// array the engine launches with. These tests run on the iOS Simulator — whose
/// Metal layer crashes inside MLX GPU inference — so they verify every choice
/// clamps the MLX/GPU device (0) out on the simulator.
struct BackendChoiceTests {
    @Test func hasThreeChoices() {
        #expect(BackendChoice.allCases.count == 3)
        #expect(BackendChoice.allCases.contains(.mux))
    }

    @Test func deviceAssignmentsNeverIncludeGPUOnSimulator() {
        for choice in BackendChoice.allCases {
            let devices = choice.deviceAssignments
            #expect(!devices.isEmpty)
            #expect(!devices.contains(0))
            #expect(devices.allSatisfy { $0 == 0 || $0 == 100 })
        }
    }

    @Test func deviceAssignmentThreadCounts() {
        #expect(BackendChoice.mlxGPU.deviceAssignments.count == 1)
        #expect(BackendChoice.coremlNE.deviceAssignments.count == 1)
        #expect(BackendChoice.mux.deviceAssignments.count == 2)
    }

    @Test func deviceAssignmentExactMappingPerPlatform() {
        #if targetEnvironment(simulator)
        #expect(BackendChoice.mlxGPU.deviceAssignments == [100])
        #expect(BackendChoice.coremlNE.deviceAssignments == [100])
        #expect(BackendChoice.mux.deviceAssignments == [100, 100])
        #else
        #expect(BackendChoice.mlxGPU.deviceAssignments == [0])
        #expect(BackendChoice.coremlNE.deviceAssignments == [100])
        #expect(BackendChoice.mux.deviceAssignments == [0, 100])
        #endif
    }
}

/// The board-too-large gate predicate (tvOS: skip loading a game whose board
/// exceeds the running engine's NN-buffer size — an oversized board aborts the
/// process on the first analysis). Equal is allowed; strictly-greater in EITHER
/// dimension is not (matches the C++ `board.x_size > nnXLen` throw).
struct BoardFitsTests {
    @Test func equalAndSmallerFit() {
        #expect(boardFits(width: 19, height: 19, maxBoardLength: 19))
        #expect(boardFits(width: 9, height: 9, maxBoardLength: 19))
        #expect(boardFits(width: 13, height: 13, maxBoardLength: 37))
    }

    @Test func largerInEitherDimensionDoesNotFit() {
        #expect(!boardFits(width: 25, height: 25, maxBoardLength: 19))
        #expect(!boardFits(width: 37, height: 19, maxBoardLength: 19))   // width only
        #expect(!boardFits(width: 19, height: 37, maxBoardLength: 19))   // height only
    }
}
