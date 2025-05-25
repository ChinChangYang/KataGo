//
//  ModelRunnerView.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/5/19.
//

import SwiftUI
import KataGoInterface

struct ModelRunnerView: View {
    @State private var selectedModel: NeuralNetworkModel?
    @State private var isModelPicked: Bool = false
    @State private var katagoThread: Thread?

    var body: some View {
        Group {
            if isModelPicked {
                ContentView(selectedModel: $selectedModel)
            } else {
                ModelPickerView(selectedModel: $selectedModel, isModelPicked: $isModelPicked)
            }
        }
        .onChange(of: isModelPicked) { _, newValue in
            if newValue {
                if let selectedModel {
                    if !selectedModel.builtIn {
                        let fileManager = FileManager.default
                        if let docsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
                            let downloadedURL = docsURL.appendingPathComponent(selectedModel.fileName)
                            startKataGoThread(modelPath: downloadedURL.path(), useMetal: !selectedModel.builtIn)
                        } else {
                            isModelPicked = false
                        }
                    } else {
                        startKataGoThread()
                    }
                } else {
                    isModelPicked = false
                }
            }
        }
    }

    private func startKataGoThread(modelPath: String? = nil, useMetal: Bool = false) {
        // Start a thread to run KataGo GTP
        let katagoThread = Thread {
            KataGoHelper.runGtp(modelPath: modelPath, useMetal: useMetal)
        }

        // Expand the stack size to resolve a stack overflow problem
        katagoThread.stackSize = 4096 * 512
        katagoThread.start()

        self.katagoThread = katagoThread
    }
}
