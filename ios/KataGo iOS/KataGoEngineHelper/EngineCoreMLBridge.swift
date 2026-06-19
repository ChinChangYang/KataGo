//
//  EngineCoreMLBridge.swift
//  KataGo Engine Helper (katago-engine)
//
//  Installs the persistent Core ML cache into the headless engine subprocess.
//  The macOS app spawns this helper as a separate process; the in-process
//  `katago_coreml_bridge` seam the app installs via `registerCoreMLBridge()`
//  does NOT cross the process boundary, so without this the MLX backend's ANE
//  path re-converts + recompiles Core ML to /tmp on EVERY launch
//  (mlxbackend.cpp: "CoreML bridge not registered, using direct-compile path").
//
//  This is the headless counterpart of the app target's
//  `CoreMLComputeHandleLoader.swift`: same cache-aware load + timeout/fallback
//  + one-shot corrupt-hit retry, minus the `EngineLaunchStatus` UI reporting
//  (the subprocess has no UI). `main.cpp` calls `katago_register_coreml_bridge`
//  once before `MainCmds::gtp`.

import CoreML
import CoreMLCacheKit
import Foundation
import KataGoSwift

// C bridge into katago.framework (mlxbackend.cpp / metalbackend.cpp).
@_silgen_name("katagocoreml_convert_to_temp")
private func katagocoreml_convert_to_temp(
    _ modelPath: UnsafePointer<CChar>,
    _ boardX: Int32, _ boardY: Int32,
    _ useFP16: Bool, _ optimizeMask: Bool,
    _ maxBatchSize: Int32, _ serverThreadIdx: Int32
) -> UnsafePointer<CChar>?

@_silgen_name("katagocoreml_free_string")
private func katagocoreml_free_string(_ s: UnsafePointer<CChar>?)

/// Cache-aware compute-handle loader for the headless engine subprocess.
/// Mirrors the app target's `loadCoreMLHandle`, minus the LoadingView status
/// reporting. One-shot corrupt-hit retry around `MLModel(contentsOf:)`.
private func loadCoreMLHandle(
    coremlModelPath: String,
    serverThreadIdx: Int,
    requireExactNNLen: Bool,
    numInputChannels: Int32,
    numInputGlobalChannels: Int32,
    numInputMetaChannels: Int32,
    numPolicyChannels: Int32,
    numValueChannels: Int32,
    numScoreValueChannels: Int32,
    numOwnershipChannels: Int32,
    context: MetalComputeContext,
    maxBatchSize: Int
) async throws -> CoreMLComputeHandle? {
    let useFP16 = context.useFP16
    let optimizeMask = requireExactNNLen
    let nnXLen = context.nnXLen
    let nnYLen = context.nnYLen
    let key = try await CoreMLModelCache.cacheKey(
        forSourcePath: coremlModelPath,
        nnXLen: nnXLen, nnYLen: nnYLen,
        requireExactNNLen: optimizeMask, useFP16: useFP16,
        maxBatchSize: maxBatchSize,
        downloadedHasher: { url in
            try await BinFileHasher.shared.identityForDownloadedFile(url)
        })
    let cache = CoreMLModelCache.shared
    await cache.start()

    let sourceFileName = (coremlModelPath as NSString).lastPathComponent
    for attempt in 0..<2 {
        let pinned = try await cache.urlForKey(
            digest: key.digest,
            priority: .userInitiated,
            sourceFileName: sourceFileName,
            missCallback: {
                return try await convertOnCooperativePool(
                    coremlModelPath: coremlModelPath,
                    boardX: nnXLen, boardY: nnYLen,
                    useFP16: useFP16, optimizeMask: optimizeMask,
                    maxBatchSize: Int32(maxBatchSize),
                    serverThreadIdx: Int32(serverThreadIdx))
            })
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            let model = try MLModel(contentsOf: pinned.url, configuration: config)
            return CoreMLComputeHandle(
                model: model,
                nnXLen: context.nnXLen,
                nnYLen: context.nnYLen,
                optimizeIdentityMask: optimizeMask,
                numInputChannels: Int(numInputChannels),
                numInputGlobalChannels: Int(numInputGlobalChannels),
                numInputMetaChannels: Int(numInputMetaChannels),
                numPolicyChannels: Int(numPolicyChannels),
                numValueChannels: Int(numValueChannels),
                numScoreValueChannels: Int(numScoreValueChannels),
                numOwnershipChannels: Int(numOwnershipChannels),
                releaseHook: { await pinned.release() })
        } catch {
            await pinned.release()
            await cache.invalidate(digest: pinned.digest, epoch: pinned.epoch)
            if attempt == 1 { throw error }
        }
    }
    fatalError("unreachable: for-loop bound is fixed at 2")
}

/// Run the C++ converter on the cooperative pool, then compile to `.mlmodelc/`
/// so the cache can store the compiled artifact (matches the app loader).
private func convertOnCooperativePool(
    coremlModelPath: String,
    boardX: Int32, boardY: Int32,
    useFP16: Bool, optimizeMask: Bool,
    maxBatchSize: Int32, serverThreadIdx: Int32
) async throws -> URL {
    let mlpackageURL = try await Task.detached(priority: .userInitiated) { () throws -> URL in
        let url = coremlModelPath.withCString { cstr -> URL? in
            guard let outCstr = katagocoreml_convert_to_temp(
                cstr, boardX, boardY, useFP16, optimizeMask,
                maxBatchSize, serverThreadIdx) else { return nil }
            defer { katagocoreml_free_string(outCstr) }
            return URL(fileURLWithPath: String(cString: outCstr))
        }
        guard let url else {
            throw NSError(domain: "katagocoreml", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "conversion failed"])
        }
        return url
    }.value
    return try await MLModel.compileModel(at: mlpackageURL)
}

// Thread-safe result box (writes happen-before signal; reads happen-after wait).
private final class ResultBox: @unchecked Sendable {
    nonisolated(unsafe) var value: Result<CoreMLComputeHandle?, Error>? = nil
}

/// Synchronous bridge wrapper driven by `mlxbackend.cpp`. 600s primary + 60s
/// secondary wait, then cancels and falls back to the legacy direct-compile.
private func loadCoreMLHandleWithBridgeTimeout(
    coremlModelPath: String,
    serverThreadIdx: Int,
    requireExactNNLen: Bool,
    numInputChannels: Int32,
    numInputGlobalChannels: Int32,
    numInputMetaChannels: Int32,
    numPolicyChannels: Int32,
    numValueChannels: Int32,
    numScoreValueChannels: Int32,
    numOwnershipChannels: Int32,
    context: MetalComputeContext,
    maxBatchSize: Int
) -> CoreMLComputeHandle? {
    let sem = DispatchSemaphore(value: 0)
    let box = ResultBox()
    let nnXLen = context.nnXLen
    let nnYLen = context.nnYLen
    let useFP16 = context.useFP16

    let task = Task.detached(priority: .userInitiated) {
        do {
            box.value = .success(try await loadCoreMLHandle(
                coremlModelPath: coremlModelPath,
                serverThreadIdx: serverThreadIdx,
                requireExactNNLen: requireExactNNLen,
                numInputChannels: numInputChannels,
                numInputGlobalChannels: numInputGlobalChannels,
                numInputMetaChannels: numInputMetaChannels,
                numPolicyChannels: numPolicyChannels,
                numValueChannels: numValueChannels,
                numScoreValueChannels: numScoreValueChannels,
                numOwnershipChannels: numOwnershipChannels,
                context: MetalComputeContext(nnXLen: nnXLen, nnYLen: nnYLen, useFP16: useFP16),
                maxBatchSize: maxBatchSize))
        } catch {
            box.value = .failure(error)
        }
        sem.signal()
    }

    if sem.wait(timeout: .now() + .seconds(600)) == .timedOut {
        let secondary = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) { await task.value; secondary.signal() }
        if secondary.wait(timeout: .now() + .seconds(60)) == .timedOut {
            task.cancel()
            return createCoreMLComputeHandle(
                coremlModelPath: coremlModelPath,
                serverThreadIdx: serverThreadIdx,
                requireExactNNLen: requireExactNNLen,
                numInputChannels: numInputChannels,
                numInputGlobalChannels: numInputGlobalChannels,
                numInputMetaChannels: numInputMetaChannels,
                numPolicyChannels: numPolicyChannels,
                numValueChannels: numValueChannels,
                numScoreValueChannels: numScoreValueChannels,
                numOwnershipChannels: numOwnershipChannels,
                context: context)
        }
    }

    switch box.value {
    case .success(let h)?: return h
    case .failure?: return nil
    case nil: return nil
    }
}

/// C entry point called once from `main.cpp` before `MainCmds::gtp`. Installs
/// the cache-aware bridge + downloaded-file hasher into the KataGoSwift seams.
@_cdecl("katago_register_coreml_bridge")
public func katago_register_coreml_bridge() {
    katagoDownloadedHasher = { url in
        try await BinFileHasher.shared.identityForDownloadedFile(url)
    }
    katago_coreml_bridge = { (
        coremlModelPath, serverThreadIdx, requireExactNNLen,
        numInputChannels, numInputGlobalChannels, numInputMetaChannels,
        numPolicyChannels, numValueChannels, numScoreValueChannels, numOwnershipChannels,
        context, maxBatchSize
    ) in
        return loadCoreMLHandleWithBridgeTimeout(
            coremlModelPath: coremlModelPath,
            serverThreadIdx: serverThreadIdx,
            requireExactNNLen: requireExactNNLen,
            numInputChannels: numInputChannels,
            numInputGlobalChannels: numInputGlobalChannels,
            numInputMetaChannels: numInputMetaChannels,
            numPolicyChannels: numPolicyChannels,
            numValueChannels: numValueChannels,
            numScoreValueChannels: numScoreValueChannels,
            numOwnershipChannels: numOwnershipChannels,
            context: context,
            maxBatchSize: maxBatchSize)
    }
}
