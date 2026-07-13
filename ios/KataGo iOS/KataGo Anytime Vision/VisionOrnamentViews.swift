//
//  VisionOrnamentViews.swift
//  KataGo Anytime Vision
//
//  The volume's control ornament: player chips (pinch to flip Human⇄AI),
//  New Game (9/13/19), the Games picker (newest iCloud-synced games), Undo,
//  the analysis sparkle (run/pause/off), the board orientation toggle,
//  controller help, the connect-controller hint, and the illegal-move row.
//  Ordinary SwiftUI — always pinch-interactive; the game controller never
//  drives the ornament.
//

import SwiftUI
import SwiftData
import KataGoUICore

struct VisionControlOrnament: View {
    let session: GameSession
    let shell: VisionGameShell
    let controllerInput: VisionControllerInput
    let navigationContext: NavigationContext
    let gameRecords: [GameRecord]
    let maxBoardLength: Int
    let onNewGame: (Int) -> Void
    let onOpenGame: (GameRecord) -> Void
    let onUndo: () -> Void
    let onSparkle: () -> Void
    let onToggleAI: (PlayerColor) -> Void
    let onDismissIllegalMove: () -> Void

    /// The `@Query` is newest-first, so the games that matter are always in
    /// range; beyond ~20 rows a pinch menu stops being usable anyway (same
    /// cap as the widget's game picker).
    private static let maxPickerGames = 20

    var body: some View {
        Group {
            if session.gobanState.confirmingIllegalMove {
                illegalMoveRow
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

            Group {
                Menu {
                    Button("9 × 9") { onNewGame(9) }
                    Button("13 × 13") { onNewGame(13) }
                    Button("19 × 19") { onNewGame(19) }
                } label: {
                    Label("New Game", systemImage: "plus")
                }

                Menu {
                    ForEach(gameRecords.prefix(Self.maxPickerGames)) { record in
                        gameRow(record)
                    }
                } label: {
                    Label("Games", systemImage: "square.stack.3d.up")
                }
                .disabled(gameRecords.isEmpty)

                Button(action: onUndo) {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }

                // Sparkle = analysis engine state, with the three iOS styles:
                // running = animated variable-color sparkle, paused = static
                // sparkle, off = red slashed sparkle. Overlay VISIBILITY is on
                // the controller's B button (no eye button here).
                Button(action: onSparkle) {
                    Label {
                        Text("Toggle Analysis")
                    } icon: {
                        Image(session.gobanState.analysisStatus == .clear
                              ? "custom.sparkle.slash" : "custom.sparkle")
                            .symbolEffect(.variableColor.iterative.reversing,
                                          isActive: session.gobanState.analysisStatus == .run)
                    }
                }
                .foregroundStyle(session.gobanState.analysisStatus == .clear
                                 ? AnyShapeStyle(.red)
                                 : AnyShapeStyle(.primary))
                .contentTransition(.symbolEffect(.replace))

                Button {
                    shell.isBoardStanding.toggle()
                } label: {
                    Label(shell.isBoardStanding ? "Lay Board Flat" : "Stand Board Up",
                          systemImage: shell.isBoardStanding
                              ? "rectangle.portrait.rotate"
                              : "rectangle.landscape.rotate")
                }

                Button {
                    shell.showingControllerHelp.toggle()
                } label: {
                    Label("Controller Help", systemImage: "gamecontroller")
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)

            if !controllerInput.isConnected {
                Divider().frame(height: 24)
                Label("Connect a controller to play", systemImage: "gamecontroller")
                    .foregroundStyle(.secondary)
            }
        }
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

    /// One Games-picker row: name + "date · size", checkmark on the open
    /// game, disabled when the stored size is known-unsupported (unknown
    /// sizes stay enabled — openGame re-derives from the SGF and gates).
    private func gameRow(_ record: GameRecord) -> some View {
        let item = VisionGamePickerItem.make(
            name: record.name,
            lastModificationDate: record.lastModificationDate,
            width: record.width,
            height: record.height,
            maxBoardLength: maxBoardLength)
        let isCurrent = record.persistentModelID
            == navigationContext.selectedGameRecord?.persistentModelID

        return Button {
            onOpenGame(record)
        } label: {
            // Bare Text/Text/Image in the label builder: menus map these to
            // title, subtitle, and trailing icon (a Label's title builder
            // drops the subtitle Text on visionOS).
            Text(item.title)
            if !item.detailText.isEmpty {
                Text(item.detailText)
            }
            if isCurrent {
                Image(systemName: "checkmark")
            }
        }
        .disabled(!item.isSelectable)
    }

    /// Pinch to flip the side between Human and AI (mirrors the iOS
    /// captured-stone-capsule tap).
    private func playerChip(_ color: PlayerColor) -> some View {
        let config = navigationContext.selectedGameRecord?.concreteConfig
        let isAI = color == .black
            ? (config?.blackMaxTime ?? 0) > 0
            : (config?.whiteMaxTime ?? 0) > 0
        let captured = color == .black
            ? session.stones.blackStonesCaptured
            : session.stones.whiteStonesCaptured
        let isToMove = session.player.nextColorForPlayCommand == color

        return Button {
            onToggleAI(color)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(color == .black ? Color.black : Color.white)
                    .stroke(.secondary, lineWidth: 1)
                    .frame(width: 14, height: 14)
                Image(systemName: isAI ? "cpu" : "person.fill")
                    .font(.caption)
                Text(isAI ? "AI" : "Human")
                    .font(.caption)
                if captured > 0 {
                    Text("×\(captured)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
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
        .buttonStyle(.plain)
        .accessibilityLabel("\(color == .black ? "Black" : "White"): \(isAI ? "AI" : "Human"). Tap to switch.")
    }
}

/// Floating card teaching the game-controller mapping (DualSense face-button
/// glyphs shown alongside the generic A/B/X/Y names). Auto-shown once when a
/// controller first connects; toggled from the ornament's gamecontroller
/// button afterward.
struct VisionControllerLegend: View {
    let onDismiss: () -> Void

    private struct Row: Identifiable {
        let symbol: String
        let name: String
        let action: String
        var id: String { name }
    }

    private let rows: [Row] = [
        Row(symbol: "l.joystick", name: "Left Stick", action: "Glide the ghost stone"),
        Row(symbol: "dpad", name: "D-Pad", action: "Step one intersection"),
        Row(symbol: "xmark.circle", name: "✕ / A", action: "Play at the ghost stone"),
        Row(symbol: "circle.circle", name: "○ / B", action: "Show / hide analysis"),
        Row(symbol: "l1.rectangle.roundedbottom", name: "L1 · R1", action: "Previous / next suggested move"),
        Row(symbol: "square.circle", name: "□ / X", action: "Undo"),
        Row(symbol: "triangle.circle", name: "△ / Y", action: "Pass"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Game Controller", systemImage: "gamecontroller.fill")
                    .font(.headline)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close controller help")
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                ForEach(rows) { row in
                    GridRow {
                        Image(systemName: row.symbol)
                            .font(.title3)
                            .frame(width: 32)
                        Text(row.name)
                            .font(.subheadline.bold())
                            .frame(width: 84, alignment: .leading)
                        Text(row.action)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text("Pinch the player chips below the board to switch a side between Human and AI.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: 320, alignment: .leading)
        }
        .padding(20)
        .glassBackgroundEffect()
    }
}
