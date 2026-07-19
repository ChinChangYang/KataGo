import SwiftUI
#if canImport(WidgetKit)
import WidgetKit
#endif

/// `widgetAccentable` hands a view's luminance to the system tint in the
/// widget accented rendering mode. `KataGoGameStore` also compiles for tvOS
/// (the TV app renders this board), which has no WidgetKit — there the
/// helper is an inert pass-through. Outside a widget (watch app, Messages)
/// the modifier is a no-op, so call sites need no context checks.
private extension View {
    @ViewBuilder func boardAccentable(_ on: Bool) -> some View {
        #if canImport(WidgetKit)
        self.widgetAccentable(on)
        #else
        self
        #endif
    }
}

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
    let candidateDots: [(x: Int, y: Int, rank: Int)]
    let lastMovePoint: (x: Int, y: Int)?
    let showCoordinates: Bool
    let style: WidgetBoardStyle

    public init(width: Int, height: Int, blackVertices: [String], whiteVertices: [String],
                candidateVertices: [String] = [], lastMoveVertex: String? = nil,
                showCoordinates: Bool = false,
                style: WidgetBoardStyle = .standard) {
        let w = max(width, 1)
        let h = max(height, 1)
        self.width = w
        self.height = h
        self.black = blackVertices.compactMap { parseVertex($0, width: w, height: h) }
        self.white = whiteVertices.compactMap { parseVertex($0, width: w, height: h) }
        let annotations = WidgetBoardView.annotationPoints(
            candidates: candidateVertices, lastMove: lastMoveVertex, width: w, height: h)
        self.candidateDots = annotations.dots
        self.lastMovePoint = annotations.last
        self.showCoordinates = showCoordinates
        self.style = style
    }

    /// GTP column label for a 0-based column index, skipping 'I' and using the
    /// "A"+letter form for columns 25…49 — the inverse of `gtpColumnIndex`, kept
    /// in sync with it so coordinate labels match `parseVertex`.
    nonisolated static func columnLabel(_ x: Int) -> String {
        if x < gtpColumnLetters.count {
            return String(gtpColumnLetters[x])
        }
        let second = x - gtpColumnLetters.count
        guard second < gtpColumnLetters.count else { return "" }
        return "A" + String(gtpColumnLetters[second])
    }

    /// Pure geometry for the watch/widget overlays: candidate vertices → grid
    /// dots ranked by surviving order (0 strongest), last move → grid point.
    /// "pass" and off-board vertices are dropped (parseVertex returns nil).
    /// nonisolated for the same reason as `hoshiPoints`.
    nonisolated public static func annotationPoints(
        candidates: [String], lastMove: String?, width: Int, height: Int
    ) -> (dots: [(x: Int, y: Int, rank: Int)], last: (x: Int, y: Int)?) {
        let dots = candidates
            .compactMap { parseVertex($0, width: width, height: height) }
            .enumerated()
            .map { (x: $0.element.x, y: $0.element.y, rank: $0.offset) }
        let last = lastMove.flatMap { parseVertex($0, width: width, height: height) }
        return (dots, last)
    }

    /// 0-based grid coordinates of the star points (hoshi), from the shared
    /// `BoardStarPoints` rule so the vector board matches every other renderer
    /// on any width x height (not just the classic squares).
    ///
    /// `nonisolated` because it is pure: `WidgetBoardView` is a SwiftUI `View`
    /// and thus `@MainActor`, which would otherwise pin this helper to the main
    /// actor and trap when called off-main (e.g. from a test).
    nonisolated public static func hoshiPoints(width: Int, height: Int) -> [(Int, Int)] {
        BoardStarPoints.points(width: width, height: height).map { ($0.x, $0.y) }
    }

    public var body: some View {
        GeometryReader { geo in
            // Coordinates need a band outside the outermost lines. Reserving it
            // shrinks the grid; with showCoordinates == false the margin is 0 and
            // the geometry is byte-identical to the widget's original layout.
            let coordinateMargin = showCoordinates
                ? min(geo.size.width, geo.size.height) * 0.06 : 0
            let availableWidth = geo.size.width - 2 * coordinateMargin
            let availableHeight = geo.size.height - 2 * coordinateMargin
            let cell = min(availableWidth / CGFloat(width), availableHeight / CGFloat(height))
            let originX = (geo.size.width - cell * CGFloat(width - 1)) / 2
            let originY = (geo.size.height - cell * CGFloat(height - 1)) / 2

            // Accented (tinted) mode: the wood would render as one flat tinted
            // slab, so it is dropped; lines and labels become dim NEUTRAL
            // (non-accentable) marks, and the stones carry the position in two
            // distinguishable accent treatments — black solid, white outlined.
            let gridColor = style.isAccented
                ? Color.white.opacity(style.gridOpacity)
                : Color.black.opacity(style.gridOpacity)

            ZStack {
                if style.showsWoodBackground {
                    Color(red: 0.85, green: 0.68, blue: 0.40)
                }
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
                .stroke(gridColor, lineWidth: 0.5)
                let hoshi = WidgetBoardView.hoshiPoints(width: width, height: height)
                ForEach(Array(hoshi.enumerated()), id: \.offset) { _, p in
                    Circle().fill(gridColor)
                        .frame(width: max(cell * 0.16, 2), height: max(cell * 0.16, 2))
                        .position(CGPoint(x: originX + CGFloat(p.0) * cell, y: originY + CGFloat(p.1) * cell))
                }
                ForEach(Array(white.enumerated()), id: \.offset) { _, s in
                    Group {
                        if style.whiteStoneIsAccentOutline {
                            // Accent RING over a faint neutral interior — the
                            // counterpart to black's solid disc; the two stay
                            // tellable apart under any single tint.
                            ZStack {
                                Circle().fill(.white.opacity(0.2))
                                Circle().strokeBorder(.white, lineWidth: max(cell * 0.08, 1))
                                    .boardAccentable(true)
                            }
                        } else {
                            Circle().fill(.white)
                        }
                    }
                    .frame(width: cell * 0.92, height: cell * 0.92)
                    .position(CGPoint(x: originX + CGFloat(s.0) * cell, y: originY + CGFloat(s.1) * cell))
                }
                ForEach(Array(black.enumerated()), id: \.offset) { _, s in
                    Group {
                        if style.blackStoneIsAccentFill {
                            // Full-luminance fill; the system supplies the hue.
                            Circle().fill(.white).boardAccentable(true)
                        } else {
                            Circle().fill(.black)
                        }
                    }
                    .frame(width: cell * 0.92, height: cell * 0.92)
                    .position(CGPoint(x: originX + CGFloat(s.0) * cell, y: originY + CGFloat(s.1) * cell))
                }
                let rankColors: [Color] = [.green, .yellow, .orange]
                ForEach(Array(candidateDots.enumerated()), id: \.offset) { _, d in
                    Group {
                        if style.usesRankHueDots {
                            Circle().fill(rankColors[min(d.rank, rankColors.count - 1)])
                        } else {
                            // Hue is meaningless under one tint; rank becomes
                            // a neutral opacity ramp instead.
                            Circle().fill(.white.opacity(style.candidateDotOpacity(rank: d.rank)))
                        }
                    }
                    .frame(width: max(cell * 0.36, 3), height: max(cell * 0.36, 3))
                    .position(CGPoint(x: originX + CGFloat(d.x) * cell, y: originY + CGFloat(d.y) * cell))
                }
                if let lm = lastMovePoint {
                    Group {
                        if style.isAccented {
                            Circle().stroke(Color.white.opacity(0.9), lineWidth: max(cell * 0.08, 1))
                                .boardAccentable(true)
                        } else {
                            Circle().stroke(Color.red, lineWidth: max(cell * 0.08, 1))
                        }
                    }
                    .frame(width: cell * 0.6, height: cell * 0.6)
                    .position(CGPoint(x: originX + CGFloat(lm.x) * cell, y: originY + CGFloat(lm.y) * cell))
                }
                if showCoordinates {
                    let fontSize = max(cell * 0.42, 5)
                    let offset = cell * 0.62
                    let labelColor = style.isAccented
                        ? Color.white.opacity(0.75)
                        : Color.black.opacity(0.75)
                    // Column letters (A–T, skipping I) above and below the grid.
                    ForEach(0..<width, id: \.self) { x in
                        let cx = originX + CGFloat(x) * cell
                        let label = WidgetBoardView.columnLabel(x)
                        Text(label).font(.system(size: fontSize)).foregroundStyle(labelColor)
                            .position(x: cx, y: originY - offset)
                        Text(label).font(.system(size: fontSize)).foregroundStyle(labelColor)
                            .position(x: cx, y: originY + CGFloat(height - 1) * cell + offset)
                    }
                    // Row numbers (1 at the bottom, increasing upward) on both sides.
                    ForEach(0..<height, id: \.self) { yy in
                        let cy = originY + CGFloat(yy) * cell
                        let number = "\(height - yy)"
                        Text(number).font(.system(size: fontSize)).foregroundStyle(labelColor)
                            .position(x: originX - offset, y: cy)
                        Text(number).font(.system(size: fontSize)).foregroundStyle(labelColor)
                            .position(x: originX + CGFloat(width - 1) * cell + offset, y: cy)
                    }
                }
            }
        }
    }
}
