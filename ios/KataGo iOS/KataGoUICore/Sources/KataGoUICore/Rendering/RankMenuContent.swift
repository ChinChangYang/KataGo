//
//  RankMenuContent.swift
//  KataGoUICore
//
//  Feedback 2026-08-31: "I wish to choose rank when I long press the 'rank'
//  button above the board." The player label's context menu: the ladder
//  grouped by `RankCatalog` so 259 entries never appear as one list: Full
//  Strength, Dan (9), Kyu (25), and Pro by decade then year (224).
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
        item(RankCatalog.aiProfile, title: RankCatalog.aiTitle)
        Menu("Dan") {
            ForEach(RankCatalog.dan, id: \.self) { item($0, title: $0) }
        }
        Menu("Kyu") {
            ForEach(RankCatalog.kyu, id: \.self) { item($0, title: $0) }
        }
        Menu("Pro") {
            ForEach(RankCatalog.decades, id: \.self) { decade in
                Menu {
                    ForEach(RankCatalog.entries(inDecade: decade)) { entry in
                        item(entry.profile, title: entry.label)
                    }
                } label: {
                    Text(verbatim: RankCatalog.decadeLabel(decade))
                }
            }
        }
    }

    /// One pick. `Text(verbatim:)` throughout: a rank like "1997" must never
    /// take the LocalizedStringKey path and render "1,997".
    private func item(_ profile: String, title: String) -> some View {
        Button {
            onChoose(profile)
        } label: {
            if profile == current {
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
