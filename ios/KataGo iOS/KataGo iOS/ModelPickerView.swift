//
//  ModelPickerView.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/5/18.
//

import SwiftUI
import KataGoInterface

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
    @Environment(PrecompileScheduler.self) private var scheduler

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
            // Wire the post-download seam: hash the file and schedule
            // a background precompile so the cache is warm before the
            // user picks the model.
            let capturedScheduler = scheduler
            let capturedFileName = model.fileName
            downloader.onDownloadComplete = { url in
                Task.detached(priority: .userInitiated) {
                    _ = try? await BinFileHasher.shared.identityForDownloadedFile(url)
                }
                await capturedScheduler.scheduleForModel(fileName: capturedFileName)
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
    @Environment(PrecompileScheduler.self) private var scheduler

    // Final selected model
    @Binding var selectedModel: NeuralNetworkModel?

    /// Title of the model whose load did not finish during the previous
    /// launch. Empty string means no crash to display. Writing an empty
    /// string (via the banner's Dismiss button) clears the crash-loop
    /// sentinel that `ModelRunnerView` persists.
    @Binding var crashedModelTitle: String

    var body: some View {
        NavigationStack {
            List(selection: $selectedModelID) {
                if !crashedModelTitle.isEmpty {
                    recoveryBanner(crashedTitle: crashedModelTitle)
                }

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
                                    if model.title == crashedModelTitle {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(.orange)
                                            .accessibilityLabel("Did not finish loading last time")
                                    }
                                }
                            }
                        }
                    }
                }

                Section {
                    CoreMLCacheFooterView(scheduler: scheduler)
                }
            }
            .navigationTitle("Select a Model")
        }
        .onOpenURL { url in
            if let result = GameRecord.importGameRecord(from: url, in: modelContext) {
                if result.isNew {
                    modelContext.insert(result.gameRecord)
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
        let status = scheduler.status[fileName] ?? .idle
        switch status {
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.tint)
                .accessibilityLabel("Core ML cache ready")
        case .compiling:
            ProgressView().controlSize(.small)
                .accessibilityLabel("Compiling Core ML model")
        case .queued:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Waiting to compile Core ML model")
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityLabel("Compile failed; will retry")
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private func recoveryBanner(crashedTitle: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text("Last launch could not finish loading **\(crashedTitle)**.")
                        .font(.headline)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }

                Text("Your device may not have enough free memory for this network. The built-in network is recommended.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack {
                    Button {
                        if let builtIn = NeuralNetworkModel.builtInModel {
                            selectedModel = builtIn
                        }
                    } label: {
                        Text("Use Built-in Network")
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Dismiss") {
                        crashedModelTitle = ""
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

#Preview("Model Picker") {
    // A simple wrapper view to host the binding required by ModelPickerView
    struct PreviewHost: View {
        @State private var selectedModel: NeuralNetworkModel? = nil
        @State private var crashedModelTitle = ""
        @State private var scheduler = PrecompileScheduler { _ in }
        var body: some View {
            ModelPickerView(
                selectedModel: $selectedModel,
                crashedModelTitle: $crashedModelTitle
            )
            .environment(scheduler)
        }
    }
    return PreviewHost()
}

#Preview("Model Picker — Recovery Banner") {
    struct PreviewHost: View {
        @State private var selectedModel: NeuralNetworkModel? = nil
        @State private var crashedModelTitle = "Official KataGo Network"
        @State private var scheduler = PrecompileScheduler { _ in }
        var body: some View {
            ModelPickerView(
                selectedModel: $selectedModel,
                crashedModelTitle: $crashedModelTitle
            )
            .environment(scheduler)
        }
    }
    return PreviewHost()
}

#Preview("Model Detail xSmall") {
    struct PreviewHost: View {
        @State private var selectedModel: NeuralNetworkModel? = nil
        @State private var scheduler = PrecompileScheduler { _ in }
        var body: some View {
            ModelDetailView(
                model: NeuralNetworkModel.allCases[1],
                downloader: Downloader(
                    destinationURL: NeuralNetworkModel.allCases[1].downloadedURL!
                ),
                selectedModel: $selectedModel
            )
            .environment(scheduler)
        }
    }

    return PreviewHost()
        .environment(\.dynamicTypeSize, .xSmall)
}

#Preview("Model Detail accessibility5") {
    struct PreviewHost: View {
        @State private var selectedModel: NeuralNetworkModel? = nil
        @State private var scheduler = PrecompileScheduler { _ in }
        var body: some View {
            ModelDetailView(
                model: NeuralNetworkModel.allCases[1],
                downloader: Downloader(
                    destinationURL: NeuralNetworkModel.allCases[1].downloadedURL!
                ),
                selectedModel: $selectedModel
            )
            .environment(scheduler)
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
