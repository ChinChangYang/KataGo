//
//  CoreMLRoutingProbeTests.swift
//  KataGo AnytimeTests
//
//  Covers the Core ML routing readout's state machine, the percentage math
//  it renders, and the aux-net projection rule that keys the bundled
//  human-SL network to the SELECTED model rather than the built-in.
//
//  Not covered here, deliberately: the `MLComputePlan` walk itself.
//  `MLModelStructure.Program.Operation` has no public initializer, so the
//  walk cannot be driven with synthetic input, and the Simulator has no
//  Neural Engine — a real probe there always reports every operation on the
//  CPU. The walk is exercised end-to-end only on device.
//

import Foundation
import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

// MARK: - Percentage math

struct CoreMLDeviceUsageCountsTests {
    @Test func percentShareIsNilWhenThereAreNoOperations() {
        let counts = CoreMLDeviceUsageCounts(cpu: 0, gpu: 0, neuralEngine: 0)
        #expect(counts.total == 0)
        #expect(counts.percentShare(of: 0) == nil)
    }

    @Test func percentShareSplitsAnEvenModel() {
        let counts = CoreMLDeviceUsageCounts(cpu: 50, gpu: 0, neuralEngine: 50)
        #expect(counts.percentShare(of: counts.neuralEngine) == 50)
        #expect(counts.percentShare(of: counts.cpu) == 50)
    }

    /// A single CPU-resident operation out of 1302 must not render as "0%
    /// CPU / 100% Neural Engine" — that reads as no fallback at all.
    @Test func tinyNonZeroShareClampsToOnePercent() {
        let counts = CoreMLDeviceUsageCounts(cpu: 1, gpu: 0, neuralEngine: 1301)
        #expect(counts.percentShare(of: counts.cpu) == 1)
        #expect(counts.percentShare(of: counts.neuralEngine) == 99)
    }

    /// The complement clamp only applies when something is actually missing.
    @Test func fullShareStillReadsAsOneHundredPercent() {
        let counts = CoreMLDeviceUsageCounts(cpu: 0, gpu: 0, neuralEngine: 1302)
        #expect(counts.percentShare(of: counts.neuralEngine) == 100)
        #expect(counts.percentShare(of: counts.cpu) == 0)
    }

    @Test func totalSumsEveryDevice() {
        let counts = CoreMLDeviceUsageCounts(cpu: 3, gpu: 5, neuralEngine: 7)
        #expect(counts.total == 15)
    }
}

// MARK: - Probe state machine

@MainActor
struct CoreMLRoutingProbeStateTests {
    private static func inputs(nnLen: Int32) -> ProjectionInputs {
        ProjectionInputs(sourcePath: "/tmp/net.bin.gz",
                         nnXLen: nnLen, nnYLen: nnLen,
                         requireExactNNLen: false,
                         useFP16: true,
                         maxBatchSize: 2)
    }

    private static func target(_ label: String,
                               digest: String,
                               nnLen: Int32 = 19) -> CoreMLRoutingTarget {
        CoreMLRoutingTarget(label: label, digest: digest, inputs: inputs(nnLen: nnLen))
    }

    private static func model() throws -> NeuralNetworkModel {
        try #require(NeuralNetworkModel.allCases.first)
    }

    private static func environment(
        targets: [CoreMLRoutingTarget]?,
        cached: Bool = true,
        routing: @escaping @Sendable (CoreMLRoutingTarget) async -> CoreMLDeviceUsageCounts?
            = { _ in CoreMLDeviceUsageCounts(cpu: 2, gpu: 0, neuralEngine: 98) }
    ) -> CoreMLRoutingProbeEnvironment {
        CoreMLRoutingProbeEnvironment(
            resolveTargets: { _ in targets },
            allCached: { _ in cached },
            routing: routing)
    }

    @Test func missingSourceReportsSourceMissingAndNeverRuns() async throws {
        let probe = CoreMLRoutingProbe(model: try Self.model(),
                                       environment: Self.environment(targets: nil))
        await probe.refresh()
        #expect(probe.readiness == .sourceMissing)

        // `run()` must be inert with no targets — the button is not offered
        // in this state, but a stale tap must not produce a bogus result.
        await probe.run()
        #expect(probe.phase == .idle)
    }

    @Test func cachedArtifactsReportCachedReadiness() async throws {
        let probe = CoreMLRoutingProbe(
            model: try Self.model(),
            environment: Self.environment(targets: [Self.target("Main", digest: "a")],
                                          cached: true))
        await probe.refresh()
        #expect(probe.readiness == .cached)
        #expect(probe.phase == .idle)
    }

    @Test func uncachedArtifactsReportNeedsCompile() async throws {
        let probe = CoreMLRoutingProbe(
            model: try Self.model(),
            environment: Self.environment(targets: [Self.target("Main", digest: "a")],
                                          cached: false))
        await probe.refresh()
        #expect(probe.readiness == .needsCompile)
    }

    @Test func runReportsOneResultPerNetInOrder() async throws {
        let targets = [Self.target("Main", digest: "a"),
                       Self.target("Aux", digest: "b")]
        let probe = CoreMLRoutingProbe(
            model: try Self.model(),
            environment: Self.environment(targets: targets, cached: true,
                                          routing: { target in
                target.digest == "a"
                    ? CoreMLDeviceUsageCounts(cpu: 1, gpu: 0, neuralEngine: 99)
                    : CoreMLDeviceUsageCounts(cpu: 4, gpu: 0, neuralEngine: 96)
            }))
        await probe.refresh()
        await probe.run()

        guard case .finished(let results) = probe.phase else {
            Issue.record("expected a finished phase, got \(probe.phase)")
            return
        }
        #expect(results.map(\.label) == ["Main", "Aux"])
        #expect(results[0].counts.neuralEngine == 99)
        #expect(results[1].counts.cpu == 4)
        #expect(probe.measuredBoardLength == 19)
    }

    /// A conversion or unreadable compute plan fails the whole readout rather
    /// than reporting a partial split that looks authoritative.
    @Test func anyNetFailingFailsTheReadout() async throws {
        let targets = [Self.target("Main", digest: "a"),
                       Self.target("Aux", digest: "b")]
        let probe = CoreMLRoutingProbe(
            model: try Self.model(),
            environment: Self.environment(targets: targets, cached: true,
                                          routing: { target in
                target.digest == "a"
                    ? CoreMLDeviceUsageCounts(cpu: 1, gpu: 0, neuralEngine: 99)
                    : nil
            }))
        await probe.refresh()
        await probe.run()
        #expect(probe.phase == .failed)
        #expect(probe.measuredBoardLength == nil)
    }

    /// A completed run has compiled whatever was missing, so the button must
    /// stop threatening another compile.
    @Test func successfulRunDowngradesNeedsCompileToCached() async throws {
        let probe = CoreMLRoutingProbe(
            model: try Self.model(),
            environment: Self.environment(targets: [Self.target("Main", digest: "a")],
                                          cached: false))
        await probe.refresh()
        #expect(probe.readiness == .needsCompile)
        await probe.run()
        #expect(probe.readiness == .cached)
    }

    /// Board size changes the artifact, so `refresh()` must drop any result
    /// on screen rather than leaving a number for a geometry the user left.
    @Test func refreshClearsAPreviousResult() async throws {
        let probe = CoreMLRoutingProbe(
            model: try Self.model(),
            environment: Self.environment(targets: [Self.target("Main", digest: "a")]))
        await probe.refresh()
        await probe.run()
        #expect(probe.measuredBoardLength != nil)
        if case .finished = probe.phase {} else {
            Issue.record("expected a finished phase before refresh")
        }

        await probe.refresh()
        #expect(probe.phase == .idle)
        #expect(probe.measuredBoardLength == nil)
    }

    /// Regression: a run that finishes AFTER a board-size change must not
    /// publish. `refresh()` clears the phase and swaps in new targets, but an
    /// in-flight loop already holds its own copy of the old array — without a
    /// generation guard it overwrites the cleared state with results for the
    /// geometry the user just left.
    @Test func aRunThatOutlivesARefreshPublishesNothing() async throws {
        // Gate the routing closure so the run is still in flight when the
        // refresh lands.
        let gate = AsyncGate()
        let probe = CoreMLRoutingProbe(
            model: try Self.model(),
            environment: Self.environment(
                targets: [Self.target("Main", digest: "a", nnLen: 19)],
                cached: true,
                routing: { _ in
                    await gate.wait()
                    return CoreMLDeviceUsageCounts(cpu: 1, gpu: 0, neuralEngine: 99)
                }))
        await probe.refresh()

        let running = Task { await probe.run() }
        await gate.waitUntilWaiting()
        #expect(probe.phase == .running)

        // The user switches board size mid-run.
        await probe.refresh()
        #expect(probe.phase == .idle)

        // The original run now completes. It must stay silent.
        await gate.open()
        await running.value
        #expect(probe.phase == .idle)
        #expect(probe.measuredBoardLength == nil)
    }

    @Test func measuredBoardLengthFollowsTheProjectedGeometry() async throws {
        let probe = CoreMLRoutingProbe(
            model: try Self.model(),
            environment: Self.environment(
                targets: [Self.target("Main", digest: "a", nnLen: 37)]))
        await probe.refresh()
        await probe.run()
        #expect(probe.measuredBoardLength == 37)
    }
}

// MARK: - Test support

/// A one-shot gate: `wait()` suspends until `open()` is called, and
/// `waitUntilWaiting()` lets the test observe that a waiter has arrived.
/// Lets a test hold a probe's routing closure open so a refresh can land
/// while the run is genuinely mid-flight.
private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var hasWaiter = false

    func wait() async {
        if isOpen { return }
        hasWaiter = true
        for arrival in arrivals { arrival.resume() }
        arrivals.removeAll()
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Suspends until some task is parked inside `wait()`.
    func waitUntilWaiting() async {
        if hasWaiter { return }
        await withCheckedContinuation { arrivals.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

// Aux-net projection coverage lives in `CoreMLCacheReadinessProjectionTests`,
// next to the rest of the projection's contract tests.
