//
//  TVSettingsScreen.swift
//  KataGo Anytime TV
//
//  Settings + recovery for the TV app. Apple TV runs a single fixed
//  CoreML/Neural Engine backend (no picker, no benchmark), so this screen is:
//  an engine restart, a "Re-download Library from iCloud" reset (arms
//  TVStoreReset and exits — the wipe happens next launch before the container
//  opens), the sound-effects toggle, and a diagnostics footer showing the
//  store mode and engine state.
//

import SwiftUI
import KataGoUICore

struct TVSettingsScreen: View {
    @Environment(TVEngineController.self) private var engine
    @Environment(GobanState.self) private var gobanState

    @AppStorage("TVSettings.soundEffects") private var soundEffects = true
    @State private var confirmingReset = false
    @State private var resetArmed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                recoverySection
                soundSection
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
                    Text(engine.phase == .running ? "Restart Engine" : engineStatusText)
                }
                .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.bordered)
            .disabled(engine.phase != .running)

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
                diagnosticRow("Engine", "CoreML / Neural Engine — \(phaseText)")
                diagnosticRow("Library store", storeModeText)
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
