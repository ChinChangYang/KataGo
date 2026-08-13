//
//  TVScoreChart.swift
//  KataGo Anytime TV
//
//  Dual-tone score-lead chart: Black-leading regions fill dark above the zero
//  baseline, White-leading regions fill light below, so who's ahead reads from
//  across the room. Data is the per-move score-lead history in
//  GameRecord.scoreLeads — synced from iPhone/iPad/Mac, and on the play screen
//  also written by the TV itself on every move. A wood-amber rule marks the
//  current move (legended by the adjacent "Move N" readout) and tracks D-pad
//  stepping. Read-only: no selection or scrubbing (a focusable chart would
//  fight section navigation).
//
//  `hidesHistoryWhenAnalysisOff` is REQUIRED at every call site, with no
//  default, because the right answer differs per screen and a silent default
//  is how the play screen shipped ungated:
//   - Play passes true. It forces the eye shut for ranked play and blanks its
//     winrate/score text accordingly, so an ungated chart was the one place
//     left that told the player who was winning.
//   - Review and self-play pass false. Review INVERTS the rule — a closed eye
//     there is what surfaces the persisted per-move numbers as a headline
//     directly above this chart — so hiding the plot would contradict the
//     number printed 40 pt higher. Self-play's eye is always open while it is
//     mounted, so the flag would be inert anyway.
//

import SwiftUI
import Charts
import KataGoUICore

struct TVScoreChart: View {
    let gameRecord: GameRecord
    /// Whether a closed eye hides the recorded history. No default — see the
    /// file header; every call site must decide.
    let hidesHistoryWhenAnalysisOff: Bool
    @Environment(GobanState.self) private var gobanState
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
        let points = self.points
        let presentation = ScoreChartVisibility.presentation(
            eyeStatus: gobanState.eyeStatus,
            honorsEyeStatus: hidesHistoryWhenAnalysisOff,
            pointCount: points.count,
            reservesSpaceWhenEmpty: reservesSpaceWhenEmpty,
            hasNoHistoryMessage: noHistoryMessage != nil)

        if presentation != .none {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Score Lead")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if presentation == .plot {
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
                switch presentation {
                case .plot:
                    // 110 (was 160): the panel also hosts the Top Moves rows
                    // now, and the trend still reads fine at this height.
                    chart(points: points)
                        .frame(height: 110)
                case .hiddenByEye, .awaitingHistory:
                    // Reserved plot slot — same 110 pt as the live chart, so
                    // the panel height is identical whether the history is
                    // pending or withheld, and toggling the eye mid-game does
                    // not reflow the panel. A gray rule echoes the chart's
                    // zero baseline so the slot reads as a chart that is not
                    // showing, rather than a hole.
                    Rectangle()
                        .fill(.gray)
                        .frame(height: 1)
                        .frame(height: 110)
                case .noHistoryText:
                    // Unreachable behind a closed eye by construction: the
                    // ladder returns .hiddenByEye first, so this sync guidance
                    // can never appear over a game whose history exists.
                    Text(noHistoryMessage ?? "")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        // Wrap instead of truncating to one line (same tvOS
                        // trap as the panel title).
                        .fixedSize(horizontal: false, vertical: true)
                case .none:
                    EmptyView()
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
@MainActor
private func chartPreview(_ game: GameRecord,
                          hidesHistoryWhenAnalysisOff: Bool = false,
                          eyeStatus: EyeStatus = .opened) -> some View {
    let gobanState = GobanState()
    gobanState.eyeStatus = eyeStatus
    return TVScoreChart(gameRecord: game,
                        hidesHistoryWhenAnalysisOff: hidesHistoryWhenAnalysisOff,
                        noHistoryMessage: nil,
                        reservesSpaceWhenEmpty: true)
        .environment(gobanState)
        .padding(28)
        .frame(width: 500)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 26))
}

// Dense zero-crossing history: both tones, mid-game marker.
#Preview("Chart — dense history") {
    chartPreview(TVPreviewData.denseAnalyzedGame())
}

// Short six-point history — the sparse-but-visible lower bound.
#Preview("Chart — sparse history") {
    chartPreview(TVPreviewData.openingGame())
}

// No usable history: the reserved slot holds the panel height steady.
#Preview("Chart — no history placeholder") {
    chartPreview(TVPreviewData.untitledFallbackGame())
}

// The play screen's default state: real history underneath, eye shut, so the
// chart shows its reserved slot and no "Move N" legend. This is the fix —
// compare against "dense history", which is the SAME record with the eye open.
#Preview("Chart — hidden by a closed eye") {
    chartPreview(TVPreviewData.denseAnalyzedGame(),
                 hidesHistoryWhenAnalysisOff: true,
                 eyeStatus: .closed)
}
#endif
