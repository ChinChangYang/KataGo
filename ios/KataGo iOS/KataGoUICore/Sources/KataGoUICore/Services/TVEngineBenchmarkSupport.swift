//
//  TVEngineBenchmarkSupport.swift
//  KataGoUICore
//
//  Pure support types for the tvOS backend picker + CoreML-vs-MLX benchmark.
//  They live in the package (not the TV target) so the iOS test target can
//  pin them — the RecoveryDecision precedent — and are inert everywhere else:
//  nothing outside the TV app references them.
//

import Foundation

/// The tvOS engine backend choice. Maps to the NN-server device-code arrays
/// `runGtp(deviceAssignments:)` takes (0 = MLX/GPU, 100 = CoreML). The TV app
/// passes these explicit arrays, deliberately bypassing the conservative tvOS
/// clamps in BackendChoice/EngineDeviceAssignments (which keep protecting all
/// default-argument launch paths).
public enum TVEngineBackend: String, CaseIterable, Sendable {
    case coreML
    case mlx

    public var displayName: String {
        switch self {
        case .coreML: return "CoreML / Neural Engine"
        case .mlx: return "MLX / GPU"
        }
    }

    /// The simulator's Metal layer crashes MLX (same as the iOS sim), so both
    /// choices clamp to CoreML there.
    public var deviceAssignments: [Int] {
        #if targetEnvironment(simulator)
        return [100]
        #else
        switch self {
        case .coreML: return [100]
        case .mlx: return [0]
        }
        #endif
    }

    /// False where the MLX leg must be REFUSED (never silently faked): the
    /// simulator would otherwise "benchmark" CoreML twice.
    public static var mlxIsAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }
}

/// Parses `kata-benchmark`'s output. The engine prints per-position progress
/// as "\r"-separated chunks WITHOUT newlines and the final result line with
/// one trailing newline — so the bridge's line reader delivers a single
/// mega-line: every progress chunk concatenated, ending with the final
/// result. Only the final `BenchmarkResults::toString()` chunk contains
/// "nnEvals/s" (playutils.cpp), which disambiguates it from the
/// `toStringNotDone()` progress chunks.
public enum TVBenchmarkParser {
    public static func parseFinalVisitsPerSecond(line: String) -> Double? {
        guard let chunk = line.split(separator: "\r").last else { return nil }
        guard let match = chunk.firstMatch(of: /visits\/s = ([0-9.]+) nnEvals\/s/) else { return nil }
        return Double(match.1)
    }

    public static func isErrorReply(_ line: String) -> Bool {
        line.hasPrefix("? ")
    }
}

/// One benchmark run's outcome, persisted as JSON in UserDefaults.
public struct TVBenchmarkResult: Codable, Equatable, Sendable {
    public var coreMLVisitsPerSecond: Double?
    public var mlxVisitsPerSecond: Double?
    public var date: Date
    public var aborted: Bool

    public init(coreMLVisitsPerSecond: Double?,
                mlxVisitsPerSecond: Double?,
                date: Date,
                aborted: Bool = false) {
        self.coreMLVisitsPerSecond = coreMLVisitsPerSecond
        self.mlxVisitsPerSecond = mlxVisitsPerSecond
        self.date = date
        self.aborted = aborted
    }

    /// MLX must strictly beat CoreML to win; any missing number falls back to
    /// the safe CoreML default.
    public var winner: TVEngineBackend {
        guard let coreML = coreMLVisitsPerSecond,
              let mlx = mlxVisitsPerSecond else { return .coreML }
        return mlx > coreML ? .mlx : .coreML
    }
}

/// Pure launch-time decision (mirrors RecoveryDecision): if the app died
/// while an engine spawn was pending or a benchmark was running, the next
/// launch must boot the safe CoreML backend and clear the sentinels —
/// regardless of the persisted choice (which may be the very backend that
/// killed the process).
public enum TVBackendRecovery {
    public static func launchBackend(
        persistedRaw: String?,
        pendingEngineBackendRaw: String?,
        benchmarkWasInProgress: Bool
    ) -> (backend: TVEngineBackend, mustClearSentinels: Bool) {
        if pendingEngineBackendRaw != nil || benchmarkWasInProgress {
            return (.coreML, true)
        }
        let backend = persistedRaw.flatMap(TVEngineBackend.init(rawValue:)) ?? .coreML
        return (backend, false)
    }
}
