//
//  TVCoreMLBenchmark.swift
//  KataGo Anytime TV
//
//  On-device CoreML diagnostics for the "why is Apple TV so slow?" investigation.
//  Benchmarks the built-in b18 net under all four `MLComputeUnits` settings
//  (CPU only / CPU+GPU / CPU+ANE / ALL) and reports, per config, both inference
//  throughput/latency AND a static per-op device-routing breakdown (ANE/GPU/CPU
//  op counts from `MLComputePlan`) — the definitive answer to "does the model
//  route to the Neural Engine?".
//
//  This is a PURE inference microbenchmark: it bypasses the GTP/MCTS engine
//  entirely, compiling the net once (compute units apply at MLModel LOAD time,
//  so all four configs reuse one `.mlmodelc`) and driving `MLModel.prediction`
//  directly with zeroed inputs. It calls `prediction` directly — NOT the engine's
//  `CoreMLComputeHandle.apply()`, which `fatalError`s on a prediction fault — so a
//  faulting config is caught and reported, never crashes the app.
//
//  The caller (TVSettingsScreen) quits the engine first (max memory headroom,
//  uncontended timings) and auto-restarts it after — see
//  `TVEngineController.restartEngine(duringDowntime:)`.
//
//  Caveat: the tvOS Simulator has no Neural Engine (CoreML falls back to CPU/host
//  GPU), so ANE routing/latency is only meaningful on real Apple TV hardware.
//

import CoreML
import Foundation
import KataGoUICore

@Observable
@MainActor
final class TVCoreMLBenchmark {
    /// One benchmarked compute-units configuration. Latency fields are nil when
    /// that config failed to load/predict (its `error` is set); routing fields are
    /// nil when `MLComputePlan` was unavailable or the structure couldn't be walked.
    struct Row: Identifiable {
        let config: String
        let infPerSec: Double?
        let medianMs: Double?
        let aneOps: Int?
        let gpuOps: Int?
        let cpuOps: Int?
        let error: String?
        var id: String { config }
    }

    enum State: Equatable {
        case idle
        case running(done: Int, total: Int)
        case finished([Row])
        case failed(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case let (.running(a, b), .running(c, d)): return a == c && b == d
            case let (.finished(a), .finished(b)): return a.map(\.id) == b.map(\.id)
            case let (.failed(a), .failed(b)): return a == b
            default: return false
            }
        }
    }

    private(set) var state: State = .idle

    /// The four compute-units settings, in the order shown in the results table.
    private nonisolated static let configs: [(name: String, units: MLComputeUnits)] = [
        ("CPU only", .cpuOnly),
        ("CPU + GPU", .cpuAndGPU),
        ("CPU + ANE", .cpuAndNeuralEngine),
        ("ALL", .all),
    ]

    /// Compile the built-in net once (19x19, tvOS batch size), then time + route
    /// each config sequentially. Safe to call while the engine is stopped.
    func run() async {
        state = .running(done: 0, total: Self.configs.count)
        do {
            let rows = try await Self.performBenchmark { done in
                await MainActor.run {
                    if case .running = self.state {
                        self.state = .running(done: done, total: Self.configs.count)
                    }
                }
            }
            state = .finished(rows)
        } catch {
            state = .failed(Self.shortError(error))
        }
    }

    // MARK: - Off-main benchmark body

    /// Runs off the main actor (nonisolated). Compiles once, then loops the four
    /// configs, releasing each `MLModel` before the next to bound peak memory.
    private nonisolated static func performBenchmark(
        progress: @escaping @Sendable (Int) async -> Void
    ) async throws -> [Row] {
        guard let netPath = Bundle.main.path(forResource: "default_model",
                                             ofType: "bin.gz") else {
            throw BenchmarkError.netMissing
        }

        // Compile-once. Compute units are applied at MLModel LOAD time, so this
        // single `.mlmodelc` is reused by all four configs. Matches the tvOS
        // engine's board size / batch size so it benchmarks the real artifact.
        let mlmodelc = try await convertOnCooperativePool(
            coremlModelPath: netPath,
            boardX: 19, boardY: 19,
            useFP16: true, optimizeMask: false,
            maxBatchSize: Int32(KataGoHelper.mlxNnMaxBatchSize),
            serverThreadIdx: 0)

        var rows: [Row] = []
        for entry in configs {
            let cfg = MLModelConfiguration()
            cfg.computeUnits = entry.units

            var infPerSec: Double?
            var medianMs: Double?
            var errorText: String?
            do {
                (infPerSec, medianMs) = try autoreleasepool {
                    () throws -> (Double, Double) in
                    let model = try MLModel(contentsOf: mlmodelc, configuration: cfg)
                    let features = try zeroInputs(for: model)
                    // Warmup — the first predictions include lazy ANE/GPU spin-up.
                    for _ in 0..<3 { _ = try model.prediction(from: features) }
                    // Timed loop: ~2s, at least 15 iterations.
                    var samplesNs: [UInt64] = []
                    let loopStart = DispatchTime.now().uptimeNanoseconds
                    repeat {
                        let t0 = DispatchTime.now().uptimeNanoseconds
                        _ = try model.prediction(from: features)
                        samplesNs.append(DispatchTime.now().uptimeNanoseconds - t0)
                    } while (DispatchTime.now().uptimeNanoseconds - loopStart) < 2_000_000_000
                        || samplesNs.count < 15
                    let totalNs = samplesNs.reduce(UInt64(0), +)
                    let ips = Double(samplesNs.count) / (Double(totalNs) / 1e9)
                    return (ips, median(samplesNs) / 1e6)
                }
            } catch {
                errorText = shortError(error)
            }

            // Static routing breakdown (after the timing model is released, so at
            // most one model-ish structure is resident at a time).
            let routing = await routing(url: mlmodelc, units: entry.units)

            rows.append(Row(config: entry.name,
                            infPerSec: infPerSec,
                            medianMs: medianMs,
                            aneOps: routing?.ane,
                            gpuOps: routing?.gpu,
                            cpuOps: routing?.cpu,
                            error: errorText))
            await progress(rows.count)
        }
        return rows
    }

    // MARK: - Inputs

    /// A feature provider of zero-filled inputs matching the model's own input
    /// shapes/dtypes. Input values don't affect dense conv/matmul timing, so zeros
    /// are a valid, net-agnostic stimulus (no hardcoded channel counts).
    private nonisolated static func zeroInputs(
        for model: MLModel
    ) throws -> MLDictionaryFeatureProvider {
        var dict: [String: MLFeatureValue] = [:]
        for (name, desc) in model.modelDescription.inputDescriptionsByName {
            guard let constraint = desc.multiArrayConstraint else { continue }
            let array = try MLMultiArray(shape: constraint.shape,
                                         dataType: constraint.dataType)
            array.withUnsafeMutableBytes { raw, _ in
                if let base = raw.baseAddress { memset(base, 0, raw.count) }
            }
            dict[name] = MLFeatureValue(multiArray: array)
        }
        return try MLDictionaryFeatureProvider(dictionary: dict)
    }

    // MARK: - Routing (MLComputePlan)

    /// Count each model operation's PREFERRED compute device under `units`. Returns
    /// nil if the compute plan can't be produced/walked (e.g. non-program structure).
    ///
    /// The walk itself lives in `KataGoUICore.CoreMLRoutingPlan` so the iOS
    /// backend-settings readout and this benchmark cannot diverge, and so the
    /// iOS-simulator test target can reach the shared type. This wrapper only
    /// reorders the fields into the column order the results table renders.
    private nonisolated static func routing(
        url: URL, units: MLComputeUnits
    ) async -> (ane: Int, gpu: Int, cpu: Int)? {
        guard let counts = await CoreMLRoutingPlan.deviceUsageCounts(
            compiledModelURL: url, computeUnits: units)
        else { return nil }
        return (counts.neuralEngine, counts.gpu, counts.cpu)
    }

    // MARK: - Helpers

    private nonisolated static func median(_ values: [UInt64]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return Double(sorted[mid - 1] + sorted[mid]) / 2.0
        }
        return Double(sorted[mid])
    }

    private nonisolated static func shortError(_ error: Error) -> String {
        let text = String(describing: error)
        return text.count > 80 ? String(text.prefix(80)) + "…" : text
    }

    private enum BenchmarkError: LocalizedError {
        case netMissing
        var errorDescription: String? {
            switch self {
            case .netMissing: return "Built-in network (default_model.bin.gz) not found in bundle."
            }
        }
    }
}
