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
public struct ProjectionInputs: Equatable, Sendable {
    public let sourcePath: String
    public let nnXLen: Int32
    public let nnYLen: Int32
    public let requireExactNNLen: Bool
    public let useFP16: Bool
    public let maxBatchSize: Int

    public init(sourcePath: String,
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

/// File name of the bundled human-SL auxiliary network. The engine loads it
/// alongside the user-selected model on every launch (`KataGoHelper.runGtp`),
/// unless `includeHumanNet:false` is passed (e.g., iOS Safari appex), so it is
/// converted and cached too.
public let humanSLAuxFileName = "b18c384nbt-humanv0.bin.gz"

/// Projection for the selected model itself.
///
/// Returns nil when the source file is not on disk — the "not downloaded
/// yet" case for catalog networks, which callers must treat as an absence
/// rather than an error.
public func mainNetProjection(for model: NeuralNetworkModel) -> ProjectionInputs? {
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

/// Projection for the bundled human-SL auxiliary network, keyed to the
/// settings of `selectedModel`.
///
/// `maxBoardSizeForNNBuffer` is engine-WIDE: `ModelRunnerView` passes the
/// SELECTED model's `effectiveMaxBoardLength`, and every net the launch
/// loads — main and aux alike — is converted at that one geometry. So the
/// aux entry's cache key follows whichever model is selected, NOT the
/// built-in's settings. This is the single implementation of that rule;
/// anything needing the aux digest must come through here rather than
/// recomputing it, or the two copies will drift.
public func auxNetProjection(keyedTo selectedModel: NeuralNetworkModel) -> ProjectionInputs? {
    guard let bundlePath = Bundle.main.path(
        forResource: "b18c384nbt-humanv0",
        ofType: "bin.gz")
    else { return nil }
    let settings = BackendSettings(model: selectedModel)
    let nnLen = Int32(settings.effectiveMaxBoardLength)
    return ProjectionInputs(
        sourcePath: bundlePath,
        nnXLen: nnLen,
        nnYLen: nnLen,
        requireExactNNLen: settings.requireExactNNLen,
        useFP16: true,
        maxBatchSize: KataGoHelper.mlxNnMaxBatchSize)
}

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
        // The aux net has no model of its own to be selected, and readiness
        // has no selection context — it is handed the picker's visible
        // filenames, which never include the aux net. Key it to the built-in
        // as the documented fallback. Callers that DO know the selection
        // (e.g. `CoreMLRoutingProbe`) must call `auxNetProjection(keyedTo:)`
        // with it directly; both paths share that one implementation.
        if fileName == humanSLAuxFileName {
            guard let builtIn = NeuralNetworkModel.builtInModel else { return nil }
            return auxNetProjection(keyedTo: builtIn)
        }

        guard let model = NeuralNetworkModel.allAvailable.first(where: { $0.fileName == fileName })
        else { return nil }

        return mainNetProjection(for: model)
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
