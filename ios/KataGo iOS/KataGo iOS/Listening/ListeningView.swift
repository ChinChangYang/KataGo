//
//  ListeningView.swift
//  KataGo iOS
//
//  The Listening Session's sheet: title, progress, transport. Deliberately
//  thin — the session lives in ListeningSessionController and keeps playing
//  when this sheet is dismissed (background audio is the point); End is the
//  explicit way out.
//

import SwiftUI
import KataGoUICore

struct ListeningView: View {
    @Environment(ListeningSessionController.self) private var controller
    @Environment(\.dismiss) private var dismiss

    private var engine: ListeningEngine { controller.engine }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "headphones")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(spacing: 4) {
                    Text(engine.script?.gameName ?? "")
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)
                    Text(progressText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                HStack(spacing: 44) {
                    Button {
                        engine.stepBackward()
                    } label: {
                        Image(systemName: "backward.frame.fill")
                    }
                    .accessibilityLabel("Previous move")

                    Button {
                        engine.togglePlayPause()
                    } label: {
                        Image(systemName: engine.state == .playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 40))
                    }
                    .accessibilityLabel(engine.state == .playing ? "Pause" : "Play")
                    .disabled(engine.state == .finished || engine.state == .idle)

                    Button {
                        engine.stepForward()
                    } label: {
                        Image(systemName: "forward.frame.fill")
                    }
                    .accessibilityLabel("Next move")
                }
                .font(.title)
                .buttonStyle(.borderless)

                if engine.state == .finished {
                    Text("End of game.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .navigationTitle("Listen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Dismiss keeps playing (pocket the phone, keep
                    // listening); End stops the session.
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("End") {
                        controller.endSession()
                        dismiss()
                    }
                    .disabled(!controller.isSessionActive)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var progressText: String {
        guard let script = engine.script else { return "" }
        return "Move \(engine.currentMoveNumber) of \(script.moveCount)"
    }
}
