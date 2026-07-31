//
//  BoardQuadEditorTests.swift
//  KataGo AnytimeTests
//
//  Pins the board-grid geometry that replaced the crop rect: the closed-form
//  square-to-quad homography that warps the lattice onto the photo, the
//  convexity and area rules that decide whether a drag is committable, and the
//  hit-testing that decides what a drag is moving.
//
//  Supersedes CropRectEditorTests. The behaviour under test is different in
//  kind: a crop rect only had to stay inside the image, whereas this quad is
//  handed to the lattice fit as the board's actual corner intersections, so a
//  self-intersecting or collapsed shape is not merely ugly — it has no valid
//  homography and would produce a meaningless fit.
//

import CoreGraphics
import Foundation
import Testing
@testable import GobanRecogKit

private let epsilon: CGFloat = 1e-9

private func expectClose(_ a: CGPoint, _ b: CGPoint,
                         tolerance: CGFloat = 1e-9,
                         sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(abs(a.x - b.x) <= tolerance, "x: \(a.x) vs \(b.x)", sourceLocation: sourceLocation)
    #expect(abs(a.y - b.y) <= tolerance, "y: \(a.y) vs \(b.y)", sourceLocation: sourceLocation)
}

private let unitFrame = CGRect(x: 0, y: 0, width: 100, height: 100)

private func rectQuad(_ rect: CGRect) -> BoardQuad {
    BoardQuad(topLeft: CGPoint(x: rect.minX, y: rect.minY),
              topRight: CGPoint(x: rect.maxX, y: rect.minY),
              bottomRight: CGPoint(x: rect.maxX, y: rect.maxY),
              bottomLeft: CGPoint(x: rect.minX, y: rect.maxY))
}

// MARK: - Homography

struct QuadHomographyTests {

    /// A quad with genuine perspective — no two sides parallel — so the
    /// projective terms are exercised rather than the affine shortcut.
    private let perspective = BoardQuad(topLeft: CGPoint(x: 10, y: 20),
                                        topRight: CGPoint(x: 180, y: 5),
                                        bottomRight: CGPoint(x: 210, y: 260),
                                        bottomLeft: CGPoint(x: 40, y: 230))

    @Test func theUnitSquareCornersLandOnTheQuadCorners() throws {
        let h = try #require(QuadHomography(unitSquareTo: perspective))
        expectClose(try #require(h.map(u: 0, v: 0)), perspective.topLeft, tolerance: 1e-9)
        expectClose(try #require(h.map(u: 1, v: 0)), perspective.topRight, tolerance: 1e-9)
        expectClose(try #require(h.map(u: 1, v: 1)), perspective.bottomRight, tolerance: 1e-9)
        expectClose(try #require(h.map(u: 0, v: 1)), perspective.bottomLeft, tolerance: 1e-9)
    }

    @Test func aParallelogramTakesTheAffineBranchAndStillMapsExactly() throws {
        // dx3 and dy3 both vanish here, which is the branch that would divide
        // by a degenerate determinant if it were not special-cased.
        let parallelogram = BoardQuad(topLeft: CGPoint(x: 0, y: 0),
                                      topRight: CGPoint(x: 100, y: 0),
                                      bottomRight: CGPoint(x: 120, y: 50),
                                      bottomLeft: CGPoint(x: 20, y: 50))
        let h = try #require(QuadHomography(unitSquareTo: parallelogram))
        expectClose(try #require(h.map(u: 0, v: 0)), parallelogram.topLeft)
        expectClose(try #require(h.map(u: 1, v: 0)), parallelogram.topRight)
        expectClose(try #require(h.map(u: 1, v: 1)), parallelogram.bottomRight)
        expectClose(try #require(h.map(u: 0, v: 1)), parallelogram.bottomLeft)
    }

    @Test func anAxisAlignedRectangleGivesEvenlySpacedLattice() throws {
        let h = try #require(QuadHomography(unitSquareTo: rectQuad(unitFrame)))
        let lattice = h.latticePoints(size: 5)
        #expect(lattice.count == 5)
        #expect(lattice.allSatisfy { $0.count == 5 })
        // 5 lines across 100 points = 25 pt spacing.
        expectClose(lattice[0][0], CGPoint(x: 0, y: 0), tolerance: 1e-9)
        expectClose(lattice[0][1], CGPoint(x: 25, y: 0), tolerance: 1e-9)
        expectClose(lattice[2][2], CGPoint(x: 50, y: 50), tolerance: 1e-9)
        expectClose(lattice[4][4], CGPoint(x: 100, y: 100), tolerance: 1e-9)
    }

    @Test func latticeCornersMatchTheQuadForEveryBoardSize() throws {
        let h = try #require(QuadHomography(unitSquareTo: perspective))
        for size in [9, 13, 19] {
            let lattice = h.latticePoints(size: size)
            #expect(lattice.count == size)
            expectClose(lattice[0][0], perspective.topLeft, tolerance: 1e-9)
            expectClose(lattice[0][size - 1], perspective.topRight, tolerance: 1e-9)
            expectClose(lattice[size - 1][size - 1], perspective.bottomRight, tolerance: 1e-9)
            expectClose(lattice[size - 1][0], perspective.bottomLeft, tolerance: 1e-9)
        }
    }

    @Test func perspectiveCompressesRowsTowardsTheFarEdge() throws {
        // A trapezoid whose short edge is at the top is a board seen with that
        // edge farther away, so evenly spaced board rows must BUNCH towards it.
        // For a trapezoid of height h with parallel edges w0 (far) and w1
        // (near), the projective midpoint is exactly h·w0/(w0+w1) — here
        // 100·20/120. If this came out at 50 the map would be silently affine
        // and the overlay would misreport the photo's perspective.
        let trapezoid = BoardQuad(topLeft: CGPoint(x: 40, y: 0),
                                  topRight: CGPoint(x: 60, y: 0),
                                  bottomRight: CGPoint(x: 100, y: 100),
                                  bottomLeft: CGPoint(x: 0, y: 100))
        let h = try #require(QuadHomography(unitSquareTo: trapezoid))
        let lattice = h.latticePoints(size: 3)
        #expect(abs(lattice[1][0].y - 100.0 * 20.0 / 120.0) < 1e-9)
        #expect(lattice[1][0].y < 50, "rows must bunch towards the far (short) edge")
    }

    @Test func aBoardSizeBelowTwoHasNoLattice() throws {
        let h = try #require(QuadHomography(unitSquareTo: rectQuad(unitFrame)))
        #expect(h.latticePoints(size: 1).isEmpty)
        #expect(h.latticePoints(size: 0).isEmpty)
    }

    @Test func aFullyCollapsedQuadNeverProducesNonFinitePoints() {
        // All four corners coincident. dx3/dy3 vanish, so this takes the affine
        // branch and yields a rank-deficient map rather than nil — the editor's
        // convexity and area rules are what refuse it. What must NOT happen is
        // a NaN leaking into the overlay's drawing code.
        let collapsed = BoardQuad(topLeft: .zero, topRight: .zero,
                                  bottomRight: .zero, bottomLeft: .zero)
        #expect(!collapsed.isConvex)
        #expect(!BoardQuadEditor(bounds: unitFrame).isUsable(collapsed))
        if let h = QuadHomography(unitSquareTo: collapsed) {
            for point in h.latticePoints(size: 9).flatMap({ $0 }) {
                #expect(point.x.isFinite && point.y.isFinite)
            }
        }
    }
}

// MARK: - Quad validity

struct BoardQuadValidityTests {

    @Test func aRectangleIsConvex() {
        #expect(rectQuad(unitFrame).isConvex)
    }

    @Test func aBowTieIsRejected() {
        // Swapping two adjacent corners crosses the edges. Its homography would
        // fold the lattice over itself.
        let bowTie = BoardQuad(topLeft: CGPoint(x: 0, y: 0),
                               topRight: CGPoint(x: 100, y: 0),
                               bottomRight: CGPoint(x: 0, y: 100),
                               bottomLeft: CGPoint(x: 100, y: 100))
        #expect(!bowTie.isConvex)
    }

    @Test func aConcaveQuadIsRejected() {
        // Bottom-right pulled inside the triangle of the other three.
        let concave = BoardQuad(topLeft: CGPoint(x: 0, y: 0),
                                topRight: CGPoint(x: 100, y: 0),
                                bottomRight: CGPoint(x: 40, y: 40),
                                bottomLeft: CGPoint(x: 0, y: 100))
        #expect(!concave.isConvex)
    }

    @Test func collinearCornersAreRejected() {
        let flat = BoardQuad(topLeft: CGPoint(x: 0, y: 0),
                             topRight: CGPoint(x: 50, y: 0),
                             bottomRight: CGPoint(x: 100, y: 0),
                             bottomLeft: CGPoint(x: 150, y: 0))
        #expect(!flat.isConvex)
    }

    @Test func areaIsTheShoelaceArea() {
        #expect(abs(rectQuad(unitFrame).area - 10_000) < epsilon)
    }

    @Test func insetProducesACenteredRectangle() {
        let quad = BoardQuad.inset(in: unitFrame, fraction: 0.1)
        expectClose(quad.topLeft, CGPoint(x: 10, y: 10))
        expectClose(quad.bottomRight, CGPoint(x: 90, y: 90))
        #expect(quad.isConvex)
    }

    @Test func containsAgreesWithTheShape() {
        let quad = rectQuad(unitFrame)
        #expect(quad.contains(CGPoint(x: 50, y: 50)))
        #expect(!quad.contains(CGPoint(x: -1, y: 50)))
        #expect(!quad.contains(CGPoint(x: 50, y: 101)))
    }
}

// MARK: - Editing

struct BoardQuadEditorTests {

    private let editor = BoardQuadEditor(bounds: unitFrame, grabRadius: 20)
    private var quad: BoardQuad { BoardQuad.inset(in: unitFrame, fraction: 0.1) }

    @Test func aTapOnACornerGrabsThatCorner() {
        #expect(editor.grab(at: CGPoint(x: 10, y: 10), in: quad) == .corner(.topLeft))
        #expect(editor.grab(at: CGPoint(x: 90, y: 10), in: quad) == .corner(.topRight))
        #expect(editor.grab(at: CGPoint(x: 90, y: 90), in: quad) == .corner(.bottomRight))
        #expect(editor.grab(at: CGPoint(x: 10, y: 90), in: quad) == .corner(.bottomLeft))
    }

    @Test func theNearestCornerWinsWhenTwoAreInRange() {
        let narrow = BoardQuad(topLeft: CGPoint(x: 40, y: 40),
                               topRight: CGPoint(x: 55, y: 40),
                               bottomRight: CGPoint(x: 55, y: 80),
                               bottomLeft: CGPoint(x: 40, y: 80))
        #expect(editor.grab(at: CGPoint(x: 44, y: 40), in: narrow) == .corner(.topLeft))
        #expect(editor.grab(at: CGPoint(x: 52, y: 40), in: narrow) == .corner(.topRight))
    }

    @Test func aCornerBeatsAnInteriorDrag() {
        // On a small quad every handle is also "inside". Interior winning there
        // would make the corners ungrabbable exactly when precision matters.
        let small = BoardQuad(topLeft: CGPoint(x: 40, y: 40),
                              topRight: CGPoint(x: 60, y: 40),
                              bottomRight: CGPoint(x: 60, y: 60),
                              bottomLeft: CGPoint(x: 40, y: 60))
        #expect(small.contains(CGPoint(x: 42, y: 42)))
        #expect(editor.grab(at: CGPoint(x: 42, y: 42), in: small) == .corner(.topLeft))
    }

    @Test func anInteriorTapMovesTheWholeQuad() {
        #expect(editor.grab(at: CGPoint(x: 50, y: 50), in: quad) == .move)
    }

    @Test func aTapOutsideEverythingIsIgnored() {
        #expect(editor.grab(at: CGPoint(x: 99, y: 50), in: quad) == nil)
    }

    @Test func draggingACornerMovesOnlyThatCorner() throws {
        let moved = try #require(editor.apply(translation: CGSize(width: 5, height: 5),
                                              grab: .corner(.topLeft),
                                              to: quad))
        expectClose(moved.topLeft, CGPoint(x: 15, y: 15))
        expectClose(moved.topRight, quad.topRight)
        expectClose(moved.bottomRight, quad.bottomRight)
        expectClose(moved.bottomLeft, quad.bottomLeft)
    }

    @Test func aCornerIsClampedToTheImage() throws {
        let moved = try #require(editor.apply(translation: CGSize(width: -50, height: -50),
                                              grab: .corner(.topLeft),
                                              to: quad))
        expectClose(moved.topLeft, CGPoint(x: 0, y: 0))
    }

    @Test func translationsNeverCompound() throws {
        // Both updates of one gesture apply to the DRAG-START quad, so the
        // second must land where the second translation says, not at the sum.
        let first = try #require(editor.apply(translation: CGSize(width: 5, height: 0),
                                              grab: .corner(.topLeft), to: quad))
        let second = try #require(editor.apply(translation: CGSize(width: 8, height: 0),
                                               grab: .corner(.topLeft), to: quad))
        expectClose(first.topLeft, CGPoint(x: 15, y: 10))
        expectClose(second.topLeft, CGPoint(x: 18, y: 10))
    }

    @Test func aDragThatWouldCrossTheEdgesIsRefused() {
        // Hauling the top-left past the top-right turns the quad into a bow
        // tie. nil lets the view keep the last accepted shape, which reads as
        // the handle refusing to cross.
        #expect(editor.apply(translation: CGSize(width: 85, height: 0),
                             grab: .corner(.topLeft),
                             to: quad) == nil)
    }

    @Test func aDragThatCollapsesTheQuadIsRefused() {
        // The 80×80 inset quad has area 6400. Pulling the top-left corner down
        // by 78 leaves 3280 — still convex, so only the area rule can catch it.
        let permissive = BoardQuadEditor(bounds: unitFrame, grabRadius: 20, minAreaFraction: 0.25)
        #expect(permissive.apply(translation: CGSize(width: 0, height: 78),
                                 grab: .corner(.topLeft),
                                 to: quad) != nil)

        let strict = BoardQuadEditor(bounds: unitFrame, grabRadius: 20, minAreaFraction: 0.5)
        #expect(strict.apply(translation: CGSize(width: 0, height: 78),
                             grab: .corner(.topLeft),
                             to: quad) == nil)
    }

    @Test func movingTheQuadIsAllOrNothing() throws {
        #expect(editor.apply(translation: CGSize(width: 5, height: 5),
                             grab: .move, to: quad) != nil)
        // Clamping individual corners would deform a shape the user is only
        // trying to reposition, so a move that leaves the image is refused.
        #expect(editor.apply(translation: CGSize(width: 50, height: 0),
                             grab: .move, to: quad) == nil)
    }

    @Test func movePreservesTheShape() throws {
        let moved = try #require(editor.apply(translation: CGSize(width: 5, height: -5),
                                              grab: .move, to: quad))
        #expect(abs(moved.area - quad.area) < 1e-9)
    }
}

// MARK: - Coordinate spaces

struct QuadGeometryTests {

    @Test func normalizedAndViewSpacesRoundTrip() {
        let frame = CGRect(x: 20, y: 40, width: 200, height: 300)
        let normalized = BoardQuad(topLeft: CGPoint(x: 0.1, y: 0.2),
                                   topRight: CGPoint(x: 0.9, y: 0.15),
                                   bottomRight: CGPoint(x: 0.95, y: 0.85),
                                   bottomLeft: CGPoint(x: 0.05, y: 0.8))
        let view = QuadGeometry.viewQuad(fromNormalized: normalized, in: frame)
        let back = QuadGeometry.normalizedQuad(fromView: view, in: frame)
        for (a, b) in zip(back.points, normalized.points) {
            expectClose(a, b, tolerance: 1e-12)
        }
    }

    @Test func normalizedTopLeftMapsToTheFramesOrigin() {
        let frame = CGRect(x: 20, y: 40, width: 200, height: 300)
        let quad = QuadGeometry.viewQuad(
            fromNormalized: rectQuad(CGRect(x: 0, y: 0, width: 1, height: 1)), in: frame)
        expectClose(quad.topLeft, CGPoint(x: 20, y: 40))
        expectClose(quad.bottomRight, CGPoint(x: 220, y: 340))
    }

    @Test func aDegenerateFrameFallsBackToTheFullFrame() {
        let quad = QuadGeometry.normalizedQuad(fromView: rectQuad(unitFrame), in: .zero)
        expectClose(quad.topLeft, CGPoint(x: 0, y: 0))
        expectClose(quad.bottomRight, CGPoint(x: 1, y: 1))
    }

    @Test func theBoundingRectClampsToTheUnitSquare() {
        // The auto-detection fallback crops to this rect, and the ingestion
        // seam takes a [0,1]² rect — an out-of-range corner must not leak out.
        let quad = BoardQuad(topLeft: CGPoint(x: -0.2, y: -0.1),
                             topRight: CGPoint(x: 1.3, y: 0.05),
                             bottomRight: CGPoint(x: 1.1, y: 1.4),
                             bottomLeft: CGPoint(x: 0.1, y: 0.9))
        let rect = QuadGeometry.boundingRect(of: quad)
        #expect(rect.minX == 0)
        #expect(rect.minY == 0)
        #expect(rect.maxX == 1)
        #expect(rect.maxY == 1)
    }

    @Test func theBoundingRectOfAnInsetQuadIsThatInset() {
        let quad = BoardQuad.inset(in: CGRect(x: 0, y: 0, width: 1, height: 1), fraction: 0.25)
        let rect = QuadGeometry.boundingRect(of: quad)
        #expect(abs(rect.minX - 0.25) < epsilon)
        #expect(abs(rect.width - 0.5) < epsilon)
    }
}

// MARK: - Fitted frame

/// `CropGeometry.fittedFrame` decides where the photo actually lands inside
/// `BoardQuadView`. It was an identity function while the view's own
/// `.aspectRatio` guaranteed a container of the image's ratio; once the view
/// is allowed to fill a greedy frame it does real letterboxing, and every
/// coordinate the grid editor speaks is measured from the rect it returns.
@Suite("Fitted frame")
struct FittedFrameTests {

    @Test func fillsAContainerOfTheSameRatio() {
        let frame = CropGeometry.fittedFrame(imageSize: CGSize(width: 1200, height: 1600),
                                             in: CGSize(width: 300, height: 400))
        expectClose(frame.origin, CGPoint(x: 0, y: 0))
        #expect(abs(frame.width - 300) <= epsilon)
        #expect(abs(frame.height - 400) <= epsilon)
    }

    @Test func letterboxesAWideContainerWithHorizontalBars() {
        // A 3:4 photo in a 4:3 container: height binds, bars left and right.
        let frame = CropGeometry.fittedFrame(imageSize: CGSize(width: 300, height: 400),
                                             in: CGSize(width: 400, height: 300))
        #expect(abs(frame.height - 300) <= epsilon)
        #expect(abs(frame.width - 225) <= epsilon)
        #expect(abs(frame.minX - 87.5) <= epsilon)
        #expect(abs(frame.minY - 0) <= epsilon)
    }

    @Test func letterboxesATallContainerWithVerticalBars() {
        // A 4:3 photo in a 3:4 container: width binds, bars top and bottom.
        let frame = CropGeometry.fittedFrame(imageSize: CGSize(width: 400, height: 300),
                                             in: CGSize(width: 300, height: 400))
        #expect(abs(frame.width - 300) <= epsilon)
        #expect(abs(frame.height - 225) <= epsilon)
        #expect(abs(frame.minX - 0) <= epsilon)
        #expect(abs(frame.minY - 87.5) <= epsilon)
    }

    /// The guard the grid editor's degenerate-frame protection keys on: a
    /// zero-sized container must produce an empty rect, never a rect that
    /// coordinates could be divided by.
    @Test(arguments: [
        CGSize(width: 0, height: 400),
        CGSize(width: 300, height: 0),
        CGSize(width: 0, height: 0),
    ])
    func degenerateContainerIsEmpty(container: CGSize) {
        let frame = CropGeometry.fittedFrame(imageSize: CGSize(width: 1200, height: 1600),
                                             in: container)
        #expect(frame.isEmpty)
    }

    @Test func degenerateImageIsEmpty() {
        let frame = CropGeometry.fittedFrame(imageSize: CGSize(width: 0, height: 0),
                                             in: CGSize(width: 300, height: 400))
        #expect(frame.isEmpty)
    }
}
