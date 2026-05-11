//
//  CoreMLCacheFooterView.swift
//  KataGo iOS
//

import SwiftUI
import KataGoInterface

struct CoreMLCacheFooterView: View {
    let scheduler: PrecompileScheduler
    @State private var entryCount: Int = 0
    @State private var sizeBytes: Int64 = 0
    @State private var showConfirm = false
    @State private var clearing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Core ML Cache")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                if entryCount == 0 {
                    Text("empty")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("CoreMLCache.footerStats")
                } else {
                    Text("\(ByteCountFormatter().string(fromByteCount: sizeBytes)) · \(entryCount) of 8 compiled models")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("CoreMLCache.footerStats")
                }
                Spacer()
                if entryCount > 0 {
                    Button("Clear Cache") { showConfirm = true }
                        .buttonStyle(.bordered)
                        .tint(.secondary)
                        .disabled(clearing)
                }
            }
        }
        .padding(.vertical, 12)
        .task { await refresh() }
        .confirmationDialog("Clear Core ML Cache?",
                            isPresented: $showConfirm,
                            titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                Task { await clear() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All \(entryCount) compiled models will be removed. They will recompile on next use. The built-in model will recompile automatically in the background.")
        }
    }

    @MainActor private func refresh() async {
        let stats = await CoreMLModelCache.shared.statsForUI()
        entryCount = stats.count
        sizeBytes = stats.totalBytes
    }

    @MainActor private func clear() async {
        clearing = true
        defer { clearing = false }
        await CoreMLModelCache.shared.clearAll()
        UserDefaults.standard.set("", forKey: "CoreMLCache.firstLaunchPrecompileVersion")
        await scheduler.scheduleBuiltIn()
        await refresh()
    }
}
