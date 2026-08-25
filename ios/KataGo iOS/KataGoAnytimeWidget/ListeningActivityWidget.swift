//
//  ListeningActivityWidget.swift
//  KataGoAnytimeWidget
//
//  Renders the Listening Session's Live Activity: lock screen, Dynamic
//  Island, and — via the `.small` supplemental family — the watch Smart
//  Stack and the iOS 26 CarPlay Dashboard, which mirrors a running Live
//  Activity with no CarPlay entitlement. Bridge-free by construction: the
//  attributes live in KataGoGameStore and carry three small fields.
//

#if os(iOS)
import ActivityKit
import WidgetKit
import SwiftUI
import KataGoGameStore

struct ListeningActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ListeningActivityAttributes.self) { context in
            ListeningActivityView(context: context)
                .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Listen", systemImage: "headphones")
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    playStateImage(isPlaying: context.state.isPlaying)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.gameName)
                            .font(.headline)
                            .lineLimit(1)
                        moveLine(state: context.state, totalMoves: context.attributes.totalMoves)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "headphones")
            } compactTrailing: {
                Text("\(context.state.moveNumber)")
                    .monospacedDigit()
            } minimal: {
                Image(systemName: "headphones")
            }
        }
        .supplementalActivityFamilies([.small])
    }

    private func playStateImage(isPlaying: Bool) -> some View {
        Image(systemName: isPlaying ? "play.fill" : "pause.fill")
            .foregroundStyle(.secondary)
    }

    private func moveLine(state: ListeningActivityAttributes.ContentState,
                          totalMoves: Int) -> Text {
        var line = "Move \(state.moveNumber) of \(totalMoves)"
        if let score = state.scoreLeadText { line += "  ·  \(score)" }
        return Text(line)
    }
}

/// One layout serves the lock screen and, through `activityFamily`, the
/// `.small` card CarPlay and the watch render — nothing here may truncate
/// into meaninglessness at card size, so the name and the move line are the
/// whole story.
private struct ListeningActivityView: View {
    @Environment(\.activityFamily) private var activityFamily
    let context: ActivityViewContext<ListeningActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Listen", systemImage: "headphones")
                    .font(activityFamily == .small ? .caption.bold() : .headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: context.state.isPlaying ? "play.fill" : "pause.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(context.state.isPlaying ? "Playing" : "Paused")
            }
            Text(context.attributes.gameName)
                .font(activityFamily == .small ? .subheadline.bold() : .title3.bold())
                .lineLimit(1)
            HStack(spacing: 6) {
                Text("Move \(context.state.moveNumber) of \(context.attributes.totalMoves)")
                    .monospacedDigit()
                if let score = context.state.scoreLeadText {
                    Text(score)
                        .foregroundStyle(.secondary)
                }
            }
            .font(activityFamily == .small ? .caption : .subheadline)
        }
    }
}
#endif
