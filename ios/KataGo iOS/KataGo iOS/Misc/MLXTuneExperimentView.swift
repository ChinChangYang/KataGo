//
//  MLXTuneExperimentView.swift
//  KataGo Anytime
//
//  DEBUG-only measurement harness. Activated by the launch argument
//  `--mlx-tune-experiment`. On appear it forces the built-in net onto MLX/GPU
//  with Re-tune and starts the engine headlessly, so the Winograd autotuner
//  runs during init and prints `[MLX-TUNE]` / `[MLX-STUDY]` lines to stderr
//  (captured via `devicectl process launch --console`). No user interaction.
//
#if DEBUG
import SwiftUI
import KataGoUICore

struct MLXTuneExperimentView: View {
    static let launchArg = "--mlx-tune-experiment"

    @State private var status = "starting…"
    @State private var started = false

    var body: some View {
        VStack(spacing: 12) {
            Text("MLX Tune Experiment").font(.headline)
            Text(status).font(.system(.body, design: .monospaced)).multilineTextAlignment(.center)
            ProgressView()
        }
        .padding()
        .onAppear { runOnce() }
    }

    private func runOnce() {
        guard !started else { return }
        started = true

        let model = NeuralNetworkModel.allCases.first { $0.builtIn } ?? NeuralNetworkModel.allCases[0]
        guard let modelPath = Bundle.main.path(forResource: "default_model", ofType: "bin.gz") else {
            status = "ERROR: built-in model not found"
            FileHandle.standardError.write(Data("[MLX-TUNE] ERROR: built-in model not found\n".utf8))
            return
        }

        FileHandle.standardError.write(Data("[MLX-TUNE] experiment: forcing MLX/GPU + reTune for \(model.title)\n".utf8))
        status = "tuning \(model.title) on MLX/GPU (Re-tune)…\nwatch stderr for [MLX-TUNE]/[MLX-STUDY]"

        let thread = Thread {
            // Force a single GPU server thread (device 0) + a fresh tune,
            // bypassing the UI/UserDefaults and the platform mux, so the
            // Winograd autotuner runs and prints measurements.
            KataGoHelper.runGtp(modelPath: modelPath,
                                deviceAssignments: [0],
                                maxBoardSizeForNNBuffer: model.nnLen,
                                requireExactNNLen: false,
                                tunerFull: false,
                                reTune: true)
        }
        thread.stackSize = 4096 * 256
        thread.start()
    }
}
#endif
