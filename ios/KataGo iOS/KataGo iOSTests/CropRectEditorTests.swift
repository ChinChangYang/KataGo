//
//  CropRectEditorTests.swift
//  KataGo AnytimeTests
//
//  Pure-geometry tests for the crop UI's interaction model: aspect-fit
//  framing, normalized↔view mapping, drag classification (corner / edge /
//  interior / outside), and translation clamping (bounds + minimum size).
//

import CoreGraphics
import Testing
import GobanRecogKit

struct CropGeometryTests {

    @Test func fittedFrameLetterboxesLandscapeImageInSquare() {
        let frame = CropGeometry.fittedFrame(imageSize: CGSize(width: 200, height: 100),
                                             in: CGSize(width: 100, height: 100))
        #expect(frame == CGRect(x: 0, y: 25, width: 100, height: 50))
    }

    @Test func viewAndNormalizedRectsRoundTrip() {
        let frame = CGRect(x: 10, y: 20, width: 200, height: 100)
        let normalized = CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25)
        let view = CropGeometry.viewRect(fromNormalized: normalized, in: frame)
        #expect(view == CGRect(x: 60, y: 70, width: 100, height: 25))
        #expect(CropGeometry.normalizedRect(fromView: view, in: frame) == normalized)
    }

    @Test func degenerateInputsAreSafe() {
        #expect(CropGeometry.fittedFrame(imageSize: .zero, in: CGSize(width: 10, height: 10)) == .zero)
        // A zero frame maps back to the full-frame rect rather than dividing by zero.
        #expect(CropGeometry.normalizedRect(fromView: CGRect(x: 1, y: 1, width: 1, height: 1), in: .zero)
                == CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}

struct CropRectEditorTests {

    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
    private var editor: CropRectEditor { CropRectEditor(bounds: bounds) }
    private let rect = CGRect(x: 100, y: 100, width: 200, height: 100)

    @Test func classifiesCornersEdgesInteriorAndOutside() {
        #expect(editor.handles(at: CGPoint(x: 102, y: 98), in: rect) == [.minX, .minY])
        #expect(editor.handles(at: CGPoint(x: 298, y: 202), in: rect) == [.maxX, .maxY])
        #expect(editor.handles(at: CGPoint(x: 200, y: 103), in: rect) == .minY) // top edge
        #expect(editor.handles(at: CGPoint(x: 98, y: 150), in: rect) == .minX)  // left edge
        #expect(editor.handles(at: CGPoint(x: 200, y: 150), in: rect) == .move) // interior
        #expect(editor.handles(at: CGPoint(x: 390, y: 20), in: rect) == [])     // far outside
    }

    @Test func cornerDragResizesAndClampsToBoundsAndMinSize() {
        // TL corner dragged up-left past the bounds: clamps to bounds origin.
        let grown = editor.apply(translation: CGSize(width: -500, height: -500),
                                 handles: [.minX, .minY], to: rect)
        #expect(grown == CGRect(x: 0, y: 0, width: 300, height: 200))

        // TL corner dragged down-right past the far side: the minimum size
        // (15% of each bounds dimension) holds against the fixed maxX/maxY.
        let shrunk = editor.apply(translation: CGSize(width: 500, height: 500),
                                  handles: [.minX, .minY], to: rect)
        #expect(shrunk.maxX == rect.maxX)
        #expect(shrunk.maxY == rect.maxY)
        #expect(shrunk.width == bounds.width * 0.15)
        #expect(shrunk.height == bounds.height * 0.15)
    }

    @Test func edgeDragMovesOneSideOnlyAndIgnoresCrossAxis() {
        let out = editor.apply(translation: CGSize(width: 40, height: 999),
                               handles: .maxX, to: rect)
        #expect(out == CGRect(x: 100, y: 100, width: 240, height: 100))
    }

    @Test func moveDragTranslatesWithoutResizingAndClampsInsideBounds() {
        let out = editor.apply(translation: CGSize(width: 500, height: -500),
                               handles: .move, to: rect)
        #expect(out.size == rect.size)
        #expect(out.maxX == bounds.maxX)
        #expect(out.minY == bounds.minY)
    }

    @Test func emptyHandlesLeaveTheRectUntouched() {
        #expect(editor.apply(translation: CGSize(width: 50, height: 50),
                             handles: [], to: rect) == rect)
    }
}
