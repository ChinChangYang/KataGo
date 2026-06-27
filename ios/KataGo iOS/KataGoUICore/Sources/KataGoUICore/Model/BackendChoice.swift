//
//  BackendChoice.swift
//  KataGo Anytime
//

import Foundation

/// User-facing inference backend for a model. `.mlxGPU` and `.coremlNE` run a
/// single NN-server thread on one device; `.mux` runs both engines in parallel
/// (GPU∥ANE) for best throughput at the cost of higher memory. The real
/// per-server-thread device mapping is `deviceAssignments` (which also applies
/// the simulator GPU clamp); `mlxDeviceToUse` is only the single-device code.
public enum BackendChoice: String, CaseIterable, Identifiable {
    case mlxGPU = "MLX/GPU"
    case coremlNE = "CoreML/NE"
    case mux = "GPU+ANE"

    public var id: String { rawValue }

    /// Upper bound for the per-model search-thread control (and the clamp
    /// applied to persisted values). 32 gives headroom well above current
    /// iPhone/iPad core counts for users who want to push throughput; the
    /// per-model default stays conservative (`KataGoHelper.mlxNumSearchThreads`).
    public static let maxSearchThreads = 32

    /// Single NN-server-thread device code: `0` = MLX/GPU, `100` = CoreML/ANE.
    /// `.mux` spans both devices, so its value here is a degenerate nominal
    /// "primary" (the GPU code) — callers needing the real assignment must use
    /// `deviceAssignments`.
    public var mlxDeviceToUse: Int {
        switch self {
        case .mlxGPU: return 0
        case .coremlNE: return 100
        case .mux: return 0
        }
    }

    /// The NN-server-thread device assignment the engine launches with for this
    /// choice — one device code per element. On the iOS/visionOS **simulator**
    /// the MLX/GPU device (`0`) crashes the Metal translation layer, so every
    /// choice is clamped to CoreML/ANE there (the per-choice thread count is
    /// preserved). macOS keeps its own fixed mux via
    /// `EngineDeviceAssignments.platformMux` and does not consult this.
    public var deviceAssignments: [Int] {
        #if targetEnvironment(simulator)
        switch self {
        case .mlxGPU, .coremlNE:
            return [BackendChoice.coremlNE.mlxDeviceToUse]                 // [100]
        case .mux:
            return [BackendChoice.coremlNE.mlxDeviceToUse,
                    BackendChoice.coremlNE.mlxDeviceToUse]                 // [100, 100]
        }
        #else
        switch self {
        case .mlxGPU:
            return [BackendChoice.mlxGPU.mlxDeviceToUse]                   // [0]
        case .coremlNE:
            return [BackendChoice.coremlNE.mlxDeviceToUse]                 // [100]
        case .mux:
            // 1 MLX/GPU + 1 CoreML/ANE server thread, run in parallel.
            return [BackendChoice.mlxGPU.mlxDeviceToUse,
                    BackendChoice.coremlNE.mlxDeviceToUse]                 // [0, 100]
        }
        #endif
    }
}

public enum BoardSizeChoice: Int, CaseIterable, Identifiable {
    case nine = 9
    case thirteen = 13
    case nineteen = 19
    case thirtySevenMax = 37

    public var id: Int { rawValue }

    public var label: String {
        "\(rawValue)x\(rawValue)"
    }
}

public struct BackendSettings {
    private let model: NeuralNetworkModel

    public init(model: NeuralNetworkModel) {
        self.model = model
    }

    private var backendKey: String { "backend_\(model.fileName)" }
    private var numSearchThreadsKey: String { "numSearchThreads_\(model.fileName)" }
    private var mlxBoardSizeKey: String { "mlxBoardSize_\(model.fileName)" }
    private var tunerFullKey: String { "mlxTunerFull_\(model.fileName)" }
    private var reTuneKey: String { "mlxReTune_\(model.fileName)" }

    /// The user-selected inference backend for this model. Defaults to single
    /// CoreML/ANE — the best power/throughput point measured on an iPad A17 Pro
    /// run; the user can opt into MLX/GPU or the GPU+ANE mux. Persisted per
    /// model.
    public var backend: BackendChoice {
        get {
            if let raw = UserDefaults.standard.string(forKey: backendKey),
               let choice = BackendChoice(rawValue: raw) {
                return choice
            }
            return .coremlNE
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: backendKey)
        }
    }

    /// MCTS search threads for this model, clamped to
    /// `1...BackendChoice.maxSearchThreads`. Defaults to the platform starting
    /// point (`KataGoHelper.mlxNumSearchThreads`). Persisted per model; applied
    /// at engine startup, so a change takes effect on the next model load.
    public var numSearchThreads: Int {
        get {
            let raw = UserDefaults.standard.integer(forKey: numSearchThreadsKey)
            guard raw != 0 else { return KataGoHelper.mlxNumSearchThreads }
            return min(max(raw, 1), BackendChoice.maxSearchThreads)
        }
        set {
            let clamped = min(max(newValue, 1), BackendChoice.maxSearchThreads)
            UserDefaults.standard.set(clamped, forKey: numSearchThreadsKey)
        }
    }

    /// The NN-server-thread device assignment for the selected backend (with the
    /// simulator GPU clamp applied). Fed to `KataGoHelper.runGtp`.
    public var deviceAssignments: [Int] { backend.deviceAssignments }

    /// Max board size for this model. Caps the largest board the engine can play
    /// and the geometry the Winograd autotuner + NN buffers optimize for.
    /// Persisted per model; the tuner cache is keyed by board size, so per-size
    /// tunes coexist.
    public var mlxBoardSize: BoardSizeChoice {
        get {
            let raw = UserDefaults.standard.integer(forKey: mlxBoardSizeKey)
            if raw != 0, let size = BoardSizeChoice(rawValue: raw) {
                return size
            }
            return .nineteen
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: mlxBoardSizeKey)
        }
    }

    /// Winograd autotuning mode for the MLX/GPU path (used by `.mlxGPU` and the
    /// GPU side of `.mux`). `false` = the fast coarse-grid tune (default),
    /// `true` = the wide-grid "full" tune (more thorough, much slower on
    /// device). Persisted per model; each mode is cached in its own file, so
    /// switching takes effect on the next load. Ignored by the CoreML/ANE path.
    public var tunerFull: Bool {
        get { UserDefaults.standard.bool(forKey: tunerFullKey) }
        set { UserDefaults.standard.set(newValue, forKey: tunerFullKey) }
    }

    /// One-shot "re-tune on next load" flag. When `true`, the next load of this
    /// model forces a fresh autotune that overwrites the cached tuning;
    /// `ModelRunnerView` clears it back to `false` after consuming it so the
    /// re-tune happens exactly once. Only consumed when the selected backend
    /// runs an MLX/GPU server thread (`.mlxGPU` or `.mux`), since the Winograd
    /// tuner is GPU-only.
    public var reTune: Bool {
        get { UserDefaults.standard.bool(forKey: reTuneKey) }
        set { UserDefaults.standard.set(newValue, forKey: reTuneKey) }
    }

    /// NN-buffer board length: the single max board size, clamped to the model's
    /// neural-net length. Backend-agnostic — every backend path converts/allocates
    /// to this same geometry.
    public var effectiveMaxBoardLength: Int { min(mlxBoardSize.rawValue, model.nnLen) }

    /// Every backend path runs with a non-exact NN length.
    public var requireExactNNLen: Bool { false }
}
