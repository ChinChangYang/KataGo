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

    public static var platformDefault: BackendChoice {
        #if os(macOS)
        return .mlxGPU
        #else
        return .coremlNE
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
    private var boardSizeKey: String { "coremlBoardSize_\(model.fileName)" }
    private var mlxBoardSizeKey: String { "mlxBoardSize_\(model.fileName)" }
    private var tunerFullKey: String { "mlxTunerFull_\(model.fileName)" }
    private var reTuneKey: String { "mlxReTune_\(model.fileName)" }

    public var backend: BackendChoice {
        get {
            #if targetEnvironment(simulator)
            // The iOS/visionOS simulator's Metal translation layer (MTLSimDriver)
            // crashes inside MLX's GPU inference path (copy_gpu_inplace). MLX-GPU
            // only works on real devices, so force the CoreML/NE path on the
            // simulator regardless of any stored MLX/GPU preference. Real devices
            // honor the stored preference below.
            return .coremlNE
            #else
            if let raw = UserDefaults.standard.string(forKey: backendKey),
               let choice = BackendChoice(rawValue: raw) {
                return choice
            }
            return BackendChoice.platformDefault
            #endif
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: backendKey)
        }
    }

    public var coremlBoardSize: BoardSizeChoice {
        get {
            let raw = UserDefaults.standard.integer(forKey: boardSizeKey)
            if raw != 0, let size = BoardSizeChoice(rawValue: raw) {
                return size
            }
            return .nineteen
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: boardSizeKey)
        }
    }

    /// MLX/GPU max board size. Caps the largest board the GPU backend can play and
    /// the geometry the Winograd autotuner + NN buffers optimize for. Persisted per
    /// model; the tuner cache is keyed by board size, so per-size tunes coexist.
    /// Only meaningful for `.mlxGPU`.
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

    /// MLX/GPU Winograd autotuning mode. `false` = the fast coarse-grid tune
    /// (default), `true` = the wide-grid "full" tune (more thorough, much slower
    /// on device). Persisted per model; each mode is cached in its own file, so
    /// switching takes effect on the next load. Only meaningful for `.mlxGPU`.
    public var tunerFull: Bool {
        get { UserDefaults.standard.bool(forKey: tunerFullKey) }
        set { UserDefaults.standard.set(newValue, forKey: tunerFullKey) }
    }

    /// One-shot "re-tune on next load" flag. When `true`, the next MLX/GPU load
    /// of this model forces a fresh autotune that overwrites the cached tuning;
    /// `ModelRunnerView` clears it back to `false` after consuming it so the
    /// re-tune happens exactly once. Only meaningful for `.mlxGPU`.
    public var reTune: Bool {
        get { UserDefaults.standard.bool(forKey: reTuneKey) }
        set { UserDefaults.standard.set(newValue, forKey: reTuneKey) }
    }

    public var effectiveMaxBoardLength: Int {
        switch backend {
        case .coremlNE: return min(coremlBoardSize.rawValue, model.nnLen)
        case .mlxGPU: return min(mlxBoardSize.rawValue, model.nnLen)
        }
    }

    public var requireExactNNLen: Bool {
        switch backend {
        case .coremlNE: return false
        case .mlxGPU: return false
        }
    }
}
