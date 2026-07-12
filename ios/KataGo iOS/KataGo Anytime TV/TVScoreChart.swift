//
//  TVScoreChart.swift
//  KataGo Anytime TV
//
//  Dual-tone score-lead chart for the review panel: Black-leading regions fill
//  dark above the zero baseline, White-leading regions fill light below, so
//  who's ahead reads from across the room. Data is the per-move score-lead
//  history recorded while reviewing on iPhone/iPad/Mac (GameRecord.scoreLeads,
//  synced via CloudKit) — the TV only reads it, never writes, so the chart
//  stays up regardless of the analysis toggle (only live engine outputs hide
//  with it). A wood-amber rule marks the current move (legended by the
//  adjacent "Move N" readout) and tracks D-pad stepping. Read-only: no
//  selection or scrubbing (a focusable chart would fight section navigation).
//

import SwiftUI
import Charts
import KataGoUICore

struct TVScoreChart: View {
    let gameRecord: GameRecord
    /// The move the wood-amber rule marks. The review screen passes its display
    /// index (branch-aware, so the marker tracks variation stepping); nil falls
    /// back to the record's own mainline position.
    var currentIndex: Int? = nil
    /// Shown when the record has no usable history. The review default points
    /// at the other devices that produce history; the self-play screen passes
    /// nil — the sync guidance would be wrong there — and reserves the chart
    /// slot instead (see `reservesSpaceWhenEmpty`).
    var noHistoryMessage: String? =
        "No score history yet. Step through this game with analysis on iPhone, iPad, or Mac and the chart will sync here."
    /// Self-play passes true: the chart area (header + 110 pt plot) is
    /// reserved from move 0, with an empty plot placeholder until two score
    /// leads exist — the panel never reflows (and never pushes the full-height
    /// board off-screen) when the chart fills in mid-game. Review keeps the
    /// default false: its no-history placeholder text takes the slot instead.
    var reservesSpaceWhenEmpty = false

    private var markedIndex: Int { currentIndex ?? gameRecord.currentIndex }

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
        // Persisted history is valid whether or not the engine is running, so
        // the chart ignores the analysis toggle (keeping the panel layout
        // stable). With no usable history (the game was never stepped through
        // with analysis on iPhone/iPad/Mac — the common state for freshly
        // synced games), an explanatory placeholder takes the chart's place
        // instead of leaving a hole in the panel.
        let points = self.points
        if points.count >= 2 || noHistoryMessage != nil || reservesSpaceWhenEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Score Lead")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if points.count >= 2 {
                        Spacer(minLength: 12)
                        // The legend for the current-move rule below: same
                        // accent, directly adjacent — no color-matching at a
                        // distance, no alarm-red.
                        Text("Move \(markedIndex)")
                            .font(.callout.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(Color.tvWoodAccent)
                    }
                }
                if points.count >= 2 {
                    // 110 (was 160): the panel also hosts the Top Moves rows
                    // now, and the trend still reads fine at this height.
                    chart(points: points)
                        .frame(height: 110)
                } else if reservesSpaceWhenEmpty {
                    // Reserved plot slot — same 110 pt as the live chart so
                    // the panel height is identical before and after the
                    // history arrives. A gray rule echoes the chart's zero
                    // baseline so the slot reads as "chart pending", not a
                    // hole.
                    Rectangle()
                        .fill(.gray)
                        .frame(height: 1)
                        .frame(height: 110)
                } else if let noHistoryMessage {
                    Text(noHistoryMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        // Wrap instead of truncating to one line (same tvOS
                        // trap as the panel title).
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func chart(points: [LeadPoint]) -> some View {
        let leads = points.map(\.lead)
        let minY = min(-10, leads.min() ?? 0)
        let maxY = max(10, leads.max() ?? 0)
        let maxX = max(points.last?.move ?? 0, Double(markedIndex))

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

            RuleMark(x: .value("Current", Double(markedIndex)))
                .foregroundStyle(Color.tvWoodAccent)
                .lineStyle(.init(lineWidth: 2, dash: [4, 2]))
        }
        .chartXScale(domain: 0...max(1, maxX))
        .chartYScale(domain: minY...maxY)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) {
                AxisGridLine()
                // .footnote (was .title3): title3 digits taller than the axis
                // slots read as cropped at the chart's 110 pt height.
                AxisValueLabel()
                    .font(.footnote.monospacedDigit())
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
    TVScoreChart(gameRecord: TVPreviewData.denseAnalyzedGame())
        .padding(28)
        .frame(width: 500)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 26))
}

// Short six-point history — the sparse-but-visible lower bound.
#Preview("Chart — sparse history") {
    TVScoreChart(gameRecord: TVPreviewData.openingGame())
        .padding(28)
        .frame(width: 500)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 26))
}

// No usable history: the explanatory placeholder takes the chart's place
// (rendered regardless of the analysis toggle — persisted data never goes
// stale, and a constant panel layout is the point).
#Preview("Chart — no history placeholder") {
    TVScoreChart(gameRecord: TVPreviewData.untitledFallbackGame())
        .padding(28)
        .frame(width: 500)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 26))
}
#endif
