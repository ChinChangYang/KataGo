//
//  ModelPickerView.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/5/18.
//

import SwiftUI

enum DownloaderError: Error {
    case noDocumentsDirectory
}

@MainActor
@Observable
class Downloader: NSObject, URLSessionDownloadDelegate {
    var isDownloading = false
    var progress: Double = 0.0
    var downloadedFileURL: URL? = nil

    func download(from sourceURL: URL, to destinationFileName: String) async throws {
        let fileManager = FileManager.default
        if let docsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            isDownloading = true
            progress = 0.0
            let (downloadedTempURL, _) = try await URLSession.shared.download(from: sourceURL, delegate: self)
            let destinationURL = docsURL.appendingPathComponent(destinationFileName)
            try? fileManager.removeItem(at: destinationURL) // Remove if exists
            try fileManager.moveItem(at: downloadedTempURL, to: destinationURL)
            downloadedFileURL = destinationURL
            isDownloading = false
        } else {
            isDownloading = false
            progress = 0.0
            downloadedFileURL = nil
            throw DownloaderError.noDocumentsDirectory
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        Task {
            await MainActor.run {
                progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
    }

}

struct ModelPickerView: View {
    @State private var selectedModelID: UUID?
    @State private var downloader: Downloader = Downloader()
    @State private var isDownloaded: [UUID: Bool] = [:]
    @Binding var selectedModel: NeuralNetworkModel?
    @Binding var isModelPicked: Bool

    var downloadedFilePath: String? {
        downloader.downloadedFileURL?.path
    }

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
                .padding()
            }

            if let selectedModelID {
                if isDownloaded[selectedModelID] ?? false {
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

                        if let theSelectedModel {
                            if !theSelectedModel.builtIn {
                                Button(role: .destructive) {
                                    let fileManager = FileManager.default
                                    if let docsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
                                        let downloadedURL = docsURL.appendingPathComponent(theSelectedModel.fileName)
                                        try? fileManager.removeItem(at: downloadedURL)
                                        isDownloaded[selectedModelID] = false
                                    }
                                } label: {
                                    VStack {
                                        Image(systemName: "trash")
                                        Text("Delete")
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                } else if !downloader.isDownloading {
                    Button {
                        Task {
                            if let theSelectedModel {
                                if let modelURL = URL(string: theSelectedModel.url) {
                                    try? await downloader.download(from: modelURL,
                                                                   to: theSelectedModel.fileName)
                                    let fileManager = FileManager.default
                                    if let docsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
                                        let downloadedURL = docsURL.appendingPathComponent(theSelectedModel.fileName)
                                        if fileManager.fileExists(atPath: downloadedURL.path) {
                                            isDownloaded[selectedModelID] = true
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        VStack {
                            Image(systemName: "square.and.arrow.down")
                            Text("Download")
                        }
                    }
                    .padding()
                } else {
                    VStack {
                        ProgressView(value: downloader.progress)
                            .progressViewStyle(.linear)
                            .padding()
                        Text("Downloading: \(Int(downloader.progress * 100))%")
                    }
                }
            }
        }
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
    }
}
