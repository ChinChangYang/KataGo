import SwiftUI
import KataGoGameStore

struct WatchMovesPage: View {
    @Environment(WatchLiveModel.self) private var model
    private let rankColors: [Color] = [.green, .yellow, .orange]

    var body: some View {
        let live = model.latest
        List {
            if let live, live.analysisRunning, live.isHumanTurn == false {
                // Spec: when the side to move is AI-controlled the carousel is
                // replaced — no Play affordance, no genmove race.
                Label("AI is playing", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            } else if let live, live.analysisRunning, !live.candidates.isEmpty {
                ForEach(Array(live.candidates.prefix(3).enumerated()),
                        id: \.element.vertex) { rank, candidate in
                    if model.canPlayNow {
                        Button {
                            model.playCandidate(vertex: candidate.vertex)
                        } label: {
                            row(rank: rank, candidate: candidate)
                        }
                        .disabled(model.playPending)
                    } else {
                        row(rank: rank, candidate: candidate)
                    }
                }
            } else {
                Text("Analysis off").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Top Moves")
    }

    private func row(rank: Int, candidate: WatchSnapshot.Candidate) -> some View {
        HStack {
            Circle().fill(rankColors[min(rank, rankColors.count - 1)])
                .frame(width: 8, height: 8)
            Text(candidate.vertex).font(.system(.body, design: .monospaced)).bold()
            if model.canPlayNow {
                Image(systemName: "hand.tap").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text(String(format: "%.0f%%", candidate.winrate * 100)).font(.caption)
                Text(String(format: "%+.1f", candidate.scoreLead)).font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
