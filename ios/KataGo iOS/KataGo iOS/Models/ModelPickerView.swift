//
//  ModelPickerView.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/5/18.
//

import SwiftUI
import KataGoUICore
import WidgetKit

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
        .accessibilityIdentifier("ModelDetailView.trashButton")
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
    @State private var isShowingConfigSheet = false
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
        .accessibilityIdentifier("ModelDetailView.downloadPlayButton")
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

                    Button {
                        isShowingConfigSheet = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Backend Settings")

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
            // Compute the downloaded file's identity hash so the
            // first engine launch that selects this model can
            // construct its cache key without re-hashing on the
            // hot path. No precompile is scheduled — the cache
            // populates lazily on first selection.
            downloader.onDownloadComplete = { url in
                Task.detached(priority: .userInitiated) {
                    _ = try? await BinFileHasher.shared.identityForDownloadedFile(url)
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
        .sheet(isPresented: $isShowingConfigSheet) {
            BackendConfigSheet(model: model)
        }
        .navigationTitle(model.title)
    }
}

struct ModelPickerView: View {
    @State private var selectedModelID: UUID?
    @Environment(\.modelContext) private var modelContext
    @Environment(CoreMLCacheReadiness.self) private var readiness

    // Final selected model
    @Binding var selectedModel: NeuralNetworkModel?

    /// Filenames of the picker's visible model rows. Seeds the
    /// readiness object once on appear. Un-downloaded models are
    /// passed through; the projection silently excludes them by
    /// returning nil when the source file is absent. Subsequent
    /// cache changes (compile, evict, clear) refresh the checkmarks
    /// via the readiness object's `indexEvents` subscription.
    private var visibleFileNames: [String] {
        NeuralNetworkModel.allCases.compactMap { model in
            guard model.visible else { return nil }
            return model.fileName
        }
    }

    var body: some View {
        NavigationStack {
            List(selection: $selectedModelID) {
                Section {
                    ForEach(NeuralNetworkModel.allCases) { model in
                        if model.visible,
                           let destinationURL = model.downloadedURL {
                            NavigationLink {
                                ModelDetailView(
                                    model: model,
                                    downloader: Downloader(destinationURL: destinationURL),
                                    selectedModel: $selectedModel
                                )
                            } label: {
                                HStack {
                                    Text(model.title)
                                    Spacer()
                                    badge(for: model.fileName)
                                }
                            }
                        }
                    }
                }

                Section {
                    NavigationLink {
                        OpeningBookPickerView()
                    } label: {
                        Label("Opening Books", systemImage: "books.vertical")
                    }
                    .accessibilityIdentifier("ModelPickerView.openingBooksLink")
                }

                Section {
                    CoreMLCacheFooterView()
                }
            }
            .navigationTitle("Select a Model")
        }
        .task {
            await readiness.update(forFileNames: visibleFileNames)
        }
        .onOpenURL { url in
            if let result = GameRecord.importGameRecord(from: url, in: modelContext) {
                if result.isNew {
                    modelContext.insert(result.gameRecord)
                    WidgetCenter.shared.reloadAllTimelines()
                }
                if selectedModel == nil,
                   let builtInModel = NeuralNetworkModel.builtInModel {
                    selectedModel = builtInModel
                }
            }
        }
    }

    @ViewBuilder
    private func badge(for fileName: String) -> some View {
        if readiness.readyFileNames.contains(fileName) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Core ML cache ready")
        }
    }

}

#Preview("Model Picker") {
    // A simple wrapper view to host the binding required by ModelPickerView
    struct PreviewHost: View {
        @State private var selectedModel: NeuralNetworkModel? = nil
        @State private var readiness = CoreMLCacheReadiness()
        var body: some View {
            ModelPickerView(
                selectedModel: $selectedModel
            )
            .environment(readiness)
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
