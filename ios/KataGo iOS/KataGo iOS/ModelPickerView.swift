//
//  ModelPickerView.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/5/18.
//

import SwiftUI

extension Int {
    var humanFileSize: String {
        let size = Double(self)
        guard size > 0 else { return "0 B" }
        let units = ["B", "kB", "MB", "GB", "TB"]
        let exponent = Int(floor(log(size) / log(1024)))
        let scaledSize = size / pow(1024, Double(exponent))
        let formattedSize = String(format: "%.2f", scaledSize)

        return "\(formattedSize) \(units[exponent])"
    }
}

struct ModelPickerView: View {
    @State private var selectedModelID: UUID?
    @State private var downloaders: [UUID: Downloader?] = [:]
    @State private var isDownloaded: [UUID: Bool] = [:]

    // Final selected model
    @Binding var selectedModel: NeuralNetworkModel?

    var selectedIndex: Int? {
        NeuralNetworkModel.allCases.map { $0.id }.firstIndex(of: selectedModelID)
    }

    var currentSelectedModel: NeuralNetworkModel? {
        if let selectedIndex {
            NeuralNetworkModel.allCases[selectedIndex]
        } else {
            nil
        }
    }

    func modelDetailView(model: NeuralNetworkModel) -> some View {
        VStack {
            ZStack {
                Image(.loadingIcon)
                    .resizable()
                    .scaledToFit()
                    .clipShape(.circle)
                    .rotationEffect(.degrees((downloaders[model.id]??.progress ?? 0) * 360))

                Button {
                    if isDownloaded[model.id] ?? false {
                        selectedModel = model
                    } else if !(downloaders[model.id]??.isDownloading ?? false) {
                        Task {
                            if let modelURL = URL(string: model.url) {
                                try? await downloaders[model.id]??.download(from: modelURL)
                            }
                        }
                    } else {
                        // TODO: pause/stop download
                    }
                } label: {
                    if isDownloaded[model.id] ?? false {
                        Image(systemName: "play.fill")
                    } else if !(downloaders[model.id]??.isDownloading ?? false) {
                        Image(systemName: "arrow.down")
                    } else {
                        if #available(iOS 26.0, *),
                           #available(macOS 26.0, *),
                           #available(visionOS 26.0, *) {
                            Image(
                                systemName: "pause.circle",
                                variableValue: downloaders[model.id]??.progress
                            )
                            .symbolVariableValueMode(.draw)

                        } else {
                            Image(systemName: "pause.circle")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            ScrollView {
                VStack(alignment: .leading) {
                    HStack {
                        Text(model.title)
                            .bold()

                        Text(model.builtIn ? "" : model.fileSize.humanFileSize)
                            .foregroundStyle(.secondary)

                        if !model.builtIn && (isDownloaded[model.id] ?? false) {
                            Button(role: .destructive) {
                                if let downloadedURL = model.downloadedURL {
                                    try? FileManager.default.removeItem(at: downloadedURL)
                                    if !FileManager.default.fileExists(atPath: downloadedURL.path) {
                                        isDownloaded[model.id] = false
                                    }
                                }
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }

                    Text(model.description)
                }
            }
        }
        .padding()
        .onChange(of: downloaders[model.id]??.isDownloading) { oldValue, newValue in
            if oldValue == true && newValue == false {
                if FileManager.default.fileExists(atPath: downloaders[model.id]??.destinationURL.path ?? "") {
                    isDownloaded[model.id] = true
                }
            }
        }
        .navigationTitle(model.title)
    }

    var body: some View {
        NavigationStack {
            List(selection: $selectedModelID) {
                ForEach(NeuralNetworkModel.allCases) { model in
                    if model.visible {
                        NavigationLink(model.title) {
                            modelDetailView(model: model)
                        }
                    }
                }
            }
            .navigationTitle("Select a Model")
            .onAppear {
                for model in NeuralNetworkModel.allCases {
                    if model.builtIn {
                        isDownloaded[model.id] = true
                    } else {
                        if let downloadedURL = model.downloadedURL {
                            downloaders[model.id] = Downloader(destinationURL: downloadedURL)
                            if FileManager.default.fileExists(atPath: downloadedURL.path) {
                                isDownloaded[model.id] = true
                            } else {
                                isDownloaded[model.id] = false
                            }
                        } else {
                            isDownloaded[model.id] = false
                        }
                    }
                }
            }
        }
    }
}

#Preview("Model Picker") {
    // A simple wrapper view to host the binding required by ModelPickerView
    struct PreviewHost: View {
        @State private var selectedModel: NeuralNetworkModel? = nil
        var body: some View {
            ModelPickerView(selectedModel: $selectedModel)
        }
    }
    return PreviewHost()
}
