//
//  CoreMLRoutingProbe.swift
//  KataGo Anytime
//
//  Drives the "Core ML Routing" section of `BackendConfigSheet`: how many
//  operations of the networks this model's engine would load are placed on
//  the Neural Engine versus falling back to the CPU.
//
//  Why it exists: iOS is the only platform with a backend picker (MLX/GPU,
//  CoreML/NE, GPU+ANE). The one thing a user needs in order to choose is
//  whether Core ML actually reaches the Neural Engine for THEIR network at
//  THEIR board size — if almost everything falls back to CPU, MLX/GPU is the
//  better pick. macOS (fixed mux), visionOS (pinned ANE) and tvOS (pinned
//  CPU+GPU) expose no such choice and deliberately do not show this.
//
//  Design notes that are easy to get wrong:
//
//  * It inspects the REAL cached artifact — same digest, same geometry, same
//    batch size the next engine launch computes — not a fresh hardcoded
//    19x19 conversion. Board size materially changes segmentation, so a
//    hardcoded size would report routing for a model the engine never runs.
//  * `maxBoardSizeForNNBuffer` is engine-wide, so BOTH nets (the selected
//    model and the bundled human-SL aux) are keyed at the selected model's
//    `effectiveMaxBoardLength`. See `auxNetProjection(keyedTo:)`.
//  * It reads under `.cpuAndNeuralEngine` because that is what the engine
//    loads with (`CoreMLComputeHandleLoader.loadCoreMLHandle`). GPU is
//    forbidden in that configuration, so a GPU count is structurally zero
//    and is never rendered — the GPU path is MLX/GPU, a different backend.
//  * A cache miss converts through `CoreMLModelCache.urlForKey` with the
//    engine's own miss callback, so the probed bytes ARE the engine's bytes
//    and the work warms the cache for a subsequent switch to CoreML/NE.
//  * `run()` is deliberately NOT cancelled when the sheet is dismissed: on
//    iOS this sheet is only reachable from the model picker with the engine
//    stopped, so the user's very next action is usually Play, which wants
//    that exact artifact. Cancelling would discard 30s of work and then make
//    them wait for it again.
//

import CoreML
import CoreMLCacheKit
import Foundation
import KataGoUICore

/// One net to probe: its display label, the cache digest the engine launch
/// would compute for it, and the primitives needed to convert it on a miss.
struct CoreMLRoutingTarget: Sendable, Equatable, Identifiable {
    let label: String
    let digest: String
    let inputs: ProjectionInputs

    var id: String { digest }
}

/// One net's finished routing readout.
struct CoreMLRoutingResult: Sendable, Equatable, Identifiable {
    let label: String
    let counts: CoreMLDeviceUsageCounts

    var id: String { label }
}

/// Injectable seams, so the state machine is testable without CoreML.
struct CoreMLRoutingProbeEnvironment: Sendable {
    /// The nets an engine launch with this model selected would convert, in
    /// display order. Returns nil when a source file is absent — the "not
    /// downloaded yet" case, which is not an error.
    var resolveTargets: @Sendable (NeuralNetworkModel) async -> [CoreMLRoutingTarget]?
    /// Whether every target already has a compiled entry on disk.
    var allCached: @Sendable ([CoreMLRoutingTarget]) async -> Bool
    /// Compiled-artifact routing for one target. nil on any failure —
    /// conversion, compilation, or an unreadable compute plan.
    var routing: @Sendable (CoreMLRoutingTarget) async -> CoreMLDeviceUsageCounts?

    static let live = CoreMLRoutingProbeEnvironment(
        resolveTargets: { model in
            guard let main = mainNetProjection(for: model) else { return nil }
            // The aux net ships in the bundle, so a nil here means a broken
            // install rather than a pending download; treat it as absent and
            // report the main net alone rather than failing the whole probe.
            let aux = auxNetProjection(keyedTo: model)

            let labelled: [(String, ProjectionInputs)] =
                [(model.title, main)] + (aux.map { [(humanSLAuxLabel, $0)] } ?? [])

            var targets: [CoreMLRoutingTarget] = []
            for (label, inputs) in labelled {
                // `projectedDigest` yields nil for a source file that is not
                // on disk, and throws only on a hasher failure. Either way
                // there is no artifact to describe.
                let projected = try? await CoreMLModelCache.projectedDigest(
                    forSourcePath: inputs.sourcePath,
                    nnXLen: inputs.nnXLen, nnYLen: inputs.nnYLen,
                    requireExactNNLen: inputs.requireExactNNLen,
                    useFP16: inputs.useFP16,
                    maxBatchSize: inputs.maxBatchSize,
                    downloadedHasher: BinFileHasher.shared.identityForDownloadedFile)
                guard let digest = projected ?? nil else { return nil }
                targets.append(CoreMLRoutingTarget(label: label, digest: digest, inputs: inputs))
            }
            return targets
        },
        allCached: { targets in
            guard !targets.isEmpty else { return false }
            await CoreMLModelCache.shared.start()
            for target in targets {
                let cached = await CoreMLModelCache.shared.hasEntry(digest: target.digest)
                if !cached { return false }
            }
            return true
        },
        routing: { target in
            await CoreMLModelCache.shared.start()
            let inputs = target.inputs
            let sourceFileName = (inputs.sourcePath as NSString).lastPathComponent
            guard let pinned = try? await CoreMLModelCache.shared.urlForKey(
                digest: target.digest,
                priority: .userInitiated,
                sourceFileName: sourceFileName,
                missCallback: {
                    try await convertOnCooperativePool(
                        coremlModelPath: inputs.sourcePath,
                        boardX: inputs.nnXLen, boardY: inputs.nnYLen,
                        useFP16: inputs.useFP16,
                        optimizeMask: inputs.requireExactNNLen,
                        maxBatchSize: Int32(inputs.maxBatchSize),
                        serverThreadIdx: 0)
                })
            else { return nil }
            // `deviceUsageCounts` never throws, so the pin cannot be stranded
            // between here and `release()`.
            let counts = await CoreMLRoutingPlan.deviceUsageCounts(
                compiledModelURL: pinned.url,
                computeUnits: engineCoreMLComputeUnits)
            await pinned.release()
            return counts
        })
}

/// The compute units the engine loads Core ML models with — see
/// `CoreMLComputeHandleLoader.loadCoreMLHandle`. Named here so the readout
/// and the engine cannot silently disagree about which configuration is
/// being described. GPU is not among them, which is why the readout shows
/// no GPU column.
let engineCoreMLComputeUnits: MLComputeUnits = .cpuAndNeuralEngine

/// Display name for the bundled human-SL auxiliary network.
let humanSLAuxLabel = String(localized: "Human-style network")

@MainActor
@Observable
final class CoreMLRoutingProbe {
    /// What the action button can do right now.
    enum Readiness: Equatable {
        /// Resolving digests and cache state. The button is usable; only its
        /// wording is still provisional.
        case resolving
        /// Every artifact is compiled — reading routing is quick.
        case cached
        /// At least one artifact must be converted first (tens of seconds).
        case needsCompile
        /// The network file is not on disk yet.
        case sourceMissing
    }

    enum Phase: Equatable {
        case idle
        case running
        case finished([CoreMLRoutingResult])
        case failed
    }

    private(set) var readiness: Readiness = .resolving
    private(set) var phase: Phase = .idle
    /// Board length the displayed results were produced at, for the footer.
    private(set) var measuredBoardLength: Int?

    private let model: NeuralNetworkModel
    private let environment: CoreMLRoutingProbeEnvironment
    private var targets: [CoreMLRoutingTarget] = []

    /// Bumped by every `refresh()`. A `run()` captures the value it started
    /// under and publishes nothing if it no longer matches.
    ///
    /// Without this, changing Max Board Size mid-run reintroduces exactly the
    /// staleness the refresh exists to prevent: `refresh()` clears the phase
    /// and swaps in new targets, but the in-flight loop is already iterating
    /// its own copy of the old array (Swift arrays are values) and would then
    /// overwrite the cleared state with results for the geometry the user
    /// just left. The conversion itself is still allowed to finish — it is
    /// committed to the cache either way.
    private var generation = 0

    init(model: NeuralNetworkModel,
         environment: CoreMLRoutingProbeEnvironment = .live) {
        self.model = model
        self.environment = environment
    }

    /// Resolve digests and cache state, discarding any displayed result.
    ///
    /// Called when the section appears and again whenever Max Board Size
    /// changes — a different board length is a different artifact, so any
    /// result on screen describes a geometry the user is no longer on.
    func refresh() async {
        generation &+= 1
        let generationAtStart = generation
        readiness = .resolving
        phase = .idle
        measuredBoardLength = nil
        targets = []

        guard let resolved = await environment.resolveTargets(model) else {
            guard generation == generationAtStart else { return }
            readiness = .sourceMissing
            return
        }
        let cached = await environment.allCached(resolved)
        // A newer refresh may have landed while those awaits were suspended.
        guard generation == generationAtStart else { return }
        targets = resolved
        readiness = cached ? .cached : .needsCompile
    }

    /// Read routing for every target. Runs to completion even if the sheet is
    /// dismissed mid-flight, so a conversion the user already waited for is
    /// committed to the cache rather than thrown away.
    func run() async {
        guard !targets.isEmpty, phase != .running else { return }
        let generationAtStart = generation
        phase = .running

        var results: [CoreMLRoutingResult] = []
        for target in targets {
            guard let counts = await environment.routing(target) else {
                guard generation == generationAtStart else { return }
                phase = .failed
                return
            }
            results.append(CoreMLRoutingResult(label: target.label, counts: counts))
        }

        guard generation == generationAtStart else { return }
        measuredBoardLength = targets.first.map { Int($0.inputs.nnXLen) }
        phase = .finished(results)
        // Anything that needed converting has now been committed.
        readiness = .cached
    }
}
