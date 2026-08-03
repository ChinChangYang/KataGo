import Testing
import SwiftUI
import UIKit
import KataGoGameStore
import KataGoUICore

struct WidgetBoardViewTests {
    /// The app-parity wood asset moved down into KataGoGameStore so the appex
    /// can draw the SAME wood.png as the in-app board. Regression guard for
    /// the asset move: it must resolve from the package bundle.
    @Test func woodAsset_resolvesFromKataGoGameStoreBundle() {
        #expect(UIImage(named: "Wood", in: .kataGoGameStore, with: nil) != nil)
    }

    /// The iOS/macOS widget board style (appGoban: wood.png, black grid, bold
    /// black app-style labels) renders at both widget-family extremes, in card
    /// and full-bleed modes, without collapsing or faulting.
    @MainActor @Test(arguments: [CGFloat(120), CGFloat(360)])
    func widgetBoardView_appGobanRendersToImage(side: CGFloat) {
        let card = WidgetBoardView(width: 19, height: 19,
                                   blackVertices: ["Q16", "D4"], whiteVertices: ["Q4"],
                                   showCoordinates: true,
                                   style: .appGoban(drawsOwnWood: true))
        #expect(ImageRenderer(content: card.frame(width: side, height: side)).uiImage != nil)

        let fullBleed = WidgetBoardView(width: 9, height: 9,
                                        blackVertices: ["C3"], whiteVertices: ["G7"],
                                        showCoordinates: true,
                                        style: .appGoban(drawsOwnWood: false))
        #expect(ImageRenderer(content: fullBleed.frame(width: side, height: side)).uiImage != nil)
    }
    @Test func parseVertex_handlesGTPCoordinates() {
        // 19x19: "A1" is bottom-left → grid (0, 18); "T19" top-right → (18, 0).
        #expect(parseVertex("A1", width: 19, height: 19)! == (0, 18))
        #expect(parseVertex("T19", width: 19, height: 19)! == (18, 0))
        #expect(parseVertex("Q16", width: 19, height: 19)! == (15, 3))
        #expect(parseVertex("", width: 19, height: 19) == nil)
        #expect(parseVertex("I5", width: 19, height: 19) == nil) // 'I' is skipped in GTP columns
    }

    @Test func parseVertex_handlesTwoLetterColumnsOnWideBoards() {
        // KataGo encodes columns ≥25 as "A"+letter (skipping I and AI), matching
        // Coordinate.xMap. 37x37: "AA" = col 25, "AM" = col 36.
        // Optional-chained (not force-unwrapped) so a regression fails gracefully.
        let aa = parseVertex("AA1", width: 37, height: 37)
        #expect(aa?.x == 25 && aa?.y == 36)
        let am = parseVertex("AM19", width: 37, height: 37)
        #expect(am?.x == 36 && am?.y == 18)
        #expect(parseVertex("AI1", width: 37, height: 37) == nil) // 'AI' is skipped, like 'I'
    }

    @Test func parseVertex_rejectsColumnBeyondWidth() {
        // The column must be bounded to 0..<width, mirroring the existing row
        // guard and Coordinate.init?(x:y:width:height:). On a 9x9 the rightmost
        // column is 'J' (index 8); without a width guard a wider column letter
        // returned an off-board (x ≥ width) coordinate and the widget drew a
        // stone outside the grid.
        #expect(parseVertex("J9", width: 9, height: 9)! == (8, 0)) // last valid column
        #expect(parseVertex("K9", width: 9, height: 9) == nil)     // one past the right edge
        #expect(parseVertex("T1", width: 9, height: 9) == nil)     // far off-board column
        // A two-letter column also out of range on a 19x19 board.
        #expect(parseVertex("AA1", width: 19, height: 19) == nil)
    }

    /// The crisp vector board renders to an image at every family's square size —
    /// from the small family (~120pt) up to the systemExtraLarge square (~360pt). It
    /// has no intrinsic size (greedy GeometryReader), so it must fill whatever square
    /// frame it's given rather than collapsing or faulting.
    @MainActor @Test(arguments: [CGFloat(120), CGFloat(360)])
    func widgetBoardView_rendersToImage(side: CGFloat) {
        let view = WidgetBoardView(width: 19, height: 19,
                                   blackVertices: ["Q16", "D4", "C16"], whiteVertices: ["Q4", "D16"])
        let renderer = ImageRenderer(content: view.frame(width: side, height: side))
        #expect(renderer.uiImage != nil)
    }

    /// visionOS creates any 2..37 board, square or rectangular, and those games
    /// reach the widget thumbnails and the watch (WatchBoardPage renders this
    /// same view) — the extremes must render, not collapse or fault.
    @MainActor @Test func widgetBoardView_rendersLargeRectangularAndTinyBoards() {
        let large = WidgetBoardView(width: 37, height: 37,
                                    blackVertices: ["AA1", "AM37"], whiteVertices: ["A1"])
        #expect(ImageRenderer(content: large.frame(width: 360, height: 360)).uiImage != nil)

        let rectangle = WidgetBoardView(width: 13, height: 9,
                                        blackVertices: ["C3"], whiteVertices: ["L7"])
        #expect(ImageRenderer(content: rectangle.frame(width: 360, height: 360)).uiImage != nil)

        let tiny = WidgetBoardView(width: 2, height: 2,
                                   blackVertices: ["A1"], whiteVertices: [])
        #expect(ImageRenderer(content: tiny.frame(width: 120, height: 120)).uiImage != nil)
    }

    /// The crisp vector board (now the only widget renderer) draws star points so
    /// it reads as a real goban, matching the standard hoshi layout per board size.
    /// Counts/booleans are computed into locals first: passing a non-empty
    /// `[(Int, Int)]` directly into `#expect` crashes the swift-testing macro's
    /// expression reflection (an empty tuple-array is fine, a single tuple is fine).
    @Test func hoshiPoints_standardSquareSizes() {
        let count19 = WidgetBoardView.hoshiPoints(width: 19, height: 19).count
        let count13 = WidgetBoardView.hoshiPoints(width: 13, height: 13).count
        let count9 = WidgetBoardView.hoshiPoints(width: 9, height: 9).count
        #expect(count19 == 9)   // 3×3 grid {3,9,15}
        #expect(count13 == 5)   // 4 corners + center
        #expect(count9 == 5)

        let has9Tengen = WidgetBoardView.hoshiPoints(width: 9, height: 9).contains { $0.0 == 4 && $0.1 == 4 }
        let has19Tengen = WidgetBoardView.hoshiPoints(width: 19, height: 19).contains { $0.0 == 9 && $0.1 == 9 }
        #expect(has9Tengen)
        #expect(has19Tengen)
    }

    /// Samples one pixel of a rendered view via a 1x1 sRGB context, in
    /// top-left image coordinates (CGContext draws bottom-up, hence the flip).
    @MainActor private func pixel(of view: some View, size: CGFloat,
                                  x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        let renderer = ImageRenderer(content: view.frame(width: size, height: size))
        guard let cg = renderer.cgImage,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &buffer, width: 1, height: 1,
                                  bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: CGFloat(-x), y: CGFloat(-(cg.height - 1 - y)),
                                width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return (buffer[0], buffer[1], buffer[2], buffer[3])
    }

    /// The goban style renders at both widget-family extremes, with and
    /// without the wood image, in both card and full-bleed modes.
    @MainActor @Test(arguments: [CGFloat(120), CGFloat(360)])
    func widgetBoardView_gobanRendersToImage(side: CGFloat) {
        let wood = WidgetWoodTexture.texture(widthPX: 64, heightPX: 64).cgImage
        let card = WidgetBoardView(width: 19, height: 19,
                                   blackVertices: ["Q16", "D4"], whiteVertices: ["Q4"],
                                   style: .goban(drawsOwnWood: true), woodImage: wood)
        #expect(ImageRenderer(content: card.frame(width: side, height: side)).uiImage != nil)

        let fullBleed = WidgetBoardView(width: 9, height: 9,
                                        blackVertices: ["C3"], whiteVertices: ["G7"],
                                        style: .goban(drawsOwnWood: false), woodImage: wood)
        #expect(ImageRenderer(content: fullBleed.frame(width: side, height: side)).uiImage != nil)

        let noImageFallback = WidgetBoardView(width: 9, height: 9,
                                              blackVertices: ["C3"], whiteVertices: [],
                                              style: .goban(drawsOwnWood: true))
        #expect(ImageRenderer(content: noImageFallback.frame(width: side, height: side)).uiImage != nil)
    }

    /// The wood-card goban actually paints wood: a margin pixel (outside the
    /// grid) reads warm wood — red high and materially above blue, ruling out
    /// both a transparent miss and the pre-redesign flat gray/black.
    @MainActor @Test func widgetBoardView_gobanCardPaintsWood() {
        let wood = WidgetWoodTexture.texture(widthPX: 64, heightPX: 64).cgImage
        let view = WidgetBoardView(width: 9, height: 9, blackVertices: [], whiteVertices: [],
                                   style: .goban(drawsOwnWood: true), woodImage: wood)
        guard let corner = pixel(of: view, size: 200, x: 4, y: 4) else {
            Issue.record("render produced no image")
            return
        }
        #expect(corner.a == 255)
        #expect(corner.r > 150)
        #expect(Int(corner.r) - Int(corner.b) > 50)
    }

    /// Full-bleed mode draws NOTHING behind the grid — the widget backplate
    /// already is the wood, and a second slab would create a grain seam. The
    /// same margin pixel must stay fully transparent.
    @MainActor @Test func widgetBoardView_gobanFullBleedLeavesMarginTransparent() {
        let wood = WidgetWoodTexture.texture(widthPX: 64, heightPX: 64).cgImage
        let view = WidgetBoardView(width: 9, height: 9, blackVertices: [], whiteVertices: [],
                                   style: .goban(drawsOwnWood: false), woodImage: wood)
        guard let corner = pixel(of: view, size: 200, x: 4, y: 4) else {
            Issue.record("render produced no image")
            return
        }
        #expect(corner.a == 0)
    }

    /// The Saved Game widget now always shows coordinate labels (the goban
    /// styles pass showCoordinates: true). The labeled board must render at
    /// both widget-family extremes without collapsing or faulting.
    @MainActor @Test(arguments: [CGFloat(120), CGFloat(360)])
    func widgetBoardView_rendersCoordinatesToImage(side: CGFloat) {
        let wood = WidgetWoodTexture.texture(widthPX: 64, heightPX: 64).cgImage
        let card = WidgetBoardView(width: 19, height: 19,
                                   blackVertices: ["Q16", "D4"], whiteVertices: ["Q4"],
                                   showCoordinates: true,
                                   style: .goban(drawsOwnWood: true), woodImage: wood)
        #expect(ImageRenderer(content: card.frame(width: side, height: side)).uiImage != nil)

        let fullBleed = WidgetBoardView(width: 9, height: 9,
                                        blackVertices: ["C3"], whiteVertices: ["G7"],
                                        showCoordinates: true,
                                        style: .goban(drawsOwnWood: false), woodImage: wood)
        #expect(ImageRenderer(content: fullBleed.frame(width: side, height: side)).uiImage != nil)
    }

    /// The appGoban label is clipped to a cell-sized frame, so it TRUNCATES —
    /// not merely smears — once the cell pitch falls under the widest label's
    /// width at the 5 pt font floor. The old gate let everything down to 4 pt
    /// through, which is why a 19x19 in the small widget families drew a bare
    /// "…" — not even a leading digit — for every row number 10-19.
    @Test func coordinateLabelsFit_gatesOnCellPitch() {
        // Small-family board square: a 19x19 lands at cell ≈ 5.1 pt and needs
        // 7.34 pt for "NN", so it now drops its labels; a 9x9 (cell ≈ 10.8 pt,
        // single-digit rows, needing only the 5.97 pt line height) keeps them.
        let small = CGSize(width: 110, height: 110)
        #expect(!WidgetBoardView.coordinateLabelsFit(size: small, width: 19, height: 19))
        #expect(WidgetBoardView.coordinateLabelsFit(size: small, width: 9, height: 9))
        #expect(!WidgetBoardView.coordinateLabelsFit(size: small, width: 37, height: 37))

        // A 19x19 needs a board square of ~158 pt; large/extraLarge clear that
        // easily. A 37x37 needs ~383 pt because "AM" is the widest label there,
        // so 320 pt is NOT enough for it (the old gate wrongly allowed it).
        let large = CGSize(width: 320, height: 320)
        #expect(WidgetBoardView.coordinateLabelsFit(size: large, width: 19, height: 19))
        #expect(!WidgetBoardView.coordinateLabelsFit(size: large, width: 37, height: 37))
        #expect(WidgetBoardView.coordinateLabelsFit(size: CGSize(width: 400, height: 400),
                                                    width: 37, height: 37))

        // Rectangular boards gate on their LONG side (the colliding one).
        #expect(!WidgetBoardView.coordinateLabelsFit(size: small, width: 37, height: 2))
    }

    /// The real per-family geometry, MEASURED off widgets actually placed on an
    /// iPhone 17 Home Screen (board card ≈ 109 pt small, ≈ 117 pt medium,
    /// ≈ 263 pt large). Pins the device reality behind the reported bug so a
    /// future layout change — a different margin fraction, a taller caption, a
    /// new stack spacing — that pushes a 19x19 back over the line fails here
    /// instead of shipping truncated labels again.
    @Test func measuredFamilyGeometry_matchesTheShippedBehavior() {
        let small = CGSize(width: 109, height: 109)
        #expect(!WidgetBoardView.coordinateLabelsFit(size: small, width: 19, height: 19))
        #expect(WidgetBoardView.coordinateLabelsFit(size: small, width: 9, height: 9))
        #expect(WidgetBoardView.coordinateLabelsFit(size: small, width: 13, height: 13))

        // Medium's board is height-bounded and barely larger, so a 19x19 was
        // truncating there too even though only the small family was reported.
        let medium = CGSize(width: 117, height: 117)
        #expect(!WidgetBoardView.coordinateLabelsFit(size: medium, width: 19, height: 19))

        // Large is where a 19x19 earns its coordinates back.
        let large = CGSize(width: 263, height: 263)
        #expect(WidgetBoardView.coordinateLabelsFit(size: large, width: 19, height: 19))
    }

    /// The requirement collapses to three cases: single-digit boards are bound
    /// by the label's LINE HEIGHT (a width-only rule would stack 5.89 pt labels
    /// 3.7 pt apart), taller boards by their two-digit row numbers, and boards
    /// past 25 columns by their "A"+letter column labels.
    @Test func requiredCell_bindsOnTheWidestLabelTheBoardDraws() {
        let floor = WidgetCoordinateMetrics.fontFloor
        let lineHeight = floor * WidgetCoordinateMetrics.lineHeightEm
        let twoDigits = floor * 2 * WidgetCoordinateMetrics.maxDigitAdvanceEm
        let twoLetters = floor * (WidgetCoordinateMetrics.capitalAAdvanceEm
                                  + WidgetCoordinateMetrics.maxLetterAdvanceEm)

        #expect(WidgetCoordinateMetrics.requiredCell(width: 9, height: 9) == lineHeight)
        #expect(WidgetCoordinateMetrics.requiredCell(width: 19, height: 19) == twoDigits)
        #expect(WidgetCoordinateMetrics.requiredCell(width: 37, height: 37) == twoLetters)
        // Wide but short: the columns still need the two-letter width.
        #expect(WidgetCoordinateMetrics.requiredCell(width: 37, height: 9) == twoLetters)
        // Tall but narrow: rows drive it.
        #expect(WidgetCoordinateMetrics.requiredCell(width: 9, height: 19) == twoDigits)
        // Strictly increasing across the three classes.
        #expect(lineHeight < twoDigits)
        #expect(twoDigits < twoLetters)
    }

    /// The drift guard for the hardcoded em constants. They are worst-case SF
    /// Bold advances measured at the font floor; if a future SF revision grows
    /// a glyph past them the gate would start passing boards whose labels
    /// truncate again, so re-measure against the REAL system font here.
    @Test func coordinateMetrics_boundRealSystemFontAdvances() {
        let floor = WidgetCoordinateMetrics.fontFloor
        let font = UIFont.boldSystemFont(ofSize: floor)
        func advance(_ s: String) -> CGFloat {
            (s as NSString).size(withAttributes: [.font: font]).width
        }
        let widestDigit = (0...9).map { advance(String($0)) }.max() ?? .infinity
        let widestLetter = "ABCDEFGHJKLMNOPQRSTUVWXYZ"
            .map { advance(String($0)) }.max() ?? .infinity

        #expect(widestDigit <= floor * WidgetCoordinateMetrics.maxDigitAdvanceEm)
        #expect(widestLetter <= floor * WidgetCoordinateMetrics.maxLetterAdvanceEm)
        #expect(advance("A") <= floor * WidgetCoordinateMetrics.capitalAAdvanceEm)
        #expect(font.lineHeight <= floor * WidgetCoordinateMetrics.lineHeightEm)
    }

    /// The end-to-end promise: at exactly the required cell pitch, EVERY label
    /// the board actually draws fits inside its own cell-sized frame at the
    /// font floor — i.e. nothing truncates. Builds the real label set from
    /// `columnLabel` and the row numbers rather than trusting the em algebra.
    @Test(arguments: [(9, 9), (13, 13), (19, 19), (37, 37), (19, 13), (26, 26)])
    func requiredCell_fitsEveryLabelTheBoardDraws(board: (width: Int, height: Int)) {
        let floor = WidgetCoordinateMetrics.fontFloor
        let font = UIFont.boldSystemFont(ofSize: floor)
        let labels = (0..<board.width).map { WidgetBoardView.columnLabel($0) }
            + (1...board.height).map { String($0) }
        let widest = labels
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? .infinity
        let required = WidgetCoordinateMetrics.requiredCell(width: board.width,
                                                            height: board.height)
        #expect(widest <= required)
        #expect(font.lineHeight <= required)
    }

    /// Reserving the coordinate margin shrinks the GRID, never the card: the
    /// wood still fills the whole frame, so the corner pixel (now inside the
    /// label band) keeps reading as warm wood.
    @MainActor @Test func widgetBoardView_coordinateMarginStaysWoodInCardMode() {
        let wood = WidgetWoodTexture.texture(widthPX: 64, heightPX: 64).cgImage
        let view = WidgetBoardView(width: 9, height: 9, blackVertices: [], whiteVertices: [],
                                   showCoordinates: true,
                                   style: .goban(drawsOwnWood: true), woodImage: wood)
        guard let corner = pixel(of: view, size: 200, x: 4, y: 4) else {
            Issue.record("render produced no image")
            return
        }
        #expect(corner.a == 255)
        #expect(corner.r > 150)
        #expect(Int(corner.r) - Int(corner.b) > 50)
    }

    /// Where the best-move probe samples. On a 9x9 drawn into 200 pt with
    /// coordinates off the margin is 0, so the cell is 200/9 = 22.222 pt and
    /// the origin is (200 - 8 * 22.222)/2 = 11.111 pt. "D5" is grid (3, 4) —
    /// column D is index 3, and GTP row 5 flips to y = 9 - 5 — which lands at
    /// (11.111 + 3 * 22.222, 11.111 + 4 * 22.222) = (77.8, 100).
    ///
    /// Deliberately NOT the centre point "E5": grid (4, 4) is the 9x9 tengen,
    /// and a star point is painted in the opaque grid ink, so a "this pixel is
    /// bare wood" control would read black there and pass or fail for the
    /// wrong reason.
    private static let bestMoveProbe = (vertex: "D5", x: 78, y: 100)

    /// Blue minus red for a sampled pixel. The marker fill is RGB(0, 1, 1) at
    /// 0.8 opacity, so anywhere it paints this is strongly positive; wood is
    /// strongly negative (r ≈ 216, b ≈ 92) and the grid ink is ~0.
    private func cyanness(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Int {
        Int(p.b) - Int(p.r)
    }

    /// The cached best move paints the in-app board's marker AT the requested
    /// intersection: a full-cell disc in the top-candidate color (hue 0.5 /
    /// sat 1 / bri 1 at 0.8 opacity, i.e. cyan), ringed in blue.
    @MainActor @Test func bestMoveVertex_paintsTheAnalysisMarkerAtTheGridPoint() {
        let probe = Self.bestMoveProbe
        let view = WidgetBoardView(width: 9, height: 9, blackVertices: [], whiteVertices: [],
                                   bestMoveVertex: probe.vertex,
                                   style: .appGoban(drawsOwnWood: true))
        guard let sample = pixel(of: view, size: 200, x: probe.x, y: probe.y) else {
            Issue.record("render produced no image")
            return
        }
        #expect(sample.a == 255)
        #expect(sample.b > 150)
        #expect(sample.g > 150)
        #expect(cyanness(sample) > 100)
    }

    /// The A/B control: the same board WITHOUT the marker is not cyan at that
    /// intersection, so the test above is measuring the marker and not the
    /// board's own colouring. (The bare intersection is a grid crossing —
    /// opaque ink — so this is near 0 rather than wood's negative value.)
    @MainActor @Test func bestMoveVertex_absentLeavesTheIntersectionUnmarked() {
        let probe = Self.bestMoveProbe
        let view = WidgetBoardView(width: 9, height: 9, blackVertices: [], whiteVertices: [],
                                   style: .appGoban(drawsOwnWood: true))
        guard let sample = pixel(of: view, size: 200, x: probe.x, y: probe.y) else {
            Issue.record("render produced no image")
            return
        }
        #expect(cyanness(sample) < 50)
    }

    /// A cached "pass" — which `Coordinate.move` really does return, and which
    /// `GobanState.maybeUpdateAnalysisData` stores verbatim — is unparseable,
    /// so the board draws nothing rather than putting a marker on some wrong
    /// intersection. Callers that must not show an unchanged board are
    /// expected to classify it first (`WatchBoardFrame.bestMoveMark`).
    ///
    /// Sweeps every intersection rather than one probe point, so a regression
    /// that mapped an unparseable vertex onto SOME point (say (0,0)) is caught
    /// wherever it landed.
    @MainActor @Test(arguments: ["pass", "I5", "Z99", ""])
    func bestMoveVertex_unparseableDrawsNothingAnywhere(vertex: String) {
        let view = WidgetBoardView(width: 9, height: 9, blackVertices: [], whiteVertices: [],
                                   bestMoveVertex: vertex,
                                   style: .appGoban(drawsOwnWood: true))
        let geometry = WidgetBoardGeometry(width: 9, height: 9,
                                           size: CGSize(width: 200, height: 200))
        for gx in 0..<9 {
            for gy in 0..<9 {
                let point = geometry.position(x: gx, y: gy)
                guard let sample = pixel(of: view, size: 200,
                                         x: Int(point.x.rounded()),
                                         y: Int(point.y.rounded())) else {
                    Issue.record("render produced no image")
                    return
                }
                #expect(cyanness(sample) < 50,
                        "\(vertex) drew a marker at grid (\(gx), \(gy))")
            }
        }
    }

    /// The spherical stones moved from a view-per-stone `ForEach` into one
    /// `Canvas` of two sprites (`SphericalStoneLayer`), because the watch now
    /// re-evaluates the whole board on every Digital Crown detent. Every
    /// goban-family variant that renders spherical stones must still produce
    /// an image, at both extremes of board size.
    @MainActor @Test(arguments: [CGFloat(120), CGFloat(360)])
    func sphericalStoneLayer_rendersEveryGobanVariant(side: CGFloat) {
        let wood = WidgetWoodTexture.texture(widthPX: 64, heightPX: 64).cgImage
        let appGoban = WidgetBoardView(width: 19, height: 19,
                                       blackVertices: ["Q16", "D4"], whiteVertices: ["Q4", "D16"],
                                       style: .appGoban(drawsOwnWood: true))
        #expect(ImageRenderer(content: appGoban.frame(width: side, height: side)).uiImage != nil)

        let goban = WidgetBoardView(width: 9, height: 9,
                                    blackVertices: ["C3"], whiteVertices: ["G7"],
                                    style: .goban(drawsOwnWood: true), woodImage: wood)
        #expect(ImageRenderer(content: goban.frame(width: side, height: side)).uiImage != nil)

        // The dense case the batching exists for: 37x37 with a full board.
        let dense = WidgetBoardView(
            width: 37, height: 37,
            blackVertices: (1...37).map { "AA\($0)" },
            whiteVertices: (1...37).map { "AB\($0)" },
            style: .appGoban(drawsOwnWood: true))
        #expect(ImageRenderer(content: dense.frame(width: side, height: side)).uiImage != nil)
    }

    /// REGRESSION GUARD for the sprite padding. `SphericalStoneLayer` pads its
    /// Canvas sprite by `stoneShadowExtent`; a Canvas symbol is rasterized at
    /// its layout size, so too little padding shears the shadow off square at
    /// the stone's edge.
    ///
    /// This is not theoretical — it shipped in the first cut of the batching.
    /// A/B rendering the batched Canvas against the per-view drawing it
    /// replaced (2026-08-04, 9x9 at 109 pt, scale 3) measured stone ink 5.41%
    /// LIGHT at a blur factor of 3, against a 50%-contrast edge radius that
    /// moved only 0.25 px — the stone was the right size, the shadow was
    /// clipped. It converged to 0.05% from ~0.55 x diameter upward. Tightening
    /// the extent back below that floor must fail here.
    @Test func stoneShadowExtent_clearsTheMeasuredClippingFloor() {
        for diameter in [4.0, 10.0, 33.4, 120.0] {
            let extent = WidgetBoardStyle.stoneShadowExtent(diameter: diameter)
            #expect(extent >= diameter * WidgetBoardStyle.stoneShadowExtentFloorRatio)
        }
        // Scales linearly with the stone, so one ratio governs every size.
        let unit = WidgetBoardStyle.stoneShadowExtent(diameter: 1)
        #expect(abs(WidgetBoardStyle.stoneShadowExtent(diameter: 50) - unit * 50) < 1e-9)
        // And it must actually cover the shadow it is derived from: the blur
        // reach plus the downward offset.
        #expect(unit > WidgetBoardStyle.stoneShadowRadiusRatio * 3
                       + WidgetBoardStyle.stoneShadowYOffsetRatio)
    }

    /// REGRESSION GUARD for the Canvas switch. A `Canvas` is greedy — it fills
    /// the frame it is given — so if it ever painted a background (or were
    /// constructed `opaque:`), the full-bleed goban would stop being
    /// transparent outside its grid and the widget backplate's wood would show
    /// a seam. `widgetBoardView_gobanFullBleedLeavesMarginTransparent` covers
    /// the empty board; this covers the board WITH stones, which is the case
    /// that actually instantiates the stone layer.
    @MainActor @Test func sphericalStoneLayer_leavesTheFullBleedMarginTransparent() {
        let wood = WidgetWoodTexture.texture(widthPX: 64, heightPX: 64).cgImage
        let view = WidgetBoardView(width: 9, height: 9,
                                   blackVertices: ["C3", "E5"], whiteVertices: ["G7"],
                                   style: .goban(drawsOwnWood: false), woodImage: wood)
        guard let corner = pixel(of: view, size: 200, x: 4, y: 4) else {
            Issue.record("render produced no image")
            return
        }
        #expect(corner.a == 0)
    }

    /// Non-standard and rectangular boards now get star points too, from the
    /// shared BoardStarPoints rule (even sizes still have none).
    @Test func hoshiPoints_nonStandardSizes_useSharedRule() {
        let count7 = WidgetBoardView.hoshiPoints(width: 7, height: 7).count
        let count19x13 = WidgetBoardView.hoshiPoints(width: 19, height: 13).count
        let count37 = WidgetBoardView.hoshiPoints(width: 37, height: 37).count
        #expect(count7 == 5)      // corners + tengen
        #expect(count19x13 == 5)  // corner crosses + tengen, no mixed side stars
        #expect(count37 == 9)     // full 3x3 grid, like 19x19
        #expect(WidgetBoardView.hoshiPoints(width: 24, height: 24).isEmpty)
    }
}
