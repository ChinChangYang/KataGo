//
//  BackendConfigSheet.swift
//  KataGo Anytime
//

import SwiftUI

struct BackendConfigSheet: View {
    let model: NeuralNetworkModel
    @State private var backend: BackendChoice
    @State private var coremlBoardSize: CoreMLBoardSize
    @Environment(\.dismiss) private var dismiss

    init(model: NeuralNetworkModel) {
        self.model = model
        let settings = BackendSettings(model: model)
        self._backend = State(initialValue: settings.backend)
        self._coremlBoardSize = State(initialValue: settings.coremlBoardSize)
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
                    case .mpsGPU:
                        Text("Responsive. No compilation needed.")
                    case .coremlNE:
                        Text("Power-efficient. First launch for a board size takes time to compile.")
                    }
                }

                if backend == .coremlNE {
                    Section("Compiled Board Size") {
                        Picker("Board Size", selection: $coremlBoardSize) {
                            ForEach(CoreMLBoardSize.allCases) { size in
                                Text(size.label).tag(size)
                            }
                        }
                        .pickerStyle(.segmented)
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
        }
    }
}

#Preview {
    BackendConfigSheet(model: NeuralNetworkModel.allCases[0])
}
