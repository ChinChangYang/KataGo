//
//  VisionModelsOrnament.swift
//  KataGo Anytime Vision
//
//  Right-anchor Models card — the visionOS mirror of iOS's
//  ModelPickerView / ModelDetailView, built on the same shared blocks
//  (NeuralNetworkModel registry, Downloader, CoreMLCacheReadiness,
//  BinFileHasher) with the pure row/detail state in KataGoUICore
//  (VisionModelListItem / VisionModelDetailState). A NavigationStack
//  inside the glass card: the full catalog list (active row + green
//  cache-ready checkmark) pushes a detail page with the tri-state
//  download / activate / stop button, description, and trash.
//  Downloaders are cached per fileName at the card level (the Mac
//  ModelsViewController pattern) so an in-flight download keeps its
//  progress when the user navigates away and back.
//

import SwiftUI
import KataGoUICore

struct VisionModelsOrnament: View {
    let engine: VisionEngineController
    let readiness: CoreMLCacheReadiness
    /// Pre-boot chooser mode (shell.phase == .choosingModel): no engine is
    /// running yet, so nothing is "active", every net is activatable, and
    /// the card cannot be dismissed — picking a net IS the boot.
    var isBootChooser = false
    let onActivate: (NeuralNetworkModel) -> Void
    let onDismiss: () -> Void

    @State private var downloaders: [String: Downloader] = [:]

    private var items: [VisionModelListItem] {
        VisionModelListItem.makeAll(
            activeTitle: isBootChooser ? "" : engine.activeModel.title,
            readyFileNames: readiness.readyFileNames)
    }

    var body: some View {
        NavigationStack {
            List(items) { item in
                NavigationLink(value: item.title) {
                    HStack {
                        Text(item.title)
                        Spacer()
                        if item.isActive {
                            Image(systemName: "play.circle.fill")
                                .foregroundStyle(.tint)
                                .accessibilityLabel("Active model")
                        }
                        if item.showsReadyCheckmark {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .accessibilityLabel("Core ML cache ready")
                        }
                    }
                }
            }
            .navigationTitle("Models")
            .navigationDestination(for: String.self) { title in
                if let model = NeuralNetworkModel.allCases
                    .first(where: { $0.title == title }) {
                    VisionModelDetailView(model: model,
                                          engine: engine,
                                          isBootChooser: isBootChooser,
                                          downloader: downloader(for: model),
                                          onActivate: onActivate)
                }
            }
            .toolbar {
                if !isBootChooser {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("Close models")
                    }
                }
            }
        }
        .frame(width: 440, height: 620)
        .glassBackgroundEffect()
        .task {
            await readiness.update(forFileNames: items.map(\.fileName))
        }
    }

    /// One Downloader per model for the card's lifetime, wired to pre-hash
    /// the finished file for the CoreML cache key (iOS ModelDetailView
    /// onAppear parity — the cache itself populates lazily on first load).
    private func downloader(for model: NeuralNetworkModel) -> Downloader {
        if let existing = downloaders[model.fileName] { return existing }
        let downloader = Downloader(
            destinationURL: model.downloadedURL
                ?? URL.documentsDirectory.appendingPathComponent(model.fileName))
        downloader.onDownloadComplete = { url in
            Task.detached(priority: .userInitiated) {
                _ = try? await BinFileHasher.shared.identityForDownloadedFile(url)
            }
        }
        downloaders[model.fileName] = downloader
        return downloader
    }
}

/// Detail page: iOS ModelDetailView without the backend gear (Vision has no
/// per-model backend/threads pickers; Max Board Size lives in Settings and
/// keys off the active model). Rendering follows VisionModelDetailState.
private struct VisionModelDetailView: View {
    let model: NeuralNetworkModel
    let engine: VisionEngineController
    var isBootChooser = false
    let downloader: Downloader
    let onActivate: (NeuralNetworkModel) -> Void

    @State private var isDownloaded = false

    private var state: VisionModelDetailState {
        // Pre-boot chooser: no engine yet, so nothing is active and
        // activation is always allowed (it IS the boot).
        VisionModelDetailState.make(
            isBuiltIn: model.builtIn,
            fileSize: model.fileSize,
            isDownloaded: isDownloaded,
            isDownloading: downloader.isDownloading,
            isActive: !isBootChooser && model.title == engine.activeModel.title,
            engineIsRunning: isBootChooser || engine.phase == .running)
    }

    var body: some View {
        VStack {
            Image(.loadingIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 160, height: 160)
                .clipShape(.circle)
                .rotationEffect(.degrees(downloader.progress * 360))

            VStack(alignment: .leading) {
                Text(model.title)
                    .bold()

                HStack {
                    Text(state.sizeText)
                        .foregroundStyle(.secondary)

                    primaryButton

                    Spacer()

                    if state.showsTrash {
                        VisionModelTrashButton(model: model,
                                               isDownloaded: $isDownloaded)
                    }
                }
                .padding(.vertical)

                ScrollView {
                    Text(model.description)
                }
            }
        }
        .padding()
        .navigationTitle(model.title)
        .onAppear {
            if model.builtIn {
                isDownloaded = true
            } else if let downloadedURL = model.downloadedURL {
                isDownloaded = FileManager.default
                    .fileExists(atPath: downloadedURL.path)
            } else {
                isDownloaded = false
            }
        }
        .onChange(of: downloader.isDownloading) { oldValue, newValue in
            if oldValue == true && newValue == false {
                if FileManager.default.fileExists(atPath: downloader.destinationURL.path) {
                    isDownloaded = true
                }
            }
        }
    }

    private var primaryButton: some View {
        Button {
            switch state.primary {
            case .activate:
                onActivate(model)
            case .download:
                Task {
                    if let modelURL = URL(string: model.url) {
                        try? await downloader.download(from: modelURL)
                    }
                }
            case .stopDownload:
                downloader.cancel()
            }
        } label: {
            if state.primary == .stopDownload {
                Image(systemName: "stop.circle", variableValue: downloader.progress)
                    .symbolVariableValueMode(.draw)
            } else {
                Image(systemName: state.primarySystemImage)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(state.primaryDisabled)
        .accessibilityLabel(state.primary == .activate ? "Activate model"
                            : state.primary == .download ? "Download model"
                            : "Stop download")
    }
}

/// iOS ModelTrashButton, ported verbatim (it is app-target-private there):
/// destructive trash with the same confirmation strings, removing the
/// downloaded file from Documents.
private struct VisionModelTrashButton: View {
    var model: NeuralNetworkModel
    @Binding var isDownloaded: Bool
    @State private var isConfirming = false

    var body: some View {
        Button(role: .destructive) {
            isConfirming = true
        } label: {
            Image(systemName: "trash")
        }
        .accessibilityLabel("Remove model")
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
