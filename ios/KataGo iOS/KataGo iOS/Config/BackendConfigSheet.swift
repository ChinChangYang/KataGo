//
//  BackendConfigSheet.swift
//  KataGo Anytime
//

import SwiftUI
import KataGoUICore

struct BackendConfigSheet: View {
    let model: NeuralNetworkModel
    @State private var backend: BackendChoice
    @State private var numSearchThreads: Int
    @State private var mlxBoardSize: BoardSizeChoice
    @State private var tunerFull: Bool
    @State private var reTune: Bool
    @Environment(\.dismiss) private var dismiss

    /// The Winograd autotuner only runs on an MLX/GPU server thread, so the
    /// tuning controls are only relevant when the selected backend uses the GPU.
    private var backendUsesGPU: Bool {
        backend == .mlxGPU || backend == .mux
    }

    init(model: NeuralNetworkModel) {
        self.model = model
        let settings = BackendSettings(model: model)
        self._backend = State(initialValue: settings.backend)
        self._numSearchThreads = State(initialValue: settings.numSearchThreads)
        self._mlxBoardSize = State(initialValue: settings.mlxBoardSize)
        self._tunerFull = State(initialValue: settings.tunerFull)
        self._reTune = State(initialValue: settings.reTune)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Backend", selection: $backend) {
                        ForEach(BackendChoice.allCases) { choice in
                            Text(choice.rawValue).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Backend")
                } footer: {
                    switch backend {
                    case .mlxGPU:
                        Text("MLX/GPU: responsive, with no compilation step.")
                    case .coremlNE:
                        Text("CoreML / Neural Engine: most power-efficient. The first launch for a board size takes time to compile.")
                    case .mux:
                        Text("Runs the GPU and Neural Engine in parallel for the best throughput, at the cost of higher memory. Takes effect on the next load.")
                    }
                }

                Section {
                    Picker("Board Size", selection: $mlxBoardSize) {
                        ForEach(BoardSizeChoice.allCases) { size in
                            Text(size.label).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Max Board Size")
                } footer: {
                    Text("Sets the largest board the engine can play and the size the performance tuner optimizes for. Boards larger than this won't be available until you raise it.")
                }

                Section {
                    Stepper(value: $numSearchThreads, in: 1...BackendChoice.maxSearchThreads) {
                        Text("Search Threads: \(numSearchThreads)")
                    }
                    .accessibilityIdentifier("SearchThreadsStepper")
                } header: {
                    Text("Search Threads")
                } footer: {
                    Text("More search threads can raise playing strength and throughput but use more power. Takes effect on the next load.")
                }

                if backendUsesGPU {
                    Section {
                        Picker("Autotuning", selection: $tunerFull) {
                            Text("Fast").tag(false)
                            Text("Full").tag(true)
                        }
                        .pickerStyle(.segmented)

                        Toggle("Re-tune on next load", isOn: $reTune)
                    } header: {
                        Text("Performance Tuning")
                    } footer: {
                        Text("Tunes the MLX/GPU path. Fast tunes a coarse grid in seconds. Full tunes the wide grid — more thorough but much slower on device. Each mode is cached separately, so switching takes effect on the next load. Re-tune discards the cached tuning and measures again once, the next time this model loads.")
                    }
                }
            }
            .navigationTitle(model.title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onChange(of: backend) { _, newValue in
                var settings = BackendSettings(model: model)
                settings.backend = newValue
            }
            .onChange(of: numSearchThreads) { _, newValue in
                var settings = BackendSettings(model: model)
                settings.numSearchThreads = newValue
            }
            .onChange(of: mlxBoardSize) { _, newValue in
                var settings = BackendSettings(model: model)
                settings.mlxBoardSize = newValue
            }
            .onChange(of: tunerFull) { _, newValue in
                var settings = BackendSettings(model: model)
                settings.tunerFull = newValue
            }
            .onChange(of: reTune) { _, newValue in
                var settings = BackendSettings(model: model)
                settings.reTune = newValue
            }
        }
    }
}

#Preview {
    BackendConfigSheet(model: NeuralNetworkModel.allCases[0])
}
