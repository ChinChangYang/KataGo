//
//  ModelPickerView.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/5/18.
//

import SwiftUI
import KataGoUICore
import UniformTypeIdentifiers

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
            Label("Remove Model", systemImage: "trash")
                .labelStyle(.iconOnly)
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
    /// Vended by the center and memoized against the destination, so pushing
    /// this view a second time lands on the same object instead of minting a
    /// second concurrent transfer of the same file.
    let download: Download
    @State var isDownloaded = false
    @State private var isShowingConfigSheet = false
    @Binding var selectedModel: NeuralNetworkModel?

    private var role: DownloadButtonRole {
        DownloadButtonRole.role(isOnDisk: isDownloaded,
                                state: download.state,
                                hasPartial: download.hasPartial)
    }

    func downloadPlayButton(model: NeuralNetworkModel) -> some View {
        Button {
            switch role {
            case .play:
                selectedModel = model
            case .download, .resume:
                if let modelURL = URL(string: model.url) {
                    DownloadCenter.shared.start(download, from: modelURL)
                }
            case .pause:
                DownloadCenter.shared.pause(download)
            }
        } label: {
            Label {
                Text(role.actionTitle)
            } icon: {
                if role == .pause {
                    Image(systemName: role.systemImageName, variableValue: download.progress)
                        .symbolVariableValueMode(.draw)
                } else {
                    Image(systemName: role.systemImageName)
                }
            }
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderedProminent)
        // Nine UI-test files tap this identifier. It must stay on ONE
        // always-present button across every role — a button that appears and
        // disappears takes the offline suite down with it.
        .accessibilityIdentifier("ModelDetailView.downloadPlayButton")
    }

    var body: some View {
        VStack {
            DownloadProgressIcon(icon: Image(.loadingIcon), progress: download.progress)

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
        .onAppear { refreshDownloadedFlag() }
        // Explicit state, not the old `isDownloading` true->false edge: a
        // pause takes that same edge, so the edge could never tell a stopped
        // download from a finished one. The center pre-hashes the finished
        // file itself, so nothing is wired here any more.
        .onChange(of: download.state) { _, newState in
            if newState == .succeeded { isDownloaded = true }
        }
        .sheet(isPresented: $isShowingConfigSheet) {
            BackendConfigSheet(model: model)
        }
        .navigationTitle(model.title)
    }

    private func refreshDownloadedFlag() {
        if model.builtIn {
            isDownloaded = true
        } else if let downloadedURL = model.downloadedURL {
            isDownloaded = FileManager.default.fileExists(atPath: downloadedURL.path)
        } else {
            isDownloaded = false
        }
    }
}

struct ModelPickerView: View {
    @State private var selectedModelID: UUID?
    @Environment(CoreMLCacheReadiness.self) private var readiness
    @Environment(\.dismiss) private var dismiss
    /// The engine-status header's inputs (ADR 0010): the resting states no
    /// longer overlay the board, so THIS surface explains them — and offers
    /// Retry — above the remedy, the model list itself. All optional: a host
    /// that injects nothing simply shows no header.
    @Environment(EngineStatus.self) private var engineStatus: EngineStatus?
    @Environment(EngineLaunchStatus.self) private var launchStatus: EngineLaunchStatus?
    @Environment(BoardSize.self) private var board: BoardSize?
    @Environment(AppEngineController.self) private var controller: AppEngineController?

    // Final selected model
    @Binding var selectedModel: NeuralNetworkModel?

    /// The user's imported networks. Held in state rather than read inline so
    /// the list is stable across the view's redraws, and refreshed explicitly
    /// after an add, rename or delete.
    @State private var customRecords: [CustomModelRecord] = []
    @State private var isPresentingImporter = false
    @State private var isCopying = false
    @State private var copyProgress: Double = 0
    @State private var importTask: Task<Void, Never>?
    @State private var importErrorMessage: String?

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
        } + customRecords.map(\.fileName)
    }

    var body: some View {
        NavigationStack {
            List(selection: $selectedModelID) {
                // Not wrapped in a Section: the view renders NOTHING when a
                // ready engine has nothing to say, and a bare row vanishes
                // cleanly where an empty Section would keep its chrome.
                if let engineStatus {
                    EngineStatusHeaderView(status: engineStatus,
                                           launchStatus: launchStatus,
                                           board: board,
                                           modelBoardCap: controller?.activeModel?.nnLen,
                                           hintStyle: .iosBackendSettings)
                }

                Section {
                    ForEach(NeuralNetworkModel.allCases) { model in
                        if model.visible,
                           let destinationURL = model.downloadedURL {
                            NavigationLink {
                                ModelDetailView(
                                    model: model,
                                    download: DownloadCenter.shared.download(for: destinationURL),
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
                    ForEach(customRecords) { record in
                        NavigationLink {
                            CustomModelDetailView(
                                record: record,
                                selectedModel: $selectedModel,
                                onStoreChanged: reloadCustomRecords
                            )
                        } label: {
                            CustomModelRow(
                                record: record,
                                isCacheReady: readiness.readyFileNames.contains(record.fileName)
                            )
                        }
                    }
                    .onDelete(perform: deleteCustomRecords)

                    Button {
                        isPresentingImporter = true
                    } label: {
                        Label("Add Custom Network…", systemImage: "plus")
                    }
                    .accessibilityIdentifier("ModelPickerView.addCustomModel")
                } header: {
                    Text("Custom Networks")
                } footer: {
                    Text("Add a KataGo network file (.bin.gz) from this device. Custom networks stay on this device.")
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
            .toolbar {
                // The picker is a sheet over a live board now, so it needs a
                // labelled way out. Swipe-to-dismiss is the only other one, and
                // it is invisible to Voice Control and VoiceOver — a user who
                // opened this from Settings ▸ Change model and changed their
                // mind had no control to speak or focus.
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("ModelPickerView.done")
                }
            }
        }
        .task {
            reloadCustomRecords()
            await readiness.update(forFileNames: visibleFileNames)
        }
        .fileImporter(
            isPresented: $isPresentingImporter,
            // Permissive on purpose. A KataGo network is `.gz` by convention
            // but may be a plain `.bin`/`.txt`, and third-party providers type
            // files inconsistently — a strict filter greys out files that
            // would have worked. The header check in the importer is what
            // actually decides, and it gives a specific reason when it says no.
            allowedContentTypes: [.gzip, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                startImport(from: url)
            case .failure(let error):
                importErrorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $isCopying) {
            CustomModelImportProgressView(progress: copyProgress, onCancel: cancelImport)
                .interactiveDismissDisabled()
        }
        .alert("Couldn't Add Network",
               isPresented: Binding(get: { importErrorMessage != nil },
                                    set: { if !$0 { importErrorMessage = nil } })) {
            Button("OK", role: .cancel) { importErrorMessage = nil }
        } message: {
            Text(importErrorMessage ?? "")
        }
        // No `.onOpenURL` here any more. It existed to answer a file/image open
        // that arrived while the picker was the ONLY thing on screen: it
        // imported the record and then selected the built-in net purely so the
        // board would mount and could present the sheet. `GameSplitView` is
        // mounted from the first frame now and owns every import, so this
        // handler could only ever duplicate it — and its side effect (launching
        // a net the user did not choose) is exactly the thing the Absent state
        // exists to avoid.
    }

    @ViewBuilder
    private func badge(for fileName: String) -> some View {
        if readiness.readyFileNames.contains(fileName) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Core ML cache ready")
        }
    }

    // MARK: - Custom networks

    private func reloadCustomRecords() {
        customRecords = CustomModelStore().records
    }

    /// Copies the picked file in on a background task, then refreshes the list.
    /// The sheet is raised before the copy starts so a large file never looks
    /// like a dropped tap.
    private func startImport(from url: URL) {
        copyProgress = 0
        isCopying = true
        importTask = Task {
            defer { isCopying = false }
            do {
                // `importModel` is a nonisolated async function, so the copy
                // runs off the main actor even though this Task inherits it.
                _ = try await CustomModelImporter.importModel(from: url) { fraction in
                    Task { @MainActor in copyProgress = fraction }
                }
                reloadCustomRecords()
                await readiness.update(forFileNames: visibleFileNames)
            } catch is CancellationError {
                // The partial file is already gone; nothing was recorded.
            } catch {
                importErrorMessage = error.localizedDescription
            }
        }
    }

    private func cancelImport() {
        importTask?.cancel()
        importTask = nil
        isCopying = false
    }

    /// Swipe-to-delete. The rows go immediately so the list feels responsive;
    /// the file, settings and Core ML cleanup follow on a background task, and
    /// the list is re-read from the store afterwards as the source of truth.
    private func deleteCustomRecords(at offsets: IndexSet) {
        let doomed = offsets.map { customRecords[$0] }
        customRecords.remove(atOffsets: offsets)
        Task {
            for record in doomed {
                await CustomModelImporter.delete(record)
            }
            reloadCustomRecords()
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
                download: DownloadCenter.shared.download(
                    for: NeuralNetworkModel.allCases[1].downloadedURL!
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
                download: DownloadCenter.shared.download(
                    for: NeuralNetworkModel.allCases[1].downloadedURL!
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
