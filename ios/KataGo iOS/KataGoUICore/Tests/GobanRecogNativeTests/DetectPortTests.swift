//
//  DetectPortTests.swift
//  GobanRecogNativeTests
//
//  Native tests for the gr_detect part-B port of gobanrecog/pipeline/detect.py
//  (Task 8): the verification / margin gates (_verified, _eff_margin) and a
//  lattice_quality planted-vs-perturbed monotonicity check. Ground truth was
//  generated with the reference venv (numpy 2.5.1, cv2 5.0.0); the generating
//  snippets are inline.
//
//  The full end-to-end detect_board parity (warpPerspective / findHomography cv
//  ops on real images) is covered by the gobanrecog-dev `detect` micro-parity
//  harness; these tests pin the ported gate LOGIC bit-exactly, isolated from the
//  HAL-diverging cv ops.
//

import CGobanRecog
import Foundation
import Testing

// MARK: - Bridge helpers

private func verified(hasStats: Bool, n_in: Int32, A: Double, B: Double, resid: Double,
                      n: Int32) -> Bool {
    return gobanrecog.testbridge.detect_verified(hasStats ? 1 : 0, n_in, A, B, resid, n) != 0
}

private func effMargin(scores: [(Int, Double)], margin: Double, boardSize: Int32,
                       stats: (n_in: Int32, A: Double, B: Double, resid: Double)?) -> Double {
    let keys = scores.map { Double($0.0) }
    let vals = scores.map { $0.1 }
    let hasStats: Int32 = stats == nil ? 0 : 1
    let s = stats ?? (0, 0, 0, 0)
    return keys.withUnsafeBufferPointer { kp in
        vals.withUnsafeBufferPointer { vp in
            gobanrecog.testbridge.detect_eff_margin(kp.baseAddress, vp.baseAddress,
                                                    Int32(scores.count), margin, boardSize,
                                                    hasStats, s.n_in, s.A, s.B, s.resid)
        }
    }
}

private func latticeQuality(_ gray: [UInt8], width: Int32, height: Int32, h9: [Double],
                            n: Int32) -> Double {
    return gray.withUnsafeBufferPointer { gp in
        h9.withUnsafeBufferPointer { hp in
            gobanrecog.testbridge.detect_lattice_quality(gp.baseAddress, width, height,
                                                         hp.baseAddress, n)
        }
    }
}

// MARK: - _verified gate (detect.py:689)
//   st is not None and st["n_in"] >= max(12, 0.25*n*n)
//     and st["A"] <= 0.10 and st["B"] <= 1 and st["resid"] <= 0.23
// venv (numpy 2.5.1): all rows below confirmed by _verified(...).

@Test func verifiedNoneIsFalse() {
    #expect(verified(hasStats: false, n_in: 100, A: 0.0, B: 0, resid: 0.0, n: 19) == false)
}

@Test func verifiedTypicalTrue() {
    #expect(verified(hasStats: true, n_in: 100, A: 0.05, B: 1, resid: 0.2, n: 19) == true)
}

@Test func verifiedNInGate19() {
    // max(12, 0.25*19*19)=90.25: 90 fails, 91 passes.
    #expect(verified(hasStats: true, n_in: 90, A: 0.05, B: 1, resid: 0.2, n: 19) == false)
    #expect(verified(hasStats: true, n_in: 91, A: 0.05, B: 1, resid: 0.2, n: 19) == true)
}

@Test func verifiedBoundaryValuesInclusive() {
    // A<=0.10, B<=1, resid<=0.23 are all inclusive at the boundary.
    #expect(verified(hasStats: true, n_in: 91, A: 0.10, B: 1, resid: 0.23, n: 19) == true)
    #expect(verified(hasStats: true, n_in: 100, A: 0.11, B: 1, resid: 0.20, n: 19) == false)
    #expect(verified(hasStats: true, n_in: 100, A: 0.05, B: 2, resid: 0.20, n: 19) == false)
    #expect(verified(hasStats: true, n_in: 100, A: 0.05, B: 1, resid: 0.24, n: 19) == false)
}

@Test func verifiedNInGate9And5() {
    // n=9: max(12, 20.25)=20.25 -> 20 fails, 21 passes.
    #expect(verified(hasStats: true, n_in: 20, A: 0.05, B: 1, resid: 0.2, n: 9) == false)
    #expect(verified(hasStats: true, n_in: 21, A: 0.05, B: 1, resid: 0.2, n: 9) == true)
    // n=5: max(12, 6.25)=12 -> 11 fails, 12 passes.
    #expect(verified(hasStats: true, n_in: 11, A: 0.05, B: 1, resid: 0.2, n: 5) == false)
    #expect(verified(hasStats: true, n_in: 12, A: 0.05, B: 1, resid: 0.2, n: 5) == true)
}

// MARK: - _eff_margin (detect.py:704)
//   _nocont_margin(size_res) if _verified else size_res.margin
//   _nocont_margin = sorted(scores.values(), reverse=True)[0] - [1]

@Test func effMarginVerifiedUsesNocont() {
    // scores {9:1, 13:5, 19:2} -> sorted desc [5,2,1] -> 5-2 = 3.0 when verified.
    let m = effMargin(scores: [(9, 1.0), (13, 5.0), (19, 2.0)], margin: 0.3, boardSize: 19,
                      stats: (n_in: 100, A: 0.05, B: 1, resid: 0.2))
    #expect(m == 3.0)
}

@Test func effMarginUnverifiedUsesRawMargin() {
    // A=0.11 -> not verified -> raw margin 0.3.
    let m = effMargin(scores: [(9, 1.0), (13, 5.0), (19, 2.0)], margin: 0.3, boardSize: 19,
                      stats: (n_in: 100, A: 0.11, B: 1, resid: 0.2))
    #expect(m == 0.3)
}

@Test func effMarginNoneStatsUsesRawMargin() {
    let m = effMargin(scores: [(9, 1.0), (13, 5.0), (19, 2.0)], margin: 0.3, boardSize: 19,
                      stats: nil)
    #expect(m == 0.3)
}

// MARK: - lattice_quality monotonicity (detect.py:237)
// A canonical 9x9 grid frame (light bg 200, dark grid lines 40 at ks=48+32*i).
// Planted H = A = [[32,0,48],[0,32,48],[0,0,1]] warps identity (A@inv(A)=I), so
// the lattice lands exactly on the canonical nodes; the 0.4-cell-shifted H (=A
// @ [[1,0,0.4],[0,1,0.4],[0,0,1]]) misaligns it. venv: q_good=65.658842,
// q_bad=-23.642254 -> a robust >89 gap (immune to any warp HAL).
@Test func latticeQualityFavorsAlignedLattice() {
    let n: Int32 = 9
    let SP = 32, PAD = 48
    let side = 2 * PAD + (Int(n) - 1) * SP  // 352
    var gray = [UInt8](repeating: 200, count: side * side)
    let ks = (0..<Int(n)).map { PAD + SP * $0 }
    for k in ks {
        for x in 0..<side { gray[k * side + x] = 40 }  // horizontal line at row k
        for y in 0..<side { gray[y * side + k] = 40 }  // vertical line at col k
    }
    let hGood: [Double] = [32, 0, 48, 0, 32, 48, 0, 0, 1]
    let hBad: [Double] = [32, 0, 60.8, 0, 32, 60.8, 0, 0, 1]  // A @ shift(0.4, 0.4)
    let qGood = latticeQuality(gray, width: Int32(side), height: Int32(side), h9: hGood, n: n)
    let qBad = latticeQuality(gray, width: Int32(side), height: Int32(side), h9: hBad, n: n)
    #expect(qGood > qBad)          // the monotonicity gate
    #expect(qGood > 40.0)          // aligned lattice scores high (venv 65.66)
    #expect(qBad < 0.0)            // misaligned lattice scores low (venv -23.64)
}
