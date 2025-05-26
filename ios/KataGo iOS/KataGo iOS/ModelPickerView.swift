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

    var listView: some View {
        List(NeuralNetworkModel.allCases, selection: $selectedModelID) { model in
            VStack(alignment: .leading) {
                Text(model.title)
                    .bold()
                Text(model.description)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical)
            .onChange(of: downloaders[model.id]??.isDownloading) { oldValue, newValue in
                if oldValue == true && newValue == false {
                    if FileManager.default.fileExists(atPath: downloaders[model.id]??.destinationURL.path ?? "") {
                        isDownloaded[model.id] = true
                    }
                }
            }
        }
    }

    var bottomView: some View {
        Group {
            if let currentSelectedModel {
                if isDownloaded[currentSelectedModel.id] ?? false {
                    HStack {
                        Button {
                            selectedModel = currentSelectedModel
                        } label: {
                            VStack {
                                Image(systemName: "arrowtriangle.forward")
                                Text("Start")
                            }
                        }
                        .padding(.horizontal)

                        if !currentSelectedModel.builtIn {
                            Button(role: .destructive) {
                                if let downloadedURL = currentSelectedModel.downloadedURL {
                                    try? FileManager.default.removeItem(at: downloadedURL)
                                    if !FileManager.default.fileExists(atPath: downloadedURL.path) {
                                        isDownloaded[currentSelectedModel.id] = false
                                    }
                                }
                            } label: {
                                VStack {
                                    Image(systemName: "trash")
                                    Text("Delete (\(currentSelectedModel.fileSize.humanFileSize))")
                                }
                            }
                        }
                    }
                    .padding()
                } else if !(downloaders[currentSelectedModel.id]??.isDownloading ?? false) {
                    Button {
                        Task {
                            if let modelURL = URL(string: currentSelectedModel.url) {
                                try? await downloaders[currentSelectedModel.id]??.download(from: modelURL)
                            }
                        }
                    } label: {
                        VStack {
                            Image(systemName: "square.and.arrow.down")
                            Text("Download (\(currentSelectedModel.fileSize.humanFileSize))")
                        }
                    }
                    .padding()
                } else {
                    VStack {
                        ProgressView(value: downloaders[currentSelectedModel.id]??.progress)
                            .progressViewStyle(.linear)
                            .padding()
                        Text("Downloading: \(Int((downloaders[currentSelectedModel.id]??.progress ?? 0) * 100))%")
                    }
                }
            }
        }
    }

    var body: some View {
        VStack {
            Text("Select a Model")
                .font(.headline)

            listView
            bottomView
        }
        .padding()
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
