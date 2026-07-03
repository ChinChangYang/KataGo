//
//  TVBenchmarkController.swift
//  KataGo Anytime TV
//
//  The CoreML-vs-MLX backend benchmark. Runs both legs sequentially IN THAT
//  ORDER — CoreML first, so if the never-characterized MLX leg jetsams the
//  process, the persisted default is still the safe CoreML (the winner is
//  persisted only at the very end, and TVSettingsStore.benchmarkInProgress
//  makes the next launch boot CoreML with an "aborted" note). Each leg:
//  restart the engine on that backend → send `kata-benchmark N` → parse the
//  final visits/s from the engine's one concatenated output line (see
//  TVBenchmarkParser). On the Simulator the MLX leg is REFUSED, never faked:
//  the sim device clamp would silently measure CoreML twice.
//

import Foundation
import KataGoUICore

@Observable
@MainActor
final class TVBenchmarkController {
    enum State: Equatable {
        case idle
        case restarting(TVEngineBackend)
        case measuring(TVEngineBackend)
        case finished(TVBenchmarkResult)
        case failed(String)
    }

    private(set) var state: State = .idle

    /// 10 fixed positions × this many visits per position. Small enough that
    /// a CPU-fallback CoreML (~10 visits/s) still finishes in ~2 minutes;
    /// noisy-but-sufficient for the expected multiple-times gap.
    private static let visitsPerPosition = 100
    private static let legTimeout: Double = 300

    @ObservationIgnored private var measurement: CheckedContinuation<Double?, Never>?

    var isRunning: Bool {
        switch state {
        case .restarting, .measuring: return true
        default: return false
        }
    }

    func run(engine: TVEngineController, session: GameSession) async {
        guard !isRunning, engine.phase == .running else { return }
        TVSettingsStore.benchmarkInProgress = true

        var coreMLResult: Double?
        var mlxResult: Double?

        let legs: [TVEngineBackend] = TVEngineBackend.mlxIsAvailable ? [.coreML, .mlx] : [.coreML]
        for leg in legs {
            // Only restart when the leg actually differs from the running
            // backend: quitting an engine that has just run a benchmark can
            // take minutes to tear down (observed in-app), so every avoided
            // restart matters — and on the Simulator (CoreML-only) this makes
            // the whole benchmark restart-free.
            if engine.currentBackend != leg {
                state = .restarting(leg)
                guard await engine.restart(to: leg, persistOnSuccess: false) else {
                    TVSettingsStore.benchmarkInProgress = false
                    state = .failed("\(leg.displayName) failed to start.")
                    return
                }
            }

            state = .measuring(leg)
            let visitsPerSecond = await measureLeg(session: session)
            guard let visitsPerSecond else {
                TVSettingsStore.benchmarkInProgress = false
                state = .failed("\(leg.displayName) produced no benchmark result.")
                // Leave the app usable: fall back to the safe default.
                if leg != .coreML {
                    _ = await engine.restart(to: .coreML, persistOnSuccess: false)
                }
                return
            }
            switch leg {
            case .coreML: coreMLResult = visitsPerSecond
            case .mlx: mlxResult = visitsPerSecond
            }
        }

        var result = TVBenchmarkResult(coreMLVisitsPerSecond: coreMLResult,
                                       mlxVisitsPerSecond: mlxResult,
                                       date: Date.now)
        if !TVEngineBackend.mlxIsAvailable {
            // Simulator: the MLX leg was refused; record the partial run.
            result.aborted = true
        }
        TVSettingsStore.lastBenchmark = result

        // Persist the winner and leave the engine running on it.
        let winner = result.winner
        TVSettingsStore.backend = winner
        if engine.currentBackend != winner {
            state = .restarting(winner)
            _ = await engine.restart(to: winner, persistOnSuccess: true)
        }
        TVSettingsStore.benchmarkInProgress = false
        state = .finished(result)
    }

    /// Sends kata-benchmark and waits for the parsable final line via the
    /// session's out-of-band line tap (the bridge keeps its single reader —
    /// the regular read loop — so we observe, never read). The observer runs
    /// off the main actor (GameSession.messaging is non-isolated), so it
    /// parses synchronously and hops to resolve.
    private func measureLeg(session: GameSession) async -> Double? {
        defer {
            session.lineObserver = nil
            measurement = nil
        }
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.legTimeout))
            guard !Task.isCancelled else { return }
            self?.finishMeasurement(with: nil)
        }
        defer { timeout.cancel() }

        return await withCheckedContinuation { continuation in
            measurement = continuation
            session.lineObserver = { [weak self] line in
                if let visitsPerSecond = TVBenchmarkParser.parseFinalVisitsPerSecond(line: line) {
                    Task { @MainActor in self?.finishMeasurement(with: visitsPerSecond) }
                } else if TVBenchmarkParser.isErrorReply(line) {
                    Task { @MainActor in self?.finishMeasurement(with: nil) }
                }
            }
            session.messageList.appendAndSend(command: "kata-benchmark \(Self.visitsPerPosition)")
        }
    }

    /// Idempotent: the first of {result line, error line, timeout} wins.
    private func finishMeasurement(with value: Double?) {
        measurement?.resume(returning: value)
        measurement = nil
    }
}
