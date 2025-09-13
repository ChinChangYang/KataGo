//
//  ModelRunnerView.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/5/19.
//

import SwiftUI
import KataGoInterface

struct ModelRunnerView: View {
    @State private var selectedModel: NeuralNetworkModel? = nil
    @State private var katagoThread: Thread?
    @State private var humanSLEnabled: Bool = true

    var body: some View {
        Group {
            if let selectedModel {
                ContentView(selectedModel: selectedModel)
            } else {
               ModelPickerView(isHumanSLEnabled: $humanSLEnabled,
                               selectedModel: $selectedModel)
            }
        }
        .onChange(of: selectedModel) { _, _ in
            if let selectedModel {
                if selectedModel.builtIn {
                    // Start KataGo with the built-in model
                    startKataGoThread(coremlModelPath: selectedModel.url,
                                      humanCoremlModelPath: humanSLEnabled ? selectedModel.humanUrl : nil,
                                      nnLen: selectedModel.nnLen,
                                      humanSLEnabled: humanSLEnabled)
                } else {
                    if let downloadedURL = selectedModel.downloadedURL {
                        startKataGoThread(modelPath: downloadedURL.path(),
                                          useMetal: !selectedModel.builtIn,
                                          nnLen: selectedModel.nnLen,
                                          humanSLEnabled: humanSLEnabled)
                    } else {
                        // Failed to get model URL, go back to the model picker view
                        self.selectedModel = nil
                    }
                }
            }
        }
    }

    private func startKataGoThread(modelPath: String? = nil,
                                   useMetal: Bool = false,
                                   coremlModelPath: String? = nil,
                                   humanCoremlModelPath: String? = nil,
                                   nnLen: Int,
                                   humanSLEnabled: Bool = false) {
        // Start a thread to run KataGo GTP
        let katagoThread = Thread {
            KataGoHelper.runGtp(modelPath: modelPath,
                                useMetal: useMetal,
                                coremlModelPath: coremlModelPath,
                                humanCoremlModelPath: humanCoremlModelPath,
                                nnLen: nnLen,
                                humanSLEnabled: humanSLEnabled)

            Task {
                await MainActor.run {
                    withAnimation {
                        selectedModel = nil
                    }
                }
            }
        }

        // Expand the stack size to resolve a stack overflow problem
        katagoThread.stackSize = 4096 * 256
        katagoThread.start()

        self.katagoThread = katagoThread
    }
}
