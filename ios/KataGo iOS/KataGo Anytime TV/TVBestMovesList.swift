//
//  TVBestMovesList.swift
//  KataGo Anytime TV
//
//  The panel's "Top Moves" block: the engine's live candidate moves as
//  focusable rows the viewer can click to PLAY that move (a variation branch
//  on the review screen, a direct move on the self-play screen). The block
//  always renders exactly `rowCount` fixed-height rows — placeholders fill in
//  when analysis is off, still warming up, or reporting fewer candidates — so
//  toggling analysis or stepping moves never reflows the panel.
//

import SwiftUI
import KataGoUICore

struct TVBestMovesList: View {
    /// Strongest first (`Analysis.candidateMoves`). Values are in the
    /// side-to-move perspective, matching the on-board overlay circles.
    let candidates: [Analysis.CandidateMove]
    /// False renders non-focusable placeholder rows only (analysis off).
    let isEnabled: Bool
    var rowCount: Int = 4
    let onPick: (Analysis.CandidateMove) -> Void

    private static let rowHeight: CGFloat = 38

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Top Moves")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(0..<rowCount, id: \.self) { index in
                if isEnabled, index < candidates.count {
                    row(candidates[index])
                } else {
                    placeholderRow
                }
            }
        }
    }

    private func row(_ candidate: Analysis.CandidateMove) -> some View {
        Button {
            onPick(candidate)
        } label: {
            HStack(spacing: 0) {
                Text(candidate.vertex)
                    .font(.body.weight(.semibold))
                    .frame(width: 92, alignment: .leading)
                Text(String(format: "%.0f%%", candidate.winrate * 100))
                    .frame(width: 84, alignment: .trailing)
                Text(String(format: "%+.1f", candidate.scoreLead))
                    .frame(width: 92, alignment: .trailing)
                Spacer(minLength: 8)
                Text(convertToSIUnits(candidate.visits))
                    .foregroundStyle(.secondary)
            }
            .font(.body)
            .monospacedDigit()
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight)
        }
        .buttonStyle(.bordered)
    }

    /// A disabled button, so the chrome — and therefore the row height and
    /// the whole panel's height — is IDENTICAL to a real row's. (A plain
    /// capsule is a few points shorter than tvOS button chrome, and that
    /// difference reflowed the panel and resized the board on the analysis
    /// toggle.) Disabled ⇒ not focusable, so attract mode and analysis-off
    /// keep no clickable rows.
    private var placeholderRow: some View {
        Button {} label: {
            HStack {
                Text("—")
                    .font(.body.weight(.semibold))
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight)
        }
        .buttonStyle(.bordered)
        .disabled(true)
    }
}

// MARK: - Previews

// #Preview bodies still compile in Release, and the TVPreviewData fixtures are
// DEBUG-only — guard the whole section or archiving fails.
#if DEBUG
private let previewCandidates: [Analysis.CandidateMove] = [
    .init(vertex: "Q16", point: BoardPoint(x: 15, y: 15),
          visits: 1842, winrate: 0.54, scoreLead: 2.3, utilityLcb: 0.4),
    .init(vertex: "D4", point: BoardPoint(x: 3, y: 3),
          visits: 907, winrate: 0.51, scoreLead: 0.8, utilityLcb: 0.2),
    .init(vertex: "C17", point: BoardPoint(x: 2, y: 16),
          visits: 213, winrate: 0.47, scoreLead: -0.5, utilityLcb: -0.1),
    .init(vertex: "pass", point: BoardPoint.pass(width: 19, height: 19),
          visits: 44, winrate: 0.31, scoreLead: -4.1, utilityLcb: -0.6),
]

#Preview("Top Moves — full list") {
    TVBestMovesList(candidates: previewCandidates, isEnabled: true) { _ in }
        .padding(40)
        .frame(width: 500)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 26))
}

#Preview("Top Moves — two candidates (placeholder fill)") {
    TVBestMovesList(candidates: Array(previewCandidates.prefix(2)), isEnabled: true) { _ in }
        .padding(40)
        .frame(width: 500)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 26))
}

#Preview("Top Moves — disabled (analysis off)") {
    TVBestMovesList(candidates: previewCandidates, isEnabled: false) { _ in }
        .padding(40)
        .frame(width: 500)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 26))
}
#endif
