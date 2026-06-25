//
//  CoreMLCacheReadinessProjection.swift
//  KataGo Anytime
//
//  App-side mapping from a model `fileName` to the primitive inputs
//  needed by `CoreMLModelCache.projectedDigest`. Used by
//  `CoreMLCacheReadiness` to decide whether a row's green checkmark
//  should show in the model picker.
//
//  Keeps the `KataGoInterface` framework ignorant of app-target types
//  like `BackendSettings` and `NeuralNetworkModel`.
//

import CoreMLCacheKit
import Foundation

/// Primitive inputs for `CoreMLModelCache.projectedDigest`.
/// Keeps the framework ignorant of app-target types like
/// `BackendSettings` and `NeuralNetworkModel`.
struct ProjectionInputs: Equatable {
    let sourcePath: String
    let nnXLen: Int32
    let nnYLen: Int32
    let requireExactNNLen: Bool
    let useFP16: Bool
    let maxBatchSize: Int

    init(sourcePath: String,
         nnXLen: Int32,
         nnYLen: Int32,
         requireExactNNLen: Bool,
         useFP16: Bool,
         maxBatchSize: Int) {
        self.sourcePath = sourcePath
        self.nnXLen = nnXLen
        self.nnYLen = nnYLen
        self.requireExactNNLen = requireExactNNLen
        self.useFP16 = useFP16
        self.maxBatchSize = maxBatchSize
    }
}

typealias ProjectionResolver = @Sendable (_ fileName: String) -> ProjectionInputs?

/// Production resolver. Walks `NeuralNetworkModel.allCases` to find
/// the named model, computes its `BackendSettings`, and maps to the
/// engine-launch primitives. Returns nil if the file is not present
/// on disk (pre-download for non-built-in models).
///
/// NOTE: `useFP16` and `maxBatchSize` must match what the C++ launch
/// path computes. `useFP16 = true` is the iOS Apple Silicon default;
/// `maxBatchSize` references `KataGoHelper.mlxNnMaxBatchSize` — the same
/// constant the engine launch passes as `nnMaxBatchSize` — so the
/// projection cannot drift from the launch's actual cache key.
func makeProjectionResolver() -> ProjectionResolver {
    return { fileName in
        // Human SL aux is bundled and shares the built-in's backend
        // settings (the engine loads them together with the same nnLen
        // and same fp16/maxBatchSize). Project its digest against the
        // built-in's settings so the cached aux entry is reused verbatim
        // when the user selects the built-in.
        if fileName == "b18c384nbt-humanv0.bin.gz" {
            guard let bundlePath = Bundle.main.path(
                    forResource: "b18c384nbt-humanv0",
                    ofType: "bin.gz"),
                  let builtIn = NeuralNetworkModel.builtInModel
            else { return nil }
            let settings = BackendSettings(model: builtIn)
            let nnLen = Int32(settings.effectiveMaxBoardLength)
            return ProjectionInputs(
                sourcePath: bundlePath,
                nnXLen: nnLen,
                nnYLen: nnLen,
                requireExactNNLen: settings.requireExactNNLen,
                useFP16: true,
                maxBatchSize: KataGoHelper.mlxNnMaxBatchSize)
        }

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
            maxBatchSize: KataGoHelper.mlxNnMaxBatchSize)
    }
}

/// Returns a digest-only closure that maps a fileName to the cache
/// digest the next engine launch would compute. Used by
/// `CoreMLCacheReadiness` to ask `CoreMLModelCache.hasEntry(digest:)`
/// whether a given fileName is currently cached on disk.
/// Returns nil when the file is not downloaded.
func makeProjectionDigestFor() -> @Sendable (String) async throws -> String? {
    let resolver = makeProjectionResolver()
    return { fileName in
        guard let inputs = resolver(fileName) else { return nil }
        return try await CoreMLModelCache.projectedDigest(
            forSourcePath: inputs.sourcePath,
            nnXLen: inputs.nnXLen, nnYLen: inputs.nnYLen,
            requireExactNNLen: inputs.requireExactNNLen,
            useFP16: inputs.useFP16,
            maxBatchSize: inputs.maxBatchSize,
            downloadedHasher: BinFileHasher.shared.identityForDownloadedFile)
    }
}
