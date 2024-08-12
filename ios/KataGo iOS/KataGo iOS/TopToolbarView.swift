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
    @Binding var isBoardSizeChanged: Bool
    @Environment(\.modelContext) private var modelContext
    @Environment(NavigationContext.self) var navigationContext
    @Environment(GobanTab.self) var gobanTab

    var body: some View {
        HStack {
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
            .onChange(of: gobanTab.isConfigPresented) { _, isConfigPresentedNow in
                if !isConfigPresentedNow && (isBoardSizeChanged) {
                    KataGoHelper.sendCommand(gameRecord.config.getKataBoardSizeCommand())
                    KataGoHelper.sendCommand("printsgf")
                    isBoardSizeChanged = false
                }
            }

            Button {
                withAnimation {
                    let newGameRecord = GameRecord(gameRecord: gameRecord)
                    modelContext.insert(newGameRecord)
                    navigationContext.selectedGameRecord = newGameRecord
                    gobanTab.isCommandPresented = false
                    gobanTab.isConfigPresented = false
                }
            } label: {
                Image(systemName: "plus.square")
            }
        }
    }
}
