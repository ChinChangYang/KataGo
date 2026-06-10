//
//  BackendConfigSheet.swift
//  KataGo Anytime
//

import SwiftUI

struct BackendConfigSheet: View {
    let model: NeuralNetworkModel
    @State private var backend: BackendChoice
    @State private var coremlBoardSize: BoardSizeChoice
    @State private var mlxBoardSize: BoardSizeChoice
    @State private var tunerFull: Bool
    @State private var reTune: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: NeuralNetworkModel) {
        self.model = model
        let settings = BackendSettings(model: model)
        self._backend = State(initialValue: settings.backend)
        self._coremlBoardSize = State(initialValue: settings.coremlBoardSize)
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
                } footer: {
                    switch backend {
                    case .mlxGPU:
                        Text("Responsive. No compilation needed.")
                    case .coremlNE:
                        Text("Power-efficient. First launch for a board size takes time to compile.")
                    }
                }

                if backend == .coremlNE {
                    Section("Compiled Board Size") {
                        Picker("Board Size", selection: $coremlBoardSize) {
                            ForEach(BoardSizeChoice.allCases) { size in
                                Text(size.label).tag(size)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                if backend == .mlxGPU {
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
                        Text("Sets the largest board MLX/GPU can play and the size the performance tuner optimizes for. Boards larger than this won't be available on MLX/GPU until you raise it.")
                    }

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
                        Text("Fast tunes a coarse grid in seconds. Full tunes the wide grid — more thorough but much slower on device. Each mode is cached separately, so switching takes effect on the next load. Re-tune discards the cached tuning and measures again once, the next time this model loads.")
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
            .onChange(of: coremlBoardSize) { _, newValue in
                var settings = BackendSettings(model: model)
                settings.coremlBoardSize = newValue
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
