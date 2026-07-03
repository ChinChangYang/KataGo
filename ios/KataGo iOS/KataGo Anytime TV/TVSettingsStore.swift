//
//  TVSettingsStore.swift
//  KataGo Anytime TV
//
//  TV-local persisted settings (UserDefaults, BackendSettings-style statics).
//  The engine-backend keys implement the crash-safe launch ladder: a sentinel
//  armed before every engine spawn (cleared on the version handshake) plus a
//  benchmark-in-progress flag mean a jetsam during an MLX experiment can
//  never wedge the app — the next launch always boots the safe CoreML
//  default via TVBackendRecovery.
//

import Foundation
import KataGoUICore

enum TVSettingsStore {
    private static let backendKey = "TVSettings.backend"
    private static let pendingEngineBackendKey = "TVSettings.pendingEngineBackend"
    private static let benchmarkInProgressKey = "TVSettings.benchmarkInProgress"
    private static let soundEffectsKey = "TVSettings.soundEffects"
    private static let lastBenchmarkKey = "TVSettings.lastBenchmark"

    /// The persisted default backend (what a clean launch boots).
    static var backend: TVEngineBackend {
        get {
            UserDefaults.standard.string(forKey: backendKey)
                .flatMap(TVEngineBackend.init(rawValue:)) ?? .coreML
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: backendKey) }
    }

    /// Armed with the backend being started immediately BEFORE every engine
    /// spawn; cleared when the `version` handshake succeeds. Found armed at
    /// launch ⇒ the previous spawn killed the process.
    static var pendingEngineBackend: TVEngineBackend? {
        get {
            UserDefaults.standard.string(forKey: pendingEngineBackendKey)
                .flatMap(TVEngineBackend.init(rawValue:))
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.rawValue, forKey: pendingEngineBackendKey)
            } else {
                UserDefaults.standard.removeObject(forKey: pendingEngineBackendKey)
            }
            UserDefaults.standard.synchronize()
        }
    }

    /// True while the benchmark flow owns the engine. Found set at launch ⇒
    /// the app died mid-benchmark; boot CoreML and note the aborted run.
    static var benchmarkInProgress: Bool {
        get { UserDefaults.standard.bool(forKey: benchmarkInProgressKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: benchmarkInProgressKey)
            UserDefaults.standard.synchronize()
        }
    }

    /// Stone/capture sounds. Defaults ON (the user asked for sound).
    static var soundEffects: Bool {
        get {
            if UserDefaults.standard.object(forKey: soundEffectsKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: soundEffectsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: soundEffectsKey) }
    }
    static var soundEffectsKeyName: String { soundEffectsKey }

    static var lastBenchmark: TVBenchmarkResult? {
        get {
            UserDefaults.standard.data(forKey: lastBenchmarkKey)
                .flatMap { try? JSONDecoder().decode(TVBenchmarkResult.self, from: $0) }
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: lastBenchmarkKey)
            } else {
                UserDefaults.standard.removeObject(forKey: lastBenchmarkKey)
            }
        }
    }

    /// The launch-time backend decision: applies TVBackendRecovery, clears
    /// tripped sentinels, and records an aborted-benchmark result so the
    /// Settings footer can explain what happened.
    static func resolveLaunchBackendApplyingRecovery() -> TVEngineBackend {
        let decision = TVBackendRecovery.launchBackend(
            persistedRaw: UserDefaults.standard.string(forKey: backendKey),
            pendingEngineBackendRaw: UserDefaults.standard.string(forKey: pendingEngineBackendKey),
            benchmarkWasInProgress: benchmarkInProgress
        )
        if decision.mustClearSentinels {
            if benchmarkInProgress {
                lastBenchmark = TVBenchmarkResult(coreMLVisitsPerSecond: nil,
                                                  mlxVisitsPerSecond: nil,
                                                  date: Date.now,
                                                  aborted: true)
            }
            pendingEngineBackend = nil
            benchmarkInProgress = false
            backend = decision.backend
        }
        return decision.backend
    }
}
