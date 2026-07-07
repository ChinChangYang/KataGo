//
//  TVBenchmarkController.swift
//  KataGo Anytime TV
//
//  The CoreML-vs-MLX backend benchmark. Runs both legs sequentially IN THAT
//  ORDER — CoreML first, so if the never-characterized MLX leg jetsams the
//  process, the persisted default is still the safe CoreML (the winner is
//  persisted only at the very end, and TVSettingsStore.benchmarkInProgress
//  makes the next launch boot CoreML with an "aborted" note). Each leg:
//  restart the engine on that backend → run the SAME light continuous
//  kata-analyze the live game uses for a fixed window → read the visits/s the
//  app already computes from that stream. This deliberately avoids the heavy,
//  highly-concurrent `kata-benchmark` search that transiently faults the ANE
//  on Apple TV (the "crash after benchmarking" report) — live analysis is
//  known-stable, so measuring with it keeps the benchmark light. On the
//  Simulator the MLX leg is REFUSED, never faked: the sim device clamp would
//  silently measure CoreML twice.
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

    /// Seconds of light continuous analysis per leg. The app's visits/s is a
    /// running session average, so a few seconds is enough to stabilize; short
    /// enough that even a CPU-fallback CoreML sim leg finishes quickly.
    private static let measureWindow: Double = 8
    /// Matches the tvOS live game: a report roughly every 0.5 s (interval is in
    /// centiseconds), standard analysis breadth.
    private static let analysisInterval = 50
    private static let analysisMaxMoves = 30

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

    /// Measures NN throughput with the light, live-game analysis path instead
    /// of the heavy `kata-benchmark` search: reset the visits/s session, start
    /// the same continuous kata-analyze the live game streams, let it deepen
    /// for a fixed window, then read the visits/s GameSession already computes
    /// from that stream (`Analysis.updateVisitsPerSecond`). GameSession is
    /// @MainActor, so `analysis.visitsPerSecond` is safe to read here. Finally
    /// send `stop` so the engine idles before the next leg's restart. Returns
    /// nil if no visits accumulated (engine stuck / never produced a report).
    private func measureLeg(session: GameSession) async -> Double? {
        session.analysis.resetVisitsPerSecondSession()
        session.messageList.appendAndSend(
            commands: GtpCommandBuilder.continuousAnalyzeCommands(interval: Self.analysisInterval,
                                                                  maxMoves: Self.analysisMaxMoves))
        try? await Task.sleep(for: .seconds(Self.measureWindow))
        let visitsPerSecond = session.analysis.visitsPerSecond
        session.messageList.appendAndSend(command: "stop")
        return visitsPerSecond > 0 ? visitsPerSecond : nil
    }
}
