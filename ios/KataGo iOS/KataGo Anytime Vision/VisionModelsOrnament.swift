//
//  VisionModelsOrnament.swift
//  KataGo Anytime Vision
//
//  Right-anchor Models card — the visionOS mirror of iOS's
//  ModelPickerView / ModelDetailView, built on the same shared blocks
//  (NeuralNetworkModel registry, DownloadCenter, CoreMLCacheReadiness)
//  with the pure row/detail state in KataGoUICore (VisionModelListItem /
//  VisionModelDetailState). A NavigationStack inside the glass card: the
//  full catalog list (active row + green cache-ready checkmark) pushes
//  a detail page with the shared four-role download button (play /
//  download / pause / resume), description, and trash. Downloads are
//  memoized by destination URL in the app-wide DownloadCenter, not
//  per-card, so an in-flight (or paused) download keeps its progress
//  across screens and app launches, not just while the card is open.
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
    /// Fired by the gear view when the ACTIVE model's Max Board Size
    /// changes (already persisted) — the root quits and respawns the
    /// engine with the new NN buffer. Other models never fire it (their
    /// value applies at activation), so the pre-boot chooser keeps the
    /// no-op default.
    var onMaxBoardSizeRestart: () -> Void = {}
    let onDismiss: () -> Void

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
                                          download: DownloadCenter.shared.download(
                                              for: model.downloadedURL
                                                  ?? URL.documentsDirectory
                                                      .appendingPathComponent(model.fileName)),
                                          onActivate: onActivate)
                }
            }
            .navigationDestination(for: BoardSizeDestination.self) { destination in
                if let model = NeuralNetworkModel.allCases
                    .first(where: { $0.title == destination.modelTitle }) {
                    VisionModelBoardSizeView(model: model,
                                             engine: engine,
                                             isBootChooser: isBootChooser,
                                             onRestart: onMaxBoardSizeRestart)
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
}

/// Detail page: iOS ModelDetailView, with the gear pushing the per-model
/// Max Board Size view (Vision's only per-model setting — no
/// backend/threads pickers). Rendering follows VisionModelDetailState.
private struct VisionModelDetailView: View {
    let model: NeuralNetworkModel
    let engine: VisionEngineController
    var isBootChooser = false
    let download: Download
    let onActivate: (NeuralNetworkModel) -> Void

    @State private var isDownloaded = false

    private var state: VisionModelDetailState {
        // Pre-boot chooser: no engine yet, so nothing is active and
        // activation is always allowed (it IS the boot).
        VisionModelDetailState.make(
            isBuiltIn: model.builtIn,
            fileSize: model.fileSize,
            isDownloaded: isDownloaded,
            downloadState: download.state,
            hasPartial: download.hasPartial,
            isActive: !isBootChooser && model.title == engine.activeModel.title,
            engineIsRunning: isBootChooser || engine.phase == .running)
    }

    var body: some View {
        VStack {
            DownloadProgressIcon(icon: Image(.loadingIcon), progress: download.progress)
                .frame(width: 160, height: 160)

            VStack(alignment: .leading) {
                Text(model.title)
                    .bold()

                HStack {
                    Text(state.sizeText)
                        .foregroundStyle(.secondary)

                    primaryButton

                    // iOS gear parity: per-model settings next to the
                    // primary button. A push, not a sheet — the card owns
                    // a NavigationStack, and sheets from ornaments are
                    // unproven on visionOS.
                    NavigationLink(value: BoardSizeDestination(modelTitle: model.title)) {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Max Board Size")

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
        .onChange(of: download.state) { _, newState in
            if newState == .succeeded { isDownloaded = true }
        }
    }

    private var primaryButton: some View {
        Button {
            switch state.primary {
            case .play:
                onActivate(model)
            case .download, .resume:
                if let modelURL = URL(string: model.url) {
                    DownloadCenter.shared.start(download, from: modelURL)
                }
            case .pause:
                DownloadCenter.shared.pause(download)
            }
        } label: {
            if state.primary == .pause {
                Image(systemName: state.primarySystemImage, variableValue: download.progress)
                    .symbolVariableValueMode(.draw)
            } else {
                Image(systemName: state.primarySystemImage)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(state.primaryDisabled)
        .accessibilityLabel(state.primary == .play ? "Activate model" : state.primary.actionTitle)
    }
}

/// Navigation value for the detail's gear push. Carries the title (the
/// registry key the String destination already resolves by), not the model,
/// so the destination lookup stays uniform.
private struct BoardSizeDestination: Hashable {
    let modelTitle: String
}

/// Max Board Size page pushed from the detail's gear — the iOS
/// BackendConfigSheet analog, holding Vision's only per-model setting.
/// Apply timing follows VisionBoardSizeSetting (hybrid): the ACTIVE model
/// restarts the engine on change (its buffer can't be reloaded any other
/// way — Activate is disabled for it); any other model, and the pre-boot
/// chooser, persist only and apply at activation.
private struct VisionModelBoardSizeView: View {
    let model: NeuralNetworkModel
    let engine: VisionEngineController
    var isBootChooser = false
    let onRestart: () -> Void

    /// Seeded from the persisted per-model choice, clamped to the offered
    /// segments; no re-seed observer — the displayed model is fixed for
    /// the pushed view's lifetime.
    @State private var boardSize: BoardSizeChoice

    init(model: NeuralNetworkModel,
         engine: VisionEngineController,
         isBootChooser: Bool = false,
         onRestart: @escaping () -> Void) {
        self.model = model
        self.engine = engine
        self.isBootChooser = isBootChooser
        self.onRestart = onRestart
        // Only persisted + nnLen feed the seed; the activity flags don't
        // affect `selection`.
        _boardSize = State(initialValue: VisionBoardSizeSetting.make(
            persisted: BackendSettings(model: model).mlxBoardSize,
            nnLen: model.nnLen,
            isActiveModel: false,
            isBootChooser: isBootChooser,
            engineIsRunning: false).selection)
    }

    private var setting: VisionBoardSizeSetting {
        VisionBoardSizeSetting.make(
            persisted: BackendSettings(model: model).mlxBoardSize,
            nnLen: model.nnLen,
            isActiveModel: !isBootChooser && model.title == engine.activeModel.title,
            isBootChooser: isBootChooser,
            engineIsRunning: engine.phase == .running)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Max board size", systemImage: "squareshape.split.3x3")
                Picker("Max board size", selection: $boardSize) {
                    ForEach(setting.choices) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(setting.pickerDisabled)
            }

            Text(setting.footerText)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if setting.showsEngineStatusFooter && engine.phase != .running {
                HStack(spacing: 8) {
                    if case .failed(let reason) = engine.phase {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Text(reason)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                        Text("Restarting engine…")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
        .navigationTitle("Max Board Size")
        .onChange(of: boardSize) { oldValue, newValue in
            guard oldValue != newValue else { return }
            // The setter writes the per-fileName UserDefaults key — the
            // local var is the persist.
            var settings = BackendSettings(model: model)
            settings.mlxBoardSize = newValue
            if setting.restartsEngineOnChange {
                onRestart()
            }
        }
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
