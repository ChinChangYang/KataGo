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
/// preview that plays the moves, a few options (speed, size, coordinates, loop),
/// and a Share button once the GIF is generated. Shared by iOS, visionOS, and
/// macOS; the caller supplies the surrounding `NavigationStack`.
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
    @State private var size: GifSize = .medium
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

    private enum GifSize: String, CaseIterable, Identifiable {
        case small, medium, large
        var id: String { rawValue }
        var pixels: CGFloat {
            switch self {
            case .small: return 320
            case .medium: return 480
            case .large: return 640
            }
        }
        var label: String {
            switch self {
            case .small: return "Small"
            case .medium: return "Medium"
            case .large: return "Large"
            }
        }
    }

    private var currentOptions: GifExportOptions {
        GifExportOptions(
            pixelSize: size.pixels,
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
                Picker("Size", selection: $size) {
                    ForEach(GifSize.allCases) { Text($0.label).tag($0) }
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
    }

    @ViewBuilder private var preview: some View {
        ZStack {
            if framesLoaded, !frames.isEmpty {
                TimelineView(.periodic(from: startDate, by: max(secondsPerMove, 0.05))) { context in
                    let step = max(secondsPerMove, 0.05)
                    let elapsed = context.date.timeIntervalSince(startDate)
                    let index = frames.count > 0 ? Int(elapsed / step) % frames.count : 0
                    board(for: index)
                }
            } else {
                ProgressView()
            }
        }
        .frame(width: 320, height: 320)
    }

    private func board(for index: Int) -> some View {
        let clamped = min(max(index, 0), max(frames.count - 1, 0))
        let frame = frames.isEmpty
            ? GifFrame(blackStones: [], whiteStones: [], lastMove: nil)
            : frames[clamped]
        // Same view the renderer rasterizes, so the preview matches the GIF.
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
        .frame(width: 320, height: 320)
    }

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

#endif
