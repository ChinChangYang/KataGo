//
//  GameGifExportView.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2026/7/7.
//

import KataGoGameStore
import SwiftUI

// GIF export is an iOS/visionOS/macOS feature. tvOS still compiles KataGoUICore
// but lacks ShareLink/SharePreview/Slider and never presents this sheet, so the
// whole view is excluded there (the renderer/encoder below stay available).
#if !os(tvOS)

/// Export sheet for turning a saved game into an animated GIF. Shows a live
/// preview that plays the moves, a few options (speed, quality, coordinates,
/// loop), and a Share button once the GIF is generated. Shared by iOS, visionOS,
/// and macOS; the caller supplies the surrounding `NavigationStack`.
public struct GameGifExportView: View {
    private let gameRecord: GameRecord
    /// Bridges Done back to AppKit dismissal when presented via
    /// `NSHostingController.presentAsSheet` on macOS (where SwiftUI's `\.dismiss`
    /// can't reach the sheet). Nil on iOS/visionOS, where `\.dismiss` is used.
    private let onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    // Frames + board size, replayed off the engine once on appear.
    @State private var frames: [GifFrame] = []
    @State private var framesLoaded = false
    @State private var boardWidth = 19
    @State private var boardHeight = 19
    @State private var startDate = Date()

    // Options.
    @State private var secondsPerMove: Double = 0.6
    @State private var quality: GifQuality = .high
    @State private var showCoordinates: Bool
    @State private var loops = true
    // Seconds the final position is held before looping; 0 == no extra hold.
    @State private var finalHoldSeconds: Double = 1.5
    // Board appearance, seeded from the user's global board settings so the GIF
    // matches the live board.
    @State private var isClassicStoneStyle: Bool
    @State private var verticalFlip: Bool

    // Render/share state.
    @State private var isRendering = false
    @State private var renderProgress = 0.0
    @State private var exportedURL: URL?
    @State private var errorMessage: String?

    public init(gameRecord: GameRecord, onClose: (() -> Void)? = nil) {
        self.gameRecord = gameRecord
        self.onClose = onClose
        // Seed the board-appearance options from the global GlobalSettings.*
        // preferences (no custom UserDefaults suite is used for them), so the
        // GIF matches how the user sees the live board.
        let defaults = UserDefaults.standard
        let storedCoord = defaults.object(forKey: GlobalSettingsKeys.showCoordinate) as? Bool
        _showCoordinates = State(initialValue: storedCoord ?? Config.defaultShowCoordinate)
        let storedFlip = defaults.object(forKey: GlobalSettingsKeys.verticalFlip) as? Bool
        _verticalFlip = State(initialValue: storedFlip ?? Config.defaultVerticalFlip)
        let styleIndex = (defaults.object(forKey: GlobalSettingsKeys.stoneStyle) as? Int)
            ?? Config.defaultStoneStyle
        let isClassic = Config.stoneStyles.indices.contains(styleIndex)
            && Config.stoneStyles[styleIndex] == Config.classicStoneStyle
        _isClassicStoneStyle = State(initialValue: isClassic)
    }

    /// Output raster size framed as image quality (pixel size is the GIF's
    /// only real quality lever: frames render at exactly this square size).
    private enum GifQuality: String, CaseIterable, Identifiable {
        case low, high
        var id: String { rawValue }
        var pixels: CGFloat {
            switch self {
            case .low: return 320
            case .high: return 640
            }
        }
        var label: String {
            switch self {
            case .low: return "Low"
            case .high: return "High"
            }
        }
    }

    private var currentOptions: GifExportOptions {
        GifExportOptions(
            pixelSize: quality.pixels,
            secondsPerMove: secondsPerMove,
            // 0 == no extra hold: the final frame just gets the per-move delay
            // (avoids an invalid 0-delay GIF frame).
            finalHoldSeconds: finalHoldSeconds <= 0 ? secondsPerMove : finalHoldSeconds,
            loops: loops,
            showCoordinates: showCoordinates,
            isClassicStoneStyle: isClassicStoneStyle,
            verticalFlip: verticalFlip
        )
    }

    /// Pacing for the live preview, matching the exported GIF's per-move speed,
    /// final hold, and loop toggle so the preview shows what the file will do.
    /// Uses the same effective values as `currentOptions` (floored speed, "0 ==
    /// no extra hold" resolved).
    private var previewTiming: GifPreviewTiming {
        let perMove = max(secondsPerMove, 0.05)
        return GifPreviewTiming(
            frameCount: frames.count,
            secondsPerMove: perMove,
            finalHoldSeconds: finalHoldSeconds <= 0 ? perMove : finalHoldSeconds,
            loops: loops
        )
    }

    public var body: some View {
        Form {
            Section {
                preview
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section("Animation") {
                VStack(alignment: .leading) {
                    Text("Speed: \(secondsPerMove, specifier: "%.1f")s per move")
                    Slider(value: $secondsPerMove, in: 0.2...1.5, step: 0.1)
                }
                Picker("Image Quality", selection: $quality) {
                    ForEach(GifQuality.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("Options") {
                VStack(alignment: .leading) {
                    Text(finalHoldSeconds <= 0
                         ? "Final hold: Off"
                         : "Final hold: \(finalHoldSeconds, specifier: "%.1f")s")
                    Slider(value: $finalHoldSeconds, in: 0...5, step: 0.5)
                }
                Toggle("Show coordinates", isOn: $showCoordinates)
                Toggle("Loop", isOn: $loops)
            }

            Section {
                actionRow
            } footer: {
                if frames.count <= 1 && framesLoaded {
                    Text("This game has no moves to animate.")
                }
            }
        }
        .navigationTitle("Export GIF")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    if let onClose { onClose() } else { dismiss() }
                }
            }
        }
        .task { await loadFrames() }
        .onChange(of: currentOptions) { _, _ in exportedURL = nil }
        // Restart the preview from the first move when a timing option (speed,
        // final hold, loop) changes, so the change is shown cleanly from the top.
        .onChange(of: previewTiming) { _, _ in startDate = Date() }
    }

    private var preview: some View {
        ZStack {
            if framesLoaded, !frames.isEmpty {
                let timing = previewTiming
                TimelineView(GifPreviewSchedule(startDate: startDate, timing: timing)) { context in
                    let elapsed = context.date.timeIntervalSince(startDate)
                    board(for: timing.index(atElapsed: elapsed))
                        .overlay {
                            // When Loop is off the preview plays once and freezes on
                            // the final position; a replay glyph makes that read as
                            // intentional (tap the preview to replay).
                            if timing.isFinished(atElapsed: elapsed) { replayHint }
                        }
                }
                // Recreate the timeline whenever the animation is (re)started so it
                // re-subscribes to the fresh schedule. Without this, restarting a
                // finished (non-looping) preview by resetting `startDate` alone
                // wouldn't replay — TimelineView doesn't re-run an exhausted
                // schedule when only the anchor changes.
                .id(startDate)
            } else {
                ProgressView()
            }
        }
        .frame(width: 320, height: 320)
        .contentShape(Rectangle())
        // Tap to replay (mainly for the frozen, non-looping end state). Use
        // `.simultaneousGesture` rather than `.onTapGesture`/a `.plain` Button:
        // inside a Form/List row those are preempted by the row's own gesture
        // handling and never fire, whereas a simultaneous tap is recognized
        // alongside it.
        .simultaneousGesture(TapGesture().onEnded { startDate = Date() })
        // Expose the preview as one tappable accessibility element so a UI test
        // can drive tap-to-replay. `.contain` keeps the "Replay" child image
        // separately queryable (unlike `.combine`), so the frozen state stays
        // assertable via that element.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("gifPreview")
        .accessibilityAddTraits(.isButton)
    }

    private var replayHint: some View {
        Image(systemName: "arrow.clockwise.circle.fill")
            .font(.system(size: 44))
            .foregroundStyle(.white.opacity(0.9))
            .shadow(radius: 4)
            .allowsHitTesting(false)
            // Present in the accessibility tree exactly when the preview is
            // frozen on its final frame (isFinished) — the signal a UI test polls
            // to assert freeze / un-freeze. `.allowsHitTesting(false)` blocks
            // touch only, not accessibility, so this stays queryable.
            .accessibilityLabel("Replay")
            .accessibilityIdentifier("gifPreviewReplayHint")
    }

    private func board(for index: Int) -> some View {
        let clamped = min(max(index, 0), max(frames.count - 1, 0))
        let frame = frames.isEmpty
            ? GifFrame(blackStones: [], whiteStones: [], lastMove: nil)
            : frames[clamped]
        // Same view the renderer rasterizes, so the preview matches the GIF —
        // including its GEOMETRY. A board wide enough that its "A"+letter
        // column labels would truncate makes the export raise its raster
        // (`effectivePixelSize`), so the preview has to render at that same
        // size and scale down into the fixed box; framing straight to
        // `previewSide` would show clipped labels the exported GIF won't have.
        // Deliberately NOT tied to the quality picker: every board that already
        // fits previews exactly as before, at scale 1.
        let side = showCoordinates
            ? max(Self.previewSide,
                  GifExportOptions.minimumPixelSize(width: boardWidth, height: boardHeight))
            : Self.previewSide
        return ReportBoardView(
            width: boardWidth,
            height: boardHeight,
            blackVertices: frame.blackStones,
            whiteVertices: frame.whiteStones,
            overlay: .none,
            lastMoveVertex: frame.lastMove,
            isClassicStoneStyle: isClassicStoneStyle,
            showCoordinate: showCoordinates,
            verticalFlip: verticalFlip
        )
        .frame(width: side, height: side)
        .scaleEffect(Self.previewSide / side)
        .frame(width: Self.previewSide, height: Self.previewSide)
    }

    /// On-screen size of the preview board, independent of the export raster.
    private static let previewSide: CGFloat = 320

    @ViewBuilder private var actionRow: some View {
        if let url = exportedURL {
            ShareLink(item: url, preview: SharePreview(gameRecord.name)) {
                Label("Share GIF", systemImage: "square.and.arrow.up")
            }
        } else if isRendering {
            ProgressView(value: renderProgress) {
                Text("Rendering… \(Int(renderProgress * 100))%")
            }
        } else {
            Button {
                Task { await generate() }
            } label: {
                Label("Create GIF", systemImage: "film")
            }
            .disabled(!framesLoaded || frames.count <= 1)
        }

        if let errorMessage {
            Text(errorMessage)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    private func loadFrames() async {
        let sgf = gameRecord.sgf
        // Replay off the main actor: gifFrames() is O(N²) and can hitch on a long
        // game. GifFrame/Int are Sendable, so handing the result back is safe.
        let result = await Task.detached(priority: .userInitiated) { () -> ([GifFrame], Int, Int) in
            let helper = SgfHelper(sgf: sgf)
            return (helper.gifFrames(), helper.xSize, helper.ySize)
        }.value
        frames = result.0
        boardWidth = max(result.1, 1)
        boardHeight = max(result.2, 1)
        framesLoaded = true
        startDate = Date()
    }

    @MainActor private func generate() async {
        isRendering = true
        renderProgress = 0
        errorMessage = nil
        let sgf = gameRecord.sgf
        let name = gameRecord.name
        // Snapshot the options this render is built from. The controls stay live
        // while rendering (render() frees the main actor between frames), so the
        // user can change a setting mid-render; only vend the result if it still
        // matches, otherwise the Share button would offer a GIF that doesn't
        // match the shown options. On a mismatch the user simply re-creates.
        let options = currentOptions
        do {
            let url = try await GameGifRenderer.render(
                sgf: sgf, options: options, gameName: name
            ) { progress in
                renderProgress = progress
            }
            if currentOptions == options {
                exportedURL = url
            }
        } catch {
            errorMessage = "Couldn't create the GIF."
        }
        isRendering = false
    }
}

/// `TimelineSchedule` that wakes the preview exactly at each frame transition
/// (`startDate + timing.start(of:)`), so it honors per-move speed, the final
/// hold, and the loop toggle — matching `GameGifRenderer`'s per-frame delays.
///
/// Looping yields an infinite stream of transitions. Not looping yields one pass
/// (frame 0…last) and then stops, so the preview freezes on the final frame with
/// no further wake-ups. The first emitted entry is always at or before `from`, as
/// `TimelineView` requires, so there is content to show immediately.
private struct GifPreviewSchedule: TimelineSchedule {
    let startDate: Date
    let timing: GifPreviewTiming

    func entries(from: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        let timing = self.timing
        let anchor = self.startDate

        // Nothing to animate (empty/one-frame game): render once, then stop.
        guard timing.frameCount > 1, timing.secondsPerMove > 0, timing.cycle > 0 else {
            var emitted = false
            return AnyIterator {
                if emitted { return nil }
                emitted = true
                return from
            }
        }

        let last = timing.frameCount - 1
        let fromElapsed = max(0, from.timeIntervalSince(anchor))

        if timing.loops {
            let cyclesDone = (fromElapsed / timing.cycle).rounded(.down)
            var cycleBase = cyclesDone * timing.cycle
            let within = fromElapsed - cycleBase
            // Start at the frame currently showing (its boundary is <= `from`).
            var i = min(Int((within / timing.secondsPerMove + 1e-6).rounded(.down)), last)
            return AnyIterator {
                let rel = cycleBase + timing.start(of: i)
                i += 1
                if i > last { i = 0; cycleBase += timing.cycle }
                return anchor.addingTimeInterval(rel)
            }
        } else {
            // One pass, frame 0…last, then a single terminal entry and nil so the
            // preview freezes on the final frame with no further wake-ups.
            //
            // TimelineView shows entry k's content during [t_k, t_{k+1}), so it
            // needs an entry *after* the last frame to transition into (and
            // display) it — without the sentinel it would freeze on the
            // second-to-last frame. The sentinel sits `finalHold` past the last
            // frame (= one cycle), matching the GIF's final-hold before it stops.
            var i = min(Int((fromElapsed / timing.secondsPerMove + 1e-6).rounded(.down)), last)
            var emittedSentinel = false
            return AnyIterator {
                if i <= last {
                    let rel = timing.start(of: i)
                    i += 1
                    return anchor.addingTimeInterval(rel)
                }
                if !emittedSentinel {
                    emittedSentinel = true
                    return anchor.addingTimeInterval(timing.cycle)
                }
                return nil
            }
        }
    }
}

#endif
