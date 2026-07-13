//
//  VisionOrnamentViews.swift
//  KataGo Anytime Vision
//
//  The volume's control ornament: player chips (pinch to flip Human⇄AI),
//  New Game (9/13/19), the Games toggle (shows/hides the left-side game-list
//  ornament), the analysis sparkle (run/pause/off), the board orientation
//  toggle, controller help, the connect-controller hint, and the
//  illegal-move row. No Undo button — the controller's X covers undo.
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
    let onNewGame: (Int) -> Void
    let onSparkle: () -> Void
    let onToggleAI: (PlayerColor) -> Void
    let onDismissIllegalMove: () -> Void

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

                Button {
                    shell.showingGameList.toggle()
                } label: {
                    Label("Games", systemImage: shell.showingGameList
                          ? "square.stack.3d.up.fill" : "square.stack.3d.up")
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

/// Left-side game list, toggled from the control bar's Games button: the
/// newest iCloud-synced games (the root @Query live-refreshes), pinch a row
/// to load it. The list stays up after a pick so the checkmark tracks the
/// switch; the toggle or the close button dismisses it.
struct VisionGameListOrnament: View {
    let gameRecords: [GameRecord]
    let maxBoardLength: Int
    let navigationContext: NavigationContext
    let onOpenGame: (GameRecord) -> Void
    let onDismiss: () -> Void

    /// Newest-first, so the games that matter are always in range; the
    /// scroll view keeps a long library usable (widget-picker precedent for
    /// the bound itself).
    private static let maxListedGames = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Games", systemImage: "square.stack.3d.up")
                    .font(.headline)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close game list")
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(gameRecords.prefix(Self.maxListedGames)) { record in
                        gameRow(record)
                    }
                }
            }
            .frame(width: 320)
            .frame(maxHeight: 480)
        }
        .padding(20)
        .glassBackgroundEffect()
    }

    /// One row: name over "date · size", checkmark on the open game,
    /// disabled when the stored size is known-unsupported (unknown sizes
    /// stay enabled — openGame re-derives from the SGF and gates).
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
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    if !item.detailText.isEmpty {
                        Text(item.detailText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.subheadline)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isCurrent ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!item.isSelectable)
    }
}
