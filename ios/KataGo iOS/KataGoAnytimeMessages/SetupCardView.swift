//
//  SetupCardView.swift
//  KataGoAnytimeMessages
//
//  Full game setup: board size (9/13/19 quick buttons + free width/height,
//  rectangles allowed), color, handicap, ruleset presets, and every rule
//  knob the app itself has (ko / scoring / tax / suicide / button / white
//  handicap bonus / komi).
//

import SwiftUI
import GoRulesKit
import KataGoGameStore

struct GameSetup {
    var width: Int
    var height: Int
    var handicap: Int
    var creatorColor: GoColor
    var rules: GoRules
}

struct RulesPreset: Identifiable, Equatable {
    let id: String
    let rules: GoRules

    static let all: [RulesPreset] = [
        RulesPreset(id: "Chinese", rules: .chinese),
        RulesPreset(id: "Japanese", rules: .japanese),
        RulesPreset(id: "Korean", rules: .korean),
        RulesPreset(id: "AGA", rules: .aga),
        RulesPreset(id: "New Zealand", rules: .newZealand),
        RulesPreset(id: "Tromp-Taylor", rules: .trompTaylor),
        RulesPreset(id: "Stone Scoring", rules: .stoneScoring),
    ]

    /// The preset matching `rules` ignoring komi, or nil for custom knobs.
    static func matching(_ rules: GoRules) -> RulesPreset? {
        all.first { preset in
            var withKomi = preset.rules
            withKomi.komi = rules.komi
            return withKomi == rules
        }
    }
}

struct SetupCardView: View {
    let start: (GameSetup) -> Void

    @State private var width = 19
    @State private var height = 19
    @State private var handicap = 0
    @State private var creatorColor: GoColor = .black
    @State private var rules: GoRules = .chinese

    private var maxHandicap: Int { GoGame.maxHandicap(width: width, height: height) }

    var body: some View {
        NavigationStack {
            Form {
                boardSection
                playersSection
                rulesSection
            }
            .navigationTitle("New Game")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        start(GameSetup(
                            width: width, height: height,
                            handicap: min(handicap, maxHandicap) == handicap ? handicap : 0,
                            creatorColor: creatorColor, rules: rules))
                    }
                }
            }
        }
    }

    private var boardSection: some View {
        Section("Board") {
            HStack {
                ForEach([9, 13, 19], id: \.self) { size in
                    Button("\(size)×\(size)") {
                        width = size
                        height = size
                    }
                    .buttonStyle(.bordered)
                    .tint(width == size && height == size ? .accentColor : .secondary)
                }
            }
            Stepper("Width: \(width)", value: $width, in: 2...37)
            Stepper("Height: \(height)", value: $height, in: 2...37)
        }
    }

    private var playersSection: some View {
        Section("Players") {
            Picker("You play", selection: $creatorColor) {
                Text("Black").tag(GoColor.black)
                Text("White").tag(GoColor.white)
            }
            .pickerStyle(.segmented)
            Picker("Handicap", selection: $handicap) {
                Text("None").tag(0)
                ForEach(2...max(2, maxHandicap), id: \.self) { n in
                    Text("\(n) stones").tag(n)
                }
            }
            .disabled(maxHandicap < 2)
            if handicap > 0 {
                Text("Black places \(handicap) handicap stones; White moves first.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: width) { clampHandicap() }
        .onChange(of: height) { clampHandicap() }
    }

    private var rulesSection: some View {
        Section("Rules") {
            Picker("Ruleset", selection: presetBinding) {
                ForEach(RulesPreset.all) { preset in
                    Text(preset.id).tag(preset.id)
                }
                if RulesPreset.matching(rules) == nil {
                    Text("Custom").tag("Custom")
                }
            }
            Stepper("Komi: \(rules.komi.formatted())", value: $rules.komi, in: -50...150, step: 0.5)
            DisclosureGroup("Advanced") {
                Picker("Ko", selection: $rules.koRule) {
                    Text("Simple").tag(KoRule.simple)
                    Text("Positional superko").tag(KoRule.positional)
                    Text("Situational superko").tag(KoRule.situational)
                }
                Picker("Scoring", selection: $rules.scoringRule) {
                    Text("Area").tag(ScoringRule.area)
                    Text("Territory").tag(ScoringRule.territory)
                }
                Picker("Tax", selection: $rules.taxRule) {
                    Text("None").tag(TaxRule.none)
                    Text("Seki").tag(TaxRule.seki)
                    Text("All (group tax)").tag(TaxRule.all)
                }
                Toggle("Multi-stone suicide legal", isOn: $rules.multiStoneSuicideLegal)
                Toggle("Button Go", isOn: buttonBinding)
                Picker("White handicap bonus", selection: $rules.whiteHandicapBonusRule) {
                    Text("None").tag(WhiteHandicapBonusRule.zero)
                    Text("N stones").tag(WhiteHandicapBonusRule.n)
                    Text("N−1 stones").tag(WhiteHandicapBonusRule.n_minus_one)
                }
            }
        }
    }

    private var presetBinding: Binding<String> {
        Binding(
            get: { RulesPreset.matching(rules)?.id ?? "Custom" },
            set: { id in
                if let preset = RulesPreset.all.first(where: { $0.id == id }) {
                    rules = preset.rules
                }
            })
    }

    /// The button only exists under area scoring; keep the invariant while
    /// editing knobs directly.
    private var buttonBinding: Binding<Bool> {
        Binding(
            get: { rules.hasButton },
            set: { rules.hasButton = $0 && rules.scoringRule == .area })
    }

    private func clampHandicap() {
        if handicap > maxHandicap { handicap = 0 }
    }
}
