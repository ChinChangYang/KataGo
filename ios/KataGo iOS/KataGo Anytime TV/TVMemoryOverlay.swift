//
//  TVMemoryOverlay.swift
//  KataGo Anytime TV
//
//  A top-right corner diagnostics readout for the "is Apple TV running out of
//  memory?" investigation. Shows current phys_footprint, the peak footprint seen
//  since the overlay was enabled, and the available jetsam budget
//  (os_proc_available_memory — the real per-process ceiling headroom). The
//  available line is what actually says "how close am I to being OOM-killed".
//
//  Toggled from Settings ▸ Diagnostics (`TVSettings.showMemoryOverlay`) and hosted
//  globally on TVRootView, so it floats over every screen while enabled. Peak
//  tracking starts fresh each time the overlay appears (no background sampler when
//  diagnostics are off) — enable it before restarting the engine to catch the
//  CoreML model-load spike. Reads via `MemoryProbe` (KataGoTVApp.swift).
//

import SwiftUI

struct TVMemoryOverlay: View {
    @State private var currentMB: Double = 0
    @State private var peakMB: Double = 0
    @State private var availableMB: Double = 0

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            row("Mem", currentMB, tint: .primary)
            row("Peak", peakMB, tint: .primary)
            row("Free", availableMB, tint: freeTint)
        }
        .font(.system(.caption, design: .monospaced).weight(.semibold))
        .monospacedDigit()
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        // Clear the TV overscan safe area so nothing is clipped at the edges.
        .padding(.top, 40)
        .padding(.trailing, 40)
        .allowsHitTesting(false)      // never steal focus from the UI beneath
        .task {
            // Peak resets on (re)appear — "peak only while the overlay is enabled".
            peakMB = 0
            while !Task.isCancelled {
                let reading = MemoryProbe.reading()
                if reading.footprintMB >= 0 {
                    currentMB = reading.footprintMB
                    peakMB = max(peakMB, reading.footprintMB)
                }
                availableMB = reading.availableMB
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func row(_ label: String, _ mb: Double, tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
            Text("\(Int(mb.rounded())) MB")
                .foregroundStyle(tint)
        }
    }

    /// The available-budget line reddens as headroom to the jetsam limit shrinks.
    private var freeTint: Color {
        if availableMB < 200 { return .red }
        if availableMB < 500 { return .orange }
        return .green
    }
}
