// PROTOTYPE (wayfinder #37), throwaway: CoreML/NE exactly as the app runs it.
//
// `apply` and everything it calls are copied from `CoreMLComputeHandle` in cpp/neuralnet/metalbackend.swift
// (feature/agent-tooling), with only the failure policy reduced to `.fatal`: each batch of rows becomes concurrent
// batch-1 `MLModel.prediction(from:)` calls in a TaskGroup on a detached task, and the calling thread blocks on a
// semaphore. The model loads the way CoreMLComputeHandleLoader.swift loads it: compiled `.mlmodelc`, compute units
// `.cpuAndNeuralEngine`.
import CoreML
import Foundation

final class AppCoreMLHandle: @unchecked Sendable {
    let model: MLModel
    let nnXLen: Int32
    let nnYLen: Int32
    let numInputChannels: Int
    let numInputGlobalChannels: Int
    let numInputMetaChannels: Int
    let numPolicyChannels: Int
    let numValueChannels: Int
    let numScoreValueChannels: Int
    let numOwnershipChannels: Int

    struct IONames {
        static let spatialInput = "spatial_input"
        static let globalInput = "global_input"
        static let inputMask = "input_mask"
        static let metaInput = "meta_input"

        static let policyOutput = "policy_p2_conv"
        static let policyPassOutput = "policy_pass"
        static let valueOutput = "value_v3_bias"
        static let ownershipOutput = "value_ownership_conv"
        static let scoreValueOutput = "value_sv3_bias"
    }

    /// Loads like CoreMLComputeHandleLoader: `MLModel(contentsOf:configuration:)` on a compiled model.
    init(compiledURL: URL, board: Int, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        model = try step("MLModel(contentsOf: \(compiledURL.lastPathComponent))") { try MLModel(contentsOf: compiledURL, configuration: config) }
        nnXLen = Int32(board)
        nnYLen = Int32(board)
        // Input shapes come from the description (its default shape, or the batch range's lower bound); output
        // channel counts from one probe prediction, since the converter leaves output shapes undeclared.
        let d = model.modelDescription
        func inShape(_ name: String) -> [Int]? {
            guard let c = d.inputDescriptionsByName[name]?.multiArrayConstraint else { return nil }
            if !c.shape.isEmpty { return c.shape.map(\.intValue) }
            let r = c.shapeConstraint.sizeRangeForDimension
            return r.isEmpty ? nil : r.map { $0.rangeValue.location }
        }
        let spatial = inShape(IONames.spatialInput)!, global = inShape(IONames.globalInput)!
        numInputChannels = spatial[1]
        numInputGlobalChannels = global[1]
        numInputMetaChannels = inShape(IONames.metaInput)?[1] ?? 0
        var probe: [String: MLFeatureValue] = [:]
        for (name, shape) in [(IONames.spatialInput, spatial), (IONames.globalInput, global),
                              (IONames.inputMask, [1, 1, board, board])] {
            let a = try MLMultiArray(shape: ([1] + shape.dropFirst()).map { NSNumber(value: $0) }, dataType: .float32)
            memset(a.dataPointer, 0, a.count * 4)
            probe[name] = MLFeatureValue(multiArray: a)
        }
        let m = model
        let out = try step("\(compiledURL.lastPathComponent) probe prediction") { try m.prediction(from: MLDictionaryFeatureProvider(dictionary: probe)) }
        func outCh(_ name: String) -> Int { out.featureValue(for: name)!.multiArrayValue!.shape[1].intValue }
        numPolicyChannels = outCh(IONames.policyOutput)
        numValueChannels = outCh(IONames.valueOutput)
        numScoreValueChannels = outCh(IONames.scoreValueOutput)
        numOwnershipChannels = outCh(IONames.ownershipOutput)
    }

    var outSizes: [String: Int] {
        let area = Int(nnXLen) * Int(nnYLen)
        return [IONames.policyOutput: numPolicyChannels * area, IONames.policyPassOutput: numPolicyChannels,
                IONames.valueOutput: numValueChannels, IONames.scoreValueOutput: numScoreValueChannels,
                IONames.ownershipOutput: numOwnershipChannels * area]
    }

    func apply(_ b: RowBuffers, batchSize: Int) {
        apply(spatialInput: b.spatial, globalInput: b.global, metaInput: b.meta, maskInput: b.mask,
              policy: b.outs[IONames.policyOutput]!, policyPass: b.outs[IONames.policyPassOutput]!,
              value: b.outs[IONames.valueOutput]!, scoreValue: b.outs[IONames.scoreValueOutput]!,
              ownership: b.outs[IONames.ownershipOutput]!, batchSize: batchSize)
    }

    // ---- copied from metalbackend.swift ----

    /// Run inference on a batch of inputs
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
        struct Buffers: @unchecked Sendable {
            let spatialInput: UnsafeMutablePointer<Float32>
            let globalInput: UnsafeMutablePointer<Float32>
            let metaInput: UnsafeMutablePointer<Float32>
            let maskInput: UnsafeMutablePointer<Float32>
            let policy: UnsafeMutablePointer<Float32>
            let policyPass: UnsafeMutablePointer<Float32>
            let value: UnsafeMutablePointer<Float32>
            let scoreValue: UnsafeMutablePointer<Float32>
            let ownership: UnsafeMutablePointer<Float32>
        }
        let buffers = Buffers(
            spatialInput: spatialInput,
            globalInput: globalInput,
            metaInput: metaInput,
            maskInput: maskInput,
            policy: policy,
            policyPass: policyPass,
            value: value,
            scoreValue: scoreValue,
            ownership: ownership)

        let semaphore = DispatchSemaphore(value: 0)
        Task.detached { [self] in
            await withTaskGroup(of: Void.self) { group in
                for b in 0..<batchSize {
                    group.addTask {
                        autoreleasepool {
                            do {
                                try self.runSingleInference(
                                    batchIndex: b,
                                    spatialInput: buffers.spatialInput,
                                    globalInput: buffers.globalInput,
                                    metaInput: buffers.metaInput,
                                    maskInput: buffers.maskInput,
                                    policy: buffers.policy,
                                    policyPass: buffers.policyPass,
                                    value: buffers.value,
                                    scoreValue: buffers.scoreValue,
                                    ownership: buffers.ownership
                                )
                            } catch {
                                fatalError("Metal backend: CoreML inference error: \(error)")
                            }
                        }
                    }
                }
            }
            semaphore.signal()
        }
        semaphore.wait()
    }

    private func runSingleInference(
        batchIndex: Int,
        spatialInput: UnsafeMutablePointer<Float32>,
        globalInput: UnsafeMutablePointer<Float32>,
        metaInput: UnsafeMutablePointer<Float32>,
        maskInput: UnsafeMutablePointer<Float32>,
        policy: UnsafeMutablePointer<Float32>,
        policyPass: UnsafeMutablePointer<Float32>,
        value: UnsafeMutablePointer<Float32>,
        scoreValue: UnsafeMutablePointer<Float32>,
        ownership: UnsafeMutablePointer<Float32>
    ) throws {
        let spatialSize = Int(nnXLen) * Int(nnYLen) * numInputChannels
        let spatialOffset = batchIndex * spatialSize

        let spatialArray = try MLMultiArray(
            shape: [1, NSNumber(value: numInputChannels),
                   NSNumber(value: nnYLen), NSNumber(value: nnXLen)],
            dataType: .float32)

        let spatialPtr = spatialArray.dataPointer.assumingMemoryBound(to: Float32.self)
        memcpy(spatialPtr, spatialInput.advanced(by: spatialOffset), spatialSize * MemoryLayout<Float32>.size)

        let globalArray = try MLMultiArray(
            shape: [1, NSNumber(value: numInputGlobalChannels)],
            dataType: .float32)
        let globalPtr = globalArray.dataPointer.assumingMemoryBound(to: Float32.self)
        let globalOffset = batchIndex * numInputGlobalChannels
        memcpy(globalPtr, globalInput.advanced(by: globalOffset), numInputGlobalChannels * MemoryLayout<Float32>.size)

        var inputDict: [String: MLFeatureValue] = [
            IONames.spatialInput: MLFeatureValue(multiArray: spatialArray),
            IONames.globalInput: MLFeatureValue(multiArray: globalArray)
        ]

        let maskArray = try MLMultiArray(
            shape: [1, 1, NSNumber(value: nnYLen), NSNumber(value: nnXLen)],
            dataType: .float32)
        let maskPtr = maskArray.dataPointer.assumingMemoryBound(to: Float32.self)
        let maskSize = Int(nnXLen) * Int(nnYLen)
        let maskOffset = batchIndex * maskSize
        memcpy(maskPtr, maskInput.advanced(by: maskOffset), maskSize * MemoryLayout<Float32>.size)
        inputDict[IONames.inputMask] = MLFeatureValue(multiArray: maskArray)

        if numInputMetaChannels > 0 {
            let metaArray = try MLMultiArray(
                shape: [1, NSNumber(value: numInputMetaChannels)],
                dataType: .float32)
            let metaPtr = metaArray.dataPointer.assumingMemoryBound(to: Float32.self)
            let metaOffset = batchIndex * numInputMetaChannels
            memcpy(metaPtr, metaInput.advanced(by: metaOffset), numInputMetaChannels * MemoryLayout<Float32>.size)
            inputDict[IONames.metaInput] = MLFeatureValue(multiArray: metaArray)
        }

        let featureProvider = try MLDictionaryFeatureProvider(dictionary: inputDict)
        let prediction = try model.prediction(from: featureProvider)

        extractOutputs(
            prediction: prediction,
            batchIndex: batchIndex,
            policy: policy,
            policyPass: policyPass,
            value: value,
            scoreValue: scoreValue,
            ownership: ownership
        )
    }

    private func copyMultiArray(
        _ array: MLMultiArray,
        to dest: UnsafeMutablePointer<Float32>,
        destOffset: Int
    ) {
        let shape = array.shape.map { $0.intValue }
        let strides = array.strides.map { $0.intValue }
        let ptr = array.dataPointer.assumingMemoryBound(to: Float32.self)
        let totalElements = shape.reduce(1, *)

        var isContiguous = true
        var expectedStride = 1
        for i in (0..<shape.count).reversed() {
            if strides[i] != expectedStride {
                isContiguous = false
                break
            }
            expectedStride *= shape[i]
        }

        if isContiguous {
            memcpy(dest.advanced(by: destOffset), ptr, totalElements * MemoryLayout<Float32>.size)
        } else {
            copyWithStrides(
                from: ptr,
                to: dest,
                destOffset: destOffset,
                shape: shape,
                strides: strides,
                dim: 0,
                srcOffset: 0,
                destIdx: 0
            )
        }
    }

    @discardableResult
    private func copyWithStrides(
        from src: UnsafePointer<Float32>,
        to dest: UnsafeMutablePointer<Float32>,
        destOffset: Int,
        shape: [Int],
        strides: [Int],
        dim: Int,
        srcOffset: Int,
        destIdx: Int
    ) -> Int {
        var currentDestIdx = destIdx

        if dim == shape.count - 1 {
            for i in 0..<shape[dim] {
                dest[destOffset + currentDestIdx] = src[srcOffset + i * strides[dim]]
                currentDestIdx += 1
            }
        } else {
            for i in 0..<shape[dim] {
                currentDestIdx = copyWithStrides(
                    from: src,
                    to: dest,
                    destOffset: destOffset,
                    shape: shape,
                    strides: strides,
                    dim: dim + 1,
                    srcOffset: srcOffset + i * strides[dim],
                    destIdx: currentDestIdx
                )
            }
        }

        return currentDestIdx
    }

    private func extractOutputs(
        prediction: MLFeatureProvider,
        batchIndex: Int,
        policy: UnsafeMutablePointer<Float32>,
        policyPass: UnsafeMutablePointer<Float32>,
        value: UnsafeMutablePointer<Float32>,
        scoreValue: UnsafeMutablePointer<Float32>,
        ownership: UnsafeMutablePointer<Float32>
    ) {
        func requireOutput(_ name: String) -> MLMultiArray {
            guard let array = prediction.featureValue(for: name)?.multiArrayValue else {
                fatalError("Metal backend: CoreML prediction missing expected output: \(name)")
            }
            return array
        }

        let policyArray = requireOutput(IONames.policyOutput)
        let policyOffset = batchIndex * Int(nnXLen) * Int(nnYLen) * numPolicyChannels
        copyMultiArray(policyArray, to: policy, destOffset: policyOffset)

        let passArray = requireOutput(IONames.policyPassOutput)
        let passOffset = batchIndex * numPolicyChannels
        copyMultiArray(passArray, to: policyPass, destOffset: passOffset)

        let valueArray = requireOutput(IONames.valueOutput)
        let valueOffset = batchIndex * numValueChannels
        copyMultiArray(valueArray, to: value, destOffset: valueOffset)

        let svArray = requireOutput(IONames.scoreValueOutput)
        let svOffset = batchIndex * numScoreValueChannels
        copyMultiArray(svArray, to: scoreValue, destOffset: svOffset)

        let ownArray = requireOutput(IONames.ownershipOutput)
        let ownOffset = batchIndex * Int(nnXLen) * Int(nnYLen) * numOwnershipChannels
        copyMultiArray(ownArray, to: ownership, destOffset: ownOffset)
    }
}

/// Compiles an `.mlpackage` once per process run into `<cacheDir>/<name>.mlmodelc` (the app's cache keeps the compiled
/// model the same way), reusing it if it is already there.
func compiledCoreMLModel(_ pkg: URL, cacheDir: URL, recompile: Bool = false) async throws -> (URL, Double?) {
    let dst = cacheDir.appendingPathComponent(pkg.deletingPathExtension().lastPathComponent + ".mlmodelc")
    let fm = FileManager.default
    if !recompile && fm.fileExists(atPath: dst.path) { return (dst, nil) }
    try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    let t0 = nowNs()
    let tmp = try await MLModel.compileModel(at: pkg)
    let secs = Double(nowNs() - t0) / 1e9
    try? fm.removeItem(at: dst)
    try fm.moveItem(at: tmp, to: dst)
    return (dst, secs)
}
