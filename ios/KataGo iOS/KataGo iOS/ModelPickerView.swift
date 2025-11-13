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

struct ModelTrashButton: View {
    var model: NeuralNetworkModel
    @Binding var isDownloaded: Bool
    @State var isConfirming = false

    var body: some View {
        Button(role: .destructive) {
            isConfirming = true
        } label: {
            Image(systemName: "trash")
        }
        .confirmationDialog(
            "Are you sure you want to remove this model? You may need to download it again.",
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let downloadedURL = model.downloadedURL {
                    try? FileManager.default.removeItem(at: downloadedURL)
                    if !FileManager.default.fileExists(atPath: downloadedURL.path) {
                        isDownloaded = false
                    }
                }
            }

            Button("Cancel", role: .cancel) {
                isConfirming = false
            }
        }
    }
}

struct ModelDetailView: View {
    var model: NeuralNetworkModel
    @State var downloader: Downloader
    @State var isDownloaded = false
    @Binding var selectedModel: NeuralNetworkModel?

    func downloadPlayButton(model: NeuralNetworkModel) -> some View {
        Button {
            if isDownloaded {
                selectedModel = model
            } else if !(downloader.isDownloading) {
                Task {
                    if let modelURL = URL(string: model.url) {
                        try? await downloader.download(from: modelURL)
                    }
                }
            } else {
                downloader.cancel()
            }
        } label: {
            if isDownloaded {
                Image(systemName: "play.fill")
            } else if !(downloader.isDownloading) {
                Image(systemName: "arrow.down")
            } else {
                    Image(
                        systemName: "stop.circle",
                        variableValue: downloader.progress
                    )
                    .symbolVariableValueMode(.draw)
            }
        }
        .buttonStyle(.borderedProminent)
    }

    var body: some View {
        VStack {
            Image(.loadingIcon)
                .resizable()
                .scaledToFit()
                .clipShape(.circle)
                .rotationEffect(.degrees(downloader.progress * 360))

            VStack(alignment: .leading) {
                Text(model.title)
                    .bold()

                HStack {
                    Text(model.builtIn ? "" : model.fileSize.humanFileSize)
                        .foregroundStyle(.secondary)

                    downloadPlayButton(model: model)
                    Spacer()

                    if !model.builtIn && isDownloaded {
                        ModelTrashButton(
                            model: model,
                            isDownloaded: $isDownloaded
                        )
                    }
                }
                .padding(.vertical)

                ScrollView {
                    Text(model.description)
                }
            }
        }
        .padding()
        .onAppear {
            if model.builtIn {
                isDownloaded = true
            } else {
                if let downloadedURL = model.downloadedURL {
                    if FileManager.default.fileExists(atPath: downloadedURL.path) {
                        isDownloaded = true
                    } else {
                        isDownloaded = false
                    }
                } else {
                    isDownloaded = false
                }
            }
        }
        .onChange(of: downloader.isDownloading) { oldValue, newValue in
            if oldValue == true && newValue == false {
                if FileManager.default.fileExists(atPath: downloader.destinationURL.path) {
                    isDownloaded = true
                }
            }
        }
        .navigationTitle(model.title)
    }
}

struct ModelPickerView: View {
    @State private var selectedModelID: UUID?
    @Environment(\.modelContext) private var modelContext

    // Final selected model
    @Binding var selectedModel: NeuralNetworkModel?

    var body: some View {
        NavigationStack {
            List(selection: $selectedModelID) {
                ForEach(NeuralNetworkModel.allCases) { model in
                    if model.visible,
                       let destinationURL = model.downloadedURL {
                        NavigationLink(model.title) {
                            ModelDetailView(
                                model: model,
                                downloader: Downloader(destinationURL: destinationURL),
                                selectedModel: $selectedModel
                            )
                        }
                    }
                }
            }
            .navigationTitle("Select a Model")
        }
        .onOpenURL { url in
            if let newGameRecord = GameRecord.createGameRecord(from: url) {
                modelContext.insert(newGameRecord)
                if let builtInModel = NeuralNetworkModel.allCases.first(
                    where: { $0.builtIn }
                ) {
                    selectedModel = builtInModel
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

#Preview("Model Detail xSmall") {
    struct PreviewHost: View {
        @State private var selectedModel: NeuralNetworkModel? = nil
        var body: some View {
            ModelDetailView(
                model: NeuralNetworkModel.allCases[1],
                downloader: Downloader(
                    destinationURL: NeuralNetworkModel.allCases[1].downloadedURL!
                ),
                selectedModel: $selectedModel
            )
        }
    }

    return PreviewHost()
        .environment(\.dynamicTypeSize, .xSmall)
}

#Preview("Model Detail accessibility5") {
    struct PreviewHost: View {
        @State private var selectedModel: NeuralNetworkModel? = nil
        var body: some View {
            ModelDetailView(
                model: NeuralNetworkModel.allCases[1],
                downloader: Downloader(
                    destinationURL: NeuralNetworkModel.allCases[1].downloadedURL!
                ),
                selectedModel: $selectedModel
            )
        }
    }

    return PreviewHost()
        .environment(\.dynamicTypeSize, .accessibility5)
}

#Preview("Model Trash Button") {
    struct PreviewHost: View {
        @State private var isDownloaded = true

        var body: some View {
            ModelTrashButton(
                model: NeuralNetworkModel.allCases[1],
                isDownloaded: $isDownloaded
            )
        }
    }

    return PreviewHost()
}
