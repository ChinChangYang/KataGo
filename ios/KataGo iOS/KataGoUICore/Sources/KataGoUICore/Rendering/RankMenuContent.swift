//
//  RankMenuContent.swift
//  KataGoUICore
//
//  Feedback 2026-08-31: "I wish to choose rank when I long press the 'rank'
//  button above the board." The player label's context menu: the ladder
//  grouped by `RankCatalog`: Full Strength, Dan (9), Kyu (25), and Pro by
//  decade then year (224). A rank pick keeps the side's style year (ADR
//  0019); a pro pick names its year outright.
//
//  Content only. The host (`StoneView`) owns the gesture and the handler, so
//  the same tree could hang off any control; `ConfigEngineSync.chooseRank`
//  owns what a pick does to the game and the engine.
//

import SwiftUI

public struct RankMenuContent: View {
    /// The side's current profile, already canonical
    /// (`HumanSLModel.canonicalProfile`) so a legacy stored string still
    /// finds its checkmark.
    let current: String
    let onChoose: (String) -> Void

    public init(current: String, onChoose: @escaping (String) -> Void) {
        self.current = current
        self.onChoose = onChoose
    }

    public var body: some View {
        kindItem(RankCatalog.aiProfile, title: RankCatalog.aiTitle)
        Menu("Dan") {
            ForEach(RankCatalog.dan, id: \.self) { kindItem($0, title: $0) }
        }
        Menu("Kyu") {
            ForEach(RankCatalog.kyu, id: \.self) { kindItem($0, title: $0) }
        }
        Menu("Pro") {
            ForEach(RankCatalog.decades, id: \.self) { decade in
                Menu {
                    ForEach(RankCatalog.entries(inDecade: decade)) { entry in
                        item(entry.profile, title: entry.label, isChecked: entry.profile == current)
                    }
                } label: {
                    Text(verbatim: RankCatalog.decadeLabel(decade))
                }
            }
        }
    }

    /// A kind pick (Full Strength or a rank): the side keeps its style year.
    private func kindItem(_ kind: String, title: String) -> some View {
        item(RankCatalog.profile(choosing: kind, from: current),
             title: title,
             isChecked: RankCatalog.isCurrent(kind: kind, current: current))
    }

    /// One pick. `Text(verbatim:)` throughout: a rank like "1997" must never
    /// take the LocalizedStringKey path and render "1,997".
    private func item(_ profile: String, title: String, isChecked: Bool) -> some View {
        Button {
            onChoose(profile)
        } label: {
            if isChecked {
                Label {
                    Text(verbatim: title)
                } icon: {
                    Image(systemName: "checkmark")
                }
            } else {
                Text(verbatim: title)
            }
        }
    }
}
