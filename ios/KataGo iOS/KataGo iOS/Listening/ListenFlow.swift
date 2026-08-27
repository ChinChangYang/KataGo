//
//  ListenFlow.swift
//  KataGo iOS
//
//  The one Listen entry flow, shared by the More menu and the game-list row
//  context menu: readiness check, the unprepared-game confirmation, the
//  Prepare sheet, and the can't-narrate alert. Container-level on purpose —
//  presentation modifiers on a lazy row die when it scrolls out (the Prepare
//  sheet is a minutes-long modal), and wrapping the list's ForEach would
//  strip DynamicViewContent, killing swipe-to-delete. Never moves the
//  selection: a Listening Session never moves any board.
//

import SwiftUI
import KataGoUICore

extension GameRecord {
    /// The derived ready-to-listen marker: every position 0...N analyzed.
    var isReadyToListen: Bool {
        guard let scan = SgfHeaderScan(sgf: sgf) else { return false }
        return ListeningReadiness.isReady(
            moveCount: scan.moveCount,
            analyzedIndices: Set(winRates?.keys ?? [:].keys))
    }
}

struct ListenFlowModifier: ViewModifier {
    /// Write a record here to request Listen on it; the modifier consumes the
    /// write (resets to nil) and takes over.
    @Binding var request: GameRecord?

    @Environment(NavigationContext.self) private var navigationContext
    @Environment(GobanState.self) private var gobanState
    @Environment(Turn.self) private var player
    @Environment(Stones.self) private var stones
    @Environment(MessageList.self) private var messageList
    @Environment(ListeningSessionController.self) private var listeningController

    @State private var confirmingUnpreparedListen = false
    @State private var dialogRecord: GameRecord?
    @State private var preparingRecord: GameRecord?
    @State private var listeningFailed = false

    func body(content: Content) -> some View {
        content
            .onChange(of: request) { _, record in
                // The self-write below re-fires this with nil; the guard
                // absorbs it, and a repeated tap on the same record still
                // transitions nil -> record.
                guard let record else { return }
                request = nil
                // Ready games start at once; an unprepared one is offered the
                // full bake first (never a gate — Listen Now narrates what
                // exists).
                if record.isReadyToListen {
                    startListening(record)
                } else {
                    dialogRecord = record
                    confirmingUnpreparedListen = true
                }
            }
            .confirmationDialog(
                "This game isn't fully analyzed yet",
                isPresented: $confirmingUnpreparedListen,
                titleVisibility: .visible,
                presenting: dialogRecord
            ) { record in
                Button("Listen Now") {
                    startListening(record)
                }
                Button("Prepare for Listening First") {
                    preparingRecord = record
                }
                .disabled(prepareDisabled(for: record))
                Button("Cancel", role: .cancel) { }
            } message: { _ in
                Text("Unanalyzed moves are read as bare move calls. Prepare analyzes every move and writes commentary first.")
            }
            .sheet(item: $preparingRecord, onDismiss: {
                // The sweep left the engine idle on the displayed position;
                // re-arm live analysis exactly as the Deep Report dismissal
                // does. The displayed record, not the swept one: a row can
                // prepare a game that is not on screen.
                if let displayed = navigationContext.selectedGameRecord {
                    gobanState.resumeAnalysisAfterReport(
                        config: displayed.concreteConfig,
                        nextColorForPlayCommand: player.nextColorForPlayCommand,
                        messageList: messageList)
                }
            }) { record in
                ListeningPrepareSheet(gameRecord: record,
                                      restoreRecord: navigationContext.selectedGameRecord)
            }
            .alert("This game can't be narrated", isPresented: $listeningFailed) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Its record holds a move the rules refuse to replay.")
            }
    }

    private func startListening(_ record: GameRecord) {
        if !listeningController.listen(to: record) {
            listeningFailed = true
        }
    }

    /// Prepare shares the Deep Report's engine envelope, so it shares the
    /// engine-side gates: engine up, no sweep/report running, no in-flight AI
    /// move on the DISPLAYED board (its cancellable search would interleave
    /// with the probes on the shared GTP stream), and the REQUESTED record's
    /// board must fit the launched NN buffer (an oversized kata-analyze
    /// aborts the in-process engine; the driver re-checks). Deliberately not
    /// the full `reportDisabled`: a finished game (two passes) is precisely
    /// Listen's prime material, and the sweep replays its own record from a
    /// clear board.
    private func prepareDisabled(for record: GameRecord) -> Bool {
        if !stones.isReady || gobanState.reportGenerationActive { return true }
        if let scan = SgfHeaderScan(sgf: record.sgf),
           !gobanState.boardFitsEngine(width: scan.boardWidth,
                                       height: scan.boardHeight) { return true }
        guard let displayed = navigationContext.selectedGameRecord else { return false }
        return gobanState.shouldGenMove(config: displayed.concreteConfig, player: player)
    }
}

extension View {
    /// Attach once per container (the More menu, the game list); trigger by
    /// writing the binding.
    func listenFlow(request: Binding<GameRecord?>) -> some View {
        modifier(ListenFlowModifier(request: request))
    }
}
