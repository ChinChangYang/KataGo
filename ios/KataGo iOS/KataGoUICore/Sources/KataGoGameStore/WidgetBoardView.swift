import SwiftUI

/// GTP columns skip the letter 'I'. Columns 0–24 are single letters A–Z (skip I);
/// columns 25–49 are "A"+letter AA–AZ (skip AI) — boards up to 37×37 are
/// supported, so two-letter columns DO occur. This mirrors `Coordinate.xMap` in
/// KataGoUICore, replicated here because this widget module (KataGoGameStore)
/// sits below KataGoUICore and can't import `Coordinate`; keep the two in sync.
/// Returns 0-based grid coordinates with the origin (0,0) at the TOP-LEFT
/// (matching SwiftUI). GTP row 1 is the BOTTOM, so y is flipped against `height`.
/// The column is bounded to `0..<width` and the row to `1...height` (parity with
/// `Coordinate.init?(x:y:width:height:)`); an off-board vertex returns nil so the
/// widget never draws a stone outside the grid.
public func parseVertex(_ vertex: String, width: Int, height: Int) -> (x: Int, y: Int)? {
    let v = vertex.uppercased()
    let letters = v.prefix { $0.isLetter }
    guard let col = gtpColumnIndex(String(letters)), col < width else { return nil }
    let rowString = v.dropFirst(letters.count)
    guard let row = Int(rowString), row >= 1, row <= height else { return nil }
    return (x: col, y: height - row)
}

/// GTP column letters in order, skipping 'I' (25 letters → indices 0…24).
private let gtpColumnLetters = Array("ABCDEFGHJKLMNOPQRSTUVWXYZ")

/// Maps a GTP column label (1–2 letters) to its 0-based index, or nil if invalid.
/// Single letters cover 0…24; "A"+letter covers 25…49 (skipping 'AI'), matching
/// `Coordinate.xMap`.
private func gtpColumnIndex(_ label: String) -> Int? {
    let chars = Array(label)
    switch chars.count {
    case 1:
        return gtpColumnLetters.firstIndex(of: chars[0])
    case 2 where chars[0] == "A":
        guard let second = gtpColumnLetters.firstIndex(of: chars[1]) else { return nil }
        return 25 + second
    default:
        return nil
    }
}

/// Minimal, dependency-free Go board: wooden background, grid lines, filled
/// stones. No Metal, no engine, no GobanState — safe for a widget extension.
public struct WidgetBoardView: View {
    let width: Int
    let height: Int
    let black: [(Int, Int)]
    let white: [(Int, Int)]

    public init(width: Int, height: Int, blackVertices: [String], whiteVertices: [String]) {
        let w = max(width, 1)
        let h = max(height, 1)
        self.width = w
        self.height = h
        self.black = blackVertices.compactMap { parseVertex($0, width: w, height: h) }
        self.white = whiteVertices.compactMap { parseVertex($0, width: w, height: h) }
    }

    public var body: some View {
        GeometryReader { geo in
            let cell = min(geo.size.width / CGFloat(width), geo.size.height / CGFloat(height))
            let originX = (geo.size.width - cell * CGFloat(width - 1)) / 2
            let originY = (geo.size.height - cell * CGFloat(height - 1)) / 2

            ZStack {
                Color(red: 0.85, green: 0.68, blue: 0.40)
                Path { p in
                    for x in 0..<width {
                        let p1 = CGPoint(x: originX + CGFloat(x) * cell, y: originY)
                        let p2 = CGPoint(x: originX + CGFloat(x) * cell, y: originY + CGFloat(height - 1) * cell)
                        p.move(to: p1)
                        p.addLine(to: p2)
                    }
                    for y in 0..<height {
                        let p1 = CGPoint(x: originX, y: originY + CGFloat(y) * cell)
                        let p2 = CGPoint(x: originX + CGFloat(width - 1) * cell, y: originY + CGFloat(y) * cell)
                        p.move(to: p1)
                        p.addLine(to: p2)
                    }
                }
                .stroke(Color.black.opacity(0.55), lineWidth: 0.5)
                ForEach(Array(white.enumerated()), id: \.offset) { _, s in
                    Circle().fill(.white)
                        .frame(width: cell * 0.92, height: cell * 0.92)
                        .position(CGPoint(x: originX + CGFloat(s.0) * cell, y: originY + CGFloat(s.1) * cell))
                }
                ForEach(Array(black.enumerated()), id: \.offset) { _, s in
                    Circle().fill(.black)
                        .frame(width: cell * 0.92, height: cell * 0.92)
                        .position(CGPoint(x: originX + CGFloat(s.0) * cell, y: originY + CGFloat(s.1) * cell))
                }
            }
        }
    }
}
