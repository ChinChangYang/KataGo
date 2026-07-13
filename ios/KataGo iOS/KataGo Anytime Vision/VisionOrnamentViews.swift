//
//  VisionOrnamentViews.swift
//  KataGo Anytime Vision
//
//  The volume's control ornament: player chips with capture counts, New
//  Game (9/13/19), Pass with inline confirmation, Undo, the analysis eye,
//  and the connect-controller hint. Ordinary SwiftUI — always pinch-
//  interactive; the game controller never drives the ornament.
//

import SwiftUI
import KataGoUICore

struct VisionControlOrnament: View {
    let session: GameSession
    let shell: VisionGameShell
    let controllerInput: VisionControllerInput
    let navigationContext: NavigationContext
    let onNewGame: (Int) -> Void
    let onPassConfirmed: () -> Void
    let onUndo: () -> Void
    let onToggleEye: () -> Void
    let onDismissIllegalMove: () -> Void

    var body: some View {
        Group {
            if session.gobanState.confirmingIllegalMove {
                illegalMoveRow
            } else if shell.passConfirmationPending {
                passConfirmRow
            } else {
                mainRow
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassBackgroundEffect()
    }

    // MARK: - Rows

    private var mainRow: some View {
        HStack(spacing: 16) {
            playerChip(.black)
            playerChip(.white)

            Divider().frame(height: 24)

            Menu {
                Button("9 × 9") { onNewGame(9) }
                Button("13 × 13") { onNewGame(13) }
                Button("19 × 19") { onNewGame(19) }
            } label: {
                Label("New Game", systemImage: "plus")
            }

            Button {
                shell.passConfirmationPending = true
            } label: {
                Label("Pass", systemImage: "arrow.right.to.line")
            }

            Button(action: onUndo) {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }

            Button(action: onToggleEye) {
                Label(eyeOpen ? "Hide Analysis" : "Show Analysis",
                      systemImage: eyeOpen ? "eye" : "eye.slash")
            }

            if !controllerInput.isConnected {
                Divider().frame(height: 24)
                Label("Connect a controller to play", systemImage: "gamecontroller")
                    .foregroundStyle(.secondary)
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }

    private var passConfirmRow: some View {
        HStack(spacing: 16) {
            Text("Pass this turn?")
            Button("Pass", role: .destructive, action: onPassConfirmed)
            Button("Cancel") { shell.passConfirmationPending = false }
        }
        .buttonStyle(.bordered)
    }

    private var illegalMoveRow: some View {
        HStack(spacing: 16) {
            Label("That move is illegal here (ko or suicide).",
                  systemImage: "exclamationmark.triangle")
            Button("OK", action: onDismissIllegalMove)
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Pieces

    private var eyeOpen: Bool {
        session.gobanState.eyeStatus == .opened
    }

    private func playerChip(_ color: PlayerColor) -> some View {
        let config = navigationContext.selectedGameRecord?.concreteConfig
        let isAI = color == .black
            ? (config?.blackMaxTime ?? 0) > 0
            : (config?.whiteMaxTime ?? 0) > 0
        let captured = color == .black
            ? session.stones.blackStonesCaptured
            : session.stones.whiteStonesCaptured
        let isToMove = session.player.nextColorForPlayCommand == color

        return HStack(spacing: 6) {
            Circle()
                .fill(color == .black ? Color.black : Color.white)
                .stroke(.secondary, lineWidth: 1)
                .frame(width: 14, height: 14)
            Image(systemName: isAI ? "cpu" : "person.fill")
                .font(.caption)
            if captured > 0 {
                Text("×\(captured)")
                    .font(.caption.monospacedDigit())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isToMove ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.clear),
                    in: Capsule())
        .overlay {
            if isToMove {
                Capsule().stroke(.primary.opacity(0.4), lineWidth: 1)
            }
        }
    }
}
