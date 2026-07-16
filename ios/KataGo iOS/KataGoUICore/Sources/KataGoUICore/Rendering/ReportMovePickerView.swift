//
//  ReportMovePickerView.swift
//  KataGoUICore
//
//  Full-size board picker for the Deep Report's Alternative slot, pushed
//  inside the report's NavigationStack on iOS/visionOS and the macOS AppKit
//  sheet alike. Quick-pick marks annotate the engine's ranked candidates, the
//  game's move, the current alternative, and the unselectable best move; any
//  legal empty intersection is pickable. Rejections (occupied point, the best
//  move itself) surface inline without leaving the picker; engine-level
//  rejections (ko/suicide) surface later as the report's transientNotice.
//

import SwiftUI

public struct ReportMovePickerView: View {
    let model: DeepReportModel
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var feedback: String?

    public init(model: DeepReportModel, onPick: @escaping (String) -> Void) {
        self.model = model
        self.onPick = onPick
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Tap any empty intersection to make it the report's alternative move.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ReportBoardView(width: model.boardWidth, height: model.boardHeight,
                                blackVertices: model.blackVertices,
                                whiteVertices: model.whiteVertices,
                                overlay: .none,
                                pickMarks: Self.quickPicks(model: model),
                                isClassicStoneStyle: model.isClassicStoneStyle,
                                showCoordinate: model.showCoordinate,
                                verticalFlip: model.verticalFlip,
                                onTapCoordinate: handleTap)
                if let feedback {
                    Label(feedback, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                legend
            }
            .padding()
        }
        .navigationTitle("Pick an Alternative")
#if !os(macOS) && !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
            // An explicit Back beats the platform chevron here: macOS
            // presentAsSheet renders pushed views without a reliable back
            // affordance (the navigationTitle doesn't even reach the window).
            ToolbarItem(placement: .cancellationAction) {
                Button("Back") { dismiss() }
            }
        }
    }

    private func handleTap(_ coordinate: Coordinate) {
        guard let vertex = coordinate.move, vertex != "pass" else { return }
        if let rejection = Self.pickRejection(vertex: vertex, model: model) {
            feedback = rejection
            return
        }
        // Re-picking the current alternative is a no-op: just go back.
        if vertex != model.candidates.dropFirst().first?.vertex {
            onPick(vertex)
        }
        dismiss()
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            legendRow(.engineRank(1), text: "Engine candidate (ranked)")
            legendRow(.gameMove, text: "Played in the game")
            legendRow(.currentAlternative, text: "Current alternative")
            legendRow(.bestDisallowed, text: "Best Move — not selectable")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private func legendRow(_ kind: ReportPickMark.Kind, text: String) -> some View {
        HStack(spacing: 8) {
            ReportBoardView.legendSwatch(kind)
                .frame(width: 18, height: 18)
            Text(text)
        }
    }

    // MARK: - Pure logic (unit-tested)

    /// Why `vertex` can't become the alternative, or nil when it can.
    /// Board-level checks only — engine-level legality (ko, suicide) is the
    /// probe's job.
    static func pickRejection(vertex: String, model: DeepReportModel) -> String? {
        if model.blackVertices.contains(vertex) || model.whiteVertices.contains(vertex) {
            return "That point is occupied."
        }
        if vertex == model.candidates.first?.vertex {
            return "That's the Best Move — pick a different move."
        }
        return nil
    }

    /// The quick-pick marks: one mark per vertex, precedence best > current
    /// alternative > game move > engine rank; remaining engine entries keep
    /// their true rank numbers; an unranked game move comes last.
    static func quickPicks(model: DeepReportModel) -> [ReportPickMark] {
        var marks: [ReportPickMark] = []
        var seen = Set<String>()
        func add(_ vertex: String?, _ kind: ReportPickMark.Kind) {
            guard let vertex, vertex != "pass", seen.insert(vertex).inserted else { return }
            marks.append(ReportPickMark(vertex: vertex, kind: kind))
        }
        add(model.candidates.first?.vertex, .bestDisallowed)
        add(model.candidates.dropFirst().first?.vertex, .currentAlternative)
        for (index, entry) in model.snapshotEntries.enumerated() {
            add(entry.vertex,
                entry.vertex == model.gameMoveVertex ? .gameMove : .engineRank(index + 1))
        }
        add(model.gameMoveVertex, .gameMove)
        return marks
    }
}

extension ReportBoardView {
    /// The picker legend reuses the exact mark symbols the board draws.
    @ViewBuilder
    static func legendSwatch(_ kind: ReportPickMark.Kind) -> some View {
        switch kind {
        case .engineRank(let rank):
            ZStack {
                Circle().fill(.blue.opacity(0.75))
                Text("\(rank)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
        case .gameMove:
            Image(systemName: "diamond.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.green)
        case .currentAlternative:
            Circle().stroke(.orange, lineWidth: 2.5)
        case .bestDisallowed:
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
        }
    }
}
