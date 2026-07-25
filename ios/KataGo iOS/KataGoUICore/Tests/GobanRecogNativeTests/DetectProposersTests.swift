//
//  DetectProposersTests.swift
//  GobanRecogNativeTests
//
//  Native tests for the gr_detect_proposers port of gobanrecog/pipeline/
//  detect.py part A (Task 7): the shared geometry helpers (_order_quad,
//  _degenerate_quad), the approxPolyDP corner sweep shared by the hull/texture/
//  slab proposers, and the pure hough line-family clustering
//  (_line_params/_extreme_lines/_intersect). Ground truth generated with the
//  reference venv (numpy 2.5.1, cv2 5.0.0); the generating snippets are inline.
//
//  The full end-to-end proposer parity (Canny/Hough/box-filter cv ops on real
//  images) is covered by the gobanrecog-dev `proposers` micro-parity harness;
//  these tests pin the PORTED numpy/geometry logic bit-exactly, isolated from
//  the HAL-diverging cv ops.
//

import CGobanRecog
import Foundation
import Testing

// MARK: - Bridge helpers

private func orderQuad(_ pts8: [Double]) -> [Double] {
    var out = [Double](repeating: 0, count: 8)
    pts8.withUnsafeBufferPointer { pp in
        out.withUnsafeMutableBufferPointer { op in
            gobanrecog.testbridge.detect_order_quad(pp.baseAddress, op.baseAddress)
        }
    }
    return out
}

private func degenerateQuad(_ quad8: [Double]) -> Bool {
    let r = quad8.withUnsafeBufferPointer { qp in
        gobanrecog.testbridge.detect_degenerate_quad(qp.baseAddress)
    }
    return r != 0
}

private func hullSweep(_ hullXY: [Int32]) -> [Double]? {
    var out = [Double](repeating: 0, count: 8)
    let ok = hullXY.withUnsafeBufferPointer { hp in
        out.withUnsafeMutableBufferPointer { op in
            gobanrecog.testbridge.detect_hull_sweep(hp.baseAddress, Int32(hullXY.count / 2),
                                                    op.baseAddress)
        }
    }
    return ok != 0 ? out : nil
}

private func houghFromSegments(_ segs: [Int32]) -> (quad: [Double]?, reason: String) {
    var out = [Double](repeating: 0, count: 8)
    var reason = [CChar](repeating: 0, count: 128)
    let ok = segs.withUnsafeBufferPointer { sp in
        out.withUnsafeMutableBufferPointer { op in
            reason.withUnsafeMutableBufferPointer { rp in
                gobanrecog.testbridge.detect_hough_from_segments(
                    sp.baseAddress, Int32(segs.count / 4), op.baseAddress, rp.baseAddress, 128)
            }
        }
    }
    // Pointer form: String(cString:) on an *array* is deprecated in Swift 6.
    let reasonText = reason.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    return (ok != 0 ? out : nil, reasonText)
}

private func expectQuad(_ a: [Double], _ b: [Double], tol: Double = 0.0, _ what: String) {
    #expect(a.count == b.count)
    for i in 0..<min(a.count, b.count) {
        if tol == 0.0 {
            #expect(a[i] == b[i], "\(what)[\(i)]: \(a[i]) != \(b[i])")
        } else {
            #expect(abs(a[i] - b[i]) <= tol, "\(what)[\(i)]: |\(a[i]) - \(b[i])| > \(tol)")
        }
    }
}

// MARK: - _order_quad (detect.py:51-54)

@Test
func orderQuadSortsScrambledSquareToTLTRBRBL() {
    // venv: pts = [[10,80],[70,10],[10,10],[70,80]] (BL,TR,TL,BR scrambled)
    //       _order_quad(pts) -> [[10,10],[70,10],[70,80],[10,80]]
    let out = orderQuad([10, 80, 70, 10, 10, 10, 70, 80])
    expectQuad(out, [10, 10, 70, 10, 70, 80, 10, 80], "order_quad(square)")
}

@Test
func orderQuadKeepsAlreadyOrderedObliqueQuad() {
    // venv: _order_quad([[30,10],[90,40],[60,95],[5,55]]) -> same (already TL,TR,BR,BL)
    let out = orderQuad([30, 10, 90, 40, 60, 95, 5, 55])
    expectQuad(out, [30, 10, 90, 40, 60, 95, 5, 55], "order_quad(oblique)")
}

// MARK: - _degenerate_quad (detect.py:57-66)

@Test
func degenerateQuadFalseForRealSquareTrueForCollapsedCorner() {
    // venv: _degenerate_quad([[10,10],[70,10],[70,80],[10,80]]) -> False
    #expect(degenerateQuad([10, 10, 70, 10, 70, 80, 10, 80]) == false)
    // venv: _degenerate_quad([[0,0],[0,0],[100,0],[100,100]]) -> True (dup corner)
    #expect(degenerateQuad([0, 0, 0, 0, 100, 0, 100, 100]) == true)
}

// MARK: - approxPolyDP corner sweep (detect.py:80-85, shared by hull/texture/slab)

@Test
func hullSweepReducesBeveledSquareToFourOrderedCorners() {
    // venv: hull = [[70,50],[430,50],[450,70],[450,430],[430,450],[70,450],
    //               [50,430],[50,70]] (a big square with beveled corners);
    //       arcLength + arange(0.01,0.12,0.01) sweep + approxPolyDP -> 4 verts;
    //       _order_quad(...) -> [[70,50],[450,70],[430,450],[50,430]]
    let hull: [Int32] = [70, 50, 430, 50, 450, 70, 450, 430,
                         430, 450, 70, 450, 50, 430, 50, 70]
    let quad = hullSweep(hull)
    #expect(quad != nil)
    if let q = quad {
        expectQuad(q, [70, 50, 450, 70, 430, 450, 50, 430], "hull sweep")
    }
}

// MARK: - hough line-family clustering (detect.py:88-162, pure tail)

@Test
func houghQuadFromCleanRectangleSegments() {
    // venv: four segments forming a rectangle (top y=100, bottom y=400,
    //       left x=100, right x=400); _line_params -> horiz/vert split ->
    //       _extreme_lines -> _intersect -> _order_quad ->
    //       [[~100,100],[400,100],[400,400],[~100,400]]  (tiny solve2x2 ULPs)
    let segs: [Int32] = [100, 100, 400, 100,   // top horizontal
                         120, 400, 380, 400,   // bottom horizontal
                         100, 120, 100, 380,   // left vertical
                         400, 110, 400, 390]   // right vertical
    let (quad, _) = houghFromSegments(segs)
    #expect(quad != nil)
    if let q = quad {
        expectQuad(q, [100, 100, 400, 100, 400, 400, 100, 400], tol: 1e-9, "hough quad")
    }
}

@Test
func houghRaisesMissingLineFamilyWhenOneFamilyAbsent() {
    // Three horizontal-only segments -> vert family < 2 -> "missing a line family".
    let segs: [Int32] = [100, 100, 400, 100,
                         100, 200, 400, 200,
                         100, 300, 400, 300]
    let (quad, reason) = houghFromSegments(segs)
    #expect(quad == nil)
    #expect(reason == "missing a line family")
}

@Test
func houghRaisesNotEnoughLineClustersWhenAFamilyCollapses() {
    // horiz: two segments at the SAME y (rho within 8 -> one cluster) -> the
    // horizontal family yields < 2 clusters -> "not enough line clusters".
    // vert: two well-separated verticals so the family-count guard passes first.
    let segs: [Int32] = [100, 100, 300, 100,   // horiz y=100
                         150, 100, 380, 100,   // horiz y=100 (merges)
                         100, 120, 100, 380,   // left vertical x=100
                         400, 110, 400, 390]   // right vertical x=400
    let (quad, reason) = houghFromSegments(segs)
    #expect(quad == nil)
    #expect(reason == "not enough line clusters")
}

@Test
func houghRaisesLineFamiliesDegenerateWhenExtremesTooClose() {
    // horiz: two clusters (y=100, y=140) whose rhos differ by 40 < 50 ->
    // "line families degenerate" (raised before vert is examined).
    let segs: [Int32] = [100, 100, 400, 100,   // horiz y=100 (rho -100)
                         100, 140, 400, 140,   // horiz y=140 (rho -140)
                         100, 120, 100, 380,   // vertical x=100
                         400, 110, 400, 390]   // vertical x=400
    let (quad, reason) = houghFromSegments(segs)
    #expect(quad == nil)
    #expect(reason == "line families degenerate")
}
