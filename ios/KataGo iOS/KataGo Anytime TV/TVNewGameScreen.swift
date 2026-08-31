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
//  WHY DRILL-DOWN ROWS AND NOT PICKERS. A bare SwiftUI `Picker` on tvOS
//  renders as ONE squeezed horizontal segment row, so every option fights its
//  siblings for width and the long ones are truncated to glyph fragments: the
//  11 rulesets came out as "Chi... Chi... Jap... Kor..." (both Chinese presets
//  collapsing to the same fragment) and the 259 rank profiles as an illegible
//  bar. This screen therefore shows a one-row-per-setting SUMMARY
//  ("Ruleset ——— Chinese (OGS/KGS) ›") and pushes a full-screen chooser per
//  setting, where an option NEVER shares a horizontal line with a sibling —
//  that is what makes the layout indifferent to how long a label or a list is.
//
//  STANDING CONSTRAINT — NOTHING TRUNCATES AND NOTHING WRAPS, on this screen
//  or in any of its choosers. No `.lineLimit` ellipsis, no
//  `minimumScaleFactor`, and no string that would need a second line at its
//  widest real value ("Chinese (OGS/KGS)", "Pro 2023", "37 × 37",
//  "9 stones"). Labels and values are `.fixedSize()` so the flexible leader
//  line — never the text — absorbs the slack. Explanatory prose that cannot
//  fit one line is DELETED rather than shrunk: the Ruleset and Komi rows
//  visibly flipping to "Chinese" and "0.5" when a handicap is taken teach that
//  rule better than the wrapped paragraph that used to say it.
//
//  SELECTION COLOUR. A selected control is filled with `Color.tvWoodAccent`
//  (a light gold) and its label forced BLACK. The default white label on that
//  fill is invisible — that was the old quick-size buttons' bug.
//
//  tvOS has NO Stepper and NO Menu, so every control here is a Button or a
//  NavigationLink reached through the focus engine (no bare `.onTapGesture`);
//  the number ladders are grids of one-token cells for the same reason.
//
//  NAVIGATION. The choosers are pushed with `NavigationLink(value:)` onto
//  TVRootView's OWN `libraryPath` stack — this screen is itself a destination
//  on it, and a nested NavigationStack here would capture the Menu button so
//  it no longer pops one chooser at a time. Hence the file-scope
//  `TVNewGameChooser` route plus a single `.navigationDestination` on the
//  body, which attaches to the enclosing stack; each destination re-hides the
//  tab bar exactly the way TVRootView does for this screen.
//

import SwiftUI
import SwiftData
import KataGoUICore

/// Navigation token for the New Game screen, placed beside the screen it
/// routes to — mirrors `SelfPlayRoute` living beside `TVSelfPlayScreen`.
struct NewGameRoute: Hashable {}

/// Where a summary row pushes. File scope (not nested in the View) because
/// `NavigationLink(value:)` hands this to TVRootView's type-erased
/// `NavigationPath`, and `.customSize` is pushed from inside the `.boardSize`
/// destination — both resolve against the one `.navigationDestination` below.
private enum TVNewGameChooser: Hashable {
    case boardSize, customSize, ruleset, rank, handicap
}

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
            VStack(alignment: .leading, spacing: 14) {
                TVNewGameSummaryLink(
                    title: "Board Size",
                    value: "\(form.boardWidth) × \(form.boardHeight)",
                    route: .boardSize)

                TVNewGameSummaryLink(
                    title: "Ruleset",
                    value: form.ruleset.displayName,
                    route: .ruleset)

                // Read-only, between the two rows that move it: this is the
                // only place komi is ever visible on tvOS, and watching it drop
                // to 0.5 is how a handicap game explains itself.
                TVNewGameReadOnlyRow(title: "Komi", value: formattedKomi)

                TVNewGameSummaryLink(
                    title: "Handicap",
                    value: form.handicap == 0 ? "None" : "\(form.handicap) stones",
                    route: .handicap,
                    enabled: form.handicapPickerEnabled)

                TVNewGameSummaryLink(
                    title: "KataGo Rank",
                    value: form.rankProfile,
                    route: .rank)

                // Two values only, so this row flips in place instead of
                // pushing a chooser — one press beats two, and the swap glyph
                // (not a chevron) says the row acts rather than navigates.
                TVNewGameToggleRow(
                    title: "Your Color",
                    value: form.humanPlaysBlack ? "Black" : "White") {
                    form.humanPlaysBlack.toggle()
                }

                startButton
                    .padding(.top, 12)
            }
            .modifier(TVNewGamePageFrame())
        }
        .navigationTitle("Play KataGo")
        .navigationDestination(for: TVNewGameChooser.self) { chooser in
            destination(chooser)
                .toolbar(.hidden, for: .tabBar)
        }
        .onAppear {
            guard !didSeed else { return }
            didSeed = true
            form = TVNewGameForm(maxBoardLength: engine.maxBoardLength)
        }
    }

    /// `form.komi` is a Float; one decimal is what every komi in the presets
    /// needs ("7.5", "7.0", "0.5").
    private var formattedKomi: String {
        String(format: "%.1f", Double(form.komi))
    }

    // MARK: - Choosers

    @ViewBuilder
    private func destination(_ chooser: TVNewGameChooser) -> some View {
        switch chooser {
        case .boardSize:
            TVNewGameBoardSizeChooser(form: $form)
        case .customSize:
            TVNewGameCustomSizeChooser(form: $form)
        case .ruleset:
            TVNewGameRulesetChooser(form: $form)
        case .rank:
            TVNewGameRankChooser(form: $form)
        case .handicap:
            TVNewGameHandicapChooser(form: $form)
        }
    }

    // MARK: - Start

    private var startButton: some View {
        Button {
            startGame()
        } label: {
            Text("Start Game")
                .font(.title2.weight(.semibold))
                // Dark label on the wood fill unfocused; the focused white lift
                // also takes a dark label, so forcing black is safe in both.
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 76)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.tvWoodAccent)
        // Engine-FREE, deliberately: creating the record and opening its board
        // are pure record work (the SGF is written by the form, the board is
        // replayed from it), so a game can be started while the net is still
        // loading — the analysis line on the new board then reports the launch
        // — and while the engine is *Held* on a board too large for it, where
        // starting a smaller game is the way out of the hold. `canStart` is the
        // form's own rule, pinned by TVNewGameFormTests.
        .disabled(!form.canStart)
    }

    private func startGame() {
        // Guard again, independent of the button's `.disabled`: a stale focus
        // press or a screenshot-tool synthetic press must not slip through on
        // a form that cannot produce an SGF.
        guard let sgf = form.sgf else { return }
        let record = GameRecord.createGameRecord(sgf: sgf, name: form.suggestedName)
        form.apply(to: record.concreteConfig)
        modelContext.insert(record)
        try? modelContext.save()
        onStart(record)
    }
}

// MARK: - Board size chooser

/// Level one: the three quick sizes, plus a row that pushes the full ladders.
/// The 36-entry Width/Height lists deliberately do NOT live here — a chooser's
/// first level stays scannable from ten feet.
private struct TVNewGameBoardSizeChooser: View {
    @Binding var form: TVNewGameForm
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TVNewGameSectionLabel("Quick Sizes")

                ForEach(TVNewGameForm.quickSizes, id: \.self) { size in
                    TVNewGameOptionRow(
                        title: "\(size) × \(size)",
                        isSelected: form.boardWidth == size && form.boardHeight == size,
                        enabled: form.quickSizeEnabled(size)
                    ) {
                        form.setSize(width: size, height: size)
                        dismiss()
                    }
                }

                TVNewGameSectionLabel("Any Board")
                    .padding(.top, 10)

                // Carries the live size as its value, so a custom board still
                // reads back here even when no quick size is checked.
                TVNewGameSummaryLink(
                    title: "Custom Size…",
                    value: "\(form.boardWidth) × \(form.boardHeight)",
                    route: .customSize)
            }
            .modifier(TVNewGamePageFrame())
        }
        .navigationTitle("Board Size")
    }
}

/// Level two: one cell per line count, 2 up to the launched NN buffer's cap.
/// Picking does not pop — width and height are usually set together, so Menu
/// is the way out.
private struct TVNewGameCustomSizeChooser: View {
    @Binding var form: TVNewGameForm

    private enum Axis: Hashable { case width, height }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                band(.width)
                band(.height)
            }
            .modifier(TVNewGamePageFrame())
        }
        .navigationTitle("Custom Size")
    }

    private func band(_ axis: Axis) -> some View {
        let current = axis == .width ? form.boardWidth : form.boardHeight
        return VStack(alignment: .leading, spacing: 12) {
            TVNewGameSectionLabel(axis == .width ? "Width" : "Height")
            LazyVGrid(columns: TVNewGameGrid.columns(9), spacing: 14) {
                // `sizeCap` is clamped to at least 2 by the form, so this range
                // is always valid even on a 2-line engine buffer.
                ForEach(2...form.sizeCap, id: \.self) { lines in
                    TVNewGameCell(label: "\(lines)",
                                  isCurrent: lines == current,
                                  isChecked: lines == current) {
                        switch axis {
                        case .width: form.setSize(width: lines, height: form.boardHeight)
                        case .height: form.setSize(width: form.boardWidth, height: lines)
                        }
                    }
                }
            }
            .focusSection()
        }
    }
}

// MARK: - Ruleset chooser

/// Names only — one full-width row each, so "Chinese" and "Chinese (OGS/KGS)"
/// can never collapse into the same fragment again.
private struct TVNewGameRulesetChooser: View {
    @Binding var form: TVNewGameForm
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // `NewGameRuleset` is Equatable but neither Hashable nor
                // Identifiable (the AppKit editors index into `pickerCases`
                // instead of binding SwiftUI Pickers directly), so identity is
                // the offset into `rulesetChoices`, never the value.
                ForEach(Array(TVNewGameForm.rulesetChoices.enumerated()), id: \.offset) { _, ruleset in
                    TVNewGameOptionRow(title: ruleset.displayName,
                                       isSelected: ruleset == form.ruleset) {
                        form.setRuleset(ruleset)
                        dismiss()
                    }
                }
            }
            .modifier(TVNewGamePageFrame())
        }
        .navigationTitle("Ruleset")
    }
}

// MARK: - Handicap chooser

private struct TVNewGameHandicapChooser: View {
    @Binding var form: TVNewGameForm
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Only the counts this board has a star-point layout for; the
                // summary row is disabled outright when that is just "None".
                ForEach(form.availableHandicaps, id: \.self) { stones in
                    TVNewGameOptionRow(title: stones == 0 ? "None" : "\(stones) stones",
                                       isSelected: stones == form.handicap) {
                        form.setHandicap(stones)
                        dismiss()
                    }
                }
            }
            .modifier(TVNewGamePageFrame())
        }
        .navigationTitle("Handicap")
    }
}

// MARK: - Rank chooser

/// The 259 profiles are split by TYPE, not by scrolling: a three-way group
/// selector, then one card / two rank ladders / a decade-then-year two-step.
/// No single list on screen runs past 25 tokens.
private struct TVNewGameRankChooser: View {
    @Binding var form: TVNewGameForm
    @Environment(\.dismiss) private var dismiss

    /// Which group is on screen. Seeded from the saved rank, so opening the
    /// chooser always lands on the family the current value belongs to.
    @State private var group: TVNewGameRankGroup
    /// Which decade of pro years is on screen (Pro Era group only).
    @State private var decade: Int

    init(form: Binding<TVNewGameForm>) {
        _form = form
        let current = form.wrappedValue.rankProfile
        _group = State(initialValue: TVNewGameRankCatalog.group(for: current))
        _decade = State(initialValue: TVNewGameRankCatalog.decade(for: current))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                groupSelector
                content
            }
            .modifier(TVNewGamePageFrame())
        }
        .navigationTitle("KataGo Rank")
    }

    private var groupSelector: some View {
        HStack(spacing: 18) {
            ForEach(TVNewGameRankGroup.allCases) { candidate in
                TVNewGameGroupButton(
                    title: candidate.title,
                    isCurrent: candidate == group,
                    isChecked: candidate == TVNewGameRankCatalog.group(for: form.rankProfile)
                ) { group = candidate }
            }
        }
        .focusSection()
    }

    @ViewBuilder
    private var content: some View {
        switch group {
        case .ai:
            TVNewGameOptionRow(title: TVNewGameRankCatalog.aiProfile,
                               isSelected: form.rankProfile == TVNewGameRankCatalog.aiProfile) {
                pick(TVNewGameRankCatalog.aiProfile)
            }

        case .human:
            VStack(alignment: .leading, spacing: 20) {
                band("Dan", ranks: TVNewGameRankCatalog.dan)
                band("Kyu", ranks: TVNewGameRankCatalog.kyu)
            }

        case .proEra:
            VStack(alignment: .leading, spacing: 20) {
                TVNewGameSectionLabel("Decade")
                LazyVGrid(columns: TVNewGameGrid.columns(8), spacing: 14) {
                    ForEach(TVNewGameRankCatalog.decades, id: \.self) { candidate in
                        TVNewGameCell(
                            label: "\(candidate)s",
                            isCurrent: candidate == decade,
                            isChecked: TVNewGameRankCatalog.decade(containing: form.rankProfile) == candidate
                        ) { decade = candidate }
                    }
                }
                .focusSection()

                TVNewGameSectionLabel("\(decade)s")
                LazyVGrid(columns: TVNewGameGrid.columns(5), spacing: 14) {
                    ForEach(TVNewGameRankCatalog.entries(inDecade: decade)) { entry in
                        TVNewGameCell(label: entry.label,
                                      isCurrent: entry.profile == form.rankProfile,
                                      isChecked: entry.profile == form.rankProfile) {
                            pick(entry.profile)
                        }
                    }
                }
                .focusSection()
            }
        }
    }

    private func band(_ title: String, ranks: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TVNewGameSectionLabel(title)
            LazyVGrid(columns: TVNewGameGrid.columns(9), spacing: 14) {
                ForEach(ranks, id: \.self) { rank in
                    TVNewGameCell(label: rank,
                                  isCurrent: rank == form.rankProfile,
                                  isChecked: rank == form.rankProfile) {
                        pick(rank)
                    }
                }
            }
            .focusSection()
        }
    }

    private func pick(_ profile: String) {
        form.rankProfile = profile
        dismiss()
    }
}

private enum TVNewGameRankGroup: Int, CaseIterable, Identifiable {
    case ai, human, proEra

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .ai: return "Full Strength"
        case .human: return "Human Rank"
        case .proEra: return "Pro Era"
        }
    }
}

/// The pro-era entry the chooser's grid cells bind to: `RankCatalog.ProEntry`,
/// whose `label` is already the verbatim year string.
private typealias TVNewGameProEntry = RankCatalog.ProEntry

/// The three-way presentation this screen puts on top of the shared
/// `RankCatalog` partition (Full Strength / Human Rank / Pro Era). The
/// grouping itself — dan, kyu, pro years by decade — is the catalog's, shared
/// with the iOS long-press menu and the Mac rank menu.
private enum TVNewGameRankCatalog {
    static var aiProfile: String { RankCatalog.aiProfile }
    static var dan: [String] { RankCatalog.dan }
    static var kyu: [String] { RankCatalog.kyu }
    static var decades: [Int] { RankCatalog.decades }

    static func entries(inDecade start: Int) -> [TVNewGameProEntry] {
        RankCatalog.entries(inDecade: start)
    }

    static func group(for profile: String) -> TVNewGameRankGroup {
        if profile.hasPrefix("Pro ") { return .proEra }
        if dan.contains(profile) || kyu.contains(profile) { return .human }
        return .ai
    }

    /// The decade to show when the chooser opens: the selection's own decade,
    /// or the most recent one for a non-pro selection.
    static func decade(for profile: String) -> Int {
        decade(containing: profile) ?? decades.last ?? 2020
    }

    static func decade(containing profile: String) -> Int? {
        RankCatalog.decade(containing: profile)
    }
}

// MARK: - Building blocks

/// One "Label ——— Value ›" line, shared by the pushing rows, the flip row and
/// the read-only Komi row so every value lands in the same column.
private struct TVNewGameRowLine: View {
    let title: String
    let value: String
    /// `nil` on the read-only row: the trailing glyph is still laid out, just
    /// invisible, so the value column does not shift between rows.
    let glyph: String?

    var body: some View {
        HStack(alignment: .center, spacing: 26) {
            Text(title)
                .font(.title3.weight(.semibold))
                .fixedSize()
            // The leader line runs the eye from label to value across a very
            // wide 10-foot row, and is the ONLY flexible view here — with both
            // Texts at their ideal width, the stack can never truncate one.
            Rectangle()
                .frame(height: 2)
                .frame(maxWidth: .infinity)
                .opacity(0.18)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .fixedSize()
            Image(systemName: glyph ?? "chevron.right")
                .font(.title3)
                .opacity(glyph == nil ? 0 : 0.6)
        }
        .frame(minHeight: 68)
        .padding(.vertical, 4)
    }
}

/// A summary row that pushes a chooser onto the enclosing stack.
private struct TVNewGameSummaryLink: View {
    let title: String
    let value: String
    let route: TVNewGameChooser
    var enabled: Bool = true

    var body: some View {
        NavigationLink(value: route) {
            TVNewGameRowLine(title: title, value: value, glyph: "chevron.right")
        }
        .buttonStyle(.bordered)
        .disabled(!enabled)
    }
}

/// A summary row that flips its own value in place (Your Color).
private struct TVNewGameToggleRow: View {
    let title: String
    let value: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TVNewGameRowLine(title: title, value: value, glyph: "arrow.left.arrow.right")
        }
        .buttonStyle(.bordered)
    }
}

/// A summary row that only reports (Komi). Not a Button, so the focus engine
/// walks straight past it; the material background keeps it in the row rhythm.
private struct TVNewGameReadOnlyRow: View {
    let title: String
    let value: String

    var body: some View {
        TVNewGameRowLine(title: title, value: value, glyph: nil)
            .padding(.horizontal, 34)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22))
    }
}

/// One option in a chooser: checkmark plus the name, nothing else. Full width —
/// an option never shares a line with a sibling, which is what makes truncation
/// structurally impossible however long the name gets.
private struct TVNewGameOptionRow: View {
    let title: String
    let isSelected: Bool
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 22) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .opacity(isSelected ? 1 : 0.22)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .fixedSize()
                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .padding(.vertical, 4)
            .modifier(TVNewGameSelectedLabel(isSelected: isSelected))
        }
        .buttonStyle(.bordered)
        .tint(isSelected ? Color.tvWoodAccent : nil)
        .disabled(!enabled)
    }
}

/// One of the rank chooser's three family buttons.
private struct TVNewGameGroupButton: View {
    let title: String
    /// Gold fill — the family whose list is on screen.
    let isCurrent: Bool
    /// Checkmark — the family the saved rank belongs to.
    let isChecked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isChecked {
                    Image(systemName: "checkmark")
                        .font(.callout.weight(.bold))
                }
                Text(title)
                    .font(.title3.weight(.semibold))
                    .fixedSize()
            }
            .frame(maxWidth: .infinity, minHeight: 76)
            .modifier(TVNewGameSelectedLabel(isSelected: isCurrent))
        }
        .buttonStyle(.bordered)
        .tint(isCurrent ? Color.tvWoodAccent : nil)
    }
}

/// A grid cell for a short token: a rank ("5k"), a decade ("1990s"), a pro
/// year ("1997") or a line count ("37").
private struct TVNewGameCell: View {
    let label: String
    /// Gold fill — "you are here" (the saved value, or the decade on screen).
    let isCurrent: Bool
    /// Checkmark — this cell is, or contains, the saved value.
    var isChecked: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isChecked {
                    Image(systemName: "checkmark")
                        .font(.callout.weight(.bold))
                }
                Text(label)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .fixedSize()
            }
            .frame(maxWidth: .infinity, minHeight: 62)
            .modifier(TVNewGameSelectedLabel(isSelected: isCurrent))
        }
        .buttonStyle(.bordered)
        .tint(isCurrent ? Color.tvWoodAccent : nil)
    }
}

private struct TVNewGameSectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.secondary)
            .fixedSize()
    }
}

/// Forces a DARK label on the gold selected fill — a white label on
/// `tvWoodAccent` is invisible. Unselected labels are left at the system colour
/// so tvOS can invert them itself on the white focused background.
private struct TVNewGameSelectedLabel: ViewModifier {
    let isSelected: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isSelected {
            content.foregroundStyle(.black)
        } else {
            content
        }
    }
}

/// The shared page box: one measure for the summary and every chooser, so a
/// push never re-flows the row width under the viewer.
private struct TVNewGamePageFrame: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: 1420)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 60)
            .padding(.vertical, 24)
    }
}

private enum TVNewGameGrid {
    static func columns(_ count: Int, spacing: CGFloat = 14) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing), count: count)
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
