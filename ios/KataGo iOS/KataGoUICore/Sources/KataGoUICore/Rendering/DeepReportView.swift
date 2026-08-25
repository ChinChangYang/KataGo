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
    /// One engine operation on the report; `.task(id:)` keyed on this value
    /// runs it and auto-cancels the previous one. The seq/attempt/pass
    /// payloads exist to make retries distinct ids — SwiftUI won't re-fire
    /// an unchanged id.
    private enum ReportOperation: Equatable, Hashable {
        case initial(attempt: Int)
        case refine(pass: Int)
        case pick(vertex: String, seq: Int)
        case idle
    }

    var gameRecord: GameRecord
    @Environment(MessageList.self) var messageList
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = DeepReportModel()
    @State private var operation: ReportOperation = .initial(attempt: 0)
    @State private var opSeq = 0
    @State private var showingPicker = false
    @State private var confirmingReplaceComment = false
    /// Drives the Copy-to-Comment icon's brief checkmark morph after a write.
    @State private var justCopied = false
    @State private var copyRevertTask: Task<Void, Never>?

    /// AppKit hosts (NSHostingController + presentAsSheet) pass a closure
    /// here because SwiftUI's DismissAction cannot reach an AppKit-presented
    /// sheet. SwiftUI presentation contexts (iOS/visionOS .sheet) leave this
    /// nil and \.dismiss is used instead.
    private let onClose: (() -> Void)?

    public init(gameRecord: GameRecord, onClose: (() -> Void)? = nil) {
        self.gameRecord = gameRecord
        self.onClose = onClose
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    public var body: some View {
        // The NavigationStack lives INSIDE the view (not at the call sites) so
        // the picker push works identically under the iOS/visionOS .sheet and
        // the macOS NSHostingController+presentAsSheet host.
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    headerSection
                    candidatesSection
                    passSection
                    narrativeSection
                }
                .padding()
            }
            .navigationTitle("Deep Analysis Report")
#if !os(macOS) && !os(tvOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar { toolbarContent }
            .confirmationDialog("Replace existing comment?",
                                isPresented: $confirmingReplaceComment,
                                titleVisibility: .visible) {
                Button("Replace", role: .destructive) { performCopyToComment() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This move already has a comment. Copying the report replaces it.")
            }
            .navigationDestination(isPresented: $showingPicker) {
                ReportMovePickerView(model: model) { vertex in
                    opSeq += 1
                    operation = .pick(vertex: vertex, seq: opSeq)
                }
            }
        }
        .task(id: operation) {
            let generator = DeepReportGenerator(messageList: messageList)
            switch operation {
            case .initial:
                model = DeepReportModel()
                await generator.generate(model: model, gameRecord: gameRecord)
            case .refine:
                await generator.refine(model: model, gameRecord: gameRecord)
            case .pick(let vertex, _):
                await generator.repickAlternative(model: model, gameRecord: gameRecord, vertex: vertex)
            case .idle:
                break
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Spec: app backgrounding aborts generation (iOS/visionOS — suspension
            // would freeze mid-probe). Inert on macOS by design: the AppKit host
            // never leaves .active, and macOS never suspends the process, so
            // there is nothing to abort. Dismissing cancels the .task, which the
            // generator turns into abort + restore — mid-refine/pick included.
            if newPhase == .background && model.isGenerating {
                close()
            }
        }
    }

    // MARK: - Sections

    private var sideName: String { model.sideToMove == .black ? "Black" : "White" }
    private var opponentName: String { model.sideToMove == .black ? "White" : "Black" }

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
            // One-shot refine/pick outcome ("… was kept/reset"); cleared at
            // the start of the next operation.
            if let notice = model.transientNotice {
                Label(notice, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var candidatesSection: some View {
        if model.candidates.isEmpty && model.isGenerating {
            skeletonRow(height: 180)
        }
        ForEach(model.candidates) { candidate in
            let isBest = candidate.id == model.candidates.first?.id
            CandidateSectionView(candidate: candidate,
                                 model: model,
                                 sideName: sideName,
                                 opponentName: opponentName,
                                 isBest: isBest,
                                 onChangeAlternative: (!isBest && model.stage == .complete)
                                     ? { showingPicker = true } : nil)
        }
        // A single-candidate report (the engine ranked only one move) still
        // deserves a reachable Alternative slot.
        if model.stage == .complete && model.candidates.count == 1 {
            Button("Pick an alternative…") { showingPicker = true }
                // Liquid Glass: the sheet body is floating chrome, not a List
                // row, so the house style applies. `.glass` and not
                // `.glassProminent` because the report's one default action is
                // the toolbar's Done — these two in-body buttons both open the
                // same picker, and neither is the thing the sheet is for.
                //
                // `#if os(visionOS)` and NOT the `|| os(tvOS)` this package
                // uses in StoneView/CommentView: in the 26 SDKs both styles are
                // `@available(iOS 26, macOS 26, tvOS 26, watchOS 26, *)` with
                // `@available(visionOS, unavailable)` — visionOS is the only
                // platform that cannot compile them. tvOS's exclusion elsewhere
                // is a styling choice, not a constraint. Moot for rendering
                // either way: DeepReportView is presented only by the iOS sheet
                // and the macOS hosting controller (tvOS reuses DeepReportModel
                // alone), so the fallback exists to keep the package building.
#if os(visionOS)
                .buttonStyle(.bordered)
#else
                .buttonStyle(.glass)
#endif
        }
    }

    @ViewBuilder
    private var passSection: some View {
        if let pass = model.passComparison {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                Text("Playing vs. Passing")
                    .font(.title3.bold())
                Text(Self.passSentence(pass: pass,
                                       bestVertex: model.candidates.first?.vertex,
                                       sideName: sideName, opponentName: opponentName))
                    .font(.callout)
                ReportBoardView(width: model.boardWidth, height: model.boardHeight,
                                blackVertices: model.blackVertices,
                                whiteVertices: model.whiteVertices,
                                overlay: .ownershipDelta(pass.ownershipDelta),
                                // "Playing" means the best move: draw it so the
                                // Δ squares have a visible anchor (round 3).
                                markedMove: model.candidates.first.map {
                                    ReportMarkedMove(vertex: $0.vertex, color: model.sideToMove)
                                },
                                isClassicStoneStyle: model.isClassicStoneStyle,
                                showCoordinate: model.showCoordinate,
                                verticalFlip: model.verticalFlip)
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
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                Label("Pass comparison unavailable — the engine produced no analysis for it.",
                      systemImage: "questionmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
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
                // The initial generation has nothing to fall back to, so
                // Cancel closes the sheet; a refine/pick abort returns to the
                // still-valid completed report instead (the generator restores
                // and re-completes on task cancellation).
                Button("Cancel") {
                    if model.mode == .initial {
                        close()
                    } else {
                        operation = .idle
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                ProgressView()
            }
        } else if model.stage == .complete {
            // Every platform shares the icon-button form (titles are the
            // accessibility labels, `.help` carries the tooltip text) so the
            // Copy-to-Comment checkmark morph reads identically everywhere.
            ToolbarItem(placement: .cancellationAction) {
                Button("Refine", systemImage: "plus.magnifyingglass") { startRefine() }
                    .disabled(model.isAtBudgetCap)
                    .help(model.isAtBudgetCap
                          ? "Already at the deepest analysis budget"
                          : "Search deeper — twice the previous analysis budget")
            }
            ToolbarItem(placement: .primaryAction) {
                // Disabled for branch positions: the comment would be keyed by
                // the committed game's currentIndex (the divergence point), not
                // the analyzed branch move.
                Button("Copy to Comment",
                       systemImage: justCopied ? "checkmark" : "text.bubble") {
                    requestCopyToComment()
                }
                .contentTransition(.symbolEffect(.replace))
                .disabled(model.position == nil || model.isBranchPosition)
                .help(model.isBranchPosition
                      ? "Unavailable for branch positions — comments belong to the saved game's moves"
                      : "Replace this move's comment with the report summary")
            }
#if os(iOS)
            // Break the trailing Liquid Glass group so Copy-to-Comment and
            // Done read as separate actions on iPhone (round-4 feedback).
            // iOS only: ToolbarSpacer doesn't compile on visionOS/tvOS, and
            // macOS toolbar buttons don't group in the first place.
            ToolbarSpacer(.fixed, placement: .confirmationAction)
#endif
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { close() }
            }
        } else {
            // Failed or cancelled: the only path forward is a fresh
            // base-budget run.
            ToolbarItem(placement: .cancellationAction) {
                Button("Regenerate", systemImage: "arrow.clockwise") { startRegenerate() }
                    .help("Run the report again for this position")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { close() }
            }
        }
    }

    private func startRefine() {
        opSeq += 1
        operation = .refine(pass: opSeq)
    }

    private func startRegenerate() {
        opSeq += 1
        operation = .initial(attempt: opSeq)
    }

    /// Copy-to-Comment REPLACES the move's comment, so a non-empty existing
    /// comment is user data about to be lost — that, and only that, warrants
    /// a confirmation dialog. Static so it is unit-testable (the passSentence
    /// precedent).
    static func replaceNeedsConfirmation(existingComment: String?) -> Bool {
        !(existingComment ?? "").isEmpty
    }

    private func requestCopyToComment() {
        if Self.replaceNeedsConfirmation(
            existingComment: gameRecord.comments?[gameRecord.currentIndex]) {
            confirmingReplaceComment = true
        } else {
            performCopyToComment()
        }
    }

    /// The text Copy-to-Comment writes: the streamed narrative when present,
    /// else the joined fact list. Static + pure so it is unit-testable (the
    /// passSentence precedent).
    static func copiedCommentText(model: DeepReportModel) -> String {
        model.narrative.isEmpty
            ? ReportNarrator.facts(from: model).joined(separator: "\n")
            : model.narrative
    }

    /// Applies Copy-to-Comment to the move's comment dictionary: REPLACES the
    /// entry at `index` (never appends to any prior comment). Static + pure so
    /// the headline replace-not-append behavior is tested without the view.
    static func applyingCopiedComment(_ comments: [Int: String]?,
                                      text: String, index: Int) -> [Int: String] {
        var result = comments ?? [:]
        result[index] = text
        return result
    }

    private func performCopyToComment() {
        let text = Self.copiedCommentText(model: model)
        gameRecord.comments = Self.applyingCopiedComment(
            gameRecord.comments, text: text, index: gameRecord.currentIndex)
        withAnimation { justCopied = true }
        copyRevertTask?.cancel()
        copyRevertTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled {
                withAnimation { justCopied = false }
            }
        }
    }

    // MARK: - Bits

    /// The Playing-vs-Passing sentence: the narrator's shared head + punish
    /// pair joined into one paragraph, so the sheet reads exactly what the
    /// broadcast speaks. Static (not a computed property on the view) so the
    /// bestVertex-nil fallback is unit-testable.
    static func passSentence(pass: PassComparison, bestVertex: String?,
                             sideName: String, opponentName: String) -> String {
        let (head, punish) = ReportNarrator.passHeadAndPunish(pass: pass,
                                                              bestVertex: bestVertex,
                                                              sideName: sideName,
                                                              opponentName: opponentName)
        return head + " " + punish
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
    let opponentName: String
    /// The top-ranked candidate's Δ-vs-root is ~zero by construction (it IS
    /// the root's chosen line), so it skips the toggle/Δ view entirely and
    /// always shows its variation. Its heading reads "Best Move" and its
    /// stats drop the vs-best delta (always ~+0% for itself).
    let isBest: Bool
    /// Opens the alternative-move picker. nil while generating (and always
    /// for the best move), which hides the Change… affordance.
    var onChangeAlternative: (() -> Void)?
    @State private var showsDelta = false

    private var statsText: String {
        var text = "\(String(format: "%.0f%%", candidate.winrate * 100)) win rate"
        if !isBest {
            text += " (\(String(format: "%+.0f%%", candidate.winrateDelta * 100)))"
        }
        text += " · \(String(format: "%+.1f", candidate.scoreLead)) points · \(candidate.visits.formatted()) visits"
        return text
    }

    private var headingText: some View {
        Text(isBest ? "Best Move \(candidate.vertex)" : "Alternative \(candidate.vertex)")
            .font(.title3.bold())
    }

    /// Same style and the same guard as the "Pick an alternative…" button in
    /// `DeepReportView.candidatesSection`, which carries the reasoning.
    private func changeButton(_ action: @escaping () -> Void) -> some View {
        let button = Button("Change…", action: action)
#if os(visionOS)
        return button.buttonStyle(.bordered).controlSize(.small)
#else
        return button.buttonStyle(.glass).controlSize(.small)
#endif
    }

    /// Heading plus the Change… affordance, stacked instead when they cannot
    /// sit side by side.
    ///
    /// Measured, not assumed: rendered at `.accessibility5` in a 370pt lane —
    /// the report sheet's content width on an iPhone — the one-line HStack
    /// hyphen-breaks the heading across three lines ("Alter-/native/C7") AND
    /// wraps the button label to "Chang/e…". That is a PRE-EXISTING overflow,
    /// visible with the bare label and unchanged by the move to Liquid Glass;
    /// the glass capsule's ~40pt of horizontal padding only widens the miss.
    ///
    /// `ViewThatFits` measures the horizontal branch's ideal width (the
    /// `Spacer` contributes zero, so it is just heading + button) and falls
    /// back only on genuine overflow, so ordinary text sizes lay out exactly
    /// as before. Not `ActionRow`: that helper is for a secondary/primary
    /// action pair — it clamps both children to `lineLimit(1)` and puts the
    /// primary FIRST when stacked, and a section heading must neither be
    /// truncated to one line nor follow the control it labels.
    @ViewBuilder
    private var headingRow: some View {
        if let onChangeAlternative {
            ViewThatFits(in: .horizontal) {
                HStack {
                    headingText
                    Spacer()
                    changeButton(onChangeAlternative)
                }
                VStack(alignment: .leading, spacing: 8) {
                    headingText
                    changeButton(onChangeAlternative)
                }
            }
        } else {
            headingText
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            headingRow
            VStack(alignment: .leading, spacing: 8) {
                Text(statsText)
                    .font(.callout)
                if let tenuki = candidate.tenuki {
                    Label(ReportNarrator.tenukiSentence(opponentName: opponentName,
                                                        sideName: sideName,
                                                        ignoredVertex: candidate.vertex,
                                                        followUpVertex: tenuki.vertex,
                                                        winrate: tenuki.winrate,
                                                        scoreLead: tenuki.scoreLead),
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
                    }
                    ReportBoardView(width: model.boardWidth, height: model.boardHeight,
                                    blackVertices: model.blackVertices,
                                    whiteVertices: model.whiteVertices,
                                    overlay: (!isBest && showsDelta)
                                        ? .ownershipDelta(candidate.ownershipDelta)
                                        : .pv(candidate.pv, startingWith: model.sideToMove),
                                    // On the Δ view the candidate itself must stay
                                    // visible — stone + red dot (round 3).
                                    markedMove: (!isBest && showsDelta)
                                        ? ReportMarkedMove(vertex: candidate.vertex, color: model.sideToMove)
                                        : nil,
                                    isClassicStoneStyle: model.isClassicStoneStyle,
                                    showCoordinate: model.showCoordinate,
                                    verticalFlip: model.verticalFlip)
                    if !isBest && showsDelta {
                        DeltaLegendView()
                    }
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
        // A second candidate so the preview covers the Alternative block too —
        // its Variation/Δ picker and its "Change…" button only exist for a
        // non-best candidate, and a one-candidate preview never drew them.
        CandidateReport(vertex: "C7", visits: 60, winrate: 0.36, scoreLead: -6.5,
                        winrateDelta: -0.06, scoreLeadDelta: -2.5, pv: ["C7", "E5"],
                        ownershipDelta: [BoardPoint(x: 2, y: 6): -0.4],
                        tenuki: nil),
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
                    let isBest = candidate.id == model.candidates.first?.id
                    CandidateSectionView(candidate: candidate, model: model, sideName: "Black",
                                         opponentName: "White",
                                         isBest: isBest,
                                         // Non-nil for an alternative, matching
                                         // candidatesSection's own condition, so
                                         // the preview draws the "Change…" button.
                                         // Inert: the picker is a navigation
                                         // destination the host does not own.
                                         onChangeAlternative: isBest ? nil : {})
                }
            }
            .padding()
        }
    }
}
