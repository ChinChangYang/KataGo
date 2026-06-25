//
//  EngineDeviceAssignments.swift
//  KataGo Anytime
//

import Foundation

/// The fixed GPU+ANE inference mux the engine always launches with. Each
/// element is one NN-server-thread device code in the
/// `BackendChoice.mlxDeviceToUse` vocabulary: `0` = MLX/GPU, `100` = CoreML/ANE.
///
/// This replaces the former per-model backend picker — the app runs both
/// engines in parallel for best throughput (the 2 ANE / 1 GPU threads overlap;
/// all GPU work serializes on `mlxGpuEvalMutex`, so the win is GPU∥ANE
/// concurrency). The picker is gone; only this fixed assignment remains.
public enum EngineDeviceAssignments {
    public static var platformMux: [Int] {
        #if targetEnvironment(simulator)
        // The iOS/visionOS simulator's Metal translation layer crashes inside
        // MLX's GPU inference path, so the mux must NOT include device 0. Keep
        // the 2-thread shape with both server threads on CoreML/ANE.
        return [BackendChoice.coremlNE.mlxDeviceToUse,
                BackendChoice.coremlNE.mlxDeviceToUse]            // [100, 100]
        #elseif os(macOS)
        // macOS "best throughput" mux: 1 MLX/GPU + 2 CoreML/ANE server threads
        // (~1.25× the old single-GPU default). Unchanged from the prior
        // MainWindowController literal.
        return [BackendChoice.mlxGPU.mlxDeviceToUse,
                BackendChoice.coremlNE.mlxDeviceToUse,
                BackendChoice.coremlNE.mlxDeviceToUse]            // [0, 100, 100]
        #else
        // Real iOS/visionOS: 1 MLX/GPU + 1 CoreML/ANE. Runs both engines in
        // parallel; lighter than macOS's 1+2 to limit phone memory/power.
        return [BackendChoice.mlxGPU.mlxDeviceToUse,
                BackendChoice.coremlNE.mlxDeviceToUse]            // [0, 100]
        #endif
    }
}
