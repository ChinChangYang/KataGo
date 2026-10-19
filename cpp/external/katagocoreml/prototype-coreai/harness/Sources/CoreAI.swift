// PROTOTYPE (wayfinder #37), throwaway: Core AI the way a backend would call it.
//
// Two call paths, both from synchronous code like KataGo's NN server threads:
//   encode: the research note's pattern (section 2.3). Each slot owns an MTLCommandQueue, a ComputeStream, and
//           shared MTLBuffers for every input and output, laid out with the function's preferred strides. A call
//           copies rows in, `encode`s with pre-allocated output views, commits an empty marker command buffer on the
//           same queue and waits for it, then copies rows out.
//   run:    the async `run(inputs:)` with per-slot NDArrays, bridged to the caller with a semaphore.
import CoreAICompiler
import CoreAIDelegates
import CoreAIRuntime
import Foundation
import Metal

func coreAIOptions(_ unit: String, debug: Bool = false) -> SpecializationOptions {
    var o: SpecializationOptions
    switch unit {
    case "cpu": o = .cpuOnly
    case "gpu": o = SpecializationOptions(preferredComputeUnitKind: .gpu)
    case "ane": o = SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
    default: o = .default
    }
    if debug {
        var dc = Compiler.DebugConfiguration()
        dc.enableDebugInfo = true
        dc.writeDebugInfo = true  // without it a cached specialization comes back with no delegate records
        o.debugConfiguration = dc
    }
    return o
}

struct TensorSpec {
    let name: String
    let shape: [Int]
    let strides: [Int]   // preferred strides, or contiguous
    var elements: Int { shape.reduce(1, *) }
    var span: Int { spanElements(shape, strides) }
    var rowElements: Int { elements / shape[0] }
}

/// Cached-specialization failures recovered by deleting the entry (reported in every result).
nonisolated(unsafe) var cacheRecoveries: [String] = []

/// Loads `url` and its function `name`. If either step fails, deletes the model's cache entries and specializes
/// afresh, once. On the Mac, a cached specialization written by an earlier build of this (ad hoc signed) tool has been
/// seen to load as an AIModel and then fail in `loadFunction` with Foundation's `nilError`; deleting the entry fixed
/// it every time.
func loadAIFunction(_ url: URL, options: SpecializationOptions, name: String) async throws -> (AIModel, InferenceFunction?) {
    do {
        let m = try await AIModel(contentsOf: url, options: options)
        return (m, try m.loadFunction(named: name))
    } catch {
        let note = "\(url.lastPathComponent): cached load failed (\(error)); deleted its cache entries and specialized again"
        log("WARNING: " + note)
        cacheRecoveries.append(note)
        try? AIModelCache.default.deleteEntries(for: url)
        let m = try await AIModel(contentsOf: url, options: options)
        return (m, try step("\(url.lastPathComponent) loadFunction after re-specializing") { try m.loadFunction(named: name) })
    }
}

/// `AIModel(contentsOf:options:)` with the same recovery, for callers that need no function.
func loadAIModel(_ url: URL, options: SpecializationOptions) async throws -> AIModel {
    try await loadAIFunction(url, options: options, name: "main").0
}

/// One loaded Core AI function and its I/O layout.
final class CoreAIFunction: @unchecked Sendable {
    let model: AIModel
    let fn: InferenceFunction
    let inputs: [TensorSpec]
    let outputs: [TensorSpec]
    let batch: Int
    let loadSeconds: Double

    convenience init(url: URL, unit: String, preferredStrides: Bool = true, function: String = "main") async throws {
        let t0 = nowNs()
        let (m, loaded) = try await loadAIFunction(url, options: coreAIOptions(unit), name: function)
        guard let f = loaded else {
            throw HarnessError("\(url.lastPathComponent): no function \(function) (has \(m.functionNames))")
        }
        try self.init(model: m, fn: f, preferredStrides: preferredStrides, loadSeconds: Double(nowNs() - t0) / 1e9)
    }

    /// Another InferenceFunction from the same specialized model (a second `loadFunction`).
    func sibling() throws -> CoreAIFunction {
        guard let f = try model.loadFunction(named: fn.descriptor.name) else { throw HarnessError("loadFunction returned nil") }
        return try CoreAIFunction(model: model, fn: f, preferredStrides: true, loadSeconds: 0)
    }

    init(model m: AIModel, fn f: InferenceFunction, preferredStrides: Bool, loadSeconds: Double) throws {
        model = m
        self.loadSeconds = loadSeconds
        fn = f
        func spec(_ name: String, _ d: InferenceValue.Descriptor?) throws -> TensorSpec {
            guard case .ndArray(let nd)? = d else { throw HarnessError("\(name): not an NDArray") }
            guard nd.scalarType == .float32 else { throw HarnessError("\(name): expected FP32 I/O") }
            let st = preferredStrides ? nd.preferredStrides : contiguousStrides(nd.shape)
            return TensorSpec(name: name, shape: nd.shape, strides: st.isEmpty ? contiguousStrides(nd.shape) : st)
        }
        inputs = try f.descriptor.inputNames.map { try spec($0, f.descriptor.inputDescriptor(of: $0)) }
        outputs = try f.descriptor.outputNames.map { try spec($0, f.descriptor.outputDescriptor(of: $0)) }
        batch = inputs.first?.shape.first ?? 1
    }
}

/// Per-thread resources for the encode path.
final class EncodeSlot: @unchecked Sendable {
    let f: CoreAIFunction
    let queue: MTLCommandQueue
    let stream: ComputeStream
    let inBufs: [MTLBuffer]
    let outBufs: [MTLBuffer]
    let inValues: [String: InferenceFunction.AsyncValue]

    init(_ f: CoreAIFunction, device: MTLDevice) throws {
        self.f = f
        guard let q = device.makeCommandQueue() else { throw HarnessError("no command queue") }
        queue = q
        stream = ComputeStream(commandQueue: q)
        func buf(_ t: TensorSpec) throws -> MTLBuffer {
            guard let b = device.makeBuffer(length: t.span * 4, options: .storageModeShared) else {
                throw HarnessError("no buffer for \(t.name)")
            }
            memset(b.contents(), 0, t.span * 4)
            return b
        }
        inBufs = try f.inputs.map(buf)
        outBufs = try f.outputs.map(buf)
        var iv: [String: InferenceFunction.AsyncValue] = [:]
        for (t, b) in zip(f.inputs, inBufs) {
            iv[t.name] = unsafe InferenceFunction.AsyncValue(unsafeBuffer: b, scalarType: .float32, shape: t.shape,
                                                             strides: t.strides)
        }
        inValues = iv
    }

    /// Evaluate `count` rows of `rows` starting at `first`, into the slot's batch positions 0..<count.
    func evaluate(_ rows: RowBuffers, first: Int, count: Int) throws {
        copyIn(rows, first: first, count: count, inputs: f.inputs) { i in self.inBufs[i].contents().assumingMemoryBound(to: Float.self) }
        try encodeAndWait()
        copyOut(rows, first: first, count: count, outputs: f.outputs) { i in UnsafePointer(self.outBufs[i].contents().assumingMemoryBound(to: Float.self)) }
    }

    func encodeAndWait() throws {
        let o = f.outputs
        precondition(o.count == 5, "the KataGo network has five outputs")
        var m0 = unsafe InferenceFunction.AsyncMutableValue(unsafeBuffer: outBufs[0], scalarType: .float32, shape: o[0].shape, strides: o[0].strides)
        var m1 = unsafe InferenceFunction.AsyncMutableValue(unsafeBuffer: outBufs[1], scalarType: .float32, shape: o[1].shape, strides: o[1].strides)
        var m2 = unsafe InferenceFunction.AsyncMutableValue(unsafeBuffer: outBufs[2], scalarType: .float32, shape: o[2].shape, strides: o[2].strides)
        var m3 = unsafe InferenceFunction.AsyncMutableValue(unsafeBuffer: outBufs[3], scalarType: .float32, shape: o[3].shape, strides: o[3].strides)
        var m4 = unsafe InferenceFunction.AsyncMutableValue(unsafeBuffer: outBufs[4], scalarType: .float32, shape: o[4].shape, strides: o[4].strides)
        var views = InferenceFunction.AsyncMutableViews()
        views.insert(&m0, for: o[0].name)
        views.insert(&m1, for: o[1].name)
        views.insert(&m2, for: o[2].name)
        views.insert(&m3, for: o[3].name)
        views.insert(&m4, for: o[4].name)
        let results: [String: InferenceFunction.AsyncValue]
        do { results = try f.fn.encode(inputs: inValues, outputViews: views, to: stream) }
        catch { throw HarnessError("encode \(f.inputs[0].shape): \(error)") }
        guard let marker = queue.makeCommandBuffer() else { throw HarnessError("no marker command buffer") }
        marker.commit()
        marker.waitUntilCompleted()
        withExtendedLifetime(results) {}
    }
}

/// Generic-output encode for single-output probes (the Mish sweep): returns the output as contiguous floats.
final class ProbeEncoder: @unchecked Sendable {
    let f: CoreAIFunction
    let slot: (queue: MTLCommandQueue, stream: ComputeStream)
    let inBuf: MTLBuffer, outBuf: MTLBuffer
    let inValue: InferenceFunction.AsyncValue

    init(_ f: CoreAIFunction, device: MTLDevice) throws {
        self.f = f
        let q = device.makeCommandQueue()!
        slot = (q, ComputeStream(commandQueue: q))
        inBuf = device.makeBuffer(length: f.inputs[0].span * 4, options: .storageModeShared)!
        outBuf = device.makeBuffer(length: f.outputs[0].span * 4, options: .storageModeShared)!
        inValue = unsafe InferenceFunction.AsyncValue(unsafeBuffer: inBuf, scalarType: .float32, shape: f.inputs[0].shape,
                                                      strides: f.inputs[0].strides)
    }

    func run(_ x: [Float]) throws -> [Float] {
        let ti = f.inputs[0], to = f.outputs[0]
        x.withUnsafeBufferPointer { copyIntoStrided(from: $0.baseAddress!, to: inBuf.contents().assumingMemoryBound(to: Float.self), shape: ti.shape, strides: ti.strides) }
        var m = unsafe InferenceFunction.AsyncMutableValue(unsafeBuffer: outBuf, scalarType: .float32, shape: to.shape, strides: to.strides)
        var views = InferenceFunction.AsyncMutableViews()
        views.insert(&m, for: to.name)
        let results = try f.fn.encode(inputs: [ti.name: inValue], outputViews: views, to: slot.stream)
        let marker = slot.queue.makeCommandBuffer()!
        marker.commit()
        marker.waitUntilCompleted()
        withExtendedLifetime(results) {}
        var y = [Float](repeating: 0, count: to.elements)
        y.withUnsafeMutableBufferPointer { copyStrided(from: outBuf.contents().assumingMemoryBound(to: Float.self), shape: to.shape, strides: to.strides, to: $0.baseAddress!) }
        return y
    }
}

/// Per-task resources for the async `run` path.
final class RunSlot: @unchecked Sendable {
    let f: CoreAIFunction
    var inArrays: [NDArray]

    init(_ f: CoreAIFunction) {
        self.f = f
        inArrays = f.inputs.map { NDArray(shape: $0.shape, scalarType: .float32, strides: $0.strides) }
    }

    func evaluate(_ rows: RowBuffers, first: Int, count: Int) async throws {
        let specs = f.inputs
        for i in 0..<specs.count {
            let t = specs[i]
            let n = t.rowElements
            let src: UnsafeMutablePointer<Float> = rowInput(rows, t.name)
            let rowStride = rowsStride(rows, t.name)
            inArrays[i].mutableView(as: Float.self).withUnsafeMutablePointer { p, _, _ in
                for r in 0..<count {
                    copyIntoStrided(from: src + (first + r) * rowStride, to: p + r * t.strides[0],
                                    shape: Array(t.shape.dropFirst()), strides: Array(t.strides.dropFirst()))
                }
                _ = n
            }
        }
        var dict: [String: NDArray] = [:]
        for (t, a) in zip(specs, inArrays) { dict[t.name] = a }
        var outs = try await f.fn.run(inputs: dict)
        for t in f.outputs {
            guard let nd = outs.remove(t.name)?.ndArray else { throw HarnessError("missing output \(t.name)") }
            let dst = rows.outs[t.name]!
            let rowN = rows.outSizes[t.name]!
            nd.view(as: Float.self).withUnsafePointer { p, shape, strides in
                let sh = (0..<shape.count).map { shape[$0] }, st = (0..<strides.count).map { strides[$0] }
                for r in 0..<count {
                    copyStrided(from: p + r * st[0], shape: Array(sh.dropFirst()), strides: Array(st.dropFirst()),
                                to: dst + (first + r) * rowN)
                }
            }
        }
    }
}

// MARK: - Row copies shared by both paths

func rowInput(_ rows: RowBuffers, _ name: String) -> UnsafeMutablePointer<Float> {
    switch name {
    case "spatial_input": return rows.spatial
    case "global_input": return rows.global
    case "input_mask": return rows.mask
    default: fatalError("unexpected input \(name)")
    }
}

func rowsStride(_ rows: RowBuffers, _ name: String) -> Int {
    let area = rows.board * rows.board
    switch name {
    case "spatial_input": return rows.numSpatial * area
    case "global_input": return rows.numGlobal
    case "input_mask": return area
    default: fatalError("unexpected input \(name)")
    }
}

func copyIn(_ rows: RowBuffers, first: Int, count: Int, inputs: [TensorSpec], dst: (Int) -> UnsafeMutablePointer<Float>) {
    for (i, t) in inputs.enumerated() {
        let src = rowInput(rows, t.name), rs = rowsStride(rows, t.name)
        let d = dst(i)
        for r in 0..<count {
            copyIntoStrided(from: src + (first + r) * rs, to: d + r * t.strides[0],
                            shape: Array(t.shape.dropFirst()), strides: Array(t.strides.dropFirst()))
        }
    }
}

func copyOut(_ rows: RowBuffers, first: Int, count: Int, outputs: [TensorSpec], src: (Int) -> UnsafePointer<Float>) {
    for (i, t) in outputs.enumerated() {
        let dst = rows.outs[t.name]!, n = rows.outSizes[t.name]!
        let s = src(i)
        for r in 0..<count {
            copyStrided(from: s + r * t.strides[0], shape: Array(t.shape.dropFirst()), strides: Array(t.strides.dropFirst()),
                        to: dst + (first + r) * n)
        }
    }
}
