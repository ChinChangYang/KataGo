//
//  QuitButton.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/9/22.
//

import SwiftUI
import KataGoInterface

struct QuitButton: View {
    @Binding var quitStatus: QuitStatus
    @State var isConfirming = false

    var body: some View {
        Button(role: .destructive) {
            isConfirming = true
        } label: {
            Image(systemName: "rectangle.portrait.and.arrow.forward")
                .foregroundStyle(.red)
        }
        .confirmationDialog(
            "Are you sure you want to quit? This will close KataGo model and go back to the model selection screen.",
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("Quit", role: .destructive) {
                quitStatus = .quitting
                KataGoSendCommand("quit")
                Task {
                    // Wait until all messages are consumed.
                    try? await Task.sleep(for: .seconds(1))
                    // False the condition of consumer's loop.
                    quitStatus = .quitted
                    // An additional message to terminate the consumer.
                    KataGoHelper.sendMessage("\n")
                }
            }

            Button("Cancel", role: .cancel) {
                isConfirming = false
            }
            
        }
    }
}

#Preview {
    struct PreviewHost: View {
        @State var quitStatus: QuitStatus = .none
        var body: some View {
            QuitButton(quitStatus: $quitStatus)
        }
    }

    return PreviewHost()
}
