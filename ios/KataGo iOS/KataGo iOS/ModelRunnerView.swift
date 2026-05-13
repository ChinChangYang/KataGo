//
//  ModelRunnerView.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/5/19.
//

import OSLog
import SwiftUI
import KataGoInterface

private let recoveryLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "KataGo Anytime",
    category: "engine.recovery"
)

struct ModelRunnerView: View {
    @State private var selectedModel: NeuralNetworkModel? = nil
    @State private var katagoThread: Thread?
    @State private var engineLifecycle = EngineLifecycle()
    @State private var hasDecidedRecovery = false
    @State private var launchedMaxBoardLength: Int = 19
    @AppStorage("ModelRunnerView.selectedModelTitle") private var selectedModelTitle = ""
    @AppStorage("ModelRunnerView.pendingLoadModelTitle") private var pendingLoadModelTitle = ""

    var body: some View {
        Group {
            if selectedModel != nil {
                ContentView(
                    selectedModel: $selectedModel,
                    engineLifecycle: engineLifecycle,
                    maxBoardLength: launchedMaxBoardLength
                )
            } else {
                ModelPickerView(
                    selectedModel: $selectedModel,
                    crashedModelTitle: $pendingLoadModelTitle
                )
            }
        }
        .onAppear {
            // Guard against re-appearance (e.g. scene lifecycle transitions)
            // re-triggering the recovery log and auto-restore.
            guard !hasDecidedRecovery else { return }
            hasDecidedRecovery = true

            #if DEBUG
            let isDebug = true
            #else
            let isDebug = false
            #endif

            switch RecoveryDecision.decide(
                pendingLoadModelTitle: pendingLoadModelTitle,
                selectedModelTitle: selectedModelTitle,
                isDebug: isDebug
            ) {
            case .showPickerWithBanner:
                recoveryLogger.error(
                    "Recovered from apparent crash loading model: \(pendingLoadModelTitle, privacy: .public)"
                )
                // Leave pendingLoadModelTitle set: the picker reads it to
                // render the banner, and user action (Dismiss, or selecting
                // a new model) is what clears it.
            case .autoRestore(let title):
                selectedModel = NeuralNetworkModel.allCases.first { $0.title == title }
            case .showPicker:
                break
            }
        }
        .onChange(of: selectedModel) { _, newValue in
            guard let newValue else { return }

            let modelPath: String?
            if newValue.builtIn {
                modelPath = Bundle.main.path(forResource: "default_model", ofType: "bin.gz")
            } else {
                modelPath = newValue.downloadedURL?.path()
            }

            guard let modelPath else {
                selectedModel = nil
                return
            }

            // Arm the crash sentinel BEFORE starting the engine thread. If the
            // engine OOM-crashes before `ContentView` sees its first GTP
            // response, this value survives the process death and the next
            // launch will show the picker with a recovery banner instead of
            // restarting the same crash. `reset()` first so the observer
            // re-fires even if the user picked the same model twice in a row.
            engineLifecycle.reset()
            pendingLoadModelTitle = newValue.title
            UserDefaults.standard.synchronize()

            let settings = BackendSettings(model: newValue)
            launchedMaxBoardLength = settings.effectiveMaxBoardLength
            startKataGoThread(
                modelPath: modelPath,
                metalDeviceToUse: settings.backend.metalDeviceToUse,
                maxBoardSizeForNNBuffer: settings.effectiveMaxBoardLength,
                requireExactNNLen: settings.requireExactNNLen
            )
        }
        .onChange(of: engineLifecycle.lastLoadedModelTitle) { _, newValue in
            guard let newValue else { return }
            selectedModelTitle = newValue
            pendingLoadModelTitle = ""
        }
    }

    private func startKataGoThread(modelPath: String,
                                   metalDeviceToUse: Int,
                                   maxBoardSizeForNNBuffer: Int,
                                   requireExactNNLen: Bool) {
        let katagoThread = Thread {
            KataGoHelper.runGtp(modelPath: modelPath,
                                metalDeviceToUse: metalDeviceToUse,
                                maxBoardSizeForNNBuffer: maxBoardSizeForNNBuffer,
                                requireExactNNLen: requireExactNNLen)

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
