//
//  LastGameWidget.swift
//  KataGoAnytimeWatchWidget
//
//  The last game, at the position it is parked on: its name, the comment
//  written there, and the score.
//
//  This appex links KataGoAnalysisKit and NOTHING else. It must never touch
//  SwiftData: on watchOS the shared container takes the CloudKit-only branch
//  with no App Group, so an appex opening it would get a second, permanently
//  empty store — which is exactly why the watch app mirrors into UserDefaults
//  for this process to read.
//

import WidgetKit
import SwiftUI
import KataGoAnalysisKit

struct LastGameEntry: TimelineEntry {
    let date: Date
    let snapshot: WatchWidgetSnapshot?
    /// False when the App Group is unavailable — rendered differently from
    /// "no record yet", now that the tile claims to name a game.
    let storageAvailable: Bool
    /// The retired complication's score. Read for one release: immediately
    /// after the update nothing has written the new record yet, and the watch
    /// app can go days unopened.
    let legacyScoreLeadBlack: Double?
}

struct LastGameProvider: TimelineProvider {
    private func read(at date: Date) -> LastGameEntry {
        let defaults = WatchWidgetDefaults.sharedDefaults()
        let records = WatchWidgetDefaults.read(from: defaults)
        return LastGameEntry(date: date,
                             snapshot: records.resolved(now: date),
                             storageAvailable: defaults != nil,
                             legacyScoreLeadBlack:
                                WatchWidgetDefaults.legacyScoreLeadBlack(from: defaults))
    }

    func placeholder(in context: Context) -> LastGameEntry {
        LastGameEntry(date: .now,
                      snapshot: WatchWidgetSnapshot(
                        gameID: "", name: "Ladder Fight 3",
                        comment: "White's cut is the only move that keeps the corner alive.",
                        parkedIndex: 42, mainlineMoveCount: 178,
                        scoreLeadBlack: 3.5, isBranch: false,
                        capturedAt: .now, source: .library),
                      storageAvailable: true,
                      legacyScoreLeadBlack: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (LastGameEntry) -> Void) {
        // The gallery only needs a representative sample; reading the App
        // Group there would show one user's game name in a chooser.
        completion(context.isPreview ? placeholder(in: context) : read(at: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LastGameEntry>) -> Void) {
        // Bounded, never `.never`. Every real update arrives as an explicit
        // reloadTimelines from the watch app, but a tile showing a three-day-
        // old sentence with no self-healing path reads as truth, so it also
        // re-asks on its own.
        let entry = read(at: .now)
        completion(Timeline(entries: [entry],
                            policy: .after(WatchWidgetRefreshPolicy.nextReloadDate(after: entry.date))))
    }
}

struct LastGameWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    let entry: LastGameEntry

    var body: some View {
        content
            // One root for every family and every state, so the empty case is
            // laid out by the same rules as the populated one. The previous
            // tile applied this separately in each branch of an if/else around
            // a centered Text — fine for a numeral, wrong for a left-aligned
            // name above a paragraph.
            .containerBackground(.fill.tertiary, for: .widget)
            // Exactly one tap target: Link is unsupported in watchOS accessory
            // widgets. Because the URL and the rendered content come from the
            // same entry, a stale tile always opens the game it is showing.
            .widgetURL(tapURL)
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryInline:
            // System-rendered: font, tint and truncation are the face's, and
            // .font/.foregroundStyle/.lineLimit here would be silently
            // dropped. The writer already truncated.
            Text(inlineText)
        case .accessoryCircular:
            Text(circularText)
                .font(.system(.body, design: .rounded))
                .minimumScaleFactor(0.7)
                .widgetAccentable()
        default:
            rectangular
        }
    }

    // MARK: rectangular

    private var layout: WatchWidgetTileLayout {
        WatchWidgetTileText.layout(for: entry.snapshot,
                                   storageAvailable: entry.storageAvailable,
                                   luminanceReduced: isLuminanceReduced)
    }

    @ViewBuilder private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch layout {
            case .unavailable(let headline, let detail):
                unavailableBody(headline: headline, detail: detail)
            case .reduced:
                headerRow
                metaLine
            case .withoutComment:
                headerRow
                metaLine
            case .withComment:
                headerRow
                metaLine
                if let comment = entry.snapshot?.comment {
                    // No lineLimit on purpose: the body takes whatever height
                    // is left, so it renders two lines on a small watch and
                    // three on a large one instead of clipping a fixed stack.
                    Text(comment)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func unavailableBody(headline: String, detail: String?) -> some View {
        if let legacy = entry.legacyScoreLeadBlack,
           let score = WatchWidgetTileText.scoreText(legacy) {
            // Cutover window: no record yet, but the retired complication's
            // score is still in the App Group and beats a "no game" card.
            Text(score).font(.system(.headline, design: .monospaced))
        } else {
            Text(headline).font(.headline).lineLimit(1)
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var headerRow: some View {
        if let snapshot = entry.snapshot {
            HStack(spacing: 4) {
                Text(snapshot.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if let score = WatchWidgetTileText.scoreText(snapshot.scoreLeadBlack) {
                    // layoutPriority so the NAME yields, not the number: a
                    // half-truncated score is unreadable, a half-truncated
                    // name is still recognisable.
                    Text(score)
                        .font(.caption2.monospacedDigit())
                        .layoutPriority(1)
                        .widgetAccentable()
                }
            }
        }
    }

    @ViewBuilder private var metaLine: some View {
        if let snapshot = entry.snapshot {
            HStack(spacing: 4) {
                Text(WatchWidgetTileText.moveText(parkedIndex: snapshot.parkedIndex,
                                                  mainlineMoveCount: snapshot.mainlineMoveCount,
                                                  isBranch: snapshot.isBranch))
                Text("-")
                // Self-updating in a widget without a timeline entry, which is
                // what keeps the tile honest between reloads — and it is the
                // one signal that separates "the push never fired" from "the
                // reload was gated out" in a tester report.
                Text(snapshot.capturedAt, style: .relative)
                Spacer(minLength: 0)
                Image(systemName: snapshot.source == .live
                      ? "dot.radiowaves.left.and.right" : "icloud")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    // MARK: small families

    private var inlineText: String {
        if entry.snapshot == nil, let legacy = entry.legacyScoreLeadBlack,
           let score = WatchWidgetTileText.compactScoreText(legacy) {
            return score
        }
        return WatchWidgetTileText.inlineText(for: entry.snapshot)
    }

    private var circularText: String {
        if entry.snapshot == nil, let legacy = entry.legacyScoreLeadBlack,
           let score = WatchWidgetTileText.compactScoreText(legacy) {
            return score
        }
        return WatchWidgetTileText.circularText(for: entry.snapshot)
    }

    /// Built inline rather than by linking `GameDeepLink`: that type reaches
    /// `SharedModelContainer.appGroupID` and would drag the SwiftData tier into
    /// this appex. `GameDeepLink` stays the source of truth for the scheme and
    /// host — keep these three literals in sync with it.
    private var tapURL: URL? {
        guard let gameID = entry.snapshot?.gameID, !gameID.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "katago-anytime"
        components.host = "open-game"
        components.queryItems = [URLQueryItem(name: "id", value: gameID)]
        return components.url
    }
}

struct LastGameWidget: Widget {
    var body: some WidgetConfiguration {
        // The kind is deliberately the legacy identifier — see
        // WatchWidgetDefaults.widgetKind for why renaming it would orphan
        // placements and silently disable the phone's push.
        StaticConfiguration(kind: WatchWidgetDefaults.widgetKind,
                            provider: LastGameProvider()) { entry in
            LastGameWidgetView(entry: entry)
        }
        .configurationDisplayName("Last Game")
        .description("The name and comment at the position your last game is parked on.")
        .supportedFamilies([.accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}

#Preview("Rectangular, with comment", as: .accessoryRectangular) {
    LastGameWidget()
} timeline: {
    LastGameEntry(date: .now,
                  snapshot: WatchWidgetSnapshot(
                    gameID: "GAME-A", name: "Ladder Fight 3",
                    comment: "White's cut is the only move that keeps the corner alive.",
                    parkedIndex: 42, mainlineMoveCount: 178, scoreLeadBlack: 3.5,
                    isBranch: false, capturedAt: .now, source: .live),
                  storageAvailable: true, legacyScoreLeadBlack: nil)
}

#Preview("Rectangular, no comment (the default)", as: .accessoryRectangular) {
    LastGameWidget()
} timeline: {
    LastGameEntry(date: .now,
                  snapshot: WatchWidgetSnapshot(
                    gameID: "GAME-A", name: "Ladder Fight 3", comment: nil,
                    parkedIndex: 42, mainlineMoveCount: 178, scoreLeadBlack: 3.5,
                    isBranch: false, capturedAt: .now, source: .library),
                  storageAvailable: true, legacyScoreLeadBlack: nil)
}

#Preview("Rectangular, empty", as: .accessoryRectangular) {
    LastGameWidget()
} timeline: {
    LastGameEntry(date: .now, snapshot: nil, storageAvailable: true,
                  legacyScoreLeadBlack: nil)
}

#Preview("Inline", as: .accessoryInline) {
    LastGameWidget()
} timeline: {
    LastGameEntry(date: .now,
                  snapshot: WatchWidgetSnapshot(
                    gameID: "GAME-A", name: "Ladder Fight 3", comment: nil,
                    parkedIndex: 42, mainlineMoveCount: 178, scoreLeadBlack: 4.5,
                    isBranch: false, capturedAt: .now, source: .live),
                  storageAvailable: true, legacyScoreLeadBlack: nil)
}

#Preview("Circular", as: .accessoryCircular) {
    LastGameWidget()
} timeline: {
    LastGameEntry(date: .now,
                  snapshot: WatchWidgetSnapshot(
                    gameID: "GAME-A", name: "Ladder Fight 3", comment: nil,
                    parkedIndex: 42, mainlineMoveCount: 178, scoreLeadBlack: 21.8,
                    isBranch: false, capturedAt: .now, source: .live),
                  storageAvailable: true, legacyScoreLeadBlack: nil)
}
