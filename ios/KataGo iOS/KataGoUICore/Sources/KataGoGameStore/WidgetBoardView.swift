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

/// Worst-case glyph metrics for the coordinate labels, in ems of the label
/// font floor. Both label idioms bottom out at the SAME size — the appGoban
/// label is `.font(.system(size: 500)).minimumScaleFactor(0.01)` and the
/// goban/standard label is `max(cell * 0.42, floor)` — so one set of numbers
/// bounds every style. The advances are the widest glyph in each class of SF
/// **Bold** (appGoban bolds, and bold is the wider weight, so these bound the
/// unbolded styles too), measured at the floor:
///
///     digits  "8"  3.669 pt      letters  "W"  5.247 pt
///     "A"          3.862 pt      line height   5.967 pt
///
/// The line height is `UIFont.lineHeight`, which is NOT the CoreText
/// ascent + descent + leading (5.890 pt) — UIKit rounds it up, and the taller
/// of the two is the one that governs layout.
///
/// `WidgetBoardViewTests` re-measures them against the real system font and
/// fails if SF ever outgrows them, so a font-metrics change surfaces as a red
/// test rather than as silently truncated labels.
public enum WidgetCoordinateMetrics: Sendable {
    /// The nominal size the appGoban label shrinks FROM. Paired with
    /// `minimumScaleFactor` below so the 5 pt floor is spelled out in the code
    /// instead of hidden in a `0.01` literal.
    public static let appLabelNominalFontSize: CGFloat = 500

    /// The size both label idioms floor at. Below it the appGoban label can
    /// only truncate (it is clipped to a cell-sized frame) and the unclipped
    /// styles can only overlap their neighbours.
    public static let fontFloor: CGFloat = 5

    /// `minimumScaleFactor` that lands the nominal size exactly on the floor.
    public static var appLabelMinimumScaleFactor: CGFloat {
        fontFloor / appLabelNominalFontSize
    }

    public static let maxDigitAdvanceEm: CGFloat = 0.734   // "8"
    public static let capitalAAdvanceEm: CGFloat = 0.773   // "A"
    public static let maxLetterAdvanceEm: CGFloat = 1.050  // "W"
    public static let lineHeightEm: CGFloat = 1.194  // UIFont.lineHeight

    /// The smallest cell pitch at which every label a `width` x `height` board
    /// draws still fits its own cell-sized box at the font floor. Rows are the
    /// numbers 1...height, so they take two digits once the board is 10 or
    /// taller; columns are single letters up to 25 wide and "A"+letter beyond
    /// that (`WidgetBoardView.columnLabel`).
    ///
    /// The line height is folded in because a label is nearly as tall as it is
    /// wide: on a 9x9 the widest label is a single digit (3.67 pt), and a
    /// width-only rule would happily stack 5.97 pt-tall labels 3.7 pt apart.
    public static func requiredCell(width: Int, height: Int) -> CGFloat {
        let rowDigits: CGFloat = height >= 10 ? 2 : 1
        let rowWidth = fontFloor * rowDigits * maxDigitAdvanceEm
        let columnWidth = width > 25
            ? fontFloor * (capitalAAdvanceEm + maxLetterAdvanceEm)
            : fontFloor * maxLetterAdvanceEm
        return max(rowWidth, columnWidth, fontFloor * lineHeightEm)
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
    let woodImage: CGImage?

    public init(width: Int, height: Int, blackVertices: [String], whiteVertices: [String],
                candidateVertices: [String] = [], lastMoveVertex: String? = nil,
                showCoordinates: Bool = false,
                style: WidgetBoardStyle = .standard,
                woodImage: CGImage? = nil) {
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
        self.woodImage = woodImage
    }

    /// GTP column label for a 0-based column index, skipping 'I' and using the
    /// "A"+letter form for columns 25…49 — the inverse of `gtpColumnIndex`, kept
    /// in sync with it so coordinate labels match `parseVertex`. Public so the
    /// tests can build the exact label set a board draws and measure it against
    /// `WidgetCoordinateMetrics.requiredCell`.
    nonisolated public static func columnLabel(_ x: Int) -> String {
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

    /// Whether coordinate labels render INTACT for a `width` x `height` board
    /// drawn into `size` — see `WidgetBoardGeometry.coordinateLabelsFit`, which
    /// owns this rule along with the rest of the grid layout. Kept here as a
    /// forwarding shim for existing callers.
    nonisolated public static func coordinateLabelsFit(size: CGSize, width: Int, height: Int) -> Bool {
        WidgetBoardGeometry.coordinateLabelsFit(size: size, width: width, height: height)
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

    /// One coordinate label. appGoban uses the in-app board's exact idiom
    /// (`BoardLineView.drawCoordinate`): bold black size-500 text shrunk to
    /// fit a cell-sized frame, so widget and app coordinates render alike.
    /// The other styles keep the historical fixed sizing and per-style colors,
    /// with accented additionally bolding for legibility. Both floor at
    /// `WidgetCoordinateMetrics.fontFloor` — the size `coordinateLabelsFit`
    /// sizes its glyphs at, so the renderer and the gate cannot drift apart.
    @ViewBuilder private func coordinateLabel(_ text: String, cell: CGFloat) -> some View {
        if style.usesAppCoordinateLabels {
            Text(text)
                .foregroundStyle(.black)
                .font(.system(size: WidgetCoordinateMetrics.appLabelNominalFontSize))
                .minimumScaleFactor(WidgetCoordinateMetrics.appLabelMinimumScaleFactor)
                .bold()
                .frame(width: cell, height: cell)
        } else {
            let labelColor = style.isGoban
                ? Color(red: WidgetBoardStyle.gobanInk.red,
                        green: WidgetBoardStyle.gobanInk.green,
                        blue: WidgetBoardStyle.gobanInk.blue).opacity(0.9)
                : style.isAccented
                    ? Color.white.opacity(0.75)
                    : Color.black.opacity(0.75)
            Text(text)
                .font(.system(size: max(cell * 0.42, WidgetCoordinateMetrics.fontFloor)))
                .bold(style.coordinateLabelsAreBold)
                .foregroundStyle(labelColor)
        }
    }

    /// The stones. The classic variant stamps the app's Metal-shader stones
    /// through ONE `Canvas` of pre-rasterized symbols (`ClassicStoneLayer`) —
    /// a per-stone `colorEffect` view would be the ~1000-layer, 76 ms case
    /// `StoneView` was rewritten to escape, and boards here reach 37x37.
    /// Every other variant keeps the original view-per-stone drawing, so the
    /// watch, widget and TV boards are untouched.
    @ViewBuilder
    private func stoneLayer(cell: CGFloat, originX: CGFloat, originY: CGFloat) -> some View {
        let diameter = cell * style.stoneDiameterRatio
#if !os(watchOS)
        if style.usesShaderStones {
            ClassicStoneLayer(black: black, white: white,
                              cell: cell, stoneLength: diameter,
                              originX: originX, originY: originY)
        } else {
            flatStoneLayer(cell: cell, diameter: diameter, originX: originX, originY: originY)
        }
#else
        flatStoneLayer(cell: cell, diameter: diameter, originX: originX, originY: originY)
#endif
    }

    /// White first, then black — the historical order, kept so already-shipped
    /// surfaces render identically.
    @ViewBuilder
    private func flatStoneLayer(cell: CGFloat, diameter: CGFloat,
                                originX: CGFloat, originY: CGFloat) -> some View {
        ForEach(Array(white.enumerated()), id: \.offset) { _, s in
            Group {
                if style.stonesAreSpherical {
                    SphericalStone(isBlack: false, diameter: diameter)
                } else if style.whiteStoneIsAccentOutline {
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
            .frame(width: diameter, height: diameter)
            .position(CGPoint(x: originX + CGFloat(s.0) * cell, y: originY + CGFloat(s.1) * cell))
        }
        ForEach(Array(black.enumerated()), id: \.offset) { _, s in
            Group {
                if style.stonesAreSpherical {
                    SphericalStone(isBlack: true, diameter: diameter)
                } else if style.blackStoneIsAccentFill {
                    // Full-luminance fill; the system supplies the hue.
                    Circle().fill(.white).boardAccentable(true)
                } else {
                    Circle().fill(.black)
                }
            }
            .frame(width: diameter, height: diameter)
            .position(CGPoint(x: originX + CGFloat(s.0) * cell, y: originY + CGFloat(s.1) * cell))
        }
    }

    public var body: some View {
        GeometryReader { geo in
            // Coordinates need a band outside the outermost lines. Reserving it
            // shrinks the grid; with the labels off the margin is 0 and the
            // geometry is byte-identical to the widget's original layout.
            // `WidgetBoardGeometry` owns that math so an interactive host can
            // hit-test against exactly the grid drawn here.
            let geometry = WidgetBoardGeometry(width: width, height: height,
                                               size: geo.size,
                                               showCoordinates: showCoordinates)
            let showsLabels = geometry.showsLabels
            let cell = geometry.cell
            let originX = geometry.originX
            let originY = geometry.originY

            // Goban: the texture generator's opaque dark-brown ink. appGoban:
            // the app board's plain black lines. Accented (tinted) mode: the
            // wood would render as one flat tinted slab, so it is dropped;
            // lines and labels become dim NEUTRAL (non-accentable) marks, and
            // the stones carry the position in two distinguishable accent
            // treatments — black solid, white outlined.
            let gridColor = style.isGoban
                ? Color(red: WidgetBoardStyle.gobanInk.red,
                        green: WidgetBoardStyle.gobanInk.green,
                        blue: WidgetBoardStyle.gobanInk.blue).opacity(style.gridOpacity)
                : style.isAccented
                    ? Color.white.opacity(style.gridOpacity)
                    : Color.black.opacity(style.gridOpacity)
            let hoshiDiameter = style.hoshiDiameter(cellSize: cell)

            ZStack {
                if style.showsWoodBackground {
                    if style.usesBundledWoodAsset {
                        // The app board's own texture (`BoardLineView` draws
                        // this same asset) — exact widget/app parity.
                        Image(decorative: "Wood", bundle: .module)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    } else if style.usesWoodImage, let woodImage {
                        // The real grain, cropped to fill — same image the
                        // Wood backplate uses, so card and full-bleed agree.
                        Image(decorative: woodImage, scale: 1)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    } else if style.usesWoodImage {
                        Color(red: WidgetBoardStyle.gobanWood.red,
                              green: WidgetBoardStyle.gobanWood.green,
                              blue: WidgetBoardStyle.gobanWood.blue)
                    } else {
                        Color(red: 0.85, green: 0.68, blue: 0.40)
                    }
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
                .stroke(gridColor, lineWidth: style.gridLineWidth(cellSize: cell))
                let hoshi = WidgetBoardView.hoshiPoints(width: width, height: height)
                ForEach(Array(hoshi.enumerated()), id: \.offset) { _, p in
                    Circle().fill(gridColor)
                        .frame(width: hoshiDiameter, height: hoshiDiameter)
                        .position(CGPoint(x: originX + CGFloat(p.0) * cell, y: originY + CGFloat(p.1) * cell))
                }
                stoneLayer(cell: cell, originX: originX, originY: originY)
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
                    let marker = style.lastMoveMarkerDiameter(cellSize: cell)
                    Group {
                        if style.lastMoveIsFilledDot {
                            // The app board's marker: a small solid red dot,
                            // legible on both stone colors.
                            Circle().fill(Color.red)
                        } else if style.isAccented {
                            Circle().stroke(Color.white.opacity(0.9), lineWidth: max(cell * 0.08, 1))
                                .boardAccentable(true)
                        } else {
                            Circle().stroke(Color.red, lineWidth: max(cell * 0.08, 1))
                        }
                    }
                    .frame(width: marker, height: marker)
                    .position(CGPoint(x: originX + CGFloat(lm.x) * cell, y: originY + CGFloat(lm.y) * cell))
                }
                if showsLabels {
                    let offset = cell * 0.62
                    // Column letters (A–T, skipping I) above and below the grid.
                    ForEach(0..<width, id: \.self) { x in
                        let cx = originX + CGFloat(x) * cell
                        let label = WidgetBoardView.columnLabel(x)
                        coordinateLabel(label, cell: cell)
                            .position(x: cx, y: originY - offset)
                        coordinateLabel(label, cell: cell)
                            .position(x: cx, y: originY + CGFloat(height - 1) * cell + offset)
                    }
                    // Row numbers (1 at the bottom, increasing upward) on both sides.
                    ForEach(0..<height, id: \.self) { yy in
                        let cy = originY + CGFloat(yy) * cell
                        let number = "\(height - yy)"
                        coordinateLabel(number, cell: cell)
                            .position(x: originX - offset, y: cy)
                        coordinateLabel(number, cell: cell)
                            .position(x: originX + CGFloat(width - 1) * cell + offset, y: cy)
                    }
                }
            }
        }
    }
}

/// A flat-vector approximation of the 3D stones: an off-center radial
/// highlight (upper-left key light) over a darkening rim, plus a soft drop
/// shadow that scales with the stone. White additionally gets a faint dark
/// rim so it separates from the light wood underneath.
private struct SphericalStone: View {
    let isBlack: Bool
    let diameter: CGFloat

    var body: some View {
        let stops: [Gradient.Stop] = isBlack
            ? [.init(color: Color(white: 0.52), location: 0),
               .init(color: Color(white: 0.22), location: 0.45),
               .init(color: Color(white: 0.05), location: 1)]
            : [.init(color: .white, location: 0),
               .init(color: Color(white: 0.93), location: 0.55),
               .init(color: Color(white: 0.78), location: 1)]
        ZStack {
            Circle().fill(RadialGradient(stops: stops,
                                         center: UnitPoint(x: 0.37, y: 0.33),
                                         startRadius: 0,
                                         endRadius: diameter * 0.70))
            if !isBlack {
                Circle().strokeBorder(.black.opacity(0.12),
                                      lineWidth: max(diameter * 0.02, 0.5))
            }
        }
        .shadow(color: .black.opacity(WidgetBoardStyle.stoneShadowOpacity),
                radius: diameter * WidgetBoardStyle.stoneShadowRadiusRatio,
                x: 0, y: diameter * WidgetBoardStyle.stoneShadowYOffsetRatio)
    }
}
