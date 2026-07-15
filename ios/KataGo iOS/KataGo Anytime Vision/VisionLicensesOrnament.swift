//
//  VisionLicensesOrnament.swift
//  KataGo Anytime Vision
//
//  Right-anchor glass card rendering the shared third-party license
//  registry (EULA parity: every platform lists its licenses under
//  Settings). Same shape as the Models card: its own NavigationStack for
//  the list → detail push, an X to dismiss, mutually exclusive with the
//  other right-anchor cards via the shell helpers.
//

import SwiftUI
import KataGoUICore

struct VisionLicensesOrnament: View {
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            AcknowledgmentsView()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("Close licenses")
                    }
                }
        }
        .frame(width: 440, height: 620)
        .glassBackgroundEffect()
    }
}
