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
    @State private var downloader: Downloader?
    @State private var isDownloaded: [UUID: Bool] = [:]
    @Binding var selectedModel: NeuralNetworkModel?
    @Binding var isModelPicked: Bool

    var selectedIndex: Int? {
        NeuralNetworkModel.allCases.map { $0.id }.firstIndex(of: selectedModelID)
    }

    var theSelectedModel: NeuralNetworkModel? {
        if let selectedIndex {
            NeuralNetworkModel.allCases[selectedIndex]
        } else {
            nil
        }
    }

    var body: some View {
        VStack {
            Text("Select a Model")
                .font(.headline)

            List(NeuralNetworkModel.allCases, selection: $selectedModelID) { model in
                VStack(alignment: .leading) {
                    Text(model.title)
                        .bold()
                    Text(model.description)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical)
            }

            if let theSelectedModel {
                if isDownloaded[theSelectedModel.id] ?? false {
                    HStack {
                        Button {
                            selectedModel = theSelectedModel
                            isModelPicked = true
                        } label: {
                            VStack {
                                Image(systemName: "arrowtriangle.forward")
                                Text("Start")
                            }
                        }
                        .padding(.horizontal)

                        if !theSelectedModel.builtIn {
                            Button(role: .destructive) {
                                let fileManager = FileManager.default
                                if let docsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
                                    let downloadedURL = docsURL.appendingPathComponent(theSelectedModel.fileName)
                                    try? fileManager.removeItem(at: downloadedURL)
                                    isDownloaded[theSelectedModel.id] = false
                                }
                            } label: {
                                VStack {
                                    Image(systemName: "trash")
                                    Text("Delete (\(theSelectedModel.fileSize.humanFileSize))")
                                }
                            }
                        }
                    }
                    .padding()
                } else if !(downloader?.isDownloading ?? false) {
                    Button {
                        Task {
                            let fileManager = FileManager.default
                            if let modelURL = URL(string: theSelectedModel.url),
                               let docsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
                                let downloadedURL = docsURL.appendingPathComponent(theSelectedModel.fileName)
                                downloader = Downloader(destinationURL: downloadedURL)
                                try? await downloader?.download(from: modelURL)
                            }
                        }
                    } label: {
                        VStack {
                            Image(systemName: "square.and.arrow.down")
                            Text("Download (\(theSelectedModel.fileSize.humanFileSize))")
                        }
                    }
                    .padding()
                } else {
                    VStack {
                        ProgressView(value: downloader?.progress)
                            .progressViewStyle(.linear)
                            .padding()
                        Text("Downloading: \(Int((downloader?.progress ?? 0) * 100))%")
                    }
                }
            }
        }
        .padding()
        .onAppear {
            for model in NeuralNetworkModel.allCases {
                if model.builtIn {
                    isDownloaded[model.id] = true
                } else {
                    let fileManager = FileManager.default
                    if let docsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
                        let downloadedURL = docsURL.appendingPathComponent(model.fileName)
                        if fileManager.fileExists(atPath: downloadedURL.path) {
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
        .onChange(of: downloader?.isDownloading) { oldValue, newValue in
            if oldValue == true && newValue == false,
               let theSelectedModel {
                if FileManager.default.fileExists(atPath: downloader?.destinationURL.path ?? "") {
                    isDownloaded[theSelectedModel.id] = true
                }
            }
        }
    }
}
