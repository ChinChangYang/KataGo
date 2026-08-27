//
//  ListeningPrepareSheet.swift
//  KataGo iOS
//
//  Prepare for Listening's modal progress. Modal on purpose: the sweep and
//  the user share one GTP stream, so navigation during a sweep would
//  interleave board feeds — the Deep Report sheet's lockout, borrowed.
//  Cancel is honored between probes; SwiftUI's task cancellation reaches the
//  driver, whose deferred restore stands the engine back on the displayed
//  position on every exit.
//

import SwiftUI
import KataGoUICore

struct ListeningPrepareSheet: View {
    let gameRecord: GameRecord
    /// The record whose position the engine is restored to on exit — the
    /// displayed game when preparing from a game-list row. Nil restores to
    /// `gameRecord` itself (the original single-game behavior).
    var restoreRecord: GameRecord? = nil
    @Environment(MessageList.self) private var messageList
    @Environment(ListeningSessionController.self) private var listeningController
    @Environment(\.dismiss) private var dismiss
    @State private var model = ListeningPrepareModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                switch model.phase {
                case .idle, .sweeping:
                    ProgressView(value: progressFraction) {
                        Text("Analyzing every move…")
                    } currentValueLabel: {
                        Text("Position \(model.completedPositions) of \(model.totalPositions)")
                            .monospacedDigit()
                    }
                    Text("The engine walks the whole game once; the board keeps its place. Keep the app open.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                case .commenting:
                    ProgressView {
                        Text("Writing commentary…")
                    }
                case .complete:
                    Label("Ready to listen", systemImage: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                    Button {
                        dismiss()
                        listeningController.listen(to: gameRecord)
                    } label: {
                        Label("Listen", systemImage: "headphones")
                    }
                    .buttonStyle(.borderedProminent)
                case .cancelled:
                    Text("Preparation stopped. Analyzed moves keep their data; run Prepare again to fill the rest.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .navigationTitle("Prepare for Listening")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isRunning ? "Cancel" : "Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(isRunning)
        .task {
            // .task's lifetime IS the cancellation seam: Cancel/dismiss
            // cancels this task; the driver's deferred restore still runs.
            await ListeningPrepareDriver(messageList: messageList)
                .prepare(gameRecord: gameRecord, model: model,
                         restoreTo: restoreRecord)
        }
    }

    private var isRunning: Bool {
        model.phase == .idle || model.phase == .sweeping || model.phase == .commenting
    }

    private var progressFraction: Double {
        guard model.totalPositions > 0 else { return 0 }
        return Double(model.completedPositions) / Double(model.totalPositions)
    }
}
