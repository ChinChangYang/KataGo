import SwiftUI

/// GTP columns skip the letter 'I'. Returns 0-based grid coordinates where the
/// origin (0,0) is the TOP-LEFT, matching SwiftUI's drawing space. GTP row 1 is
/// the BOTTOM, so y is flipped against `height`.
public func parseVertex(_ vertex: String, height: Int) -> (x: Int, y: Int)? {
    let v = vertex.uppercased()
    guard let first = v.first, first.isLetter, first != "I" else { return nil }
    let columns = Array("ABCDEFGHJKLMNOPQRSTUVWXYZ")
    guard let col = columns.firstIndex(of: first) else { return nil }
    let rowString = v.dropFirst()
    guard let row = Int(rowString), row >= 1, row <= height else { return nil }
    return (x: col, y: height - row)
}

/// Minimal, dependency-free Go board: wooden background, grid lines, filled
/// stones. No Metal, no engine, no GobanState — safe for a widget extension.
public struct WidgetBoardView: View {
    let width: Int
    let height: Int
    let black: [(Int, Int)]
    let white: [(Int, Int)]

    public init(width: Int, height: Int, blackVertices: [String], whiteVertices: [String]) {
        self.width = max(width, 1)
        self.height = max(height, 1)
        self.black = blackVertices.compactMap { parseVertex($0, height: height) }
        self.white = whiteVertices.compactMap { parseVertex($0, height: height) }
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
