import CoreML
import Foundation
import KataGoSwift

// MARK: - C bridge declarations (resolve against metalbackend.cpp in KataGoSwift)

@_silgen_name("katagocoreml_convert_to_temp")
private func katagocoreml_convert_to_temp(
    _ modelPath: UnsafePointer<CChar>,
    _ boardX: Int32, _ boardY: Int32,
    _ useFP16: Bool, _ optimizeMask: Bool,
    _ maxBatchSize: Int32, _ serverThreadIdx: Int32
) -> UnsafePointer<CChar>?

@_silgen_name("katagocoreml_free_string")
private func katagocoreml_free_string(_ s: UnsafePointer<CChar>?)

/// Cache-aware compute-handle loader. The C++/Swift bridge (Task 19)
/// calls this from a `Task.detached(priority: .userInitiated)`. Wraps
/// `MLModel(contentsOf:)` in a one-shot corrupt-hit retry loop:
/// on first failure, invalidate the cache entry and call urlForKey
/// again, which forces a fresh recompile.
public func loadCoreMLHandle(
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
    // Extract board dimensions before closures to avoid capturing non-Sendable context.
    let nnXLen = context.nnXLen
    let nnYLen = context.nnYLen
    let key = try await CoreMLModelCache.cacheKey(
        forSourcePath: coremlModelPath,
        nnXLen: nnXLen, nnYLen: nnYLen,
        requireExactNNLen: optimizeMask, useFP16: useFP16,
        maxBatchSize: maxBatchSize,
        downloadedHasher: { url in
            guard let hasher = katagoDownloadedHasher else {
                throw CoreMLCacheKeyError.downloadedHasherNotInjected
            }
            return try await hasher(url)
        })
    let cache = CoreMLModelCache.shared
    await cache.start()

    // Report compilation status for the duration of the cache lookup.
    // On a cache hit this clears quickly; on a miss it persists until
    // compilation finishes, giving the user a meaningful caption in
    // LoadingView (Task 25).
    await reportLaunchStatus(.compilingMissFirstLaunch)
    defer { Task { await reportLaunchStatus(.idle) } }

    for attempt in 0..<2 {
        let pinned = try await cache.urlForKey(
            digest: key.digest,
            priority: .userInitiated,
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
            // Capture pinned so the handle's releaseHook releases the pin
            // when the engine tears the handle down.
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

// MARK: - Cooperative-pool conversion shim (Task 19)

/// Run the C++ converter on the cooperative thread pool. Used as the
/// `missCallback` body in `loadCoreMLHandle`. The C call writes a
/// `.mlpackage` to a temp dir and returns the path; we then
/// `MLModel.compileModel(at:)` it inline and return the resulting
/// `.mlmodelc/` URL so the cache can store it.
func convertOnCooperativePool(
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
    // The cache stores .mlmodelc/, not .mlpackage, so compile here.
    return try await MLModel.compileModel(at: mlpackageURL)
}

// MARK: - Synchronous bridge wrapper (Task 19)

/// Synchronous wrapper that drives `loadCoreMLHandle` from a C++ caller.
/// Spawns a `Task.detached(priority: .userInitiated)` so cooperative-pool
/// priority escalation works, then waits on the result with a 10-min
/// primary timeout + 60-sec secondary wait before falling through to
/// the legacy direct-compile path.
// Thread-safe result box for the DispatchSemaphore-based bridge pattern.
// Safety: writes happen-before sem.signal(); reads happen-after sem.wait().
// The class wrapper lets us capture a reference in a @Sendable closure
// while acknowledging the unsafety via nonisolated(unsafe).
private final class ResultBox: @unchecked Sendable {
    nonisolated(unsafe) var value: Result<CoreMLComputeHandle?, Error>? = nil
}

public func loadCoreMLHandleWithBridgeTimeout(
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
    // Extract Sendable primitives from non-Sendable context before the closure.
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
        // Secondary 60s wait — give a slow-but-finishing compile a chance.
        let secondary = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            _ = try? await task.value
            secondary.signal()
        }
        if secondary.wait(timeout: .now() + .seconds(60)) == .timedOut {
            // Truly hung. Cancel and fall through to legacy direct-compile.
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
            // releaseHook stays nil for the legacy path — see Task 18.
        }
    }

    switch box.value {
    case .success(let h)?: return h
    case .failure?: return nil
    case nil: return nil
    }
}

// MARK: - Bridge seam registration (Task 19)

/// Register `loadCoreMLHandleWithBridgeTimeout` into the KataGoSwift
/// closure seam (`katago_coreml_bridge`) so that `metalbackend.cpp`
/// can invoke it synchronously. Call this once at KataGoInterface
/// initialisation time.
///
/// This is the counterpart to `katagoDownloadedHasher` (Task 17/23):
/// KataGoSwift cannot import KataGoInterface (circular), so we inject
/// from KataGoInterface into the KataGoSwift global at startup.
public func registerCoreMLBridge() {
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

// MARK: - Downloaded-hasher seam registration (Task 23)

/// Wire a downloaded-file hasher closure into the KataGoSwift global
/// (`katagoDownloadedHasher`). The app target calls this at launch,
/// passing `BinFileHasher.shared.identityForDownloadedFile`. We expose
/// it here so the app target need not import KataGoSwift directly
/// (circular-dependency avoidance mirrors `registerCoreMLBridge()`).
public func registerDownloadedHasher(
    _ hasher: @Sendable @escaping (URL) async throws -> String
) {
    katagoDownloadedHasher = hasher
}

// MARK: - Engine-launch status updater seam (Task 25)

/// Process-wide engine-launch status updater. The main app target sets
/// this at launch (Task 25 wires `EngineLaunchStatus.phase = ...`).
/// Off-MainActor; the producer hops to MainActor inside the closure.
nonisolated(unsafe) private var engineLaunchStatusUpdater:
    ((EngineLaunchStatus.Phase) async -> Void)? = nil

/// Register a closure that receives `EngineLaunchStatus.Phase` updates
/// from the cache-loading path. Mirrors `registerDownloadedHasher` and
/// `registerCoreMLBridge` — call once at app launch from the main target.
public func registerEngineLaunchStatusUpdater(
    _ updater: @escaping @Sendable (EngineLaunchStatus.Phase) async -> Void
) {
    engineLaunchStatusUpdater = updater
}

private func reportLaunchStatus(_ phase: EngineLaunchStatus.Phase) async {
    await engineLaunchStatusUpdater?(phase)
}
