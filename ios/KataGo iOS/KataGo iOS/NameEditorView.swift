//
//  NameEditorView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/7/30.
//

import SwiftUI
import KataGoUICore

struct NameEditorView: View {
    let gameRecord: GameRecord?
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Edit Name")
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        withAnimation {
                            if let gameRecord {
                                gameRecord.name = name
                            }

                            dismiss()
                        }
                    }
                }

                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                }
            }
            .onAppear {
                if let gameRecord {
                    name = gameRecord.name
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 300, minHeight: 80)
        .padding()
        #endif
    }
}
