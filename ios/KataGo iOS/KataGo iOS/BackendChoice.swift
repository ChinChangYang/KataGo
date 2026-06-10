//
//  BackendChoice.swift
//  KataGo Anytime
//

import Foundation

enum BackendChoice: String, CaseIterable, Identifiable {
    case mpsGPU = "MLX/GPU"
    case coremlNE = "CoreML/NE"

    var id: String { rawValue }

    var metalDeviceToUse: Int {
        switch self {
        case .mpsGPU: return 0
        case .coremlNE: return 100
        }
    }

    static var platformDefault: BackendChoice {
        #if os(macOS)
        return .mpsGPU
        #else
        return .coremlNE
        #endif
    }
}

enum BoardSizeChoice: Int, CaseIterable, Identifiable {
    case nine = 9
    case thirteen = 13
    case nineteen = 19
    case thirtySevenMax = 37

    var id: Int { rawValue }

    var label: String {
        "\(rawValue)x\(rawValue)"
    }
}

struct BackendSettings {
    private let model: NeuralNetworkModel

    init(model: NeuralNetworkModel) {
        self.model = model
    }

    private var backendKey: String { "backend_\(model.fileName)" }
    private var boardSizeKey: String { "coremlBoardSize_\(model.fileName)" }
    private var mlxBoardSizeKey: String { "mlxBoardSize_\(model.fileName)" }
    private var tunerFullKey: String { "mlxTunerFull_\(model.fileName)" }
    private var reTuneKey: String { "mlxReTune_\(model.fileName)" }

    var backend: BackendChoice {
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

    var coremlBoardSize: BoardSizeChoice {
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
    /// Only meaningful for `.mpsGPU`.
    var mlxBoardSize: BoardSizeChoice {
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
    /// switching takes effect on the next load. Only meaningful for `.mpsGPU`.
    var tunerFull: Bool {
        get { UserDefaults.standard.bool(forKey: tunerFullKey) }
        set { UserDefaults.standard.set(newValue, forKey: tunerFullKey) }
    }

    /// One-shot "re-tune on next load" flag. When `true`, the next MLX/GPU load
    /// of this model forces a fresh autotune that overwrites the cached tuning;
    /// `ModelRunnerView` clears it back to `false` after consuming it so the
    /// re-tune happens exactly once. Only meaningful for `.mpsGPU`.
    var reTune: Bool {
        get { UserDefaults.standard.bool(forKey: reTuneKey) }
        set { UserDefaults.standard.set(newValue, forKey: reTuneKey) }
    }

    var effectiveMaxBoardLength: Int {
        switch backend {
        case .coremlNE: return min(coremlBoardSize.rawValue, model.nnLen)
        case .mpsGPU: return min(mlxBoardSize.rawValue, model.nnLen)
        }
    }

    var requireExactNNLen: Bool {
        switch backend {
        case .coremlNE: return false
        case .mpsGPU: return false
        }
    }
}
