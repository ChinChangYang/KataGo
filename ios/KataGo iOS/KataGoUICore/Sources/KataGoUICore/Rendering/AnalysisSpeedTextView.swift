//
//  AnalysisSpeedTextView.swift
//  KataGo iOS
//

import SwiftUI

/// The visits/s readout centered in the empty gap between the captured-stone
/// counts. The counts keep their fixed positions, so enabling/disabling the
/// readout never shifts them.
///
/// A standalone view so the per-line `analysis.visitsPerSecond` mutation from
/// the continuous kata-analyze stream invalidates only this text — reading it
/// from `BoardView.body` (the old `speedText` computed property) re-rendered
/// the whole board, stones included, on every analysis line.
struct AnalysisSpeedTextView: View {
    @Environment(GobanState.self) var gobanState
    @Environment(Analysis.self) var analysis

    let dimensions: Dimensions

    var body: some View {
        if let text = speedText {
            let spread = 0.75 * max(dimensions.gobanWidth / 2, dimensions.capturedStonesWidth)
            let gapWidth = max(0, (2 * spread) - dimensions.capturedStonesWidth)
            Text(text)
                .contentTransition(.numericText())
                .font(.system(size: dimensions.capturedStonesHeight * 0.85, design: .monospaced))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .frame(width: gapWidth, height: dimensions.capturedStonesHeight)
                .position(x: dimensions.gobanStartX + (dimensions.gobanWidth / 2),
                          y: dimensions.capturedStonesStartY)
        }
    }

    /// The visits/s text to show, or nil when hidden.
    private var speedText: String? {
        guard gobanState.showVisitsPerSecond,
              gobanState.analysisStatus == .run,
              analysis.visitsPerSecond > 0 else { return nil }
        return analysis.visitsPerSecondText
    }
}
