//
//  CustomModelViews.swift
//  KataGo Anytime
//
//  The manage surface for user-imported networks: the picker's "Custom
//  Networks" rows, the copy-progress sheet, and the detail screen where a
//  network is renamed, annotated, launched or deleted.
//
//  Deliberately separate from `ModelDetailView`. A catalog entry's detail
//  screen is organized around downloading — its primary control cycles
//  Download / Stop / Play, and its trash button removes a file that can always
//  be fetched again. A custom network has no URL to re-fetch from, so its
//  delete is final, and it gains the two things a catalog entry can never
//  have: an editable name and editable notes.
//

import SwiftUI
import KataGoUICore

/// One row in the picker's Custom Networks section.
struct CustomModelRow: View {
    let record: CustomModelRecord
    let isCacheReady: Bool

    private var fileExists: Bool {
        FileManager.default.fileExists(
            atPath: CustomModelStore.directoryURL.appendingPathComponent(record.fileName).path)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.displayName)
                Text(record.fileSize.humanFileSize)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !fileExists {
                // Should not happen — the file is written before the record —
                // but a row that silently fails to launch is worse than one
                // that says why.
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("File missing")
            } else if isCacheReady {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Core ML cache ready")
            }
        }
    }
}

/// Modal shown while a picked file is copied into the app. Determinate
/// because the copy can be hundreds of megabytes, where a bare spinner is
/// indistinguishable from a hang.
struct CustomModelImportProgressView: View {
    let progress: Double
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Adding Network")
                .font(.headline)
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .accessibilityIdentifier("CustomModelImport.progress")
            Text("\(Int((progress * 100).rounded()))%")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button("Cancel", role: .cancel, action: onCancel)
                .accessibilityIdentifier("CustomModelImport.cancel")
        }
        .padding(32)
        .frame(maxWidth: 360)
    }
}

struct CustomModelDetailView: View {
    let record: CustomModelRecord
    @Binding var selectedModel: NeuralNetworkModel?
    /// Invoked after a change the picker's list must reflect (rename, delete).
    /// Notes are not included — they never appear in the list.
    let onStoreChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var notes: String
    @State private var isShowingConfigSheet = false
    @State private var isConfirmingDelete = false
    @State private var isDeleting = false
    @FocusState private var isNameFocused: Bool

    init(record: CustomModelRecord,
         selectedModel: Binding<NeuralNetworkModel?>,
         onStoreChanged: @escaping () -> Void) {
        self.record = record
        self._selectedModel = selectedModel
        self.onStoreChanged = onStoreChanged
        self._name = State(initialValue: record.displayName)
        self._notes = State(initialValue: record.notes)
    }

    private var fileURL: URL {
        CustomModelStore.directoryURL.appendingPathComponent(record.fileName)
    }

    private var fileExists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// The live projection of this record. Re-read from the store rather than
    /// captured, so a rename is reflected in the settings sheet immediately.
    private var model: NeuralNetworkModel? {
        CustomModelStore().models.first { $0.id == record.id }
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Network name", text: $name)
                    .focused($isNameFocused)
                    .onSubmit(commitName)
                    .accessibilityIdentifier("CustomModelDetailView.nameField")
            }

            Section("Notes") {
                TextEditor(text: $notes)
                    .frame(minHeight: 88)
                    .onChange(of: notes) { _, newValue in
                        CustomModelStore().setNotes(id: record.id, to: newValue)
                    }
                    .accessibilityIdentifier("CustomModelDetailView.notesField")
            }

            Section {
                LabeledContent("Size", value: record.fileSize.humanFileSize)
                LabeledContent("Added",
                               value: record.importedAt.formatted(date: .abbreviated,
                                                                  time: .shortened))
                if !fileExists {
                    Label("This network's file is missing. Delete it and add it again.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text("This network stays on this device. It is not copied to your other devices.")
            }

            Section {
                Button {
                    if let model { selectedModel = model }
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .disabled(!fileExists)
                .accessibilityIdentifier("CustomModelDetailView.playButton")

                Button {
                    isShowingConfigSheet = true
                } label: {
                    Label("Backend Settings", systemImage: "gearshape")
                }
            } footer: {
                Text("Max Board Size lives in Backend Settings and starts at 19×19. Raise it only if you know this network handles larger boards.")
            }

            Section {
                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Label("Delete Network", systemImage: "trash")
                }
                .disabled(isDeleting)
                .accessibilityIdentifier("CustomModelDetailView.deleteButton")
            }
        }
        .navigationTitle(name.isEmpty ? "Custom Network" : name)
        .onChange(of: isNameFocused) { _, focused in
            // Committing on blur as well as on submit: a hardware keyboard's
            // Return fires onSubmit, but tapping away from the field does not.
            if !focused { commitName() }
        }
        .sheet(isPresented: $isShowingConfigSheet) {
            if let model {
                BackendConfigSheet(model: model)
            }
        }
        .confirmationDialog(
            "Delete “\(name)”? The network file is removed from this device, along with its settings. This cannot be undone — you would need to add the file again.",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: delete)
            Button("Cancel", role: .cancel) { isConfirmingDelete = false }
        }
    }

    /// Writes the edited name back, adopting whatever the store returns — a
    /// collision with a built-in title or another custom network comes back
    /// suffixed, and the field must show the name that was actually stored.
    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != record.displayName else { return }
        guard let stored = CustomModelStore().rename(id: record.id, to: trimmed) else { return }
        name = stored
        onStoreChanged()
    }

    private func delete() {
        isDeleting = true
        Task {
            await CustomModelImporter.delete(record)
            onStoreChanged()
            dismiss()
        }
    }
}
