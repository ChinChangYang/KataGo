//
//  VisionOrnamentViews.swift
//  KataGo Anytime Vision
//
//  The volume's control ornament: it is up for as long as the BOARD is, which
//  is now from the first frames of a launch onward. The controls that send GTP
//  commands (the analysis sparkle, the Human/AI chips) disable themselves while
//  the engine is unavailable; Games, the lock slot, Settings and the controller
//  legend are engine-free and stay live throughout.
//
//  Contents: player chips (pinch to flip Human⇄AI),
//  the Games toggle (shows/hides the left-side game-list ornament, whose
//  header carries New Game), the analysis sparkle (run/pause/off), the lock
//  slot (iOS TopToolbarView parity: Lock/Unlock off-branch, red Deactivate
//  Branch on-branch, with the Replace/Discard confirmation chain), the
//  Settings gear (right-side card: analysis-information picker, ownership
//  toggle, board orientation — mutually exclusive with the controller
//  legend), controller help, the connect-controller hint, and the
//  illegal-move row.
//  No Undo or navigation buttons — the controller's X/L1 cover single-move
//  undo, R1 steps forward, and L2/R2 jump to the start/end of the game.
//  Ordinary SwiftUI — always pinch-interactive;
//  the game controller never drives the ornament (enforced by
//  handlesGameControllerEvents on every ornament content root in
//  VisionRootView, which keeps presses flowing to VisionControllerInput
//  even while gaze rests here).
//

import SwiftUI
import SwiftData
import KataGoUICore
import KataGoGameStore

struct VisionControlOrnament: View {
    let session: GameSession
    /// `VisionEngineChrome.allowsEngineCommands` — only the controls that SEND
    /// GTP read it. Everything else here is engine-free and stays live.
    let isEngineReady: Bool
    let shell: VisionGameShell
    let controllerInput: VisionControllerInput
    let navigationContext: NavigationContext
    let onSparkle: () -> Void
    /// The sparkle's remedy tap (ADR 0010): opens the Models card, where the
    /// engine-status header explains the down state and offers the way out.
    let onOpenModels: () -> Void
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
        // The branch chooser/confirm flow renders as front-anchored glass
        // cards owned by the ROOT (VisionBranchChooserCard /
        // VisionBranchConfirmCard), driven by the shared GobanState confirm
        // flags this bar's Deactivate Branch button raises. Deliberately NO
        // .confirmationDialog here: a button-tap dismissal of an
        // ornament-hosted dialog that re-renders another ornament blanks
        // the volumetric window's render tree on visionOS 26 (verified
        // live; the app keeps running under a permanently empty volume).
    }

    // MARK: - Rows

    private var mainRow: some View {
        HStack(spacing: 16) {
            playerChip(.black)
            playerChip(.white)

            Divider().frame(height: 24)

            Group {
                Button {
                    shell.showingGameList.toggle()
                } label: {
                    Label("Games", systemImage: shell.showingGameList
                          ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                }

                // Sparkle (ADR 0010): appearance reports analysis ACTIVITY —
                // running = animated variable-color sparkle, paused = static
                // sparkle, user-off = bare red slash, engine down = badged red
                // slash. Overlay VISIBILITY is on the controller's B button
                // (no eye button here). Tap follows the engine: usable cycles
                // the preference; a resting-down engine opens the Models card,
                // whose status header explains the state and offers the way
                // out. Only the transient Launching wait disables it.
                let control = AnalysisControlModel.make(
                    analysisStatus: session.gobanState.analysisStatus,
                    availability: session.engineStatus.availability)
                Button {
                    if control.tap == .openRemedy {
                        onOpenModels()
                    } else {
                        onSparkle()
                    }
                } label: {
                    Label {
                        Text("Toggle Analysis")
                    } icon: {
                        Image(control.symbolName)
                            .symbolEffect(.variableColor.iterative.reversing,
                                          isActive: control.isAnimating)
                            // The engine-down badge: a SHAPE, not a colour, so
                            // a bare red slash (user off) and a badged one
                            // (engine down) stay distinguishable to everyone.
                            .overlay(alignment: .bottomTrailing) {
                                if control.showsWarningBadge {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.orange)
                                        .offset(x: 4, y: 4)
                                }
                            }
                    }
                }
                .foregroundStyle(control.isRed
                                 ? AnyShapeStyle(.red)
                                 : AnyShapeStyle(.primary))
                .contentTransition(.symbolEffect(.replace))
                .disabled(!control.isEnabled)
                .accessibilityLabel(control.accessibilityLabel)

                lockSlotButton

                Button {
                    shell.toggleSettings()
                } label: {
                    Label("Settings", systemImage: shell.showingSettings
                          ? "gearshape.fill" : "gearshape")
                }

                Button {
                    shell.toggleControllerHelp()
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

    /// The state-dependent lock slot (iOS TopToolbarView parity): Lock/Unlock
    /// toggling isEditing while no branch is active; the red "Deactivate
    /// Branch" u-turn while one is (editing must never toggle mid-branch —
    /// a branch only forms while isEditing == false, and the editing play
    /// path would clear the saved record's data while moves are
    /// branch-routed). LockSlotModel owns the mapping; tests pin it. Vision has
    /// no auto-play UI, so it leaves `isAutoPlaying` at its default (false) and
    /// keeps the always-enabled toggle.
    private var lockSlotButton: some View {
        let config = navigationContext.selectedGameRecord?.concreteConfig
        let slot = LockSlotModel.make(
            isBranchActive: session.gobanState.isBranchActive,
            isEditing: session.gobanState.isEditing,
            shouldGenMove: config.map {
                session.gobanState.shouldGenMove(config: $0,
                                                 player: session.player)
            } ?? false)
        return Button {
            switch slot.kind {
            case .toggleLock:
                session.gobanState.isEditing.toggle()
            case .deactivateBranch:
                session.gobanState.confirmingBranchDeactivation = true
            }
        } label: {
            Label(slot.label, systemImage: slot.systemImage)
        }
        .foregroundStyle(slot.isRed ? AnyShapeStyle(.red)
                                    : AnyShapeStyle(.primary))
        .disabled(slot.isDisabled)
        .contentTransition(.symbolEffect(.replace))
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

        // One interpolated Text so the SF Symbol shares the label's baseline:
        // sibling Image + Text views center-align in the HStack, which reads
        // as vertical misalignment on device. The captured count interpolates
        // into that same Text (Text + Text is deprecated as of 26) so it stays
        // on that baseline while keeping its own monospaced-digit font and
        // secondary foreground style.
        var chipText = Text("\(Image(systemName: isAI ? "cpu" : "person.fill")) \(isAI ? "AI" : "Human")")
            .font(.caption)
        if captured > 0 {
            let capturedText = Text(" ×\(captured)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            chipText = Text("\(chipText)\(capturedText)")
        }

        return Button {
            onToggleAI(color)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(color == .black ? Color.black : Color.white)
                    .stroke(.secondary, lineWidth: 1)
                    .frame(width: 14, height: 14)
                chipText
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            // Flat tint, never a material: a .regularMaterial capsule nested
            // inside the ornament's glassBackgroundEffect becomes its own
            // glass plate with separate depth on visionOS, so the two chips
            // ended up on different visual planes (read as vertically
            // misaligned).
            .background(isToMove ? AnyShapeStyle(.primary.opacity(0.15)) : AnyShapeStyle(.clear),
                        in: Capsule())
            .overlay {
                if isToMove {
                    Capsule().stroke(.primary.opacity(0.4), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        // Flipping a side rewrites the human-SL bundle and re-arms the search —
        // all of it commands, and all of it dropped while the engine is away.
        .disabled(!isEngineReady)
        .accessibilityLabel("\(color == .black ? "Black" : "White"): \(isAI ? "AI" : "Human"). Tap to switch.")
    }
}

/// Front-anchored branch chooser — the glass-card stand-in for iOS's first
/// confirmation dialog (see VisionControlOrnament's comment for why the
/// flow uses no dialogs). Raising a confirm flag and clearing this one is
/// the caller's job; there is no isPresented binding.
struct VisionBranchChooserCard: View {
    let onReplace: () -> Void
    let onDiscard: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text(VisionBranchConfirm.chooserTitle)
                .font(.headline)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Button("Cancel", role: .cancel, action: onCancel)

                Button("Discard Branch", action: onDiscard)

                Button("Replace", action: onReplace)
            }
        }
        .frame(width: 460)
        .padding(20)
        .glassBackgroundEffect()
    }
}

/// Front-anchored destructive confirm for the Replace/Discard-branch flow —
/// the glass-card stand-in for iOS's second confirmation dialog (see
/// VisionControlOrnament's comment for why it is not a dialog). Driven
/// entirely by the shared GobanState confirm flags; the callers clear the
/// flag in BOTH actions (there is no isPresented binding to do it for
/// them).
struct VisionBranchConfirmCard: View {
    let confirm: VisionBranchConfirm
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text(confirm.title)
                .font(.headline)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Button("Cancel", role: .cancel, action: onCancel)

                Button(confirm.confirmLabel, role: .destructive,
                       action: onConfirm)
            }
        }
        .frame(width: 460)
        .padding(20)
        .glassBackgroundEffect()
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
        Row(symbol: "l1.rectangle.roundedbottom", name: "L1 · R1", action: "Back / forward one move (hold to repeat)"),
        Row(symbol: "l2.rectangle.roundedtop", name: "L2 · R2", action: "Jump to start / end of game"),
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

/// Right-side settings card, toggled from the control bar's gear button.
/// It shares the anchor with the controller legend — the shell's toggle
/// helpers keep the two mutually exclusive. Rows write the shell, which
/// persists them (VisionSettings.* keys); the root mirrors the display
/// settings into GobanState, which is what the 3D scene reads.
struct VisionSettingsOrnament: View {
    @Bindable var shell: VisionGameShell
    let engine: VisionEngineController
    let onShowModels: () -> Void
    let onShowLicenses: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Settings", systemImage: "gearshape")
                    .font(.headline)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close settings")
            }

            // The default picker drops its title on visionOS here — keep an
            // explicit row label and hide the picker's own.
            HStack {
                Label("Analysis information", systemImage: "textformat.123")
                Spacer()
                Picker("Analysis information", selection: $shell.analysisInformation) {
                    ForEach(Config.analysisInformations.indices, id: \.self) { index in
                        Text(Config.analysisInformations[index]).tag(index)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            Toggle(isOn: $shell.showOwnership) {
                Label("Show ownership", systemImage: "circle.lefthalf.filled")
            }

            Toggle(isOn: $shell.isBoardStanding) {
                Label("Stand board up", systemImage: "rectangle.portrait.rotate")
            }

            // Opens the Models card in this same right-anchor slot (the
            // shell's presentModels closes settings) — download and
            // activate extra nets, iOS model-picker style. Per-model Max
            // Board Size lives behind each model detail's gear there
            // (which also owns the restart trigger and its progress
            // feedback), so nothing on this card is engine-gated.
            Button(action: onShowModels) {
                HStack {
                    Label("Neural Net", systemImage: "brain")
                    Spacer()
                    Text(engine.activeModel.title)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Neural Net: \(engine.activeModel.title)")

            // Opens the Licenses card in this same right-anchor slot —
            // EULA parity: every platform lists its third-party licenses
            // under Settings.
            Button(action: onShowLicenses) {
                HStack {
                    Label("Open-Source Licenses", systemImage: "doc.text")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open-Source Licenses")
        }
        .frame(width: 380)
        .padding(20)
        .glassBackgroundEffect()
    }
}

/// Right-side custom New Game card (New Game ▸ Custom…): width/height
/// steppers bounded by 2...min(37, the launched Max Board Size), any
/// rectangle allowed. Shares the right anchor with settings and the legend
/// (the shell's toggle helpers keep the three mutually exclusive).
struct VisionNewGamePanel: View {
    let maxBoardLength: Int
    /// `VisionEngineChrome.allowsNewGame`. Only the Create button reads it:
    /// making a game feeds the engine, and the steppers are bounded by a buffer
    /// a launching engine has not settled yet. The card itself stays usable so
    /// it can always be dismissed.
    let canCreateGame: Bool
    let onCreate: (Int, Int) -> Void
    let onDismiss: () -> Void

    @State private var boardWidth: Int
    @State private var boardHeight: Int

    private var sizeCap: Int { max(2, min(37, maxBoardLength)) }

    init(maxBoardLength: Int,
         canCreateGame: Bool,
         onCreate: @escaping (Int, Int) -> Void,
         onDismiss: @escaping () -> Void) {
        self.maxBoardLength = maxBoardLength
        self.canCreateGame = canCreateGame
        self.onCreate = onCreate
        self.onDismiss = onDismiss
        let initial = min(19, max(2, min(37, maxBoardLength)))
        _boardWidth = State(initialValue: initial)
        _boardHeight = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("New Game", systemImage: "plus")
                    .font(.headline)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close new game")
            }

            Stepper(value: $boardWidth, in: 2...sizeCap) {
                Label("Width: \(boardWidth)", systemImage: "arrow.left.and.right")
            }
            Stepper(value: $boardHeight, in: 2...sizeCap) {
                Label("Height: \(boardHeight)", systemImage: "arrow.up.and.down")
            }

            if sizeCap < 37 {
                Text("Boards up to \(sizeCap)×\(sizeCap) with the current Max Board Size — raise it under Settings ▸ Neural Net for more.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button {
                onCreate(boardWidth, boardHeight)
            } label: {
                Label("Create \(boardWidth) × \(boardHeight) Game", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canCreateGame)
        }
        .frame(width: 380)
        .padding(20)
        .glassBackgroundEffect()
    }
}

/// Left-side game list, toggled from the control bar's Games button: the
/// newest iCloud-synced games (the root @Query live-refreshes), pinch a row
/// to load it. The header's + menu starts a new game (9/13/19 quick sizes,
/// gated by the engine cap, or Custom… → the right-anchor panel) — shown
/// even when the library is empty. The list stays up after a pick so the
/// checkmark tracks the switch — and after a create, for the same reason;
/// the toggle or the close button dismisses it. Deletion happens in Select
/// mode only (the open game included; the root remounts the newest
/// remaining game, else a fresh one).
struct VisionGameListOrnament: View {
    let gameRecords: [GameRecord]
    /// `VisionEngineChrome.allowsNewGame`. Opening a game never waits for the
    /// engine — the board is record-owned. CREATING one does: it is a
    /// command-sender, and it is sized by a buffer a launching engine has not
    /// settled yet. Only the + menu reads this.
    let canCreateGame: Bool
    let maxBoardLength: Int
    /// The active net's nnLen — the largest value Max Board Size can reach.
    /// Rows over it caption "switch the net", not "raise the setting".
    let modelBoardCap: Int
    let navigationContext: NavigationContext
    let onOpenGame: (GameRecord) -> Void
    let onNewGame: (Int) -> Void
    let onCustomGame: () -> Void
    let onDeleteGames: (Set<PersistentIdentifier>) -> Void
    let onDismiss: () -> Void

    /// Whether the bulk deletion awaits confirmation. The confirm renders
    /// as an in-card content swap (VisionBranchConfirmCard pattern), NEVER a
    /// .confirmationDialog: deleting the open game re-renders the board and
    /// other ornaments — the exact ornament-dialog action that blanks the
    /// volume (see VisionControlOrnament's comment). The doomed IDs live in
    /// `selectedIDs`, so a CloudKit sync deleting one mid-confirm strands
    /// nothing (bulkDelete then no-ops). Card-local: dismissing the card
    /// discards a pending confirm.
    @State private var confirmingBulkDelete = false

    /// iOS select-mode parity, card-local (dismissing the card exits
    /// selection, iOS's exitSelection-on-disappear for free).
    @State private var isSelecting = false
    @State private var selectedIDs: Set<PersistentIdentifier> = []

    /// Newest-first, so the games that matter are always in range; the
    /// scroll view keeps a long library usable (widget-picker precedent for
    /// the bound itself).
    private static let maxListedGames = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if confirmingBulkDelete {
                confirmView
            } else {
                header
                gamesScroll
                if isSelecting {
                    bulkDeleteBar
                }
            }
        }
        .padding(20)
        .glassBackgroundEffect()
    }

    private var header: some View {
        HStack {
            Label("Games", systemImage: "square.stack.3d.up")
                .font(.headline)
            Spacer()
            // Hidden in Select mode (iOS GameListToolbar parity): selection
            // is a focused flow, and a mid-selection create would land the
            // new game inside it as a deletable row.
            if !isSelecting {
                Menu {
                    ForEach([9, 13, 19], id: \.self) { size in
                        Button("\(size) × \(size)") { onNewGame(size) }
                            .disabled(size > maxBoardLength)
                    }
                    Button("Custom…") { onCustomGame() }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(!canCreateGame)
                .accessibilityLabel("New Game")
            }
            if !gameRecords.isEmpty {
                Button {
                    withAnimation {
                        isSelecting.toggle()
                        if !isSelecting {
                            selectedIDs.removeAll()
                        }
                    }
                } label: {
                    Image(systemName: VisionGameDeleteFlow.selectToggleImage(isSelecting: isSelecting))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(VisionGameDeleteFlow.selectToggleTitle(isSelecting: isSelecting))
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Close game list")
        }
    }

    /// iOS bottom-bar parity: red trash carrying the selection count,
    /// disabled at zero.
    private var bulkDeleteBar: some View {
        HStack {
            Spacer()
            Button(role: .destructive) {
                confirmingBulkDelete = true
            } label: {
                Label(VisionGameDeleteFlow.trashCountLabel(count: selectedIDs.count),
                      systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(VisionGameDeleteFlow.bulkTrashDisabled(count: selectedIDs.count))
            .accessibilityLabel("Delete \(selectedIDs.count) selected game\(selectedIDs.count == 1 ? "" : "s")")
        }
    }

    private var gamesScroll: some View {
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

    /// Both actions explicitly clear the pending flag (no isPresented
    /// binding to do it for them).
    private var confirmView: some View {
        VisionGameDeleteConfirmCard(
            prompt: VisionGameDeleteFlow.bulkDeletePrompt(count: selectedIDs.count),
            onDelete: {
                confirmingBulkDelete = false
                onDeleteGames(selectedIDs)
                withAnimation {
                    selectedIDs.removeAll()
                    isSelecting = false
                }
            },
            onCancel: { confirmingBulkDelete = false })
    }

    /// One row: name over "date · size", checkmark on the open game,
    /// disabled when the stored size is known-unsupported (unknown sizes
    /// stay enabled — openGame re-derives from the SGF and gates). Deletion
    /// lives in select mode only, where the whole row toggles membership —
    /// blocked rows included (so no .disabled there): deleting is the only
    /// remedy for a game the active net can never open.
    @ViewBuilder
    private func gameRow(_ record: GameRecord) -> some View {
        let item = VisionGamePickerItem.make(
            name: record.name,
            lastModificationDate: record.lastModificationDate,
            width: record.width,
            height: record.height,
            maxBoardLength: maxBoardLength,
            modelBoardCap: modelBoardCap)
        let isCurrent = record.persistentModelID
            == navigationContext.selectedGameRecord?.persistentModelID

        if isSelecting {
            selectableRow(record, item: item, isCurrent: isCurrent)
        } else {
            Button {
                onOpenGame(record)
            } label: {
                rowLabel(item: item, isCurrent: isCurrent)
            }
            .buttonStyle(.plain)
            .disabled(!item.isSelectable)
        }
    }

    /// Select-mode row (iOS selectableRow parity): a leading selection
    /// circle, the whole row toggles membership.
    private func selectableRow(_ record: GameRecord,
                               item: VisionGamePickerItem,
                               isCurrent: Bool) -> some View {
        let isSelected = selectedIDs.contains(record.persistentModelID)
        return Button {
            withAnimation {
                if isSelected {
                    selectedIDs.remove(record.persistentModelID)
                } else {
                    selectedIDs.insert(record.persistentModelID)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: VisionGameDeleteFlow.selectionImage(isSelected: isSelected))
                    .imageScale(.large)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint)
                                                : AnyShapeStyle(.secondary))
                rowLabel(item: item, isCurrent: isCurrent)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(isSelected ? "Deselect" : "Select") \(item.title)")
    }

    /// The row content shared by the open and select modes.
    private func rowLabel(item: VisionGamePickerItem, isCurrent: Bool) -> some View {
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
                if item.needsLargerBoardSetting {
                    Text("Raise Max Board Size in Settings ▸ Neural Net")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else if item.needsDifferentNet {
                    Text("Switch the neural net in Settings")
                        .font(.caption2)
                        .foregroundStyle(.orange)
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
}

/// In-card destructive confirm for the Games-list deletes — the content the
/// Games ornament swaps to while a delete awaits confirmation (the glass
/// belongs to the hosting card). iOS delete-dialog wording, Cancel +
/// destructive Delete; the caller clears the pending flag in BOTH actions.
private struct VisionGameDeleteConfirmCard: View {
    let prompt: String
    let onDelete: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text(prompt)
                .font(.headline)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Button("Cancel", role: .cancel, action: onCancel)

                Button("Delete", role: .destructive, action: onDelete)
            }
        }
        .frame(width: 320)
    }
}
