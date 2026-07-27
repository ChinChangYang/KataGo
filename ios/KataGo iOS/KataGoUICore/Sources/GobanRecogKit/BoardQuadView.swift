//
//  BoardQuadView.swift
//  GobanRecogKit
//
//  The board-grid control for the photo-import sheet: the photo aspect-fit in
//  the available space, a draggable quadrilateral over it, and the full N×N
//  lattice warped onto that quad so the user can SEE whether the app's idea of
//  the grid lands on the real board lines.
//
//  Replaces BoardCropView. The distinction that matters: a crop rect only said
//  "look here", whereas this quad's corners ARE the board's four outer
//  grid-line intersections, handed to the lattice fit directly. The overlay is
//  what makes that honest — a wrong board size or a misplaced corner is visible
//  immediately, because the drawn lines miss the wood.
//
//  Gesture handling and validity live in the unit-tested BoardQuadEditor; this
//  is a thin shell. It binds a normalized top-left-origin quad, the same [0,1]²
//  convention CropGeometry and BoardImageIngestion use.
//

import SwiftUI

public struct BoardQuadView: View {
    private let image: CGImage
    @Binding private var quad: BoardQuad // normalized, top-left origin
    private let boardSize: Int

    /// The gesture's start location, the quad at drag start, and what was
    /// grabbed; nil between drags. Keyed by startLocation for the same reason
    /// BoardCropView was: SwiftUI's DragGesture has no cancellation callback, so
    /// a gesture that ended without `onEnded` must not leak into the next one.
    /// Translations always apply to `start`, never to the live quad, so they
    /// cannot compound.
    @State private var drag: (startLocation: CGPoint,
                              start: BoardQuad,
                              grab: BoardQuadEditor.Grab)?
    /// Where to draw the magnifier, in view points; nil when nothing is being
    /// dragged.
    @State private var loupeTarget: CGPoint?

    private static let loupeDiameter: CGFloat = 108
    private static let loupeZoom: CGFloat = 3

    public init(image: CGImage, quad: Binding<BoardQuad>, boardSize: Int) {
        self.image = image
        self._quad = quad
        self.boardSize = boardSize
    }

    public var body: some View {
        GeometryReader { geo in
            let frame = CropGeometry.fittedFrame(
                imageSize: CGSize(width: image.width, height: image.height),
                in: geo.size)
            let editor = BoardQuadEditor(bounds: frame)
            let viewQuad = QuadGeometry.viewQuad(fromNormalized: quad, in: frame)

            ZStack {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                dimming(outside: viewQuad, in: geo.size)
                lattice(viewQuad)
                outline(viewQuad)
                handles(viewQuad)
                if let loupeTarget {
                    loupe(at: loupeTarget, frame: frame, in: geo.size)
                }
            }
            .contentShape(Rectangle())
            .gesture(quadGesture(editor: editor, frame: frame))
        }
        .aspectRatio(CGSize(width: image.width, height: image.height), contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Board grid")
        .accessibilityHint("Drag each corner onto the outermost line crossing of the board")
        .accessibilityIdentifier("BoardQuadView.gridArea")
    }

    // MARK: - Gesture

    private func quadGesture(editor: BoardQuadEditor, frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let active: (startLocation: CGPoint, start: BoardQuad, grab: BoardQuadEditor.Grab)
                if let drag, drag.startLocation == value.startLocation {
                    active = drag
                } else {
                    let current = QuadGeometry.viewQuad(fromNormalized: quad, in: frame)
                    guard let grab = editor.grab(at: value.startLocation, in: current) else {
                        return
                    }
                    active = (value.startLocation, current, grab)
                    drag = active
                }

                // A refused drag (self-intersecting, collapsed, or off the
                // image) simply leaves the last accepted quad standing, which
                // reads as the handle declining to cross rather than as the
                // whole shape jumping somewhere unexpected.
                guard let updated = editor.apply(translation: value.translation,
                                                 grab: active.grab,
                                                 to: active.start) else { return }
                quad = QuadGeometry.normalizedQuad(fromView: updated, in: frame)

                if case .corner(let corner) = active.grab {
                    loupeTarget = updated[corner]
                }
            }
            .onEnded { _ in
                drag = nil
                loupeTarget = nil
            }
    }

    // MARK: - Layers

    /// Dims everything outside the quad (even-odd fill punch-out), so the board
    /// the user is framing is the bright part.
    private func dimming(outside quad: BoardQuad, in size: CGSize) -> some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: size))
            path.addLines(quad.points)
            path.closeSubpath()
        }
        .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    /// The board's interior grid lines, warped through the quad. This is the
    /// feedback the whole control exists for: if these do not sit on the
    /// board's real lines, either a corner or the board size is wrong, and the
    /// user can see which.
    private func lattice(_ quad: BoardQuad) -> some View {
        Path { path in
            guard let homography = QuadHomography(unitSquareTo: quad) else { return }
            let points = homography.latticePoints(size: boardSize)
            guard points.count == boardSize,
                  points.allSatisfy({ $0.count == boardSize }) else { return }
            // Interior lines only — the four boundary lines are the outline,
            // drawn separately and more heavily.
            for index in 1..<(boardSize - 1) {
                path.move(to: points[index][0])
                path.addLines(points[index])
                path.move(to: points[0][index])
                path.addLines(points.map { $0[index] })
            }
        }
        .stroke(Color.white.opacity(0.55), lineWidth: 0.75)
        .allowsHitTesting(false)
    }

    private func outline(_ quad: BoardQuad) -> some View {
        Path { path in
            path.addLines(quad.points)
            path.closeSubpath()
        }
        .stroke(.white, lineWidth: 2)
        .allowsHitTesting(false)
    }

    /// The four corner grips. Purely decorative — hit-testing belongs to the
    /// editor's classification, which uses a grab radius larger than these.
    private func handles(_ quad: BoardQuad) -> some View {
        ForEach(BoardCorner.allCases, id: \.rawValue) { corner in
            let point = quad[corner]
            ZStack {
                Circle()
                    .fill(.white)
                    .frame(width: 18, height: 18)
                Circle()
                    .fill(.black.opacity(0.75))
                    .frame(width: 5, height: 5)
            }
            .position(x: point.x, y: point.y)
        }
        .allowsHitTesting(false)
    }

    /// A magnified inset of the photo centred on the corner being dragged.
    ///
    /// Precision is the entire job of this control, and a dragged corner sits
    /// under the fingertip — exactly where the user needs to look. The loupe is
    /// placed above the corner, flipping below when the corner is near the top
    /// edge, so it is never itself under the hand.
    private func loupe(at point: CGPoint, frame: CGRect, in size: CGSize) -> some View {
        let diameter = Self.loupeDiameter
        let zoom = Self.loupeZoom
        let gap = diameter * 0.85
        let above = point.y - gap - diameter / 2 >= 0
        let center = CGPoint(x: min(max(point.x, diameter / 2), size.width - diameter / 2),
                             y: above ? point.y - gap : point.y + gap)

        return ZStack {
            // Magnify about `point`: the image's own centre lands at the
            // loupe's centre by default, so shifting it by (centre − point)
            // in magnified units brings the dragged corner there instead.
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: frame.width * zoom, height: frame.height * zoom)
                .offset(x: (frame.midX - point.x) * zoom,
                        y: (frame.midY - point.y) * zoom)
            Path { path in
                let mid = diameter / 2
                path.move(to: CGPoint(x: mid - 12, y: mid))
                path.addLine(to: CGPoint(x: mid + 12, y: mid))
                path.move(to: CGPoint(x: mid, y: mid - 12))
                path.addLine(to: CGPoint(x: mid, y: mid + 12))
            }
            .stroke(.white, lineWidth: 1)
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
        .shadow(radius: 4)
        .position(center)
        .allowsHitTesting(false)
    }
}
