//
//  TVScoreChart.swift
//  KataGo Anytime TV
//
//  Dual-tone score-lead chart for the review panel: Black-leading regions fill
//  dark above the zero baseline, White-leading regions fill light below, so
//  who's ahead reads from across the room. Data is the per-move score-lead
//  history recorded while reviewing on iPhone/iPad/Mac (GameRecord.scoreLeads,
//  synced via CloudKit) — the TV only reads it, never writes. A red rule marks
//  the current move and tracks D-pad stepping. Read-only: no selection or
//  scrubbing (a focusable chart would fight section navigation).
//

import SwiftUI
import Charts
import KataGoUICore

struct TVScoreChart: View {
    let gameRecord: GameRecord

    @Environment(GobanState.self) private var gobanState

    private struct LeadPoint: Identifiable {
        let move: Double
        let lead: Float
        var id: Double { move }
    }

    /// The recorded history, with a synthetic zero point interpolated at every
    /// sign change so the clamped dual-tone fills meet the lead line exactly
    /// where it crosses the baseline (without these, fill edge and line visibly
    /// diverge around crossings).
    private var points: [LeadPoint] {
        let recorded = (gameRecord.scoreLeads ?? [:])
            .sorted { $0.key < $1.key }
            .map { LeadPoint(move: Double($0.key), lead: $0.value) }

        var result: [LeadPoint] = []
        for point in recorded {
            if let last = result.last, last.lead * point.lead < 0 {
                let t = Double(last.lead / (last.lead - point.lead))
                result.append(LeadPoint(move: last.move + t * (point.move - last.move),
                                        lead: 0))
            }
            result.append(point)
        }
        return result
    }

    var body: some View {
        let points = self.points
        // Hidden with the analysis overlay (same rule as the iOS chart), and
        // for games with no usable history (never analyzed per-move on
        // iPhone/iPad/Mac) — the panel card just keeps its text.
        if gobanState.eyeStatus != .closed, points.count >= 2 {
            chart(points: points)
                .frame(height: 200)
        }
    }

    private func chart(points: [LeadPoint]) -> some View {
        let leads = points.map(\.lead)
        let minY = min(-10, leads.min() ?? 0)
        let maxY = max(10, leads.max() ?? 0)
        let maxX = max(points.last?.move ?? 0, Double(gameRecord.currentIndex))

        return Chart {
            // Dual-tone fills, each series clamped at zero. Graphite above the
            // baseline ("Black ahead") and near-white below ("White ahead") —
            // grays rather than true black/white so both regions stay visible
            // against the dark panel card. Monotone interpolation avoids
            // overshoot artifacts at the zero crossings.
            ForEach(points) { point in
                AreaMark(x: .value("Move", point.move),
                         yStart: .value("Zero", 0),
                         yEnd: .value("Black lead", max(0, point.lead)),
                         series: .value("Side", "Black"))
                    .foregroundStyle(Color(white: 0.32))
                    .interpolationMethod(.monotone)

                AreaMark(x: .value("Move", point.move),
                         yStart: .value("Zero", 0),
                         yEnd: .value("White lead", min(0, point.lead)),
                         series: .value("Side", "White"))
                    .foregroundStyle(Color(white: 0.88))
                    .interpolationMethod(.monotone)

                LineMark(x: .value("Move", point.move),
                         y: .value("Lead", point.lead))
                    .foregroundStyle(.white)
                    .interpolationMethod(.monotone)
                    .lineStyle(.init(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }

            RuleMark(y: .value("Even", 0))
                .foregroundStyle(.gray)
                .lineStyle(.init(lineWidth: 1, dash: [4, 4]))

            RuleMark(x: .value("Current", Double(gameRecord.currentIndex)))
                .foregroundStyle(.red)
                .lineStyle(.init(lineWidth: 2, dash: [4, 2]))
        }
        .chartXScale(domain: 0...max(1, maxX))
        .chartYScale(domain: minY...maxY)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) {
                AxisGridLine()
                AxisValueLabel()
                    .font(.body.monospacedDigit())
            }
        }
    }
}

// MARK: - Previews

// #Preview bodies still compile in Release, and the TVPreviewData fixtures are
// DEBUG-only — guard the whole section or archiving fails.
#if DEBUG
// Dense zero-crossing history: both tones, mid-game marker.
#Preview("Chart — dense history") {
    let gobanState = GobanState()
    return TVScoreChart(gameRecord: TVPreviewData.denseAnalyzedGame())
        .padding(28)
        .frame(width: 500)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 26))
        .environment(gobanState)
}

// Short six-point history — the sparse-but-visible lower bound.
#Preview("Chart — sparse history") {
    let gobanState = GobanState()
    return TVScoreChart(gameRecord: TVPreviewData.openingGame())
        .padding(28)
        .frame(width: 500)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 26))
        .environment(gobanState)
}

// No usable history (and likewise when the overlay is closed): renders nothing.
#Preview("Chart — hidden (no data)") {
    let gobanState = GobanState()
    return TVScoreChart(gameRecord: TVPreviewData.untitledFallbackGame())
        .padding(28)
        .frame(width: 500)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 26))
        .environment(gobanState)
}
#endif
