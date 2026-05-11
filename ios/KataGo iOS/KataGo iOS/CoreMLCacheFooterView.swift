//
//  CoreMLCacheFooterView.swift
//  KataGo iOS
//

import SwiftUI
import KataGoInterface

struct CoreMLCacheFooterView: View {
    let scheduler: PrecompileScheduler
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
        .task { await refresh() }
        .confirmationDialog("Clear Core ML Cache?",
                            isPresented: $showConfirm,
                            titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                Task { await clear() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All \(totalCount) compiled models will be removed. They will recompile on next use. The built-in model will recompile automatically in the background.")
        }
    }

    private func line(label: String, count: Int, cap: Int, bytes: Int64) -> String {
        let size = ByteCountFormatter().string(fromByteCount: bytes)
        return "\(label): \(count) of \(cap) · \(size)"
    }

    @MainActor private func refresh() async {
        // Ensure the on-disk index is loaded into memory before reading
        // stats. On a cold launch nothing else has called `start()` yet —
        // it's normally invoked from `loadCoreMLHandle` at engine boot —
        // so without this the footer reports 0 entries even when the cache
        // on disk is populated from previous runs. `start()` is idempotent.
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
        UserDefaults.standard.set("", forKey: "CoreMLCache.firstLaunchPrecompileVersion")
        scheduler.cancelAllPending()
        // Re-hydrate so cachedReady drops to empty in lockstep with the
        // footer count zeroing. subscribeToCacheEvents would also fire
        // from the clearAll tick, but this explicit await guarantees the
        // badge is consistent by the time `refresh()` reads stats below.
        let knownFileNames = Set(NeuralNetworkModel.allCases.map(\.fileName))
        let resolver = makeProjectionResolver()
        await scheduler.hydrate(
            from: .shared,
            fileNames: knownFileNames,
            digestFor: { fileName in
                guard let inputs = resolver(fileName) else { return nil }
                return try await CoreMLModelCache.projectedDigest(
                    forSourcePath: inputs.sourcePath,
                    nnXLen: inputs.nnXLen, nnYLen: inputs.nnYLen,
                    requireExactNNLen: inputs.requireExactNNLen,
                    useFP16: inputs.useFP16,
                    maxBatchSize: inputs.maxBatchSize,
                    downloadedHasher: BinFileHasher.shared.identityForDownloadedFile)
            })
        await scheduler.scheduleBuiltIn()
        await refresh()
    }
}
