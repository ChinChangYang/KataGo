//
//  TVSettingsScreen.swift
//  KataGo Anytime TV
//
//  Settings + recovery for the TV app: the engine backend (CoreML/NE vs
//  MLX/GPU) with a one-tap on-device benchmark that persists the winner as
//  the default, engine restart, a "Re-download Library from iCloud" reset
//  (arms TVStoreReset and exits — the wipe happens next launch before the
//  container opens), and the sound-effects toggle. A diagnostics footer
//  shows the store mode, engine state, and the last benchmark.
//

import SwiftUI
import KataGoUICore

struct TVSettingsScreen: View {
    @Environment(TVEngineController.self) private var engine
    @Environment(GameSession.self) private var session
    @Environment(GobanState.self) private var gobanState

    @State private var benchmark = TVBenchmarkController()
    @AppStorage("TVSettings.soundEffects") private var soundEffects = true
    @State private var confirmingMLX = false
    @State private var confirmingReset = false
    @State private var resetArmed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                backendSection
                recoverySection
                soundSection
                diagnosticsFooter
            }
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
        .navigationTitle("Settings")
        // Settings is a tab now, so there is nothing to dismiss — let tvOS route
        // Menu to the tab bar by default. The one exception: while a benchmark
        // leg runs, the engine is synchronously inside kata-benchmark and cannot
        // be cancelled, so install a no-op handler to swallow the Menu press and
        // keep the app foregrounded until the run finishes (passing nil installs
        // no handler at all, restoring the default tab-bar behavior).
        .onExitCommand(perform: benchmark.isRunning ? {} : nil)
        .alert("Library reset armed", isPresented: $resetArmed) {
            Button("Close App Now") { exit(0) }
        } message: {
            Text("The app will now close. Open it again and your games will re-download from iCloud.")
        }
    }

    // MARK: - Backend

    private var backendSection: some View {
        section("Analysis Backend") {
            HStack(spacing: 16) {
                backendButton(.coreML)
                backendButton(.mlx)
            }

            Button {
                Task { await benchmark.run(engine: engine, session: session) }
            } label: {
                HStack(spacing: 12) {
                    if benchmark.isRunning {
                        ProgressView()
                    } else {
                        Image(systemName: "speedometer")
                    }
                    Text(benchmark.isRunning ? benchmarkStatusText : "Run Benchmark")
                }
                .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .disabled(engine.phase != .running || benchmark.isRunning)

            Text(benchmarkCaption)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog(
            "Switch to MLX / GPU?",
            isPresented: $confirmingMLX,
            titleVisibility: .visible
        ) {
            Button("Switch", role: .destructive) {
                Task { _ = await engine.restart(to: .mlx, persistOnSuccess: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("MLX runs analysis on the GPU. Its memory headroom on Apple TV is untested — if the app quits unexpectedly, it will reopen on the CoreML backend automatically.")
        }
    }

    private func backendButton(_ backend: TVEngineBackend) -> some View {
        Button {
            guard backend != engine.currentBackend else { return }
            if backend == .mlx {
                confirmingMLX = true
            } else {
                Task { _ = await engine.restart(to: .coreML, persistOnSuccess: true) }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: engine.currentBackend == backend
                      ? "checkmark.circle.fill" : "circle")
                Text(backend.displayName)
            }
            .font(.body)
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.bordered)
        .disabled(backend == .mlx && !TVEngineBackend.mlxIsAvailable
                  || engine.phase != .running || benchmark.isRunning)
    }

    private var benchmarkStatusText: String {
        switch benchmark.state {
        case .restarting(let backend):
            return backend == .mlx
                ? "Preparing MLX (first-time GPU tuning)…"
                : "Preparing \(backend.displayName)…"
        case .measuring(let backend):
            return "Benchmarking \(backend.displayName)… about a minute"
        default:
            return "Run Benchmark"
        }
    }

    private var benchmarkCaption: String {
        // Results/failures first — they must never be hidden by the static
        // simulator notice.
        switch benchmark.state {
        case .finished(let result):
            return summary(of: result) + " The faster backend is now the default."
        case .failed(let reason):
            return "Benchmark failed: \(reason)"
        case .restarting, .measuring:
            return "Switching backends can take a couple of minutes after heavy engine use — please wait."
        case .idle:
            if !TVEngineBackend.mlxIsAvailable {
                return "MLX is unavailable in the Simulator — the benchmark measures CoreML only there. Run it on a real Apple TV to compare both backends."
            }
            return "Measures both backends on fixed positions and makes the faster one the default."
        }
    }

    // MARK: - Recovery

    private var recoverySection: some View {
        section("Recovery") {
            Button {
                Task { _ = await engine.restart(to: engine.currentBackend, persistOnSuccess: false) }
            } label: {
                HStack(spacing: 12) {
                    if engine.phase == .starting || engine.phase == .stopping {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(engine.phase == .running ? "Restart Engine" : engineStatusText)
                }
                .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.bordered)
            .disabled(engine.phase != .running || benchmark.isRunning)

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
            .disabled(benchmark.isRunning)

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

    private var engineStatusText: String {
        switch engine.phase {
        case .idle: return "Engine not started"
        case .starting: return "Engine starting…"
        case .running: return "Restart Engine"
        case .stopping: return "Engine stopping…"
        case .failed(let reason): return "Engine failed: \(reason)"
        }
    }

    // MARK: - Sound

    private var soundSection: some View {
        section("Sound") {
            Toggle("Sound Effects", isOn: $soundEffects)
                .onChange(of: soundEffects) { _, newValue in
                    gobanState.soundEffect = newValue
                }
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsFooter: some View {
        section("Diagnostics") {
            VStack(alignment: .leading, spacing: 8) {
                diagnosticRow("Engine", "\(engine.currentBackend.displayName) — \(phaseText)")
                diagnosticRow("Library store", storeModeText)
                if let last = TVSettingsStore.lastBenchmark {
                    diagnosticRow("Last benchmark", last.aborted
                                  ? "Aborted (the app quit mid-run; CoreML restored)"
                                  : summary(of: last))
                }
            }
            .font(.callout)
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

    private var phaseText: String {
        switch engine.phase {
        case .idle: return "not started"
        case .starting: return "starting"
        case .running: return "running"
        case .stopping: return "stopping"
        case .failed(let reason): return "failed (\(reason))"
        }
    }

    private var storeModeText: String {
        switch SharedModelContainer.tvStoreMode {
        case .cloudKit: return "iCloud (CloudKit sync)"
        case .localOnly: return "Local only (iCloud unavailable)"
        case .inMemory: return "In-memory (storage unavailable)"
        }
    }

    private func summary(of result: TVBenchmarkResult) -> String {
        func text(_ value: Double?) -> String {
            value.map { String(format: "%.1f visits/s", $0) } ?? "—"
        }
        return "CoreML \(text(result.coreMLVisitsPerSecond)) · MLX \(text(result.mlxVisitsPerSecond)) → \(result.winner.displayName)"
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
}
#endif
