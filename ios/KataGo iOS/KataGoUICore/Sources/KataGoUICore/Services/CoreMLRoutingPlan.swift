//
//  CoreMLRoutingPlan.swift
//  KataGo Anytime
//
//  Static per-operation compute-device breakdown for a compiled Core ML
//  model, read from `MLComputePlan`. Shared by the iOS backend-settings
//  routing readout (`CoreMLRoutingProbe`) and the tvOS Core ML benchmark
//  (`TVCoreMLBenchmark`).
//
//  What this measures — and what it does NOT: `MLComputePlan` reports the
//  device Core ML says it PREFERS for each operation at plan time. It is not
//  an execution trace. On real Apple TV hardware the `.all` plan reported
//  every operation on CPU while the model measured GPU-class throughput, so
//  the GPU column in particular cannot be trusted as "what ran where". The
//  CPU-vs-Neural-Engine split under `.cpuAndNeuralEngine` DID track measured
//  behaviour there (ANE = 0 ops, and CPU+ANE measured slower than CPU-only),
//  and that split is the only comparison the iOS readout draws.
//

import CoreML
import Foundation

/// Per-operation compute-device tally for one compiled Core ML model.
public struct CoreMLDeviceUsageCounts: Sendable, Equatable {
    public let cpu: Int
    public let gpu: Int
    public let neuralEngine: Int

    public init(cpu: Int, gpu: Int, neuralEngine: Int) {
        self.cpu = cpu
        self.gpu = gpu
        self.neuralEngine = neuralEngine
    }

    public var total: Int { cpu + gpu + neuralEngine }

    /// Whole-percent share of `count` within `total`, or nil when the model
    /// reported no operations at all (nothing to divide by).
    ///
    /// Two deliberate clamps keep the rendered split honest at the extremes:
    /// a nonzero count that would round to 0% shows as 1%, and a count short
    /// of the total that would round to 100% shows as 99%. Without them a
    /// single CPU-resident operation out of 1300 reads as "0% CPU / 100%
    /// Neural Engine", i.e. as no fallback at all.
    public func percentShare(of count: Int) -> Int? {
        guard total > 0 else { return nil }
        let rounded = Int((Double(count) * 100.0 / Double(total)).rounded())
        if count > 0 && rounded == 0 { return 1 }
        if count < total && rounded == 100 { return 99 }
        return rounded
    }
}

public enum CoreMLRoutingPlan {
    /// Count each operation's preferred compute device in the compiled model
    /// at `compiledModelURL` (an `.mlmodelc`) under `computeUnits`.
    ///
    /// Never throws. Returns nil when the compute plan cannot be produced or
    /// the model structure is not a program. Callers that hold a
    /// `PinnedCacheURL` across this call depend on that: a throw between
    /// acquiring and releasing the pin would strand it and block eviction.
    public static func deviceUsageCounts(
        compiledModelURL: URL,
        computeUnits: MLComputeUnits
    ) async -> CoreMLDeviceUsageCounts? {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits

        guard let plan = try? await MLComputePlan.load(contentsOf: compiledModelURL,
                                                      configuration: configuration),
              case .program(let program) = plan.modelStructure
        else { return nil }

        var cpu = 0
        var gpu = 0
        var neuralEngine = 0

        func classify(_ device: MLComputeDevice) {
            switch device {
            case .cpu: cpu += 1
            case .gpu: gpu += 1
            case .neuralEngine: neuralEngine += 1
            @unknown default: break
            }
        }

        func walk(_ operations: [MLModelStructure.Program.Operation]) {
            for operation in operations {
                if let usage = plan.deviceUsage(for: operation) {
                    classify(usage.preferred)
                }
                for block in operation.blocks { walk(block.operations) }
            }
        }

        for function in program.functions.values {
            walk(function.block.operations)
        }

        return CoreMLDeviceUsageCounts(cpu: cpu, gpu: gpu, neuralEngine: neuralEngine)
    }
}
