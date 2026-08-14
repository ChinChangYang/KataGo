import CoreML
import Foundation
import KataGoSwift
import KataGoUICore

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

    // Compile caption: raised INSIDE the miss callback, so a cache hit — the
    // overwhelmingly common case — says nothing at all, and released here at
    // function scope, because the compile is not the last thing the user waits
    // for. After the callback returns, the cache still moves the compiled model
    // into place and rewrites its index, and `MLModel(contentsOf:)` below still
    // builds the ANE program. A callback-scoped caption would go dark two
    // thirds of the way through the wait. See ADR 0007.
    //
    // A count rather than a flag: the corrupt-hit retry below can run the miss
    // callback twice, and a flag would leak a raise.
    let compileSpan = CompileReportSpan()
    defer { compileSpan.drain() }

    let sourceFileName = (coremlModelPath as NSString).lastPathComponent
    for attempt in 0..<2 {
        let pinned = try await cache.urlForKey(
            digest: key.digest,
            priority: .userInitiated,
            sourceFileName: sourceFileName,
            missCallback: {
                return try await reportingCompile(in: compileSpan) {
                    try await convertOnCooperativePool(
                        coremlModelPath: coremlModelPath,
                        boardX: nnXLen, boardY: nnYLen,
                        useFP16: useFP16, optimizeMask: optimizeMask,
                        maxBatchSize: Int32(maxBatchSize),
                        serverThreadIdx: Int32(serverThreadIdx))
                }
            })
        do {
            let config = MLModelConfiguration()
            #if os(tvOS)
            // Apple TV never routes this net to the ANE (0 ANE ops in every
            // MLComputePlan config), and merely allowing the ANE degrades the
            // CPU fallback plan (~3.4× slower than GPU in the on-device
            // Diagnostics benchmark). Pin to CPU+GPU; .all is no faster and
            // would let CoreML attempt ANE segments that have faulted before.
            config.computeUnits = .cpuAndGPU
            #else
            // The iOS Backend settings sheet reports Core ML op routing under
            // exactly these compute units (`engineCoreMLComputeUnits` in
            // CoreMLRoutingProbe.swift), and omits a GPU column because GPU is
            // not among them. Changing this line must change that readout too.
            config.computeUnits = .cpuAndNeuralEngine
            #endif
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
public func convertOnCooperativePool(
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
            await task.value
            secondary.signal()
        }
        if secondary.wait(timeout: .now() + .seconds(60)) == .timedOut {
            // Truly hung. Cancel and fall through to legacy direct-compile.
            //
            // Deliberately does NOT clear the compile caption. `cancel()`
            // cannot stop the abandoned compile — it runs in a detached task
            // inside the cache actor whose only cancellation checks are
            // post-compile — and the legacy path below re-converts and
            // recompiles from scratch. A compile really is running here, so
            // clearing would make the caption go dark mid-compile: the exact
            // defect ADR 0007 removes. The abandoned compile's own release
            // settles the count if it ever unwinds, and `compileEnded()`
            // clamps at zero so a late one cannot silence the next compile.
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
/// can invoke it synchronously. Call this once at app-launch time
/// (KataGo_iOSApp.init), before any engine launch.
///
/// This is the counterpart to `katagoDownloadedHasher` (Task 17/23):
/// KataGoSwift cannot import this loader (circular), so the app target
/// injects into the KataGoSwift global at startup.
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

// MARK: - Compile-reporting seam (Task 25; reshaped by ADR 0007)

/// Where Core ML compile begin/end events go. Production uses `.global`, which
/// forwards to whatever `registerEngineLaunchStatusUpdater` installed; tests
/// inject a recorder so they never touch that process-wide global, which has no
/// unregister and would leak across an app-hosted suite.
public struct CompileReporter: Sendable {
    let began: @Sendable () async -> Void
    let ended: @Sendable () async -> Void

    public init(began: @escaping @Sendable () async -> Void,
                ended: @escaping @Sendable () async -> Void) {
        self.began = began
        self.ended = ended
    }

    public static let global = CompileReporter(
        began: { await engineCompileReporter?.began() },
        ended: { await engineCompileReporter?.ended() })
}

/// Process-wide reporter. The main app target sets this at launch.
/// Off-MainActor; the closures hop to MainActor themselves.
nonisolated(unsafe) private var engineCompileReporter: CompileReporter? = nil

/// Wire the launch screens' status object to the compile-reporting seam.
/// Mirrors `registerDownloadedHasher` and `registerCoreMLBridge` — call once at
/// app launch from the main target, before any engine launch.
public func registerEngineLaunchStatusUpdater(_ status: EngineLaunchStatus) {
    engineCompileReporter = CompileReporter(
        began: { await status.compileBegan() },
        ended: { await status.compileEnded() })
}

/// The compile-caption raises made by ONE handle load.
///
/// Exists because the raise and the release belong to different scopes: the
/// raise must happen inside the cache's miss callback (so a hit stays silent),
/// while the release must wait for the whole load (so the caption covers the
/// index write and the ANE program build that follow the compile). See ADR 0007.
public final class CompileReportSpan: @unchecked Sendable {
    private let reporter: CompileReporter
    private let lock = NSLock()
    private var outstanding = 0

    public init(_ reporter: CompileReporter = .global) {
        self.reporter = reporter
    }

    /// Record and report one raise. Called from the cooperative pool, so the
    /// bookkeeping uses a scoped `withLock` — `lock()`/`unlock()` are
    /// unavailable in an async context.
    public func began() async {
        lock.withLock { outstanding += 1 }
        await reporter.began()
    }

    /// Balance every raise this span made. Call exactly once, from a
    /// function-scope `defer` in the enclosing load — `defer` bodies cannot
    /// `await`, which is why this is synchronous and hands off to a `Task`.
    /// The returned task exists so tests can await the releases; production
    /// call sites discard it.
    @discardableResult
    public func drain() -> Task<Void, Never> {
        let pending = lock.withLock {
            let n = outstanding
            outstanding = 0
            return n
        }
        let reporter = self.reporter
        return Task {
            for _ in 0..<pending { await reporter.ended() }
        }
    }
}

/// Run the work that genuinely constitutes a compile, with the caption raised.
///
/// The raise is registered with `span` rather than released here: a throwing
/// `body` must still leave a balanced span, and the enclosing load's `defer`
/// is what balances it. `convertOnCooperativePool` does throw on converter
/// failure, and that failure returns promptly — so without this the caption
/// would pin on for the life of the process under a *failed* engine launch.
public func reportingCompile<T>(
    in span: CompileReportSpan,
    _ body: () async throws -> T
) async rethrows -> T {
    await span.began()
    return try await body()
}
