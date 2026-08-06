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
        return LastGameEntry(date: date,
                             snapshot: WatchWidgetDefaults.read(from: defaults).library,
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
                        capturedAt: .now),
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
                                   legacyScoreLeadBlack: entry.legacyScoreLeadBlack,
                                   storageAvailable: entry.storageAvailable,
                                   luminanceReduced: isLuminanceReduced)
    }

    @ViewBuilder private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch layout {
            case .unavailable(let headline, let detail):
                unavailableBody(headline: headline, detail: detail)
            case .legacyScore(let score):
                // Cutover window: no record yet, but the retired
                // complication's score is still in the App Group and beats a
                // "no game" card. Keeps the monospaced styling the score
                // always had here.
                Text(score).font(.system(.headline, design: .monospaced))
            case .reduced:
                headerRow
                metaLine
            case .withoutComment:
                headerRow
                metaLine
            case .withComment:
                headerRow
                if let comment = entry.snapshot?.comment {
                    // `fixedSize` is what makes the body WRAP at all. Without
                    // it this Text is proposed an unbounded width, lays out as
                    // one long line and truncates at the tile edge — roughly
                    // 25 characters of a comment capped at 256. Neither a
                    // lineLimit nor a maxWidth frame fixes that; both were
                    // measured doing nothing.
                    //
                    // But a widget cannot scroll, so a body that then demands
                    // its full ideal height CLIPS the rows above it — measured:
                    // an uncapped 256-character comment ate the name row. Three
                    // is the budget that fills a 40mm tile under this header
                    // without spilling. ViewThatFits does NOT work here: inside
                    // this VStack it is proposed less height than the stack
                    // actually grants and picks 1 line even where 3 fit.
                    commentBody(comment, lines: 3)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func commentBody(_ comment: String, lines: Int) -> some View {
        Text(comment)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(lines)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func unavailableBody(headline: String, detail: String?) -> some View {
        // The legacy-score cutover fallback is a distinct `WatchWidgetTileLayout`
        // case now (`.legacyScore`), handled above in `rectangular` — this body
        // only ever renders a genuine unavailable state.
        Text(headline).font(.headline).lineLimit(1)
        if let detail {
            // Same wrap trap as the comment body: without `fixedSize` this
            // rendered "Open KataGo Anytim…" — an instruction cut mid-word,
            // which is the one string a user with no games has to be able
            // to read.
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
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
            // No relative-date Text here, deliberately. One reserved width
            // for the widest value it could EVER show — not the value it
            // is showing — and it squeezed this row's only real content
            // down to a bare "Move…" at every size, 46mm included. The
            // move number is the position identity the tile exists to
            // name, so the age is what leaves. Cost, recorded honestly:
            // the tile no longer self-reports staleness between reloads.
            Text(WatchWidgetTileText.moveText(parkedIndex: snapshot.parkedIndex,
                                              mainlineMoveCount: snapshot.mainlineMoveCount,
                                              isBranch: snapshot.isBranch))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: small families

    private var inlineText: String {
        WatchWidgetTileText.inlineText(for: entry.snapshot,
                                       legacyScoreLeadBlack: entry.legacyScoreLeadBlack)
    }

    private var circularText: String {
        WatchWidgetTileText.circularText(for: entry.snapshot,
                                         legacyScoreLeadBlack: entry.legacyScoreLeadBlack)
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
                    // A comment at the 256-character cap, not a short one: the
                    // short fixture this preview used to carry hid the fact
                    // that the body was rendering a single truncated line.
                    comment: WatchWidgetSnapshot.cappedComment(
                        String(repeating: "White's cut is the only move that keeps the corner "
                               + "alive, and Black must answer at the 3-3 point first. ",
                               count: 4)),
                    parkedIndex: 42, mainlineMoveCount: 178, scoreLeadBlack: 3.5,
                    isBranch: false, capturedAt: .now),
                  storageAvailable: true, legacyScoreLeadBlack: nil)
}

#Preview("Rectangular, no comment (the default)", as: .accessoryRectangular) {
    LastGameWidget()
} timeline: {
    LastGameEntry(date: .now,
                  snapshot: WatchWidgetSnapshot(
                    gameID: "GAME-A", name: "Ladder Fight 3", comment: nil,
                    parkedIndex: 42, mainlineMoveCount: 178, scoreLeadBlack: 3.5,
                    isBranch: false, capturedAt: .now),
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
                    isBranch: false, capturedAt: .now),
                  storageAvailable: true, legacyScoreLeadBlack: nil)
}

#Preview("Circular", as: .accessoryCircular) {
    LastGameWidget()
} timeline: {
    LastGameEntry(date: .now,
                  snapshot: WatchWidgetSnapshot(
                    gameID: "GAME-A", name: "Ladder Fight 3", comment: nil,
                    parkedIndex: 42, mainlineMoveCount: 178, scoreLeadBlack: 21.8,
                    isBranch: false, capturedAt: .now),
                  storageAvailable: true, legacyScoreLeadBlack: nil)
}
