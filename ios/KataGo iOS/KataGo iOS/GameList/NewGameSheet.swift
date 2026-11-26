//
//  NewGameSheet.swift
//  KataGo Anytime
//
//  "Play KataGo": one screen that turns the three things a person wants to
//  decide — how strong, which colour, what board — into a started game.
//
//  Before this sheet a game against the engine took a walk through the app:
//  New Game ▸ Empty Board, then Game Settings ▸ Rule for the board size, then
//  either Game Settings ▸ AI or a long press on the 10 pt "Human" capsule above
//  the board for the rank. Every one of those still works; this is the front
//  door they never had.
//
//  A thin shell: the choices are `TVNewGameForm` (the same pure form the tvOS
//  "Play KataGo" screen uses, pinned by `TVNewGameFormTests`) and the slider
//  is `OpponentLadder`. Creating the record and opening it stay with
//  `GameSplitView`, which owns everything a game switch touches.
//

import SwiftUI
import KataGoUICore

struct NewGameSheet: View {
    let maxBoardLength: Int
    /// The form as the user left it, plus whether the board should draw the
    /// engine's analysis while they play.
    let onStart: (TVNewGameForm, _ showsHints: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(GobanState.self) private var gobanState

    // What the last New Game chose, so a second game is one tap. Stored as the
    // rank KIND ("15k"), never a slider position: the ladder may grow.
    @AppStorage("NewGame.rankKind") private var storedRankKind = OpponentLadder.defaultKind
    @AppStorage("NewGame.boardSize") private var storedBoardSize = Config.defaultBoardWidth
    @AppStorage("NewGame.humanPlaysBlack") private var storedHumanPlaysBlack = true
    @AppStorage("NewGame.showsHints") private var showsHints = false

    @State private var form: TVNewGameForm
    @State private var rung: Double
    @State private var hasRestoredLastChoices = false

    init(maxBoardLength: Int,
         onStart: @escaping (TVNewGameForm, _ showsHints: Bool) -> Void) {
        self.maxBoardLength = maxBoardLength
        self.onStart = onStart
        // Seeded from the stored choices in `.onAppear`: `@AppStorage` is not
        // readable here, before the view is installed.
        _form = State(initialValue: TVNewGameForm(maxBoardLength: maxBoardLength))
        _rung = State(initialValue: Double(OpponentLadder.index(of: OpponentLadder.defaultKind)))
    }

    private var kind: String { OpponentLadder.kind(at: Int(rung.rounded())) }

    var body: some View {
        Form {
            Section {
                hero
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            Section {
                // Segmented pickers drop their own label inside a Form, so
                // each row states it with `LabeledContent` instead.
                LabeledContent("You play") {
                    Picker("You play", selection: $form.humanPlaysBlack) {
                        Text("Black").tag(true)
                        Text("White").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("NewGame.color")
                }

                LabeledContent("Board") {
                    Picker("Board", selection: boardSize) {
                        ForEach(TVNewGameForm.quickSizes.filter(form.quickSizeEnabled), id: \.self) { size in
                            Text(verbatim: "\(size)×\(size)").tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("NewGame.boardSize")
                }

                if form.handicapPickerEnabled {
                    Picker("Handicap", selection: handicap) {
                        ForEach(form.availableHandicaps, id: \.self) { count in
                            if count == 0 {
                                Text("None").tag(count)
                            } else {
                                Text(verbatim: "\(count) stones").tag(count)
                            }
                        }
                    }
                    .accessibilityIdentifier("NewGame.handicap")
                }

                // What a hint is rides on the row itself, not in a footer a
                // scrolled form would leave behind.
                Toggle(isOn: $showsHints) {
                    Text("Show hints")
                    Text("KataGo's analysis, drawn on the board")
                }
                .accessibilityIdentifier("NewGame.showsHints")
            } footer: {
                if form.handicap > 0 {
                    Text(form.humanPlaysBlack
                         ? "You start with \(form.handicap) stones on the board."
                         : "KataGo starts with \(form.handicap) stones on the board.")
                }
            }
        }
        .navigationTitle("Play KataGo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", systemImage: "xmark") { dismiss() }
                    .accessibilityIdentifier("NewGame.cancel")
            }
        }
        // A bar, not a bare inset: the form is taller than the screen and
        // scrolls under it, and the bar's edge effect is what keeps a row
        // passing behind the button from reading as a second label on it.
        .safeAreaBar(edge: .bottom) {
            Button(action: start) {
                Text("Start Game")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(!form.canStart)
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .accessibilityIdentifier("NewGame.start")
            // Opaque to the rows: the form is taller than the screen now, and
            // a row showing through around the button reads as clutter.
            .background {
                Rectangle()
                    .fill(.bar)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        .onAppear(perform: restoreLastChoices)
        .onChange(of: kind) { _, newKind in
            form.chooseKind(newKind)
        }
    }

    // MARK: - Hero

    /// The board this game will open on, and the opponent it will be played
    /// against: the two things worth seeing before committing.
    private var hero: some View {
        VStack(spacing: 14) {
            // The board at the full width the sheet has, never scaled down to
            // make the form fit one screen: the form scrolls instead.
            boardPreview
                .aspectRatio(CGFloat(form.boardWidth) / CGFloat(form.boardHeight),
                             contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                .padding(.top, 4)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text(verbatim: OpponentLadder.title(forKind: kind))
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .contentTransition(.numericText())
                    .animation(.snappy, value: kind)
                    .accessibilityIdentifier("NewGame.rankTitle")

                Text(verbatim: OpponentLadder.summary(forKind: kind))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Slider(value: $rung,
                   in: 0...Double(OpponentLadder.kinds.count - 1),
                   step: 1) {
                Text("Opponent strength")
            } minimumValueLabel: {
                Text(verbatim: OpponentLadder.kinds.first ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text(verbatim: OpponentLadder.kinds.last ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .sensoryFeedback(.selection, trigger: kind)
            .accessibilityValue(OpponentLadder.title(forKind: kind))
            .accessibilityIdentifier("NewGame.strength")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
    }

    /// Derived from the SGF the form would write, by the same replay the
    /// library rows use (ADR 0014) — so the handicap stones shown here are the
    /// ones the game will open with, not a second drawing of the same rule.
    @ViewBuilder
    private var boardPreview: some View {
        if let sgf = form.sgf,
           let preview = RecordBoardPreviewSource.preview(sgf: sgf, index: 0) {
            ReportBoardView(width: preview.width,
                            height: preview.height,
                            blackVertices: preview.blackVertices,
                            whiteVertices: preview.whiteVertices,
                            overlay: .none,
                            isClassicStoneStyle: gobanState.isClassicStoneStyle,
                            showCoordinate: false,
                            verticalFlip: gobanState.verticalFlip)
            .allowsHitTesting(false)
        } else {
            Image(systemName: "square.grid.3x3")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Choices

    private var boardSize: Binding<Int> {
        Binding(get: { form.boardWidth },
                set: { size in withAnimation(.snappy) { form.setSize(width: size, height: size) } })
    }

    private var handicap: Binding<Int> {
        Binding(get: { form.handicap },
                set: { count in withAnimation(.snappy) { form.setHandicap(count) } })
    }

    private func restoreLastChoices() {
        // Once: a second `.onAppear` must not undo what the person has
        // changed since the sheet came up.
        guard !hasRestoredLastChoices else { return }
        hasRestoredLastChoices = true
        rung = Double(OpponentLadder.index(of: storedRankKind))
        form.chooseKind(kind)
        form.humanPlaysBlack = storedHumanPlaysBlack
        // A stored size the running engine can no longer hold (a smaller Max
        // Board Size since) falls back to the form's own capped default.
        if TVNewGameForm.quickSizes.contains(storedBoardSize),
           form.quickSizeEnabled(storedBoardSize) {
            form.setSize(width: storedBoardSize, height: storedBoardSize)
        }
    }

    private func start() {
        guard form.canStart else { return }
        storedRankKind = kind
        storedBoardSize = form.boardWidth
        storedHumanPlaysBlack = form.humanPlaysBlack
        onStart(form, showsHints)
    }
}

#Preview {
    NavigationStack {
        NewGameSheet(maxBoardLength: 19) { _, _ in }
    }
    .environment(GobanState())
}
