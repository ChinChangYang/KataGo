//
//  BackendConfigSheet.swift
//  KataGo Anytime
//

import SwiftUI
import KataGoUICore

struct BackendConfigSheet: View {
    let model: NeuralNetworkModel
    @State private var backend: BackendChoice
    @State private var numSearchThreads: Int
    @State private var mlxBoardSize: BoardSizeChoice
    @State private var tunerFull: Bool
    @State private var reTune: Bool
    @State private var routingProbe: CoreMLRoutingProbe
    @Environment(\.dismiss) private var dismiss
    /// Optional so a surface that injects no status keeps today's behaviour.
    @Environment(EngineStatus.self) private var engineStatus: EngineStatus?
    /// The unload path: `restart(performingWhileStopped:)`. Optional so a
    /// surface that injects no controller simply cannot offer the unload flow.
    @Environment(AppEngineController.self) private var controller: AppEngineController?
    @State private var showProbeConfirm = false

    /// The probe COMPILES a network on a cache miss. That was free when this
    /// sheet was only reachable with the engine stopped; it is not free with a
    /// live engine, which the compile would fight for the same Neural Engine.
    /// So a running engine no longer blocks the check — it is unloaded first
    /// and relaunched after. Only a mid-launch engine makes it wait.
    private var probePermission: AppEngineController.HeavyCoreMLWorkPermission {
        AppEngineController.heavyCoreMLWorkPermission(engineStatus?.availability)
    }

    private var canProbe: Bool {
        switch probePermission {
        case .direct: true
        case .requiresUnload: controller != nil
        case .unavailable: false
        }
    }

    /// The Winograd autotuner only runs on an MLX/GPU server thread, so the
    /// tuning controls are only relevant when the selected backend uses the GPU.
    private var backendUsesGPU: Bool {
        backend == .mlxGPU || backend == .mux
    }

    init(model: NeuralNetworkModel) {
        self.model = model
        let settings = BackendSettings(model: model)
        self._backend = State(initialValue: settings.backend)
        self._numSearchThreads = State(initialValue: settings.numSearchThreads)
        self._mlxBoardSize = State(initialValue: settings.mlxBoardSize)
        self._tunerFull = State(initialValue: settings.tunerFull)
        self._reTune = State(initialValue: settings.reTune)
        self._routingProbe = State(initialValue: CoreMLRoutingProbe(model: model))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Backend", selection: $backend) {
                        ForEach(BackendChoice.allCases) { choice in
                            Text(choice.rawValue).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Backend")
                } footer: {
                    switch backend {
                    case .mlxGPU:
                        Text("MLX/GPU: responsive, with no compilation step.")
                    case .coremlNE:
                        Text("CoreML / Neural Engine: most power-efficient. The engine compiles a Core ML model for each network it loads, and again after an app or system update — that can take a while.")
                    case .mux:
                        Text("Runs the GPU and Neural Engine in parallel for the best throughput, at the cost of higher memory. Takes effect on the next load.")
                    }
                }

                // Sits directly under the Backend picker because it exists to
                // inform it: if Core ML pushes most operations onto the CPU
                // for this network, MLX/GPU is the better choice. Shown for
                // every backend — the user weighing a switch AWAY from
                // MLX/GPU is the one who most needs the answer.
                Section {
                    coreMLRoutingContent
                } header: {
                    Text("Core ML Routing")
                } footer: {
                    coreMLRoutingFooter
                }

                Section {
                    Picker("Board Size", selection: $mlxBoardSize) {
                        ForEach(BoardSizeChoice.allCases) { size in
                            Text(size.label).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Max Board Size")
                } footer: {
                    Text("Sets the largest board the engine can play and the size the performance tuner optimizes for. Boards larger than this won't be available until you raise it.")
                }

                Section {
                    Stepper(value: $numSearchThreads, in: 1...BackendChoice.maxSearchThreads) {
                        Text("Search Threads: \(numSearchThreads)")
                    }
                    .accessibilityIdentifier("SearchThreadsStepper")
                } header: {
                    Text("Search Threads")
                } footer: {
                    Text("More search threads can raise playing strength and throughput but use more power. Takes effect on the next load.")
                }

                if backendUsesGPU {
                    Section {
                        Picker("Autotuning", selection: $tunerFull) {
                            Text("Fast").tag(false)
                            Text("Full").tag(true)
                        }
                        .pickerStyle(.segmented)

                        Toggle("Re-tune on next load", isOn: $reTune)
                    } header: {
                        Text("Performance Tuning")
                    } footer: {
                        Text("Tunes the MLX/GPU path. Fast tunes a coarse grid in seconds. Full tunes the wide grid — more thorough but much slower on device. Each mode is cached separately, so switching takes effect on the next load. Re-tune discards the cached tuning and measures again once, the next time this model loads.")
                    }
                }
            }
            .navigationTitle(model.title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onChange(of: backend) { _, newValue in
                var settings = BackendSettings(model: model)
                settings.backend = newValue
            }
            .onChange(of: numSearchThreads) { _, newValue in
                var settings = BackendSettings(model: model)
                settings.numSearchThreads = newValue
            }
            .task { await routingProbe.refresh() }
            .onChange(of: mlxBoardSize) { _, newValue in
                var settings = BackendSettings(model: model)
                settings.mlxBoardSize = newValue
                // A different board length is a different compiled artifact,
                // so any displayed routing now describes a geometry the user
                // is no longer on. Refresh AFTER the write — the projection
                // reads the persisted setting back.
                Task { await routingProbe.refresh() }
            }
            .onChange(of: tunerFull) { _, newValue in
                var settings = BackendSettings(model: model)
                settings.tunerFull = newValue
            }
            .onChange(of: reTune) { _, newValue in
                var settings = BackendSettings(model: model)
                settings.reTune = newValue
            }
        }
    }

    // MARK: - Core ML routing readout

    @ViewBuilder
    private var coreMLRoutingContent: some View {
        if routingProbe.readiness == .sourceMissing {
            Text("Download this network first.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("CoreMLRouting.unavailable")
        } else {
            Button {
                if probePermission == .requiresUnload {
                    // Non-destructive work, but a real consequence now: the
                    // engine restarts around it. Confirm only in that case —
                    // with no engine to restart the check just runs, as ever.
                    showProbeConfirm = true
                } else {
                    Task { await routingProbe.run() }
                }
            } label: {
                HStack {
                    Text(routingButtonTitle)
                    if routingProbe.phase == .running {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(routingProbe.phase == .running || !canProbe)
            .accessibilityIdentifier("CoreMLRouting.checkButton")
            .confirmationDialog("Check Core ML Routing?",
                                isPresented: $showProbeConfirm,
                                titleVisibility: .visible) {
                Button("Check Routing") {
                    guard let controller else { return }
                    Task {
                        // Unload → probe → relaunch: the check runs in the
                        // restart's stopped window, so the compile it may need
                        // never contends with a live engine.
                        await controller.restart(performingWhileStopped: {
                            await routingProbe.run()
                        })
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The engine will stop while the routing check runs, then relaunch — recompiling if needed, which can take a while.")
            }

            switch routingProbe.phase {
            case .finished(let results):
                ForEach(results) { result in
                    routingRow(result)
                }
            case .failed:
                Text("Could not read the Core ML routing plan.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("CoreMLRouting.failure")
            case .idle, .running:
                EmptyView()
            }
        }
    }

    private var routingButtonTitle: LocalizedStringKey {
        if routingProbe.phase == .running { return "Checking…" }
        return routingProbe.readiness == .needsCompile
            ? "Compile & Check Core ML Routing"
            : "Check Core ML Routing"
    }

    private func routingRow(_ result: CoreMLRoutingResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.label)
                .font(.subheadline.weight(.semibold))
            routingDeviceLine("Neural Engine",
                              count: result.counts.neuralEngine,
                              in: result.counts)
            routingDeviceLine("CPU", count: result.counts.cpu, in: result.counts)
        }
        .padding(.vertical, 2)
    }

    private func routingDeviceLine(_ name: LocalizedStringKey,
                                   count: Int,
                                   in counts: CoreMLDeviceUsageCounts) -> some View {
        HStack {
            Text(name)
                .foregroundStyle(.secondary)
            Spacer()
            Text(count.formatted())
                .monospacedDigit()
            if let percent = counts.percentShare(of: count) {
                Text("\(percent)%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
        }
        .font(.footnote)
    }

    @ViewBuilder
    private var coreMLRoutingFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let boardLength = routingProbe.measuredBoardLength {
                Text("Measured at \(boardLength)x\(boardLength).")
            }
            Text("Core ML runs on the Neural Engine, falling back to the CPU for operations it cannot place there. The GPU path is MLX/GPU, a separate backend. When most operations fall back to the CPU, MLX/GPU is often faster.")
            if probePermission == .unavailable {
                Text("Available once the engine finishes loading.")
            } else if probePermission == .requiresUnload {
                Text("Checking stops the engine while it runs, then relaunches it.")
            }
            if routingProbe.readiness == .needsCompile, routingProbe.phase == .idle {
                Text("This network has not been compiled for Core ML at this board size yet. Checking compiles it first, which can take a while.")
            }
            #if targetEnvironment(simulator)
            Text("The Simulator has no Neural Engine, so every operation falls back to the CPU here regardless of the network. Run on a device for real routing.")
            #endif
        }
    }
}

#Preview {
    BackendConfigSheet(model: NeuralNetworkModel.allCases[0])
}
