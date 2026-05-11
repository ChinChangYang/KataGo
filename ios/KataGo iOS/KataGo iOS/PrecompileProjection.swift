//
//  PrecompileProjection.swift
//  KataGo Anytime
//
//  App-side mapping from a model `fileName` to the primitive inputs
//  needed by `CoreMLModelCache.projectedDigest` / `CoreMLModelCache.warm`.
//
//  Keeps the `KataGoInterface` framework ignorant of app-target types
//  like `BackendSettings` and `NeuralNetworkModel`.
//

import Foundation
import KataGoInterface

/// Primitive inputs for `CoreMLModelCache.projectedDigest` /
/// `CoreMLModelCache.warm`. Keeps the framework ignorant of
/// app-target types like `BackendSettings` and `NeuralNetworkModel`.
struct ProjectionInputs: Equatable {
    let sourcePath: String
    let nnXLen: Int32
    let nnYLen: Int32
    let requireExactNNLen: Bool
    let useFP16: Bool
    let maxBatchSize: Int
}

typealias ProjectionResolver = (_ fileName: String) -> ProjectionInputs?

/// Production resolver. Walks `NeuralNetworkModel.allCases` to find
/// the named model, computes its `BackendSettings`, and maps to the
/// engine-launch primitives. Returns nil if the file is not present
/// on disk (pre-download for non-built-in models).
///
/// NOTE: `useFP16` and `maxBatchSize` must match what the C++ launch
/// path computes. `useFP16 = true` and `maxBatchSize = 1` are the
/// values the cooperative-pool launch uses on iOS Apple Silicon
/// today. If those defaults change, this resolver must change with
/// them, otherwise the projection drifts from the launch's actual
/// cache key.
func makeProjectionResolver() -> ProjectionResolver {
    return { fileName in
        guard let model = NeuralNetworkModel.allCases.first(where: { $0.fileName == fileName })
        else { return nil }

        let sourcePath: String
        if model.builtIn {
            // Built-in model lives in the bundle. Mirror the exact
            // lookup used at engine launch (see
            // `ModelRunnerView.onChange(of: selectedModel)`) so the
            // cache key matches.
            guard let bundlePath = Bundle.main.path(
                forResource: "default_model",
                ofType: "bin.gz")
            else { return nil }
            sourcePath = bundlePath
        } else {
            guard let downloaded = model.downloadedURL,
                  FileManager.default.fileExists(atPath: downloaded.path)
            else { return nil }
            sourcePath = downloaded.path
        }

        let settings = BackendSettings(model: model)
        let nnLen = Int32(settings.effectiveMaxBoardLength)
        return ProjectionInputs(
            sourcePath: sourcePath,
            nnXLen: nnLen,
            nnYLen: nnLen,
            requireExactNNLen: settings.requireExactNNLen,
            useFP16: true,           // iOS Apple Silicon default
            maxBatchSize: 1)         // iOS default
    }
}
