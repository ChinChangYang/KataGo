import WidgetKit
import SwiftUI

/// Smart Stack / complication tile: the live analysis score lead, colored by
/// leader, marked stale after 10 minutes without an update. Data arrives via
/// the watch-local App Group, written by WatchLiveModel; timeline reloads are
/// pushed by the watch app (WidgetCenter), so the provider itself is trivial.
struct ScoreLeadEntry: TimelineEntry {
    let date: Date
    let scoreLeadBlack: Double?
    let updatedAt: Date?
}

struct ScoreLeadProvider: TimelineProvider {
    static let appGroupID = "group.chinchangyang.KataGo-iOS.tw"

    func read(at date: Date) -> ScoreLeadEntry {
        let defaults = UserDefaults(suiteName: Self.appGroupID)
        let score = defaults?.object(forKey: "watchScoreLeadBlack") as? Double
        let updated = defaults?.object(forKey: "watchScoreUpdatedAt") as? Date
        return ScoreLeadEntry(date: date, scoreLeadBlack: score, updatedAt: updated)
    }

    func placeholder(in context: Context) -> ScoreLeadEntry {
        ScoreLeadEntry(date: .now, scoreLeadBlack: 4.5, updatedAt: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (ScoreLeadEntry) -> Void) {
        completion(read(at: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ScoreLeadEntry>) -> Void) {
        let current = read(at: .now)
        var entries = [current]
        // The tile is "fresh" until 600 s past the last update. With a single
        // entry WidgetKit never re-renders, so it stays fresh forever. Add a
        // second entry (same data) dated at the staleness boundary so the tile
        // flips to stale styling when analysis stops. App pushes still drive
        // fresh reloads, so keep the policy `.never`.
        if let updatedAt = current.updatedAt {
            let staleAt = updatedAt.addingTimeInterval(600)
            if staleAt > .now {
                entries.append(ScoreLeadEntry(date: staleAt,
                                              scoreLeadBlack: current.scoreLeadBlack,
                                              updatedAt: current.updatedAt))
            }
        }
        completion(Timeline(entries: entries, policy: .never))
    }
}

struct ScoreLeadWidgetView: View {
    let entry: ScoreLeadEntry

    private var isStale: Bool {
        guard let updatedAt = entry.updatedAt else { return true }
        return entry.date.timeIntervalSince(updatedAt) >= 600 // >= : the stale-boundary timeline entry is dated exactly +600
    }

    var body: some View {
        if let score = entry.scoreLeadBlack {
            let text = score >= 0 ? String(format: "B+%.1f", score)
                                  : String(format: "W+%.1f", -score)
            Text(text)
                .font(.system(.headline, design: .monospaced))
                .foregroundStyle(isStale ? .secondary : (score >= 0 ? .primary : .secondary))
                .containerBackground(.fill.tertiary, for: .widget)
        } else {
            Text("—").containerBackground(.fill.tertiary, for: .widget)
        }
    }
}

struct ScoreLeadWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ScoreLeadWidget", provider: ScoreLeadProvider()) {
            ScoreLeadWidgetView(entry: $0)
        }
        .configurationDisplayName("Score Lead")
        .description("Live score lead while analysis runs on your iPhone.")
        .supportedFamilies([.accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}
