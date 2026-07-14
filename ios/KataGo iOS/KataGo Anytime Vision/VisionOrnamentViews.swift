//
//  VisionOrnamentViews.swift
//  KataGo Anytime Vision
//
//  The volume's control ornament: player chips (pinch to flip Human⇄AI),
//  New Game (9/13/19), the Games toggle (shows/hides the left-side game-list
//  ornament), the analysis sparkle (run/pause/off), the lock slot (iOS
//  TopToolbarView parity: Lock/Unlock off-branch, red Deactivate Branch
//  on-branch, with the Replace/Discard confirmation chain), the Settings
//  gear (right-side card: analysis-information picker, ownership toggle,
//  board orientation — mutually exclusive with the controller legend),
//  controller help, the connect-controller hint, and the illegal-move row.
//  No Undo button — the controller's X covers single-move undo. Ordinary
//  SwiftUI — always pinch-interactive; the game controller never drives
//  the ornament.
//

import SwiftUI
import SwiftData
import KataGoUICore
import KataGoGameStore

struct VisionControlOrnament: View {
    let session: GameSession
    let shell: VisionGameShell
    let controllerInput: VisionControllerInput
    let navigationContext: NavigationContext
    let maxBoardLength: Int
    let onNewGame: (Int) -> Void
    let onCustomGame: () -> Void
    let onSparkle: () -> Void
    let onToggleAI: (PlayerColor) -> Void
    let onDismissIllegalMove: () -> Void

    var body: some View {
        @Bindable var gobanState = session.gobanState
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
        // The iOS branch confirmation chain (GameSplitView), verbatim: a
        // chooser, then one destructive confirm per outcome. Replace commits
        // the branch into the saved game (and the branch-end reload in
        // VisionRootView lands it unlocked); Discard just drops the branch.
        .confirmationDialog(
            "Branch moves are temporary. Replace the original game with this branch, or discard it?",
            isPresented: $gobanState.confirmingBranchDeactivation,
            titleVisibility: .visible
        ) {
            Button("Replace") {
                // Defer to the next runloop so the first dialog fully
                // dismisses before the second presents. Chaining
                // confirmationDialogs in the same transaction (present
                // while dismissing) is fragile on iOS 26 and can silently
                // drop the second sheet. Button actions are MainActor-
                // isolated, so this one-turn hop is concurrency-safe.
                Task { @MainActor in
                    gobanState.confirmingBranchReplace = true
                }
            }

            Button("Discard Branch") {
                Task { @MainActor in
                    gobanState.confirmingBranchDiscard = true
                }
            }

            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog(
            "Replace the original game with this branch? The original game’s moves after this point will be permanently lost.",
            isPresented: $gobanState.confirmingBranchReplace,
            titleVisibility: .visible
        ) {
            Button("Replace", role: .destructive) {
                if let gameRecord = navigationContext.selectedGameRecord {
                    gobanState.commitBranch(gameRecord: gameRecord)
                } else {
                    // No game to replace (unreachable in practice): exit branch
                    // mode anyway so confirming never leaves the branch stuck,
                    // mirroring the Discard path below.
                    gobanState.deactivateBranch()
                }
            }

            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog(
            "Discard this branch? Your newly played stones will be lost.",
            isPresented: $gobanState.confirmingBranchDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard Branch", role: .destructive) {
                gobanState.deactivateBranch()
            }

            Button("Cancel", role: .cancel) { }
        }
    }

    // MARK: - Rows

    private var mainRow: some View {
        HStack(spacing: 16) {
            playerChip(.black)
            playerChip(.white)

            Divider().frame(height: 24)

            Group {
                Menu {
                    ForEach([9, 13, 19], id: \.self) { size in
                        Button("\(size) × \(size)") { onNewGame(size) }
                            .disabled(size > maxBoardLength)
                    }
                    Button("Custom…") { onCustomGame() }
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
    /// branch-routed). VisionLockSlotModel owns the mapping; tests pin it.
    private var lockSlotButton: some View {
        let config = navigationContext.selectedGameRecord?.concreteConfig
        let slot = VisionLockSlotModel.make(
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

/// Right-side settings card, toggled from the control bar's gear button.
/// It shares the anchor with the controller legend — the shell's toggle
/// helpers keep the two mutually exclusive. Rows write the shell, which
/// persists them (VisionSettings.* keys); the root mirrors the display
/// settings into GobanState, which is what the 3D scene reads.
struct VisionSettingsOrnament: View {
    @Bindable var shell: VisionGameShell
    let engine: VisionEngineController
    let onRestart: () -> Void
    let onDismiss: () -> Void

    /// Seeded from the persisted per-model setting (TVSettingsScreen pattern);
    /// onChange persists and asks the root to restart the engine.
    @State private var boardSize: BoardSizeChoice

    init(shell: VisionGameShell,
         engine: VisionEngineController,
         onRestart: @escaping () -> Void,
         onDismiss: @escaping () -> Void) {
        self.shell = shell
        self.engine = engine
        self.onRestart = onRestart
        self.onDismiss = onDismiss
        // The buffer setting is per-model (per-fileName BackendSettings
        // keys) — seed from the ACTIVE net, not the built-in.
        _boardSize = State(initialValue:
            BackendSettings(model: engine.activeModel).mlxBoardSize)
    }

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

            // NN-buffer cap: bigger boards need a bigger (slower, hungrier)
            // buffer, so changing it quits and respawns the engine — the same
            // proven flow as tvOS's Board Size setting. Disabled unless the
            // engine is running (a restart in flight serves the OLD buffer).
            // Segmented, not a Menu: this card sits at the volume's top edge
            // and a Menu opened upward, clipping its upper options outside
            // the window.
            VStack(alignment: .leading, spacing: 8) {
                Label("Max board size", systemImage: "squareshape.split.3x3")
                Picker("Max board size", selection: $boardSize) {
                    ForEach(BoardSizeChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(engine.phase != .running)
            }
            .onChange(of: boardSize) { oldValue, newValue in
                guard oldValue != newValue else { return }
                var settings = BackendSettings(model: engine.activeModel)
                settings.mlxBoardSize = newValue
                onRestart()
            }
            // A model activation while this card stays open switches which
            // per-fileName key the picker edits — re-seed from the new
            // net's persisted value (the init seeding only covers a fresh
            // card). Without this the segmented control shows the OLD
            // model's cap and its first change writes the old key.
            .onChange(of: engine.activeModel.fileName) { _, _ in
                boardSize = BackendSettings(model: engine.activeModel).mlxBoardSize
            }

            if engine.phase != .running {
                HStack(spacing: 8) {
                    if case .failed(let reason) = engine.phase {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Text(reason)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                        Text("Restarting engine…")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
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
    let onCreate: (Int, Int) -> Void
    let onDismiss: () -> Void

    @State private var boardWidth: Int
    @State private var boardHeight: Int

    private var sizeCap: Int { max(2, min(37, maxBoardLength)) }

    init(maxBoardLength: Int,
         onCreate: @escaping (Int, Int) -> Void,
         onDismiss: @escaping () -> Void) {
        self.maxBoardLength = maxBoardLength
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
                Text("Boards up to \(sizeCap)×\(sizeCap) with the current Max Board Size — raise it in Settings for more.")
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
        }
        .frame(width: 380)
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
                    if item.needsLargerBoardSetting {
                        Text("Raise Max Board Size in Settings")
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
        .buttonStyle(.plain)
        .disabled(!item.isSelectable)
    }
}
