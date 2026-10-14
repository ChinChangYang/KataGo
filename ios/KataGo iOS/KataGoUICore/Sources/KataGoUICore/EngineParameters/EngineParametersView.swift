//
//  EngineParametersView.swift
//  KataGoUICore
//
//  The Engine Parameters screen: every parameter the engine reads, searchable,
//  each with its custom value or the value the app ships. Managed parameters
//  are shown read-only and name the setting that controls them instead.
//

#if !os(tvOS) && !os(watchOS)
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct EngineParametersView: View {
    @Bindable private var editor: CustomParametersEditor
    /// What the running engine launched with; nil when no engine has launched.
    private let launched: CustomParameters?
    /// Relaunches the engine to apply launch-timing changes; nil when the host
    /// cannot (no engine controller in reach).
    private let onRelaunch: (() -> Void)?

    @State private var searchText = ""
    @State private var confirmingResetAll = false
    @State private var showingImport = false
    @State private var showingAddKey = false

    public init(editor: CustomParametersEditor,
                launched: CustomParameters?,
                onRelaunch: (() -> Void)?) {
        self.editor = editor
        self.launched = launched
        self.onRelaunch = onRelaunch
    }

    private var pendingKeys: [String] {
        guard let launched else { return [] }
        return editor.parameters.pendingLaunchKeys(launchedWith: launched)
    }

    /// The catalog's matches, grouped by the example cfg's sections in the
    /// order they first appear alphabetically.
    private var sections: [(title: String, parameters: [EngineParameter])] {
        let matches = EngineParameterCatalog.search(searchText)
        let grouped = Dictionary(grouping: matches) { $0.section.isEmpty ? "Other" : $0.section }
        return grouped.keys.sorted().map { ($0, grouped[$0]!) }
    }

    /// Custom values for keys the catalog does not list.
    private var unlistedKeys: [String] {
        editor.parameters.sortedKeys.filter { EngineParameterCatalog.parameter(forKey: $0) == nil }
    }

    public var body: some View {
        List {
            if !pendingKeys.isEmpty {
                Section {
                    Text("Waiting for the engine to relaunch: \(pendingKeys.joined(separator: ", ")).")
                        .font(.callout)
                    if let onRelaunch {
                        Button("Relaunch Engine", action: onRelaunch)
                            .accessibilityIdentifier("EngineParameters.relaunch")
                    }
                }
            }

            if searchText.isEmpty && !editor.parameters.isEmpty {
                Section("Custom Values") {
                    ForEach(editor.parameters.sortedKeys, id: \.self) { key in
                        row(forKey: key)
                    }
                }
            } else if !unlistedKeys.isEmpty {
                Section("Unlisted Keys") {
                    ForEach(unlistedKeys, id: \.self) { key in
                        row(forKey: key)
                    }
                }
            }

            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.parameters) { parameter in
                        row(forKey: parameter.key)
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search keys and descriptions")
        .navigationTitle("Engine Parameters")
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Add Unlisted Key…", systemImage: "plus") { showingAddKey = true }
                    Button("Paste cfg…", systemImage: "doc.on.clipboard") { showingImport = true }
                    Button("Copy as cfg", systemImage: "doc.on.doc") { copyToPasteboard(editor.parameters.cfgText) }
                        .disabled(editor.parameters.isEmpty)
                    Divider()
                    Button("Reset All", systemImage: "arrow.counterclockwise", role: .destructive) {
                        confirmingResetAll = true
                    }
                    .disabled(editor.parameters.isEmpty)
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("EngineParameters.actions")
            }
        }
        .confirmationDialog("Reset all \(editor.parameters.count) custom values?",
                            isPresented: $confirmingResetAll, titleVisibility: .visible) {
            Button("Reset All", role: .destructive) { editor.resetAll() }
        }
        .sheet(isPresented: $showingImport) {
            NavigationStack { CfgImportView(editor: editor) }
        }
        .sheet(isPresented: $showingAddKey) {
            NavigationStack { AddUnlistedKeyView(editor: editor) }
        }
    }

    private func row(forKey key: String) -> some View {
        NavigationLink {
            EngineParameterDetailView(key: key, editor: editor)
        } label: {
            EngineParameterRow(key: key, customValue: editor.parameters.values[key])
        }
    }
}

/// One parameter in the list: its key, and the value in effect.
struct EngineParameterRow: View {
    let key: String
    let customValue: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                // Keys run to 44 characters with no spaces; let them wrap
                // rather than truncate, since the key is the row's identity.
                Text(key)
                    .font(.callout.monospaced())
                    .fixedSize(horizontal: false, vertical: true)
                if let owner = EngineParameterCatalog.owner(ofKey: key) {
                    Text("Set by \(owner.settingName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if EngineParameterCatalog.timing(ofKey: key) == .launch {
                    Text("Applies at relaunch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let customValue {
                Text(customValue)
                    .font(.callout.monospaced().weight(.semibold))
                    .foregroundStyle(.tint)
            } else if let shipped = EngineParameterCatalog.shippedValue(forKey: key) {
                Text(shipped.value)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("EngineParameters.row.\(key)")
    }
}

/// One parameter's description, its value in effect, and the control that sets it.
struct EngineParameterDetailView: View {
    let key: String
    @Bindable var editor: CustomParametersEditor

    @State private var draft = ""
    @State private var error: CustomValueError?

    private var parameter: EngineParameter? { EngineParameterCatalog.parameter(forKey: key) }
    private var customValue: String? { editor.parameters.values[key] }
    private var shipped: ShippedValue? { EngineParameterCatalog.shippedValue(forKey: key) }

    var body: some View {
        Form {
            Section {
                // The inline title truncates the longest keys; the full key
                // is what a person copies into a cfg or searches for.
                Text(key)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                if let summary = parameter?.summary, !summary.isEmpty {
                    Text(summary)
                } else {
                    Text("KataGo's example configuration does not describe this key.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if let shipped {
                    LabeledContent(shipped.source == .app ? "App value" : "KataGo default",
                                   value: shipped.value)
                }
                if let range = rangeText {
                    LabeledContent("Range", value: range)
                }
                LabeledContent("Takes effect",
                               value: EngineParameterCatalog.timing(ofKey: key) == .live ? "At once" : "At relaunch")
            }

            if let owner = EngineParameterCatalog.owner(ofKey: key) {
                Section {
                    Text("The app sets this itself, through \(owner.settingName).")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Custom Value") {
                    valueControl
                    if let error {
                        Text(error.message)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("EngineParameters.error")
                    }
                }
                if customValue != nil {
                    Section {
                        Button("Reset to Default", role: .destructive) {
                            editor.reset(key)
                            draft = ""
                            error = nil
                        }
                        .accessibilityIdentifier("EngineParameters.reset")
                    }
                }
            }
        }
        .navigationTitle(key)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { draft = customValue ?? "" }
    }

    private var rangeText: String? {
        switch parameter?.kind {
        case .integer(let range?): "\(range.lowerBound) to \(range.upperBound)"
        case .real(let range?): "\(range.lowerBound.formatted()) to \(range.upperBound.formatted())"
        case .bool: "true or false"
        case .enabled: "auto, true or false"
        default: nil
        }
    }

    @ViewBuilder
    private var valueControl: some View {
        switch parameter?.kind {
        case .bool:
            choicePicker(["true", "false"])
        case .enabled:
            choicePicker(["auto", "true", "false"])
        default:
            HStack {
                TextField(shipped?.value ?? "Value", text: $draft)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(isNumeric ? .numbersAndPunctuation : .default)
                    #endif
                    .onSubmit(apply)
                    .accessibilityIdentifier("EngineParameters.valueField")
                Button("Apply", action: apply)
                    .disabled(draft.trimmingCharacters(in: .whitespaces) == (customValue ?? ""))
                    .accessibilityIdentifier("EngineParameters.apply")
            }
        }
    }

    private var isNumeric: Bool {
        switch parameter?.kind {
        case .integer, .real: true
        default: false
        }
    }

    /// A choice among a few values, plus "Default" for no custom value.
    private func choicePicker(_ choices: [String]) -> some View {
        Picker("Value", selection: Binding(
            get: { customValue ?? "" },
            set: { newValue in
                if newValue.isEmpty {
                    editor.reset(key)
                } else {
                    error = editor.set(key, to: newValue)
                }
            })) {
            Text("Default").tag("")
            ForEach(choices, id: \.self) { Text($0).tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("EngineParameters.choice")
    }

    private func apply() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            editor.reset(key)
            error = nil
            return
        }
        error = editor.set(key, to: trimmed)
        if error == nil, let accepted = editor.parameters.values[key] {
            draft = accepted
        }
    }
}

/// Adds a custom value for a key the catalog does not list.
struct AddUnlistedKeyView: View {
    @Bindable var editor: CustomParametersEditor
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var value = ""
    @State private var error: CustomValueError?

    var body: some View {
        Form {
            Section {
                TextField("Key", text: $key)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityIdentifier("EngineParameters.addKey")
                TextField("Value", text: $value)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityIdentifier("EngineParameters.addValue")
            } footer: {
                Text("A key the catalog does not list is passed to the engine when it next launches. The engine ignores a key it does not know.")
            }
            if let error {
                Text(error.message)
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle("Add Unlisted Key")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    error = editor.set(key.trimmingCharacters(in: .whitespaces), to: value)
                    if error == nil { dismiss() }
                }
                .disabled(key.isEmpty || value.isEmpty)
            }
        }
    }
}

/// Imports `key = value` lines pasted from a cfg file.
struct CfgImportView: View {
    @Bindable var editor: CustomParametersEditor
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var result: (imported: [String], skipped: [SkippedCfgLine])?

    var body: some View {
        Form {
            if let result {
                Section("Imported") {
                    if result.imported.isEmpty {
                        Text("Nothing").foregroundStyle(.secondary)
                    }
                    ForEach(result.imported, id: \.self) { Text($0).font(.body.monospaced()) }
                }
                if !result.skipped.isEmpty {
                    Section("Skipped") {
                        ForEach(result.skipped, id: \.self) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.key).font(.body.monospaced())
                                Text(line.reason.message).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                Section {
                    TextEditor(text: $text)
                        .font(.body.monospaced())
                        .frame(minHeight: 200)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .accessibilityIdentifier("EngineParameters.importText")
                    PasteButton(payloadType: String.self) { strings in
                        text = strings.joined(separator: "\n")
                    }
                } footer: {
                    Text("Paste lines such as \"cpuctExploration = 1.1\". Comments are ignored; parameters the app sets itself are skipped.")
                }
            }
        }
        .navigationTitle("Paste cfg")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(result == nil ? "Cancel" : "Done") { dismiss() }
            }
            if result == nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { result = editor.importCfgText(text) }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("EngineParameters.import")
                }
            }
        }
    }
}

private func copyToPasteboard(_ text: String) {
    #if canImport(UIKit)
    UIPasteboard.general.string = text
    #elseif canImport(AppKit)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
}
#endif
