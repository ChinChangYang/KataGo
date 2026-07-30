//
//  PlusMenuView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/8/27.
//

import SwiftUI
import KataGoUICore

struct PlusMenuView: View {
    var gameRecord: GameRecord?
    var maxBoardLength: Int
    @Environment(\.modelContext) private var modelContext
    @Environment(NavigationContext.self) var navigationContext
    @Environment(GobanState.self) var gobanState
    @Environment(ThumbnailModel.self) var thumbnailModel
    @Environment(TopUIState.self) var topUIState
    @Environment(Turn.self) var player
    @Environment(Stones.self) var stones
    @Environment(MessageList.self) var messageList
    @State private var showingGameSettings = false
    @State private var confirmingClone = false
    @State private var showingReport = false
    @State private var showingGlobalSettings = false
    @State private var showingGifExport = false

    var body: some View {
        Menu {
            // Create / library actions.
            Button {
                withAnimation {
                    let newGameRecord = GameRecord.createGameRecord(maxBoardLength: maxBoardLength)
                    modelContext.insert(newGameRecord)
                    navigationContext.selectedGameRecord = newGameRecord
                }
            } label: {
                Label("New Game", systemImage: "doc")
            }

            // Import can pull in an SGF/text file, an image file, or a photo
            // from the library. Grouped into a submenu so the top level stays
            // short (menu-declutter precedent above).
            Menu {
                Button {
                    withAnimation {
                        topUIState.importing = true
                    }
                } label: {
                    Label("File", systemImage: "folder")
                }

                Button {
                    topUIState.importingPhoto = true
                } label: {
                    Label("Photo", systemImage: "photo.on.rectangle")
                }

#if os(iOS)
                // Manual board-photo capture. Hidden (not disabled) where no
                // back camera exists, e.g. Simulator. `os(iOS)` is the correct
                // gate: the xros SDK defines os(visionOS), not os(iOS).
                if CameraCaptureController.isCameraAvailable {
                    Button {
                        topUIState.capturingBoardPhoto = true
                    } label: {
                        Label("Camera", systemImage: "camera")
                    }
                }
#endif
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }

            if thumbnailModel.isGameListViewAppeared {
                // Enter multi-select mode. Exit ("Done") is a top-level toolbar
                // button (see GameListToolbar), shown only while selecting — so
                // this item only ever enters the mode.
                Button {
                    withAnimation {
                        topUIState.isSelecting = true
                    }
                } label: {
                    Label("Select", systemImage: "checkmark.circle")
                }
            }

            // Actions on the currently selected game, grouped into one submenu
            // so the top level stays short.
            if let gameRecord {
                Menu {
                    Button {
                        showingGameSettings = true
                    } label: {
                        Label("Game Settings", systemImage: "gearshape")
                    }

                    Divider()

                    ShareLink(
                        item: TransferableSgf(
                            name: gameRecord.name,
                            content: gameRecord.sgf
                        ),
                        preview: SharePreview(
                            gameRecord.name,
                            image: gameRecord.image ?? Image(.loadingIcon)
                        )
                    ) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        showingGifExport = true
                    } label: {
                        Label("Export GIF", systemImage: "film")
                    }

                    Button {
                        confirmingClone = true
                    } label: {
                        Label("Clone", systemImage: "doc.on.doc")
                    }

                    Button {
                        // The report's probes cancel live analysis and its
                        // restore doesn't re-arm, so the engine sits idle under
                        // the sheet; analysis re-arms on dismissal. (Pausing
                        // here would set a waitingForAnalysis edge whose stray
                        // "stop" ack desyncs the probe collector.)
                        showingReport = true
                    } label: {
                        Label("Deep Report", systemImage: "doc.text.magnifyingglass")
                    }
                    .disabled(reportDisabled)

                    Divider()

                    Button(role: .destructive) {
                        topUIState.confirmingDeletion = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Label("This Game", systemImage: "square.grid.3x3")
                }
            }

            Divider()

            // App-wide settings only. Per-game configuration now lives under
            // "This Game" ▸ Game Settings, so this top-level entry opens Global
            // Settings directly whether or not a game is selected.
            Button {
                showingGlobalSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape.2")
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .sheet(isPresented: $showingGameSettings) {
            if let gameRecord {
                NavigationStack {
                    GameSettingsView(gameRecord: gameRecord, maxBoardLength: maxBoardLength)
                }
                #if os(macOS)
                .frame(minWidth: 500, minHeight: 600)
                #endif
            }
        }
        .sheet(isPresented: $showingGlobalSettings) {
            NavigationStack {
                // Board size rides along for the Voice Control help screen's
                // spoken examples; nil record (nothing selected) falls back to
                // GlobalSettingsView's 19x19 defaults.
                if let config = gameRecord?.concreteConfig {
                    GlobalSettingsView(boardWidth: config.boardWidth,
                                       boardHeight: config.boardHeight)
                } else {
                    GlobalSettingsView()
                }
            }
        }
        .sheet(isPresented: $showingReport, onDismiss: {
            // The report left the engine idle; re-arm live analysis (a no-op
            // unless analysis is on) so it — and a human-vs-AI opponent — comes
            // back after the sheet closes.
            if let gameRecord {
                gobanState.resumeAnalysisAfterReport(
                    config: gameRecord.concreteConfig,
                    nextColorForPlayCommand: player.nextColorForPlayCommand,
                    messageList: messageList)
            }
        }) {
            if let gameRecord {
                // No NavigationStack wrapper: DeepReportView owns its stack
                // (the alternative-move picker pushes inside it).
                DeepReportView(gameRecord: gameRecord)
            }
        }
        .sheet(isPresented: $showingGifExport) {
            if let gameRecord {
                NavigationStack {
                    GameGifExportView(gameRecord: gameRecord)
                }
                #if os(macOS)
                .frame(minWidth: 420, minHeight: 640)
                #endif
            }
        }
        .confirmationDialog(
            "Clone this game",
            isPresented: $confirmingClone,
            titleVisibility: .visible
        ) {
            if let gameRecord {
                Button("Whole Game") {
                    withAnimation {
                        let newGameRecord = gameRecord.clone()
                        modelContext.insert(newGameRecord)
                        navigationContext.selectedGameRecord = newGameRecord
                    }
                }

                Button("Current Position") {
                    withAnimation {
                        let newGameRecord = gobanState.cloneCurrentPosition(gameRecord: gameRecord)
                        modelContext.insert(newGameRecord)
                        navigationContext.selectedGameRecord = newGameRecord
                    }
                }
            }

            Button("Cancel", role: .cancel) { }
        }
    }

    /// Deep Report gating: engine/board ready, no in-flight AI move (its
    /// cancellable search would interleave with the probes), game not
    /// finished, no report running.
    private var reportDisabled: Bool {
        guard let gameRecord else { return true }
        return !stones.isReady
            || gobanState.reportGenerationActive
            || gobanState.passCount >= 2
            || gobanState.shouldGenMove(config: gameRecord.concreteConfig, player: player)
    }
}

#Preview {
    PlusMenuView(
        gameRecord: GameRecord(config: Config()),
        maxBoardLength: 19
    )
    .environment(NavigationContext())
    .environment(GobanState())
    .environment(ThumbnailModel())
    .environment(TopUIState())
    .environment(Turn())
    .environment(Stones())
}
