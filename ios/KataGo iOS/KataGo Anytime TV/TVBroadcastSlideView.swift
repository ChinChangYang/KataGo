//
//  TVBroadcastSlideView.swift
//  KataGo Anytime TV
//
//  The broadcast's slide presentation: a full-size ReportBoardView in the
//  hero slot (opaque backdrop so the live board underneath can't ghost
//  through) and the side panel's title + typewriter text + progress dots.
//  Both are pure value renderers — the BroadcastController owns all state.
//

import SwiftUI
import KataGoUICore

/// The hero-slot slide board: the controller's current choreography frame
/// rendered over the report's base position. Full-bleed (no inner padding) —
/// Dimensions centers the wood with its own margins, and the removed margin
/// closes the board-to-panel gap. Opaque backdrop so the live board
/// underneath can't ghost through.
struct TVBroadcastSlideBoard: View {
    let frame: BroadcastBoardFrame
    let model: DeepReportModel

    var body: some View {
        let stones = frame.stones(black: model.blackVertices, white: model.whiteVertices,
                                  width: model.boardWidth, height: model.boardHeight)
        ReportBoardView(width: model.boardWidth, height: model.boardHeight,
                        blackVertices: stones.black,
                        whiteVertices: stones.white,
                        overlay: frame.overlay,
                        lastMoveVertex: frame.lastMoveVertex,
                        isClassicStoneStyle: model.isClassicStoneStyle,
                        showCoordinate: model.showCoordinate,
                        verticalFlip: model.verticalFlip)
            .overlay(alignment: .top) {
                if let caption = frame.caption {
                    TVBeatCaptionChip(caption: caption)
                        .padding(.top, 28)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
    }
}

/// The acted-out beat's caption ("Black passes" / "White plays elsewhere"):
/// stone glyph + label in a capsule, top-center over the board. The band
/// above the top grid line only ever holds decorative coordinate letters, so
/// the chip can never cover an acting stone on any board size.
///
/// The two beats read differently on purpose: a PASS BEAT forfeits the move,
/// a TENUKI BEAT relocates it. Rendering both as "plays elsewhere" (what a
/// bare PlayerColor forced) mis-narrates every pass slide.
private struct TVBeatCaptionChip: View {
    /// Which beat is being acted out, and whose it is.
    let caption: BeatCaption

    private var color: PlayerColor {
        switch caption {
        case .passes(let player), .playsElsewhere(let player): player
        }
    }

    private var text: String {
        switch caption {
        case .passes(let player): "\(player.name) passes"
        case .playsElsewhere(let player): "\(player.name) plays elsewhere"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            TVStoneIndicator(isBlack: color == .black)
            Text(text)
                .font(.title3.weight(.semibold))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
    }
}

/// The side panel's slide content: title, streaming facts, progress dots.
struct TVBroadcastSlidePanel: View {
    let title: String
    let text: String
    let slideNumber: Int
    let slideCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.bold())
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(text)
                .font(.body)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            if slideCount > 1 {
                HStack(spacing: 10) {
                    ForEach(1...slideCount, id: \.self) { number in
                        Circle()
                            .fill(number == slideNumber ? Color.tvWoodAccent
                                                        : Color(white: 0.4))
                            .frame(width: 12, height: 12)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
@MainActor
private func previewModel() -> DeepReportModel {
    let model = DeepReportModel()
    model.sideToMove = .black
    model.boardWidth = 19
    model.boardHeight = 19
    model.blackVertices = ["Q16", "D4", "Q4"]
    model.whiteVertices = ["D16", "Q3"]
    model.candidates = [
        CandidateReport(vertex: "R14", visits: 210, winrate: 0.56, scoreLead: 1.8,
                        winrateDelta: 0, scoreLeadDelta: 0,
                        pv: ["R14", "R10", "Q12"], ownershipDelta: [:],
                        tenuki: TenukiFollowUp(vertex: "R10", winrate: 0.6,
                                               scoreLead: 2.5, visits: 60,
                                               pv: ["R10"])),
        CandidateReport(vertex: "C6", visits: 90, winrate: 0.53, scoreLead: 0.9,
                        winrateDelta: -0.03, scoreLeadDelta: -0.9, pv: ["C6"],
                        ownershipDelta: [BoardPoint(x: 2, y: 5): -0.5,
                                         BoardPoint(x: 3, y: 6): 0.3],
                        tenuki: nil),
    ]
    model.passComparison = PassComparison(punishmentVertex: "R13", winrate: 0.31,
                                          scoreLead: -4.0, winrateDeltaVsBest: 0.25,
                                          scoreLeadDeltaVsBest: 5.8,
                                          ownershipDelta: [BoardPoint(x: 16, y: 13): 0.6,
                                                           BoardPoint(x: 15, y: 12): -0.4],
                                          contestedPoints: [])
    return model
}

@MainActor
private func previewFrames(_ slideIndex: Int) -> [BroadcastBoardFrame] {
    let model = previewModel()
    let slides = BroadcastScript.slides(from: model)
    return BroadcastScript.frames(for: slides[slideIndex], model: model)
}

#Preview("Best — mid-PV") {
    TVBroadcastSlideBoard(frame: previewFrames(0)[2], model: previewModel())
        .frame(width: 900, height: 900)
}

#Preview("Best — tenuki chip") {
    TVBroadcastSlideBoard(frame: previewFrames(0)[5], model: previewModel())
        .frame(width: 900, height: 900)
}

#Preview("Alternative — entry (best stone only)") {
    TVBroadcastSlideBoard(frame: previewFrames(1)[0], model: previewModel())
        .frame(width: 900, height: 900)
}

#Preview("Alternative — delta") {
    TVBroadcastSlideBoard(frame: previewFrames(1).last!, model: previewModel())
        .frame(width: 900, height: 900)
}

#Preview("Pass — punish + chip") {
    TVBroadcastSlideBoard(frame: previewFrames(2)[3], model: previewModel())
        .frame(width: 900, height: 900)
}

#Preview("Slide panel — streaming") {
    TVBroadcastSlidePanel(title: "Best Move R14",
                          text: "Position: move 12, Black to play.\nBest move R14: 56% win rate",
                          slideNumber: 1,
                          slideCount: 3)
        .frame(width: 752, height: 900)
        .background(.thinMaterial)
}
#endif
