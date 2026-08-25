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
    /// Optional so a surface that injects no status keeps today's behaviour.
    @Environment(EngineStatus.self) private var engineStatus: EngineStatus?
    /// The unload path: `restart(performingWhileStopped:)`. Optional so a
    /// surface that injects no controller simply cannot offer the unload flow.
    @Environment(AppEngineController.self) private var controller: AppEngineController?

    /// The picker is a sheet over a live board now, so Clear Cache can be
    /// reached while an engine is running off the very artifacts it would
    /// delete. A running engine no longer blocks the clear — it is unloaded
    /// first and relaunched after. Only a mid-launch engine makes it wait.
    private var permission: AppEngineController.HeavyCoreMLWorkPermission {
        AppEngineController.heavyCoreMLWorkPermission(engineStatus?.availability)
    }

    private var canClear: Bool {
        switch permission {
        case .direct: true
        case .requiresUnload: controller != nil
        case .unavailable: false
        }
    }

    // Read the caps from the cache itself rather than restating them. These
    // used to be literals and drifted from the actor's actual eviction caps,
    // which made the footer claim a ceiling the cache did not enforce.
    private var mainCap: Int { CoreMLModelCache.shared.evictionCap }
    private var auxCap: Int { CoreMLModelCache.shared.auxiliaryEvictionCap }
    private var totalCount: Int { mainCount + auxCount }

    var body: some View {
        statsRow
        // Its own row, unstyled: the in-list convention (see "Play" in
        // CustomModelViews). Parked beside the stats it would inherit the
        // row's tap target, so the stat text would open the destructive
        // dialog. `.bordered` + `.tint(.secondary)` used to confine that, at
        // the price of wearing iOS's disabled costume in every state — which
        // is exactly how it read.
        if totalCount > 0 {
            Button("Clear Cache") { showConfirm = true }
                .disabled(clearing || !canClear)
        }
    }

    /// The stats row, and the host for the index subscription and the
    /// confirmation dialog. It is the unconditional sibling, and these have to
    /// hang off one view: a modifier on a `Group` wrapping both rows applies
    /// to each child, which would open two subscriptions and register two
    /// dialogs.
    private var statsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Core ML Cache")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(line(label: "Main", count: mainCount, cap: mainCap, bytes: mainBytes))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("CoreMLCache.footerMainStats")
                Text(line(label: "Human SL", count: auxCount, cap: auxCap, bytes: auxBytes))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("CoreMLCache.footerAuxStats")
            }
            if totalCount > 0, !canClear {
                Text("Available once the engine finishes loading.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
            if permission == .requiresUnload {
                Text("All \(totalCount) compiled models will be removed. The engine will restart, then recompile its model — that can take a while.")
            } else {
                Text("All \(totalCount) compiled models will be removed. They will recompile on next use.")
            }
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
        switch permission {
        case .direct:
            await CoreMLModelCache.shared.clearAll()
            // clearAll() emits an indexEvents tick, so the task-bound
            // subscription will refresh us. Call refresh() explicitly too
            // to guarantee the user sees 0/0 before the next event loop
            // iteration in case the subscription is mid-iteration.
            await refresh()
        case .requiresUnload:
            // Unload → clear → relaunch. The clear runs in the restart's
            // stopped window, when nothing holds the compiled artifacts. The
            // `clearing` flag drops as soon as the cache is empty — the
            // relaunch continues underneath, reported by the board's inline
            // status line, and re-entry stays disabled through it because the
            // availability is `.launching` (permission `.unavailable`).
            guard let controller else {
                assertionFailure("Clear offered the unload path with no controller in the environment")
                return
            }
            await controller.restart(performingWhileStopped: {
                await CoreMLModelCache.shared.clearAll()
                await refresh()
                clearing = false
            })
        case .unavailable:
            return
        }
    }
}
