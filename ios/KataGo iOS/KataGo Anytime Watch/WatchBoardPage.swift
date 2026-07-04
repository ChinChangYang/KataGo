import SwiftUI
import KataGoGameStore

struct WatchBoardPage: View {
    @Environment(WatchLiveModel.self) private var model
    @State private var crownIndex: Double = 0

    var body: some View {
        let peek = model.peek
        let cursorMode = model.sharedCursorAvailable
        let shown = cursorMode ? cursorFrame : peek.current
        let previous = (!cursorMode && peek.entries.indices.contains(peek.viewIndex - 1))
            ? peek.entries[peek.viewIndex - 1] : nil

        VStack(spacing: 2) {
            if let s = shown {
                WidgetBoardView(
                    width: s.boardWidth, height: s.boardHeight,
                    blackVertices: s.blackStones, whiteVertices: s.whiteStones,
                    // Cursor mode: the host analyzes the shown position, so
                    // candidates are always current. Ring mode keeps v0's
                    // live-only rule.
                    candidateVertices: (cursorMode || peek.isLive)
                        ? s.candidates.prefix(3).map(\.vertex) : [],
                    lastMoveVertex: cursorMode ? nil
                        : WatchPeekBuffer.lastMoveVertex(previous: previous, current: s))
                .aspectRatio(CGFloat(s.boardWidth) / CGFloat(s.boardHeight), contentMode: .fit)

                // Two-tone winrate bar (Black share from the left) + score lead.
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        Rectangle().fill(.black)
                            .frame(width: geo.size.width * CGFloat(s.rootWinrateBlack))
                        Rectangle().fill(.white)
                    }
                }
                .frame(height: 4)
                .clipShape(Capsule())

                Text(scoreText(s.rootScoreLeadBlack))
                    .font(.system(.headline, design: .monospaced))
            }
        }
        .overlay(alignment: .top) { statusPill }
        .focusable()
        .digitalCrownRotation($crownIndex,
                              from: 0, through: crownUpperBound,
                              by: 1, sensitivity: .medium,
                              isContinuous: false, isHapticFeedbackEnabled: true)
        .onChange(of: crownIndex) { _, newValue in
            let target = Int(newValue.rounded())
            if model.sharedCursorAvailable {
                model.scrub(to: target)
            } else {
                // A crown event can land after sharedCursorAvailable flips
                // false but before this mode-flip re-anchors the crown, so
                // `target` may still be a host-space value — clamp into the
                // ring's own bounds rather than indexing out of range.
                model.peek.viewIndex = min(target, max(model.peek.entries.count - 1, 0))
            }
        }
        .onChange(of: peek.viewIndex, initial: true) { _, newValue in
            // Ring mode: keep the crown in sync when ingest re-pins live.
            guard !model.sharedCursorAvailable else { return }
            if Int(crownIndex.rounded()) != newValue { crownIndex = Double(newValue) }
        }
        .onChange(of: model.latest?.hostMoveIndex) { _, newIndex in
            // Cursor mode: follow host-side navigation (e.g. phone buttons)
            // while no watch-initiated target is pending.
            guard model.sharedCursorAvailable, model.cursorPendingTarget == nil,
                  let newIndex else { return }
            if Int(crownIndex.rounded()) != newIndex { crownIndex = Double(newIndex) }
        }
        .onChange(of: model.sharedCursorAvailable, initial: true) { _, available in
            // Mode flip: re-anchor the crown in the new coordinate space.
            crownIndex = available
                ? Double(model.latest?.hostMoveIndex ?? 0)
                : Double(model.peek.viewIndex)
        }
    }

    private var crownUpperBound: Double {
        model.sharedCursorAvailable
            ? Double(model.latest?.hostMoveCount ?? 0)
            : Double(max(model.peek.entries.count - 1, 0))
    }

    /// Optimistic render for the crown's target: the live frame when the
    /// crown is at the host position, else the freshest cached frame for that
    /// index, else the live frame while the iPhone catches up.
    private var cursorFrame: WatchSnapshot? {
        guard let latest = model.latest else { return nil }
        let target = Int(crownIndex.rounded())
        if target == latest.hostMoveIndex { return latest }
        return model.peek.entry(forHostIndex: target, gameID: latest.hostGameID) ?? latest
    }

    @ViewBuilder private var statusPill: some View {
        let peek = model.peek
        if model.isStale, let at = model.receivedAt ?? model.latest.map(\.hostTimestamp) {
            Label { Text("Stale \(at, style: .relative)") }
                icon: { Image(systemName: "wifi.slash") }
                .font(.caption2).padding(3)
                .background(.red.opacity(0.85), in: Capsule())
        } else if model.sharedCursorAvailable {
            if let target = model.cursorPendingTarget {
                Text("→ \(target)/\(model.latest?.hostMoveCount ?? 0)")
                    .font(.caption2).padding(3)
                    .background(.orange.opacity(0.85), in: Capsule())
            } else if let index = model.latest?.hostMoveIndex,
                      let count = model.latest?.hostMoveCount, index < count {
                Text("\(index)/\(count)")
                    .font(.caption2).padding(3)
                    .background(.orange.opacity(0.85), in: Capsule())
                    .onTapGesture { model.scrub(to: count) }
            }
        } else if !peek.isLive {
            Text("\(peek.movesBehindLive) behind live")
                .font(.caption2).padding(3)
                .background(.orange.opacity(0.85), in: Capsule())
                .onTapGesture { peek.viewIndex = peek.entries.count - 1 }
        }
    }

    private func scoreText(_ scoreLeadBlack: Float) -> String {
        scoreLeadBlack >= 0 ? String(format: "B+%.1f", scoreLeadBlack)
                            : String(format: "W+%.1f", -scoreLeadBlack)
    }
}
