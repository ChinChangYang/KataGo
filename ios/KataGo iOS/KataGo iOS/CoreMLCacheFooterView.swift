//
//  CoreMLCacheFooterView.swift
//  KataGo iOS
//

import SwiftUI
import KataGoUICore

struct CoreMLCacheFooterView: View {
    @State private var mainCount: Int = 0
    @State private var mainBytes: Int64 = 0
    @State private var auxCount: Int = 0
    @State private var auxBytes: Int64 = 0
    @State private var showConfirm = false
    @State private var clearing = false

    private var mainCap: Int { 4 }
    private var auxCap: Int { 4 }
    private var totalCount: Int { mainCount + auxCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Core ML Cache")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(line(label: "Main", count: mainCount, cap: mainCap, bytes: mainBytes))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("CoreMLCache.footerMainStats")
                    Text(line(label: "Human SL", count: auxCount, cap: auxCap, bytes: auxBytes))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("CoreMLCache.footerAuxStats")
                }
                Spacer()
                if totalCount > 0 {
                    Button("Clear Cache") { showConfirm = true }
                        .buttonStyle(.bordered)
                        .tint(.secondary)
                        .disabled(clearing)
                }
            }
        }
        .padding(.vertical, 12)
        .task {
            // Subscribe before the initial read so any tick that lands
            // during refresh() is buffered (bufferingNewest(1)) and
            // consumed on the first for-await iteration. Reversing the
            // order would drop ticks that fire between refresh() and
            // subscription.
            let stream = await CoreMLModelCache.shared.indexEvents
            await refresh()
            for await _ in stream {
                await refresh()
            }
        }
        .confirmationDialog("Clear Core ML Cache?",
                            isPresented: $showConfirm,
                            titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                Task { await clear() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All \(totalCount) compiled models will be removed. They will recompile on next use.")
        }
    }

    private func line(label: String, count: Int, cap: Int, bytes: Int64) -> String {
        let size = ByteCountFormatter().string(fromByteCount: bytes)
        return "\(label): \(count) of \(cap) · \(size)"
    }

    @MainActor private func refresh() async {
        // Ensure the on-disk index is loaded into memory before
        // reading stats. start() is idempotent.
        await CoreMLModelCache.shared.start()
        let stats = await CoreMLModelCache.shared.statsByCategory()
        mainCount = stats.main.count
        mainBytes = stats.main.totalBytes
        auxCount  = stats.auxiliary.count
        auxBytes  = stats.auxiliary.totalBytes
    }

    @MainActor private func clear() async {
        clearing = true
        defer { clearing = false }
        await CoreMLModelCache.shared.clearAll()
        // clearAll() emits an indexEvents tick, so the task-bound
        // subscription will refresh us. Call refresh() explicitly too
        // to guarantee the user sees 0/0 before the next event loop
        // iteration in case the subscription is mid-iteration.
        await refresh()
    }
}
