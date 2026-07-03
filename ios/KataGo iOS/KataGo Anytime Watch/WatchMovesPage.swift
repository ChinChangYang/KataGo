import SwiftUI
import KataGoGameStore

struct WatchMovesPage: View {
    @Environment(WatchLiveModel.self) private var model
    private let rankColors: [Color] = [.green, .yellow, .orange]

    var body: some View {
        let live = model.peek.entries.last
        List {
            if let live, live.analysisRunning, !live.candidates.isEmpty {
                ForEach(Array(live.candidates.prefix(3).enumerated()), id: \.element.vertex) { rank, c in
                    HStack {
                        Circle().fill(rankColors[min(rank, rankColors.count - 1)])
                            .frame(width: 8, height: 8)
                        Text(c.vertex).font(.system(.body, design: .monospaced)).bold()
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text(String(format: "%.0f%%", c.winrate * 100)).font(.caption)
                            Text(String(format: "%+.1f", c.scoreLead)).font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("Analysis off").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Top Moves")
    }
}
