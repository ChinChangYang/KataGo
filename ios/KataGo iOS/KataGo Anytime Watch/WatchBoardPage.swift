import SwiftUI
import KataGoGameStore

struct WatchBoardPage: View {
    @Environment(WatchLiveModel.self) private var model
    @State private var crownIndex: Double = 0

    var body: some View {
        let peek = model.peek

        // The VStack stays even though it now wraps a single child: the frame
        // is optional, and this container is what carries `.focusable()`, the
        // Crown, and the status pill through the no-snapshot-yet state on a
        // cold launch. Hanging them on WatchFrameBoard instead would take the
        // Crown away from the TabView's own vertical paging only once a frame
        // had arrived.
        VStack(spacing: 2) {
            if let frame = liveFrame {
                WatchFrameBoard(frame: frame)
            }
        }
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

    /// The frame to draw: same cursor/ring selection as before, expressed once.
    private var liveFrame: WatchBoardFrame? {
        let peek = model.peek
        let cursorMode = model.sharedCursorAvailable
        guard let shown = cursorMode ? cursorFrame : peek.current else { return nil }
        let previous = (!cursorMode && peek.entries.indices.contains(peek.viewIndex - 1))
            ? peek.entries[peek.viewIndex - 1] : nil
        return WatchBoardFrame.live(
            snapshot: shown,
            stale: model.isStale,
            // Cursor mode: the host analyzes the shown position, so candidates
            // are always current. Ring mode keeps v0's live-only rule.
            showCandidates: cursorMode || peek.isLive,
            // The phone's own answer wins whenever it sent one (v1.2+). It is
            // authoritative in BOTH modes: each buffered snapshot carries the
            // move that produced its own position.
            //
            // Cursor mode used to pass nil outright, so the live board drew NO
            // last-move marker exactly when the phone was nearby and healthy —
            // the common case — because the differ below needs the
            // immediately-preceding snapshot and the ring may not hold the
            // index the user scrubbed to. The fallback is kept only for
            // pre-v1.2 phones, where nil restores precisely the old behavior.
            lastMoveVertex: shown.lastMoveVertex
                ?? (cursorMode ? nil
                    : WatchPeekBuffer.lastMoveVertex(previous: previous, current: shown)),
            title: nil)
    }
}
