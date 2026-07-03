//
//  ReportBoardView.swift
//  KataGoUICore
//
//  Static mini-board for the Deep Analysis Report: the widget's vector board
//  plus one overlay layer — an ownership-delta heatmap or a numbered PV.
//  Not bound to live engine state; everything is passed in.
//

import SwiftUI

public enum ReportBoardOverlay {
    case none
    /// White-perspective ownership deltas; rendered relative to `perspective`
    /// (blue = that side gains the point, orange = loses it).
    case ownershipDelta([BoardPoint: Float], perspective: PlayerColor)
    /// Principal variation as GTP vertices; ghost stones alternate colors
    /// starting with `startingWith`. "pass" entries advance numbering unseen.
    case pv([String], startingWith: PlayerColor)
}

public struct ReportBoardView: View {
    let width: Int
    let height: Int
    let blackVertices: [String]
    let whiteVertices: [String]
    let overlay: ReportBoardOverlay

    /// Minimum |Δ| worth painting — smaller swings are visual noise.
    private static let deltaFloor: Float = 0.05

    public init(width: Int, height: Int,
                blackVertices: [String], whiteVertices: [String],
                overlay: ReportBoardOverlay) {
        self.width = width
        self.height = height
        self.blackVertices = blackVertices
        self.whiteVertices = whiteVertices
        self.overlay = overlay
    }

    public var body: some View {
        GeometryReader { geo in
            // Must mirror WidgetBoardView's internal math so overlays align.
            let cell = min(geo.size.width / CGFloat(width), geo.size.height / CGFloat(height))
            let originX = (geo.size.width - cell * CGFloat(width - 1)) / 2
            let originY = (geo.size.height - cell * CGFloat(height - 1)) / 2

            ZStack {
                WidgetBoardView(width: width, height: height,
                                blackVertices: blackVertices, whiteVertices: whiteVertices)
                overlayLayer(cell: cell, originX: originX, originY: originY)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder
    private func overlayLayer(cell: CGFloat, originX: CGFloat, originY: CGFloat) -> some View {
        switch overlay {
        case .none:
            EmptyView()

        case .ownershipDelta(let grid, let perspective):
            let entries = grid.filter { $0.value.magnitude >= Self.deltaFloor }
                .map { (point: $0.key, delta: $0.value) }
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                // Positive delta = toward White; convert to the report side.
                let gain = perspective == .white ? entry.delta > 0 : entry.delta < 0
                RoundedRectangle(cornerRadius: cell * 0.15)
                    .fill(gain ? Color.blue : Color.orange)
                    .opacity(Double(min(entry.delta.magnitude, 0.85)))
                    .frame(width: cell * 0.85, height: cell * 0.85)
                    .position(position(of: entry.point, cell: cell,
                                       originX: originX, originY: originY))
            }

        case .pv(let vertices, let startingWith):
            let stones = pvStones(vertices, startingWith: startingWith)
            ForEach(Array(stones.enumerated()), id: \.offset) { _, stone in
                ZStack {
                    Circle()
                        .fill(stone.color == .black ? Color.black : Color.white)
                        .opacity(0.75)
                    Text("\(stone.number)")
                        .font(.system(size: cell * 0.5, weight: .bold, design: .rounded))
                        .foregroundStyle(stone.color == .black ? Color.white : Color.black)
                }
                .frame(width: cell * 0.92, height: cell * 0.92)
                .position(CGPoint(x: originX + CGFloat(stone.x) * cell,
                                  y: originY + CGFloat(stone.y) * cell))
            }
        }
    }

    private func position(of point: BoardPoint, cell: CGFloat,
                          originX: CGFloat, originY: CGFloat) -> CGPoint {
        // BoardPoint y = 0 is the bottom row; screen y = 0 is the top.
        CGPoint(x: originX + CGFloat(point.x) * cell,
                y: originY + CGFloat(height - 1 - point.y) * cell)
    }

    private struct PVStone {
        let x: Int
        let y: Int   // screen-grid y (0 = top), from parseVertex
        let number: Int
        let color: PlayerColor
    }

    private func pvStones(_ vertices: [String], startingWith: PlayerColor) -> [PVStone] {
        var stones: [PVStone] = []
        var color = startingWith
        for (index, vertex) in vertices.enumerated() {
            defer { color = color == .black ? .white : .black }
            guard vertex != "pass",
                  let grid = parseVertex(vertex, width: width, height: height) else { continue }
            stones.append(PVStone(x: grid.x, y: grid.y, number: index + 1, color: color))
        }
        return stones
    }
}

#Preview("Ownership delta") {
    ReportBoardView(width: 9, height: 9,
                    blackVertices: ["C3", "G7"], whiteVertices: ["G3", "C7"],
                    overlay: .ownershipDelta([BoardPoint(x: 2, y: 6): -0.6,
                                              BoardPoint(x: 6, y: 2): 0.4,
                                              BoardPoint(x: 4, y: 4): 0.08],
                                             perspective: .black))
    .padding()
}

#Preview("PV") {
    ReportBoardView(width: 9, height: 9,
                    blackVertices: ["C3"], whiteVertices: ["G7"],
                    overlay: .pv(["E5", "G5", "pass", "C7"], startingWith: .black))
    .padding()
}
