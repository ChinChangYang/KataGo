// PROTOTYPE (wayfinder #40), throwaway: a Core AI compute handle for stage 2 of the Core AI gate.
//
// The MLX backend's device id MLX_MUX_COREAI (mlxbackend.cpp) dispatches here instead of to
// CoreMLComputeHandle. It runs a pre-converted Core AI-format network (an .aimodel with one static batch-1 "main"
// function, from #36's converter) with `.neuralEngine` preferred, using the pattern stage 1 found fastest on the
// iPad: concurrent batch-1 calls through async `run`, one AIModel per concurrent slot. Concurrent calls into ONE
// AIModel returned wrong rows on both Neural Engines (#37), so slots never share a model.
//
// The public surface carries no availability annotation, so the generated C++ header exposes it; the Core AI types
// live behind `#available` in CoreAIImpl, and behind `canImport(CoreAI)` for the SDKs without Core AI (tvOS,
// visionOS), where creating a handle returns nil.
import Foundation
#if canImport(CoreAI)
import CoreAI
#endif

public final class CoreAIComputeHandle: @unchecked Sendable {
    let impl: AnyObject

    init(impl: AnyObject) {
        self.impl = impl
    }

    /// Same signature as CoreMLComputeHandle.apply: NCHW spatial rows, contiguous outputs.
    public func apply(
        spatialInput: UnsafeMutablePointer<Float32>,
        globalInput: UnsafeMutablePointer<Float32>,
        metaInput: UnsafeMutablePointer<Float32>,
        maskInput: UnsafeMutablePointer<Float32>,
        policy: UnsafeMutablePointer<Float32>,
        policyPass: UnsafeMutablePointer<Float32>,
        value: UnsafeMutablePointer<Float32>,
        scoreValue: UnsafeMutablePointer<Float32>,
        ownership: UnsafeMutablePointer<Float32>,
        batchSize: Int
    ) {
        #if canImport(CoreAI)
        guard #available(macOS 27, iOS 27, *), let impl = impl as? CoreAIImpl else {
            fatalError("Core AI backend: unavailable on this OS")
        }
        let io = CoreAIImpl.IO(
            spatial: spatialInput, global: globalInput, mask: maskInput,
            outs: [CoreAIImpl.policyOutput: policy, CoreAIImpl.policyPassOutput: policyPass,
                   CoreAIImpl.valueOutput: value, CoreAIImpl.scoreValueOutput: scoreValue,
                   CoreAIImpl.ownershipOutput: ownership])
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failure: Error?
        Task.detached {
            do { try await impl.apply(io, batchSize: batchSize) } catch { failure = error }
            semaphore.signal()
        }
        semaphore.wait()
        if let failure {
            fatalError("Core AI backend: inference error: \(failure)")
        }
        #else
        fatalError("Core AI backend: not in this SDK")
        #endif
    }
}

#if canImport(CoreAI)

@available(macOS 27, iOS 27, *)
final class CoreAIImpl: @unchecked Sendable {
    static let spatialInput = "spatial_input"
    static let globalInput = "global_input"
    static let inputMask = "input_mask"
    static let policyOutput = "policy_p2_conv"
    static let policyPassOutput = "policy_pass"
    static let valueOutput = "value_v3_bias"
    static let ownershipOutput = "value_ownership_conv"
    static let scoreValueOutput = "value_sv3_bias"

    struct IO: @unchecked Sendable {
        let spatial: UnsafeMutablePointer<Float32>
        let global: UnsafeMutablePointer<Float32>
        let mask: UnsafeMutablePointer<Float32>
        let outs: [String: UnsafeMutablePointer<Float32>]
    }

    struct Spec {
        let name: String
        let shape: [Int]
        let strides: [Int]
        var rowElements: Int { shape.dropFirst().reduce(1, *) }
    }

    /// One AIModel, its batch-1 function and its input arrays. A slot runs one row at a time.
    final class Slot: @unchecked Sendable {
        let model: AIModel
        let fn: InferenceFunction
        var inArrays: [NDArray]

        init(model: AIModel, fn: InferenceFunction, inputs: [Spec]) {
            self.model = model
            self.fn = fn
            inArrays = inputs.map { NDArray(shape: $0.shape, scalarType: .float32, strides: $0.strides) }
        }
    }

    let slots: [Slot]
    let inputs: [Spec]
    let outputs: [Spec]

    init(slots: [Slot], inputs: [Spec], outputs: [Spec]) {
        self.slots = slots
        self.inputs = inputs
        self.outputs = outputs
    }

    func apply(_ io: IO, batchSize: Int) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for s in 0..<min(batchSize, slots.count) {
                group.addTask {
                    var row = s
                    while row < batchSize {
                        try await self.run(self.slots[s], io, row: row)
                        row += self.slots.count
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    private func source(_ io: IO, _ name: String) -> UnsafeMutablePointer<Float32> {
        switch name {
        case Self.spatialInput: return io.spatial
        case Self.globalInput: return io.global
        case Self.inputMask: return io.mask
        default: fatalError("Core AI backend: unexpected input \(name)")
        }
    }

    private func run(_ slot: Slot, _ io: IO, row: Int) async throws {
        for (i, t) in inputs.enumerated() {
            let src = source(io, t.name) + row * t.rowElements
            slot.inArrays[i].mutableView(as: Float.self).withUnsafeMutablePointer { p, _, _ in
                copyIntoStrided(from: src, to: p, shape: t.shape, strides: t.strides)
            }
        }
        var dict: [String: NDArray] = [:]
        for (t, a) in zip(inputs, slot.inArrays) { dict[t.name] = a }
        var outs = try await slot.fn.run(inputs: dict)
        for t in outputs {
            guard let nd = outs.remove(t.name)?.ndArray, let dst = io.outs[t.name] else {
                throw CoreAIBackendError("missing output \(t.name)")
            }
            nd.view(as: Float.self).withUnsafePointer { p, shape, strides in
                let sh = (0..<shape.count).map { shape[$0] }, st = (0..<strides.count).map { strides[$0] }
                copyStrided(from: p, shape: sh, strides: st, to: dst + row * t.rowElements)
            }
        }
    }

    /// Loads `slotCount` AIModels from `url`, one after another. The first specializes the model (seconds); the rest
    /// come from Core AI's specialization cache.
    static func load(url: URL, slotCount: Int, nnXLen: Int, nnYLen: Int, serverThreadIdx: Int) async throws -> CoreAIImpl {
        let options = SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
        var slots: [Slot] = []
        var inputs: [Spec] = []
        var outputs: [Spec] = []
        for s in 0..<slotCount {
            let t0 = Date()
            let (model, fn) = try await loadFunction(url, options: options)
            if s == 0 {
                func spec(_ name: String, _ d: InferenceValue.Descriptor?) throws -> Spec {
                    guard case .ndArray(let nd)? = d else { throw CoreAIBackendError("\(name): not an NDArray") }
                    guard nd.scalarType == .float32 else { throw CoreAIBackendError("\(name): expected FP32 I/O") }
                    let st = nd.preferredStrides.isEmpty ? contiguousStrides(nd.shape) : nd.preferredStrides
                    return Spec(name: name, shape: nd.shape, strides: st)
                }
                inputs = try fn.descriptor.inputNames.map { try spec($0, fn.descriptor.inputDescriptor(of: $0)) }
                outputs = try fn.descriptor.outputNames.map { try spec($0, fn.descriptor.outputDescriptor(of: $0)) }
                guard let sp = inputs.first(where: { $0.name == spatialInput }), sp.shape.count == 4,
                      sp.shape[0] == 1, sp.shape[2] == nnYLen, sp.shape[3] == nnXLen else {
                    throw CoreAIBackendError("\(url.lastPathComponent): expected a batch-1 \(nnXLen)x\(nnYLen) "
                        + "function, got inputs \(inputs.map { "\($0.name)\($0.shape)" })")
                }
                let known: Set = [policyOutput, policyPassOutput, valueOutput, ownershipOutput, scoreValueOutput]
                guard Set(outputs.map(\.name)) == known else {
                    throw CoreAIBackendError("unexpected outputs \(outputs.map(\.name))")
                }
            }
            slots.append(Slot(model: model, fn: fn, inputs: inputs))
            printError(String(format: "Core AI backend %d: slot %d loaded in %.3f s", serverThreadIdx, s,
                              Date().timeIntervalSince(t0)))
        }
        return CoreAIImpl(slots: slots, inputs: inputs, outputs: outputs)
    }

    /// A cached specialization written by an earlier build of an ad hoc-signed tool can load as an AIModel and then
    /// fail in `loadFunction` (#37). Delete its cache entries and specialize again, once.
    private static func loadFunction(_ url: URL, options: SpecializationOptions) async throws -> (AIModel, InferenceFunction) {
        func attempt() async throws -> (AIModel, InferenceFunction) {
            let m = try await AIModel(contentsOf: url, options: options)
            guard let f = try m.loadFunction(named: "main") else {
                throw CoreAIBackendError("\(url.lastPathComponent): no function main (has \(m.functionNames))")
            }
            return (m, f)
        }
        do {
            return try await attempt()
        } catch {
            printError("Core AI backend: cached load failed (\(error)); deleting its cache entries and specializing again")
            try? AIModelCache.default.deleteEntries(for: url)
            return try await attempt()
        }
    }
}

struct CoreAIBackendError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

private func contiguousStrides(_ shape: [Int]) -> [Int] {
    var s = [Int](repeating: 1, count: shape.count)
    var acc = 1
    for i in stride(from: shape.count - 1, through: 0, by: -1) { s[i] = acc; acc *= shape[i] }
    return s
}

/// Walks a strided tensor in row-major order. `body(n, off)` gets the logical index and the strided offset.
private func forEachStrided(shape: [Int], strides: [Int], _ body: (Int, Int) -> Void) {
    let rank = shape.count
    let total = shape.reduce(1, *)
    var contiguous = true
    var expect = 1
    for i in stride(from: rank - 1, through: 0, by: -1) {
        if shape[i] != 1 && strides[i] != expect { contiguous = false; break }
        expect *= shape[i]
    }
    if contiguous {
        for n in 0..<total { body(n, n) }
        return
    }
    var idx = [Int](repeating: 0, count: rank)
    for n in 0..<total {
        var off = 0
        for d in 0..<rank { off += idx[d] * strides[d] }
        body(n, off)
        var d = rank - 1
        while d >= 0 {
            idx[d] += 1
            if idx[d] < shape[d] { break }
            idx[d] = 0
            d -= 1
        }
    }
}

private func copyIntoStrided(from src: UnsafePointer<Float>, to dst: UnsafeMutablePointer<Float>, shape: [Int], strides: [Int]) {
    forEachStrided(shape: shape, strides: strides) { n, off in dst[off] = src[n] }
}

private func copyStrided(from src: UnsafePointer<Float>, shape: [Int], strides: [Int], to dst: UnsafeMutablePointer<Float>) {
    forEachStrided(shape: shape, strides: strides) { n, off in dst[n] = src[off] }
}

#endif

/// Loads the Core AI handle for one NN server thread: `slotCount` concurrent batch-1 slots, one AIModel each.
/// Returns nil (after logging why) on failure or on an OS without Core AI.
public func createCoreAIComputeHandle(
    aimodelPath: String,
    serverThreadIdx: Int,
    slotCount: Int,
    context: MetalComputeContext
) -> CoreAIComputeHandle? {
    #if canImport(CoreAI)
    guard #available(macOS 27, iOS 27, *) else {
        printError("Core AI backend \(serverThreadIdx): needs macOS 27 or iOS 27")
        return nil
    }
    let url = URL(fileURLWithPath: aimodelPath)
    let nnX = Int(context.nnXLen), nnY = Int(context.nnYLen)
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<CoreAIImpl, Error>?
    Task.detached {
        do {
            result = .success(try await CoreAIImpl.load(url: url, slotCount: max(1, slotCount), nnXLen: nnX,
                                                        nnYLen: nnY, serverThreadIdx: serverThreadIdx))
        } catch {
            result = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    switch result {
    case .success(let impl)?:
        printError("Core AI backend \(serverThreadIdx): \(url.lastPathComponent) loaded, \(impl.slots.count) slots, "
            + "\(nnX)x\(nnY), neuralEngine preferred")
        return CoreAIComputeHandle(impl: impl)
    case .failure(let error)?:
        printError("Core AI backend \(serverThreadIdx): failed to load \(aimodelPath): \(error)")
        return nil
    case nil:
        return nil
    }
    #else
    printError("Core AI backend \(serverThreadIdx): Core AI is not in this SDK")
    return nil
    #endif
}
