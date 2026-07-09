//
//  SlatPortTests.swift
//  GobanRecogNativeTests
//
//  Native tests for the gr_stonelattice port of gobanrecog/pipeline/
//  stonelattice.py (Task 6). Ground truth generated with the reference venv
//  (numpy 2.5.1, cv2 5.0.0); the generating snippets are inline.
//

import CGobanRecog
import Foundation
import Testing

// MARK: - Bridge helpers

private func latticeBasis(_ ptsXY: [Double], sp: Double) -> [Double]? {
    var out = [Double](repeating: 0, count: 4)
    let ok = ptsXY.withUnsafeBufferPointer { pp in
        out.withUnsafeMutableBufferPointer { op in
            gobanrecog.testbridge.slat_lattice_basis(pp.baseAddress, Int32(ptsXY.count / 2), sp,
                                                     op.baseAddress)
        }
    }
    return ok != 0 ? out : nil
}

private func seedComponentSize(_ ptsXY: [Double], basis: [Double], sp: Double) -> Int {
    let n = ptsXY.withUnsafeBufferPointer { pp in
        basis.withUnsafeBufferPointer { bp in
            gobanrecog.testbridge.slat_seed_component_size(pp.baseAddress, Int32(ptsXY.count / 2),
                                                          bp.baseAddress, sp)
        }
    }
    return Int(n)
}

private func coreExtent(_ cellsXY: [Int32]) -> (ext: (Int, Int), count: Int) {
    var ext = [Int32](repeating: 0, count: 2)
    let count = cellsXY.withUnsafeBufferPointer { cp in
        ext.withUnsafeMutableBufferPointer { ep in
            gobanrecog.testbridge.slat_core_extent(cp.baseAddress, Int32(cellsXY.count / 2),
                                                   ep.baseAddress)
        }
    }
    return ((Int(ext[0]), Int(ext[1])), Int(count))
}

// venv: s=32; th=0.2; e1=[s cos th, s sin th]; e2=[-s sin th, s cos th];
//       pts[i*6+j] = i*e1 + j*e2 + [100, 120]  (i,j in 0..5)  -- a rotated 6x6 lattice
private func planted6x6() -> [Double] {
    let s = 32.0, th = 0.2
    let e1 = (s * cos(th), s * sin(th))
    let e2 = (-s * sin(th), s * cos(th))
    var pts: [Double] = []
    for i in 0..<6 {
        for j in 0..<6 {
            pts.append(Double(i) * e1.0 + Double(j) * e2.0 + 100.0)
            pts.append(Double(i) * e1.1 + Double(j) * e2.1 + 120.0)
        }
    }
    return pts
}

// MARK: - _lattice_basis (stonelattice.py:115-148)

@Test
func latticeBasisRecoversPlantedSpacingAndAngle() {
    let basis = latticeBasis(planted6x6(), sp: 32.0)
    #expect(basis != nil)
    // venv: sl._lattice_basis(pts, 32.0) ->
    //   a1 = [31.362130490919725, 6.3574185854419625]
    //   a2 = [-6.3574185854419625, 31.362130490919725]
    // (medians of the ±15° displacement families; a perfect lattice recovers
    // the planted spacing 32 at angle 0.2 exactly)
    #expect(basis![0] == 31.362130490919725)
    #expect(basis![1] == 6.3574185854419625)
    #expect(basis![2] == -6.3574185854419625)
    #expect(basis![3] == 31.362130490919725)
}

@Test
func latticeBasisReturnsNilOnTooFewPoints() {
    // Fewer than 12 in-range displacement pairs -> None (stonelattice.py:124).
    // Three widely-spaced points have no 0.6sp..1.45sp neighbours.
    let pts: [Double] = [0, 0, 500, 0, 0, 500]
    #expect(latticeBasis(pts, sp: 32.0) == nil)
}

// MARK: - _seed_component FIFO BFS (stonelattice.py:151-186)

@Test
func seedComponentSpansPerfectLattice() {
    let pts = planted6x6()
    let basis = latticeBasis(pts, sp: 32.0)!
    // venv: len(sl._seed_component(pts, *basis, 32.0)) == 36
    // (the whole 6x6 lattice is one unit-step BFS component)
    #expect(seedComponentSize(pts, basis: basis, sp: 32.0) == 36)
}

// MARK: - _core_extent DFS + boundary trimming (stonelattice.py:270-305)

@Test
func coreExtentFullBlock() {
    // A solid 5x5 Chebyshev-connected block: ext (5,5), nothing trimmed.
    var cells: [Int32] = []
    for x in 0..<5 { for y in 0..<5 { cells.append(Int32(x)); cells.append(Int32(y)) } }
    let r = coreExtent(cells)
    #expect(r.ext == (5, 5))
    #expect(r.count == 25)  // venv: sl._core_extent(...) -> 25 cells
}

@Test
func coreExtentTrimsSparseBoundaryColumn() {
    // 10x8 block plus a lone cell at (10, 3): the x=10 column has a single
    // stone and >=8 survive, so it is trimmed. venv -> ext (10,8), 80 cells.
    var cells: [Int32] = []
    for x in 0..<10 { for y in 0..<8 { cells.append(Int32(x)); cells.append(Int32(y)) } }
    cells.append(10); cells.append(3)
    let r = coreExtent(cells)
    #expect(r.ext == (10, 8))
    #expect(r.count == 80)
}

@Test
func coreExtentDropsDisconnectedCell() {
    // A 6x6 block plus one far-away isolated cell: the largest component is the
    // block. venv -> ext (6,6), 36 cells.
    var cells: [Int32] = []
    for x in 0..<6 { for y in 0..<6 { cells.append(Int32(x)); cells.append(Int32(y)) } }
    cells.append(100); cells.append(100)
    let r = coreExtent(cells)
    #expect(r.ext == (6, 6))
    #expect(r.count == 36)
}

// MARK: - packed (col, row) cell key round-trip (gr_stonelattice.cpp pack_cell)

@Test
func packedCellKeyRoundTrips() {
    // key = (int64(col) << 32) | uint32(row); negatives round-trip via the
    // two's-complement low word. Distinct pairs must give distinct keys.
    let cases: [(Int32, Int32)] = [(0, 0), (1, 2), (-6, 2), (19, 19), (-1, -1), (18, -3), (-19, 18)]
    var seen = Set<Int64>()
    for (col, row) in cases {
        let key = gobanrecog.testbridge.slat_pack_cell(col, row)
        #expect(!seen.contains(key))
        seen.insert(key)
        var out = [Int32](repeating: 0, count: 2)
        out.withUnsafeMutableBufferPointer { op in
            gobanrecog.testbridge.slat_unpack_cell(key, op.baseAddress)
        }
        #expect(out[0] == col)
        #expect(out[1] == row)
    }
}
