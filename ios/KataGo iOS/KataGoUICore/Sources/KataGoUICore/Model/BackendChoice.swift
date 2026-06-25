//
//  BackendChoice.swift
//  KataGo Anytime
//

import Foundation

public enum BackendChoice: String, CaseIterable, Identifiable {
    case mlxGPU = "MLX/GPU"
    case coremlNE = "CoreML/NE"

    public var id: String { rawValue }

    public var mlxDeviceToUse: Int {
        switch self {
        case .mlxGPU: return 0
        case .coremlNE: return 100
        }
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

    private var mlxBoardSizeKey: String { "mlxBoardSize_\(model.fileName)" }
    private var tunerFullKey: String { "mlxTunerFull_\(model.fileName)" }
    private var reTuneKey: String { "mlxReTune_\(model.fileName)" }

    /// Max board size for the fixed GPU+ANE mux. Caps the largest board the
    /// engine can play and the geometry the Winograd autotuner + NN buffers
    /// (both the GPU and the ANE server threads) optimize for. Persisted per
    /// model; the tuner cache is keyed by board size, so per-size tunes coexist.
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

    /// Winograd autotuning mode for the mux's MLX/GPU server thread. `false` =
    /// the fast coarse-grid tune (default), `true` = the wide-grid "full" tune
    /// (more thorough, much slower on device). Persisted per model; each mode is
    /// cached in its own file, so switching takes effect on the next load.
    public var tunerFull: Bool {
        get { UserDefaults.standard.bool(forKey: tunerFullKey) }
        set { UserDefaults.standard.set(newValue, forKey: tunerFullKey) }
    }

    /// One-shot "re-tune on next load" flag. When `true`, the next load of this
    /// model forces a fresh autotune that overwrites the cached tuning;
    /// `ModelRunnerView` clears it back to `false` after consuming it so the
    /// re-tune happens exactly once. The mux always runs an MLX/GPU server
    /// thread, so the re-tune is always consumed.
    public var reTune: Bool {
        get { UserDefaults.standard.bool(forKey: reTuneKey) }
        set { UserDefaults.standard.set(newValue, forKey: reTuneKey) }
    }

    /// NN-buffer board length for the fixed GPU+ANE mux. The mux always includes
    /// an MLX/GPU path, so the engine-wide NN buffer geometry and the Winograd
    /// tuner key off the single max board size. Both the GPU and ANE server
    /// threads convert/allocate to this same single geometry, clamped to the
    /// model's neural-net length.
    public var effectiveMaxBoardLength: Int { min(mlxBoardSize.rawValue, model.nnLen) }

    /// The mux's two backend paths both run with a non-exact NN length.
    public var requireExactNNLen: Bool { false }
}
