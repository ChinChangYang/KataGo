//
//  TopToolbarView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/8/12.
//

import SwiftUI
import KataGoInterface
import UniformTypeIdentifiers

struct TopToolbarView: View {
    var gameRecord: GameRecord
    let sgfType = UTType("ccy.KataGo-iOS.sgf")!
    @Binding var isBoardSizeChanged: Bool
    @State private var importing = false
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

            Menu {
                Button {
                    withAnimation {
                        let newGameRecord = GameRecord()
                        modelContext.insert(newGameRecord)
                        navigationContext.selectedGameRecord = newGameRecord
                        gobanTab.isCommandPresented = false
                        gobanTab.isConfigPresented = false
                    }
                } label: {
                    Label("New Game", systemImage: "doc")
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
                    Label("Clone", systemImage: "doc.on.doc")
                }

                Button {
                    withAnimation {
                        importing = true
                    }
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }

                Button(role: .destructive) {
                    let gameRecordToDelete = gameRecord
                    navigationContext.selectedGameRecord = nil
                    modelContext.safelyDelete(gameRecord: gameRecordToDelete)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "plus.square")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [sgfType]) { result in
            switch result {
            case .success(let file):
                let gotAccess = file.startAccessingSecurityScopedResource()
                guard gotAccess else { return }
                if let fileContents = try? String(contentsOf: file) {
                    let newGameRecord = GameRecord(sgf: fileContents)
                    modelContext.insert(newGameRecord)
                    navigationContext.selectedGameRecord = newGameRecord
                    gobanTab.isCommandPresented = false
                    gobanTab.isConfigPresented = false
                }
            case .failure(_): break
            }
        }
    }
}
