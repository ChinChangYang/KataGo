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

/// The hero-slot slide board. Sized by the parent (the 1080 pt square).
struct TVBroadcastSlideBoard: View {
    let slide: BroadcastSlide
    let model: DeepReportModel

    var body: some View {
        ReportBoardView(width: model.boardWidth, height: model.boardHeight,
                        blackVertices: model.blackVertices,
                        whiteVertices: model.whiteVertices,
                        overlay: slide.overlay,
                        markedMove: slide.markedMove,
                        isClassicStoneStyle: model.isClassicStoneStyle,
                        showCoordinate: model.showCoordinate,
                        verticalFlip: model.verticalFlip)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
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
                        tenuki: nil),
        CandidateReport(vertex: "C6", visits: 90, winrate: 0.53, scoreLead: 0.9,
                        winrateDelta: -0.03, scoreLeadDelta: -0.9, pv: ["C6"],
                        ownershipDelta: [BoardPoint(x: 2, y: 5): -0.5,
                                         BoardPoint(x: 3, y: 6): 0.3],
                        tenuki: nil),
    ]
    return model
}

#Preview("Slide board — Best (PV)") {
    TVBroadcastSlideBoard(slide: BroadcastScript.slides(from: previewModel())[0],
                          model: previewModel())
        .frame(width: 900, height: 900)
}

#Preview("Slide board — Alternative (delta)") {
    TVBroadcastSlideBoard(slide: BroadcastScript.slides(from: previewModel())[1],
                          model: previewModel())
        .frame(width: 900, height: 900)
}

#Preview("Slide panel — streaming") {
    TVBroadcastSlidePanel(title: "Best Move R14",
                          text: "Position: move 12, Black to play.\nBest move R14: 56% win rate",
                          slideNumber: 1,
                          slideCount: 3)
        .frame(width: 500, height: 900)
        .background(.thinMaterial)
}
#endif
