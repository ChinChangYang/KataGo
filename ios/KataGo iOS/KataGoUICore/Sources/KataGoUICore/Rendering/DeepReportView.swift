//
//  DeepReportView.swift
//  KataGoUICore
//
//  The Deep Analysis Report sheet, shared by iOS/visionOS (.sheet) and macOS
//  (NSHostingController + presentAsSheet). Sections render skeletons and fill
//  in as probe stages land; the narrative streams in last. Dismissing the
//  sheet cancels the .task, which the generator turns into abort + restore.
//

import SwiftUI

public struct DeepReportView: View {
    var gameRecord: GameRecord
    @Environment(MessageList.self) var messageList
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = DeepReportModel()
    @State private var runID = 0

    public init(gameRecord: GameRecord) {
        self.gameRecord = gameRecord
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                positionSection
                candidatesSection
                passSection
                narrativeSection
            }
            .padding()
        }
        .navigationTitle("Deep Report")
#if !os(macOS) && !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar { toolbarContent }
        .task(id: runID) {
            model = DeepReportModel()
            let generator = DeepReportGenerator(messageList: messageList)
            await generator.generate(model: model, gameRecord: gameRecord)
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Spec: app backgrounding aborts generation (iOS/visionOS — suspension
            // would freeze mid-probe). Inert on macOS by design: the AppKit host
            // never leaves .active, and macOS never suspends the process, so
            // there is nothing to abort. Dismissing cancels the .task, which the
            // generator turns into abort + restore.
            if newPhase == .background && model.isGenerating {
                dismiss()
            }
        }
    }

    // MARK: - Sections

    private var sideName: String { model.sideToMove == .black ? "Black" : "White" }

    @ViewBuilder
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(gameRecord.name)
                .font(.headline)
            Text("Move \(model.moveNumber) · \(sideName) to play")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let vps = model.visitsPerSecondText {
                Text(vps)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if case .failed(let message) = model.stage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var positionSection: some View {
        if let position = model.position {
            HStack(spacing: 16) {
                statView("Win Rate", String(format: "%.0f%%", position.winrate * 100))
                statView("Score", String(format: "%+.1f", position.scoreLead))
                statView("Visits", "\(position.visits)")
                if position.visits < ReportConstants.lowVisitThreshold {
                    quickEstimateBadge
                }
            }
        } else if model.isGenerating {
            skeletonRow(height: 44)
        }
    }

    @ViewBuilder
    private var candidatesSection: some View {
        if model.candidates.isEmpty && model.isGenerating {
            skeletonRow(height: 180)
        }
        ForEach(model.candidates) { candidate in
            CandidateSectionView(candidate: candidate,
                                 model: model,
                                 sideName: sideName,
                                 isBest: candidate.id == model.candidates.first?.id)
        }
    }

    @ViewBuilder
    private var passSection: some View {
        if let pass = model.passComparison {
            VStack(alignment: .leading, spacing: 8) {
                Text("Playing vs. Passing")
                    .font(.title3.bold())
                Text("If \(sideName) passes: \(String(format: "%.0f%%", pass.winrate * 100)) win rate — playing is worth \(String(format: "%+.0f%%", pass.winrateDeltaVsBest * 100)) and \(String(format: "%+.1f", pass.scoreLeadDeltaVsBest)) points. The opponent would punish at \(pass.punishmentVertex).")
                    .font(.callout)
                ReportBoardView(width: model.boardWidth, height: model.boardHeight,
                                blackVertices: model.blackVertices,
                                whiteVertices: model.whiteVertices,
                                overlay: .ownershipDelta(pass.ownershipDelta),
                                isClassicStoneStyle: model.isClassicStoneStyle,
                                showCoordinate: model.showCoordinate,
                                verticalFlip: model.verticalFlip)
                    .frame(maxWidth: 360)
                DeltaLegendView()
                if !pass.contestedPoints.isEmpty {
                    Text("Most contested: " + pass.contestedPoints.map(\.regionName)
                        .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                        .joined(separator: ", "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } else if model.stage == .complete {
            Label("Pass comparison unavailable — the engine produced no analysis for it.",
                  systemImage: "questionmark.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var narrativeSection: some View {
        if let reason = model.narrativeUnavailableReason {
            if gameRecord.config?.useLLM == true {
                Label(reason, systemImage: "sparkles.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if !model.narrative.isEmpty || model.stage == .narrating {
            VStack(alignment: .leading, spacing: 8) {
                Label("Summary", systemImage: "sparkles")
                    .font(.title3.bold())
                Text(model.narrative)
                if model.stage == .narrating {
                    ProgressView()
                }
            }
        }
    }

    // MARK: - Toolbar & actions

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if model.isGenerating {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }   // cancels .task → abort + restore
            }
            ToolbarItem(placement: .confirmationAction) {
                ProgressView()
            }
        } else {
            ToolbarItem(placement: .cancellationAction) {
                Button("Regenerate", systemImage: "arrow.clockwise") { runID += 1 }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Copy to Comment", systemImage: "text.bubble") { copyToComment() }
                    .disabled(model.position == nil)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func copyToComment() {
        let text = model.narrative.isEmpty
            ? ReportNarrator.facts(from: model).joined(separator: "\n")
            : model.narrative
        if gameRecord.comments == nil { gameRecord.comments = [:] }
        let existing = gameRecord.comments?[gameRecord.currentIndex] ?? ""
        gameRecord.comments?[gameRecord.currentIndex] =
            existing.isEmpty ? text : existing + "\n\n" + text
    }

    // MARK: - Bits

    private func statView(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().bold())
        }
    }

    private var quickEstimateBadge: some View {
        Text("quick estimate")
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.yellow.opacity(0.3), in: Capsule())
    }

    private func skeletonRow(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(.quaternary)
            .frame(height: height)
            .overlay(ProgressView())
    }
}

/// One candidate's block: stats, tenuki callout, and a PV / Δ-ownership
/// toggled mini-board. Own struct so each candidate keeps its own toggle state.
struct CandidateSectionView: View {
    let candidate: CandidateReport
    let model: DeepReportModel
    let sideName: String
    /// The top-ranked candidate's Δ-vs-root is ~zero by construction (it IS
    /// the root's chosen line), so it skips the toggle/Δ view entirely and
    /// always shows its variation.
    let isBest: Bool
    @State private var showsDelta = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Candidate \(candidate.vertex)")
                    .font(.title3.bold())
                if candidate.visits < ReportConstants.lowVisitThreshold {
                    Text("quick estimate")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.yellow.opacity(0.3), in: Capsule())
                }
            }
            Text("\(String(format: "%.0f%%", candidate.winrate * 100)) win rate (\(String(format: "%+.0f%%", candidate.winrateDelta * 100))) · \(String(format: "%+.1f", candidate.scoreLead)) points · \(candidate.visits) visits")
                .font(.callout)
            if let tenuki = candidate.tenuki {
                Label("If ignored, \(sideName) follows up with \(tenuki.vertex) (\(String(format: "%.0f%%", tenuki.winrate * 100)) win rate, \(String(format: "%+.1f", tenuki.scoreLead)) points).",
                      systemImage: "arrow.turn.down.right")
                    .font(.callout)
            }
            if !candidate.pv.isEmpty || !candidate.ownershipDelta.isEmpty {
                if !isBest {
                    Picker("View", selection: $showsDelta) {
                        Text("Variation").tag(false)
                        Text("Δ Ownership").tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                }
                ReportBoardView(width: model.boardWidth, height: model.boardHeight,
                                blackVertices: model.blackVertices,
                                whiteVertices: model.whiteVertices,
                                overlay: (!isBest && showsDelta)
                                    ? .ownershipDelta(candidate.ownershipDelta)
                                    : .pv(candidate.pv, startingWith: model.sideToMove),
                                isClassicStoneStyle: model.isClassicStoneStyle,
                                showCoordinate: model.showCoordinate,
                                verticalFlip: model.verticalFlip)
                    .frame(maxWidth: 360)
                if !isBest && showsDelta {
                    DeltaLegendView()
                }
            }
        }
    }
}

/// Shared legend for every Δ-ownership board: direction (not side) is what
/// the squares encode, so the legend reads "Toward Black"/"Toward White"
/// rather than a gain/loss framing tied to one side.
struct DeltaLegendView: View {
    var body: some View {
        HStack(spacing: 12) {
            legendItem("Toward Black", fill: .black)
            // A white-filled square vanishes on a light background, so a thin
            // secondary stroke is overlaid to keep it visible there too.
            legendItem("Toward White", fill: .white, strokeSecondary: true)
        }
        .font(.caption)
    }

    private func legendItem(_ text: String, fill: Color, strokeSecondary: Bool = false) -> some View {
        HStack(spacing: 4) {
            ZStack {
                Image(systemName: "square.fill")
                    .foregroundStyle(fill)
                if strokeSecondary {
                    Image(systemName: "square")
                        .foregroundStyle(.secondary)
                }
            }
            Text(text)
        }
    }
}

#Preview("Filled") {
    let model = DeepReportModel()
    model.moveNumber = 42
    model.sideToMove = .black
    model.boardWidth = 9
    model.boardHeight = 9
    model.blackVertices = ["C3", "G7"]
    model.whiteVertices = ["G3"]
    model.position = PositionSummary(winrate: 0.42, scoreLead: -4.0, visits: 150)
    model.candidates = [
        CandidateReport(vertex: "E5", visits: 100, winrate: 0.40, scoreLead: -5.0,
                        winrateDelta: -0.02, scoreLeadDelta: -1.0, pv: ["E5", "G5", "C7"],
                        ownershipDelta: [BoardPoint(x: 4, y: 4): -0.5],
                        tenuki: TenukiFollowUp(vertex: "G5", winrate: 0.56, scoreLead: 0.5,
                                               visits: 45, pv: ["G5"])),
    ]
    model.passComparison = PassComparison(punishmentVertex: "E5", winrate: 0.28, scoreLead: -7.0,
                                          winrateDeltaVsBest: 0.12, scoreLeadDeltaVsBest: 2.0,
                                          ownershipDelta: [BoardPoint(x: 2, y: 6): -0.6],
                                          contestedPoints: [])
    model.stage = .complete
    model.narrative = "Black is slightly behind here. E5 keeps the game close..."
    return NavigationStack {
        DeepReportViewPreviewHost(model: model)
    }
}

/// Preview host: DeepReportView normally builds its own model in .task; for a
/// static preview we render the same sections through a tiny shim.
private struct DeepReportViewPreviewHost: View {
    let model: DeepReportModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(model.candidates) { candidate in
                    CandidateSectionView(candidate: candidate, model: model, sideName: "Black",
                                         isBest: candidate.id == model.candidates.first?.id)
                }
            }
            .padding()
        }
    }
}
