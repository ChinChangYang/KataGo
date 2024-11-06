//
//  TopToolbarView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/8/12.
//

import SwiftUI
import KataGoInterface

struct TopToolbarView: View {
    var gameRecord: GameRecord
    @Binding var importing: Bool
    @Environment(\.modelContext) private var modelContext
    @Environment(NavigationContext.self) var navigationContext
    @Environment(GobanTab.self) var gobanTab
    @Environment(\.editMode) private var editMode

    var body: some View {
        HStack {
            if editMode?.wrappedValue.isEditing == true {
                Button {
                    withAnimation {
                        gobanTab.isCommandPresented.toggle()
                        gobanTab.isConfigPresented = false
                    }
                } label: {
                    if gobanTab.isCommandPresented {
                        Image(systemName: "doc.plaintext.fill")
                    } else {
                        Image(systemName: "doc.plaintext")
                    }
                }

                Button {
                    withAnimation {
                        gobanTab.isCommandPresented = false
                        gobanTab.isConfigPresented.toggle()
                    }
                } label: {
                    if gobanTab.isConfigPresented {
                        Image(systemName: "gearshape.fill")
                    } else {
                        Image(systemName: "gearshape")
                    }
                }
            }

            PlusMenuView(gameRecord: gameRecord, importing: $importing)
            EditButton()
        }
    }
}
