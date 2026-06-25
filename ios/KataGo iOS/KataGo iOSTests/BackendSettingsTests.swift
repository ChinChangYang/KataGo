//
//  BackendSettingsTests.swift
//  KataGo AnytimeTests
//
//  BackendSettings now drives a fixed GPU+ANE mux (the per-model backend
//  picker is gone): the effective NN-buffer board length keys off the single
//  `mlxBoardSize`, and `requireExactNNLen` is always false.
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

    /// The mux always runs an MLX/GPU server thread, so the engine-wide NN
    /// buffer geometry keys off the single `mlxBoardSize` regardless of any
    /// (now-removed) per-model backend choice.
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

    /// Both backend paths use a non-exact NN length, so this is always false.
    @Test func requireExactNNLenIsAlwaysFalse() {
        let settings = BackendSettings(model: uniqueModel())
        #expect(settings.requireExactNNLen == false)
    }
}
