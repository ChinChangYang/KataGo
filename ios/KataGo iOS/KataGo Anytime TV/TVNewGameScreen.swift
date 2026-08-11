//
//  TVNewGameScreen.swift
//  KataGo Anytime TV
//
//  "Play KataGo" setup: board size, ruleset, KataGo's rank, handicap, and the
//  human's color, then a Start Game button that creates the SwiftData record
//  and hands off to the library stack (which routes a fresh asymmetric
//  record straight into TVPlayScreen). A thin shell over the shared
//  `TVNewGameForm` (KataGoUICore/Util) — all validation and SGF assembly live
//  there, unit-tested on the iOS Simulator target; this file is only layout.
//
//  tvOS has NO Stepper, so every control here is a Picker or Button through
//  the focus engine (no bare `.onTapGesture`). Matches TVSettingsScreen's
//  section/typography idiom; the multi-option Pickers push lists on tvOS —
//  that is the expected interaction, not a bug to fight.
//

import SwiftUI
import SwiftData
import KataGoUICore

/// Navigation token for the New Game screen, placed beside the screen it
/// routes to — mirrors `SelfPlayRoute` living beside `TVSelfPlayScreen`.
struct NewGameRoute: Hashable {}

struct TVNewGameScreen: View {
    /// Called once the record is created and inserted — the caller (TVRootView)
    /// replaces this screen with the new record on the library stack.
    let onStart: (GameRecord) -> Void

    @Environment(TVEngineController.self) private var engine
    @Environment(\.modelContext) private var modelContext

    /// Seeded from `engine.maxBoardLength` on first appear — the environment
    /// engine is unavailable in `init`, so the placeholder `19` here only
    /// ever shows for one frame before `onAppear` reseeds it.
    @State private var form = TVNewGameForm(maxBoardLength: 19)
    @State private var didSeed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                boardSizeSection
                rulesetSection
                rankSection
                handicapSection
                colorSection
                startButton
            }
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
        .navigationTitle("Play KataGo")
        .onAppear {
            guard !didSeed else { return }
            didSeed = true
            form = TVNewGameForm(maxBoardLength: engine.maxBoardLength)
        }
    }

    // MARK: - Board Size

    private var boardSizeSection: some View {
        section("Board Size") {
            HStack(spacing: 14) {
                ForEach(TVNewGameForm.quickSizes, id: \.self) { size in
                    Button {
                        form.setSize(width: size, height: size)
                    } label: {
                        Text("\(size)×\(size)")
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.bordered)
                    .tint(isQuickSizeSelected(size) ? Color.tvWoodAccent : nil)
                    .disabled(!form.quickSizeEnabled(size))
                }
            }

            HStack(spacing: 24) {
                Picker("Width", selection: Binding(
                    get: { form.boardWidth },
                    set: { form.setSize(width: $0, height: form.boardHeight) })) {
                    ForEach(2...form.sizeCap, id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Height", selection: Binding(
                    get: { form.boardHeight },
                    set: { form.setSize(width: form.boardWidth, height: $0) })) {
                    ForEach(2...form.sizeCap, id: \.self) { Text("\($0)").tag($0) }
                }
            }

            if form.sizeCap < 19 {
                Text("Boards up to \(form.sizeCap)×\(form.sizeCap) with the current Max Board Size — raise it in the Settings tab for more.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func isQuickSizeSelected(_ size: Int) -> Bool {
        form.boardWidth == size && form.boardHeight == size
    }

    // MARK: - Ruleset

    /// `NewGameRuleset` isn't `Hashable` (only `Equatable` — the AppKit
    /// editors index into `pickerCases` instead of binding SwiftUI Pickers
    /// directly), so the selection is carried as an index into
    /// `rulesetChoices` rather than the enum itself.
    private var rulesetIndexBinding: Binding<Int> {
        Binding(
            get: { TVNewGameForm.rulesetChoices.firstIndex(of: form.ruleset) ?? 0 },
            set: { form.setRuleset(TVNewGameForm.rulesetChoices[$0]) })
    }

    private var rulesetSection: some View {
        section("Ruleset") {
            Picker("Ruleset", selection: rulesetIndexBinding) {
                ForEach(Array(TVNewGameForm.rulesetChoices.enumerated()), id: \.offset) { index, ruleset in
                    Text(ruleset.displayName).tag(index)
                }
            }
        }
    }

    // MARK: - KataGo Rank

    private var rankSection: some View {
        section("KataGo Rank") {
            Picker("KataGo Rank", selection: $form.rankProfile) {
                ForEach(TVNewGameForm.rankChoices, id: \.self) { rank in
                    Text(rank).tag(rank)
                }
            }
        }
    }

    // MARK: - Handicap

    private var handicapSection: some View {
        section("Handicap") {
            Picker("Handicap", selection: Binding(
                get: { form.handicap },
                set: { form.setHandicap($0) })) {
                ForEach(form.availableHandicaps, id: \.self) { n in
                    Text(n == 0 ? "None" : "\(n) stones").tag(n)
                }
            }
            .disabled(!form.handicapPickerEnabled)

            Text(form.handicapPickerEnabled
                 ? "Handicap stones go to Black; komi becomes 0.5, and unless you pick a ruleset the rules switch to Chinese, which compensates White one point per stone."
                 : "This board size has no star-point layout for handicap stones.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Your Color

    private var colorSection: some View {
        section("Your Color") {
            Picker("Your Color", selection: $form.humanPlaysBlack) {
                Text("Black").tag(true)
                Text("White").tag(false)
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Start

    private var startButton: some View {
        Button {
            startGame()
        } label: {
            Text("Start Game")
                .frame(maxWidth: .infinity, minHeight: 60)
        }
        .buttonStyle(.borderedProminent)
        .disabled(form.sgf == nil || engine.phase != .running)
    }

    private func startGame() {
        // Guard again, independent of the button's `.disabled`: a stale focus
        // press or a screenshot-tool synthetic press must not slip through if
        // the engine dropped out of `.running` between renders.
        guard engine.phase == .running, let sgf = form.sgf else { return }
        let record = GameRecord.createGameRecord(sgf: sgf, name: form.suggestedName)
        form.apply(to: record.concreteConfig)
        modelContext.insert(record)
        try? modelContext.save()
        onStart(record)
    }

    // MARK: - Section chrome (matches TVSettingsScreen)

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 26))
        }
    }
}

// MARK: - Previews

// #Preview bodies still compile in Release, and the TVPreviewData fixtures are
// DEBUG-only — guard the whole section or archiving fails.
#if DEBUG
#Preview("New Game") {
    NavigationStack {
        TVNewGameScreen(onStart: { _ in })
    }
    .modelContainer(TVPreviewData.container(games: []))
    .environment(TVEngineController())
}
#endif
