//
//  TVSettingsScreen.swift
//  KataGo Anytime TV
//
//  Settings + recovery for the TV app. Apple TV runs a single fixed Core ML
//  backend, pinned to CPU+GPU because the Neural Engine never takes this net
//  (see CoreMLComputeHandleLoader), so there is no backend picker and this
//  screen is: an engine restart, a Core ML benchmark, a "Re-download Library
//  from iCloud" reset (arms
//  TVStoreReset and exits — the wipe happens next launch before the container
//  opens), the sound-effects toggle, and a diagnostics footer showing the
//  store mode and engine state.
//

import SwiftUI
import KataGoUICore

struct TVSettingsScreen: View {
    @Environment(TVEngineController.self) private var engine
    @Environment(GobanState.self) private var gobanState
    @Environment(TVControllerInput.self) private var controllerInput
    /// Read OPTIONALLY, like every other reader of it: a preview that injects
    /// none simply shows the phase.
    @Environment(EngineStatus.self) private var engineStatus: EngineStatus?

    @AppStorage("TVSettings.soundEffects") private var soundEffects = true
    @AppStorage(NarrationSpeechSetting.defaultsKey) private var spokenNarration
        = NarrationSpeechSetting.defaultValue
    @AppStorage("TVSettings.showMemoryOverlay") private var showMemoryOverlay = false
    /// Auto-Play cadence on the review screen. A plain @AppStorage (unlike
    /// `boardSize`, whose key is derived from a model file name at runtime and
    /// therefore needs the @State + BackendSettings round-trip).
    @AppStorage(TVAutoPlaySpeed.defaultsKey) private var autoPlaySpeed = TVAutoPlaySpeed.defaultValue
    @State private var confirmingReset = false
    @State private var resetArmed = false
    @State private var benchmark = TVCoreMLBenchmark()
    @State private var confirmingBenchmark = false
    /// Seeded from the persisted per-model setting in `init`; writes back +
    /// restart the engine on change.
    @State private var boardSize: BoardSizeChoice

    /// The single fixed tvOS model (bundled b18). `?? .allCases[0]` is defensive
    /// only — `builtInModel` is always present on tvOS.
    private static var engineModel: NeuralNetworkModel {
        NeuralNetworkModel.builtInModel ?? NeuralNetworkModel.allCases[0]
    }

    init() {
        _boardSize = State(initialValue: BackendSettings(model: Self.engineModel).mlxBoardSize)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                recoverySection
                boardSizeSection
                playbackSection
                soundSection
                if controllerInput.isConnected {
                    gameControllerSection
                }
                aboutSection
                diagnosticsFooter
            }
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
        .navigationTitle("Settings")
        .alert("Library reset armed", isPresented: $resetArmed) {
            Button("Close App Now") { exit(0) }
        } message: {
            Text("The app will now close. Open it again and your games will re-download from iCloud.")
        }
    }

    // MARK: - Recovery

    private var recoverySection: some View {
        section("Recovery") {
            Button {
                Task { _ = await engine.restartEngine() }
            } label: {
                HStack(spacing: 12) {
                    if engine.phase == .starting || engine.phase == .stopping {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(engineStatusText)
                        // Nothing on a tvOS screen may wrap: an engine failure
                        // reason has no length bound, so it shrinks instead.
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.bordered)
            // Enabled from `.failed` too — this button IS the way back from a
            // launch that never came up (the same path the status line's Retry
            // takes). Only a restart already in flight refuses another.
            .disabled(!engine.canRestartNow)

            Button {
                confirmingReset = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "icloud.and.arrow.down")
                    Text("Re-download Library from iCloud…")
                }
                .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.bordered)

            Text("Deletes the local copy of your library and downloads it again from iCloud on the next launch. Use this if games look wrong on this Apple TV. It cannot undo changes that already synced to iCloud.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog(
            "Re-download Library?",
            isPresented: $confirmingReset,
            titleVisibility: .visible
        ) {
            Button("Delete Local Copy and Close App", role: .destructive) {
                TVStoreReset.arm()
                resetArmed = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if FileManager.default.ubiquityIdentityToken != nil {
                Text("The local library is deleted and re-downloaded from iCloud when you reopen the app.")
            } else {
                Text("This Apple TV isn't signed into iCloud — after the reset the library will be EMPTY until you sign in. Continue only if you are sure.")
            }
        }
    }

    /// The Recovery button's label. tvOS has ONE engine vocabulary — the
    /// headlines come from `EngineStatusText`, the same source as the one line
    /// the game screens show — and this screen is the one place the raw failure
    /// reason may appear, because it is where a failure is acted on.
    private var engineStatusText: String {
        switch engine.phase {
        case .idle: return "Engine not started"
        case .starting: return "\(EngineStatusText.loadingHeadline)…"
        case .running: return "Restart Engine"
        case .stopping: return "Stopping engine…"
        case .failed(let reason): return "\(EngineStatusText.failedHeadline): \(reason)"
        }
    }

    // MARK: - Board size

    private var boardSizeSection: some View {
        section("Board Size") {
            Picker("Max Board Size", selection: $boardSize) {
                ForEach(BoardSizeChoice.allCases) { size in
                    Text(size.label).tag(size)
                }
            }
            .pickerStyle(.segmented)
            // Mirror the Restart button: a change triggers `restartEngine`, so
            // it is offered exactly when a restart may begin. That INCLUDES a
            // failed engine (relaunching it with a different buffer is a fix)
            // and a *held* one, whose phase is `.running` — raising this is the
            // remedy the held line on the board points at.
            .disabled(!engine.canRestartNow)
            .onChange(of: boardSize) { _, newValue in
                var settings = BackendSettings(model: Self.engineModel)
                settings.mlxBoardSize = newValue
                // Respawn so the engine's NN buffer (and the controller's
                // maxBoardLength) pick up the new size — the same proven
                // quit → respawn → handshake path as "Restart Engine".
                Task { _ = await engine.restartEngine() }
            }

            Text("Sets the largest board the engine can play. Bigger games show a message until you raise it. Changing this restarts the engine.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Playback

    private var playbackSection: some View {
        section("Playback") {
            Picker("Auto-Play Speed", selection: $autoPlaySpeed) {
                ForEach(TVAutoPlaySpeed.allCases) { speed in
                    Text(speed.label).tag(speed)
                }
            }
            .pickerStyle(.segmented)
            // Deliberately NO .disabled(engine.phase…) and NO .onChange:
            // unlike Max Board Size, a speed change must never restart the
            // engine, and the review screen re-reads the key every tick.

            Text("How fast Auto-Play steps through a saved game's recorded moves. Start and stop Auto-Play with the Play/Pause button while reviewing a game.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Sound

    private var soundSection: some View {
        section("Sound") {
            Toggle("Sound Effects", isOn: $soundEffects)
                .onChange(of: soundEffects) { _, newValue in
                    gobanState.soundEffect = newValue
                }
            Toggle("Spoken Narration", isOn: $spokenNarration)
            Text("Reads the broadcast commentary aloud during live games and Auto-Play.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Game Controller

    private var gameControllerSection: some View {
        section("Game Controller") {
            Text(controllerInput.vendorName ?? "Controller connected")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow {
                    Text("").gridCellUnsizedAxes(.horizontal)
                    Text("Reviewing").font(.callout).foregroundStyle(.secondary)
                    Text("Live").font(.callout).foregroundStyle(.secondary)
                    Text("Playing").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(TVControllerLegend.rows) { row in
                    GridRow {
                        Label(row.name, systemImage: row.symbol)
                        Text(row.review)
                        Text(row.live)
                        Text(row.play)
                    }
                }
            }

            Text("The D-pad, A and B navigate the interface as usual.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsFooter: some View {
        section("Diagnostics") {
            VStack(alignment: .leading, spacing: 22) {
                benchmarkControl
                Toggle("Memory Overlay (top-right corner)", isOn: $showMemoryOverlay)
                VStack(alignment: .leading, spacing: 8) {
                    // `phaseText` is TVEngineController's lifecycle phase, not
                    // the Core ML compile status. "pinned" describes the
                    // configuration the loader sets, which is the honest claim:
                    // the timeout fallback can still end up elsewhere.
                    diagnosticRow("Engine", "Core ML (CPU + GPU, pinned) — \(phaseText)")
                    diagnosticRow("Library store", storeModeText)
                }
                .font(.callout)
            }
        }
        .confirmationDialog(
            "Run Core ML Benchmark?",
            isPresented: $confirmingBenchmark,
            titleVisibility: .visible
        ) {
            Button("Quit Engine & Run") { runBenchmark() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Quits the analysis engine, benchmarks the Core ML model under all four compute-unit settings (CPU / CPU+GPU / CPU+ANE / ALL, ~30s), then restarts the engine. Neural-Engine numbers are only meaningful on a real Apple TV — the Simulator has no ANE.")
        }
    }

    // MARK: - Core ML benchmark

    private var benchmarkControl: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                confirmingBenchmark = true
            } label: {
                HStack(spacing: 12) {
                    if isBenchmarkRunning {
                        ProgressView()
                    } else {
                        Image(systemName: "speedometer")
                    }
                    Text(benchmarkButtonText)
                }
                .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.bordered)
            // Same rule as the other two engine controls: the benchmark runs
            // INSIDE `restartEngine`'s downtime window, so it is offered
            // exactly when a restart may begin — a failed engine included,
            // where measuring the box is a diagnostic rather than a luxury.
            .disabled(isBenchmarkRunning || !engine.canRestartNow)

            benchmarkResults

            Text("Benchmarks the built-in network at 19×19 under each Core ML compute-unit setting. Use it to see whether the model routes to the Neural Engine and which path is fastest.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var isBenchmarkRunning: Bool {
        if case .running = benchmark.state { return true }
        return false
    }

    private var benchmarkButtonText: String {
        switch benchmark.state {
        case .running(let done, let total): return "Benchmarking… [\(done)/\(total)]"
        default: return "Benchmark Core ML Model"
        }
    }

    @ViewBuilder
    private var benchmarkResults: some View {
        switch benchmark.state {
        case .finished(let rows):
            BenchmarkResultsTable(rows: rows)
        case .failed(let message):
            Text("Benchmark failed: \(message)")
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }

    private func runBenchmark() {
        Task {
            // Quit the engine, run the benchmark with the process holding no
            // resident net, then auto-restart — all inside the proven restart
            // machinery (read-loop parking, thread-exit wait, handshake).
            await engine.restartEngine(duringDowntime: {
                await benchmark.run()
            })
        }
    }

    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 260, alignment: .leading)
            Text(value)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The diagnostics footer's engine row. Same vocabulary, lower case: this
    /// is a fact list, not a control.
    private var phaseText: String {
        switch engine.phase {
        case .idle: return "not started"
        case .starting: return "starting"
        case .running: return engineStatus.map { availabilityText($0.availability) } ?? "running"
        case .stopping: return "stopping"
        case .failed(let reason): return "failed (\(reason))"
        }
    }

    /// What a RUNNING engine is doing for the board — the distinction the phase
    /// alone cannot make, and the one a viewer reporting a problem needs: an
    /// engine that is up but *held* analyses nothing, on purpose.
    private func availabilityText(_ availability: EngineAvailability) -> String {
        switch availability {
        case .held(let maxBoardLength): return "running (held: board over \(maxBoardLength))"
        default: return "running"
        }
    }

    private var storeModeText: String {
        switch SharedModelContainer.tvStoreMode {
        case .cloudKit: return "iCloud (CloudKit sync)"
        case .localOnly: return "Local only (iCloud unavailable)"
        case .inMemory: return "In-memory (storage unavailable)"
        }
    }

    // MARK: - About

    /// EULA parity: every platform lists its third-party licenses under
    /// Settings. The row pushes the shared registry list on this tab's
    /// NavigationStack (TVRootView wraps the screen in one).
    private var aboutSection: some View {
        section("About") {
            NavigationLink {
                AcknowledgmentsView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "doc.text")
                    Text("Open-Source Licenses")
                }
                .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Section chrome

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 26))
        }
    }
}

// MARK: - Benchmark results table

/// Monospaced comparison table for a completed Core ML benchmark: one row per
/// compute-unit setting, with throughput/latency and the static ANE/GPU/CPU
/// op-routing breakdown. Cells show "—" when unavailable (routing) and a failed
/// config shows its error spanning the numeric columns.
private struct BenchmarkResultsTable: View {
    let rows: [TVCoreMLBenchmark.Row]

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 22, verticalSpacing: 8) {
            GridRow {
                Text("Compute units").gridColumnAlignment(.leading)
                Text("inf/s")
                Text("ms")
                Text("ANE")
                Text("GPU")
                Text("CPU")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            Divider().gridCellUnsizedAxes(.horizontal).gridCellColumns(6)

            ForEach(rows) { row in
                GridRow {
                    Text(row.config).gridColumnAlignment(.leading)
                    if let error = row.error {
                        Text(error)
                            .foregroundStyle(.red)
                            .gridColumnAlignment(.leading)
                            .gridCellColumns(5)
                    } else {
                        Text(format(row.infPerSec, "%.1f"))
                        Text(format(row.medianMs, "%.1f"))
                        Text(formatInt(row.aneOps))
                        Text(formatInt(row.gpuOps))
                        Text(formatInt(row.cpuOps))
                    }
                }
            }
        }
        .font(.system(.callout, design: .monospaced))
        .monospacedDigit()
        .padding(.vertical, 4)
    }

    private func format(_ value: Double?, _ spec: String) -> String {
        value.map { String(format: spec, $0) } ?? "—"
    }

    private func formatInt(_ value: Int?) -> String {
        value.map(String.init) ?? "—"
    }
}

// MARK: - Previews

// #Preview bodies still compile in Release, and the TVPreviewData fixtures are
// DEBUG-only — guard the whole section or archiving fails.
#if DEBUG
#Preview("Settings") {
    let session = GameSession()
    let engine = TVEngineController()
    return NavigationStack {
        TVSettingsScreen()
    }
    .environment(engine)
    .environment(session)
    .environment(session.gobanState)
    .environment(TVControllerInput())
}
#endif
