//
//  GridPortTests.swift
//  GobanRecogNativeTests
//
//  Native tests for the grid.py port (Task 4): the new numpy-parity helpers
//  (pairwise float32 mean, float32 percentile, arange) and the pure-logic grid
//  internals (_profile_peaks, _penalized, _comb_candidates, _weak_teeth,
//  snap_lines, choose_size on a synthetic drawn grid). Every expected value is
//  generated from the reference venv (numpy 2.5.1 / cv2 5.0.0) by running the
//  REAL gobanrecog.pipeline.grid functions on inputs that are exactly
//  reproducible here (integer-built profiles/images and an xorshift64 stream);
//  the generating snippets are inline in comments.
//

import CGobanRecog
import Foundation
import Testing

// MARK: - Deterministic float32 test data (xorshift64, reproducible in numpy)

/// Python equivalent:
///   state = 88172645463325252
///   for _ in range(count):
///       state = (state ^ (state << 13)) & 0xFFFFFFFFFFFFFFFF
///       state ^= state >> 7
///       state = (state ^ (state << 17)) & 0xFFFFFFFFFFFFFFFF
///       vals.append(np.float32(state % 1000003) / np.float32(3.0))
private func lcgFloats(_ count: Int) -> [Float] {
    var state: UInt64 = 88172645463325252
    var out: [Float] = []
    out.reserveCapacity(count)
    for _ in 0..<count {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        out.append(Float(state % 1000003) / 3.0)
    }
    return out
}

// MARK: - Swift wrappers over the C++ test bridge

private func npMeanF32(_ v: [Float]) -> Double {
    v.withUnsafeBufferPointer { gobanrecog.testbridge.np_mean_f32($0.baseAddress, Int32(v.count)) }
}

private func npMeanF64(_ v: [Double]) -> Double {
    v.withUnsafeBufferPointer { gobanrecog.testbridge.np_mean_f64($0.baseAddress, Int32(v.count)) }
}

private func npPercentileF32(_ v: [Float], _ q: Double) -> Double {
    v.withUnsafeBufferPointer { gobanrecog.testbridge.np_percentile_f32($0.baseAddress, Int32(v.count), q) }
}

private func npArange(_ start: Double, _ stop: Double, _ step: Double) -> [Double] {
    var out = [Double](repeating: 0, count: 4096)
    let n = out.withUnsafeMutableBufferPointer {
        gobanrecog.testbridge.np_arange(start, stop, step, $0.baseAddress, Int32(4096))
    }
    return Array(out[0..<Int(n)])
}

private func gridProfilePeaks(_ prof: [Float], minSep: Double) -> [Double] {
    var out = [Double](repeating: 0, count: prof.count)
    let n = prof.withUnsafeBufferPointer { pp in
        out.withUnsafeMutableBufferPointer { op in
            gobanrecog.testbridge.grid_profile_peaks(pp.baseAddress, Int32(prof.count), minSep, op.baseAddress)
        }
    }
    return Array(out[0..<Int(n)])
}

private func gridPenalized(_ prof: [Float], _ peaks: [Double], n: Int, o: Double, s: Double) -> Double {
    prof.withUnsafeBufferPointer { pp in
        peaks.withUnsafeBufferPointer { kp in
            gobanrecog.testbridge.grid_penalized(
                pp.baseAddress, Int32(prof.count), kp.baseAddress, Int32(peaks.count), Int32(n), o, s)
        }
    }
}

private func gridCombCandidates(_ prof: [Float], _ peaks: [Double], n: Int, k: Int) -> [(Double, Double, Double)] {
    var out = [Double](repeating: 0, count: k * 3)
    let count = prof.withUnsafeBufferPointer { pp in
        peaks.withUnsafeBufferPointer { kp in
            out.withUnsafeMutableBufferPointer { op in
                gobanrecog.testbridge.grid_comb_candidates(
                    pp.baseAddress, Int32(prof.count), kp.baseAddress, Int32(peaks.count),
                    Int32(n), Int32(k), op.baseAddress)
            }
        }
    }
    return (0..<Int(count)).map { (out[$0 * 3], out[$0 * 3 + 1], out[$0 * 3 + 2]) }
}

private func gridWeakTeeth(
    avg: [Double], rows: Int, cols: Int, scale: Double,
    profX: [Float], profY: [Float], n: Int, ox: Double, sx: Double, oy: Double, sy: Double
) -> Int {
    Int(avg.withUnsafeBufferPointer { ap in
        profX.withUnsafeBufferPointer { xp in
            profY.withUnsafeBufferPointer { yp in
                gobanrecog.testbridge.grid_weak_teeth(
                    ap.baseAddress, Int32(rows), Int32(cols), scale,
                    xp.baseAddress, Int32(profX.count), yp.baseAddress, Int32(profY.count),
                    Int32(n), ox, sx, oy, sy)
            }
        }
    })
}

private func gridSnapLines(_ prof: [Float], positions: [Double], spacing: Double) -> [Double] {
    var out = [Double](repeating: 0, count: positions.count)
    prof.withUnsafeBufferPointer { pp in
        positions.withUnsafeBufferPointer { qp in
            out.withUnsafeMutableBufferPointer { op in
                gobanrecog.testbridge.grid_snap_lines(
                    pp.baseAddress, Int32(prof.count), qp.baseAddress, Int32(positions.count), spacing, op.baseAddress)
            }
        }
    }
    return out
}

private func gridStageJSON(_ img: [UInt8], width: Int, height: Int) -> [String: Any] {
    let json = img.withUnsafeBufferPointer {
        gobanrecog.testbridge.grid_stage_json($0.baseAddress, Int32(width), Int32(height), nil)
    }
    let data = Data(String(json).utf8)
    let obj = try? JSONSerialization.jsonObject(with: data)
    return (obj as? [String: Any]) ?? [:]
}

private func gridRectify(gray: [UInt8], width: Int, height: Int, quad: [Double]) -> (side: Int, rect: [UInt8], H: [Double]) {
    let sideGuess = 1100
    var rect = [UInt8](repeating: 0, count: sideGuess * sideGuess)
    var H = [Double](repeating: 0, count: 9)
    let side = gray.withUnsafeBufferPointer { gp in
        quad.withUnsafeBufferPointer { qp in
            rect.withUnsafeMutableBufferPointer { rp in
                H.withUnsafeMutableBufferPointer { hp in
                    gobanrecog.testbridge.grid_rectify(
                        gp.baseAddress, Int32(width), Int32(height), qp.baseAddress,
                        rp.baseAddress, hp.baseAddress)
                }
            }
        }
    }
    return (Int(side), rect, H)
}

// MARK: - Shared synthetic inputs (mirrored exactly in the venv snippets)

/// 1100-long float32 profile with a planted 13-tooth comb: teeth of height
/// 1000 at 170 + 60k (k = 0..12), shoulders of 300 at +-1.
private func plantedCombProfile() -> [Float] {
    var prof = [Float](repeating: 0, count: 1100)
    for k in 0..<13 {
        let p = 170 + 60 * k
        prof[p] = 1000.0
        prof[p - 1] = 300.0
        prof[p + 1] = 300.0
    }
    return prof
}

// MARK: - numpy parity: pairwise mean / float32 percentile / arange

struct GridParityHelperTests {
    // /Users/chinchangyang/Code/GobanRecog/.venv/bin/python: arr = xorshift64
    // stream above (1100 values);
    //   arr[:5] -> 211543.0, 40687.33203125, 219018.0, 113409.3359375, 116197.0
    //   float(arr[:5].mean())   -> 140170.921875
    //   float(arr[:19].mean())  -> 133245.5      (8..128 unrolled path)
    //   float(arr[:127].mean()) -> 157525.203125 (remainder path)
    //   float(arr[:801].mean()) -> 167954.921875 (recursive split)
    //   float(arr.mean())       -> 165996.15625
    // A naive left-to-right float32 sum does NOT reproduce these (verified),
    // so this pins numpy's pairwise blocking exactly.
    @Test func npMeanPairwiseF32() {
        let arr = lcgFloats(1100)
        #expect(arr[0] == 211543.0)
        #expect(arr[1] == 40687.33203125)
        #expect(arr[2] == 219018.0)
        #expect(arr[3] == 113409.3359375)
        #expect(arr[4] == 116197.0)
        #expect(npMeanF32(Array(arr[0..<5])) == 140170.921875)
        #expect(npMeanF32(Array(arr[0..<19])) == 133245.5)
        #expect(npMeanF32(Array(arr[0..<127])) == 157525.203125)
        #expect(npMeanF32(Array(arr[0..<801])) == 167954.921875)
        #expect(npMeanF32(arr) == 165996.15625)
    }

    // d = arr.astype(np.float64):
    //   float(d[:5].mean())   -> 140170.93359375
    //   float(d[:19].mean())  -> 133245.49018297697
    //   float(d[:361].mean()) -> 167946.0028316255
    //   float(d[:801].mean()) -> 167954.92199889908
    //   float(d.mean())       -> 165996.1575608132
    @Test func npMeanPairwiseF64() {
        let d = lcgFloats(1100).map(Double.init)
        #expect(npMeanF64(Array(d[0..<5])) == 140170.93359375)
        #expect(npMeanF64(Array(d[0..<19])) == 133245.49018297697)
        #expect(npMeanF64(Array(d[0..<361])) == 167946.0028316255)
        #expect(npMeanF64(Array(d[0..<801])) == 167954.92199889908)
        #expect(npMeanF64(d) == 165996.1575608132)
    }

    // float(np.percentile(arr, 99.5)) -> 332193.03125  (gamma >= 0.5 branch)
    // float(np.percentile(arr, 80.0)) -> 267282.53125  (gamma < 0.5 branch)
    // float(np.median(arr))           -> 165092.0
    // numpy computes the float32 lerp in PURE float32 (the float64 lerp of the
    // same inputs gives a different value; verified in the venv).
    @Test func npPercentileF32LCG() {
        let arr = lcgFloats(1100)
        #expect(npPercentileF32(arr, 99.5) == 332193.03125)
        #expect(npPercentileF32(arr, 80.0) == 267282.53125)
    }

    // The exact arange triples grid.py generates (venv ground truth):
    //   np.arange(800/10.6, 100.25, 0.5)                : len 50, last 99.97169811320755
    //   np.arange(800/14.6, 800/12 + 0.25, 0.5)         : len 25, last 66.79452054794521
    //   np.arange(800/20.6, 800/18 + 0.25, 0.5)         : len 12, last 44.33495145631068
    //   np.arange(59.394520547945206, 60.59452054794521, 0.1)
    //                                                   : len 13, last 60.59452054794522
    //     (the last value EXCEEDS `stop` -- numpy fills start + i*delta)
    //   np.arange(167.6, 172.4, 0.4)                    : len 13, last 172.40000000000006
    //   np.arange(142.0, 238.0, 1.0)                    : len 96, last 237.0
    @Test func npArangeGridTriples() {
        let a0 = npArange(800.0 / 10.6, 100.25, 0.5)
        #expect(a0.count == 50)
        #expect(a0[0] == 75.47169811320755)
        #expect(a0[1] == 75.97169811320755)
        #expect(a0[49] == 99.97169811320755)

        let a1 = npArange(800.0 / 14.6, 800.0 / 12.0 + 0.25, 0.5)
        #expect(a1.count == 25)
        #expect(a1[24] == 66.79452054794521)

        let a2 = npArange(800.0 / 20.6, 800.0 / 18.0 + 0.25, 0.5)
        #expect(a2.count == 12)
        #expect(a2[11] == 44.33495145631068)

        let a3 = npArange(59.394520547945206, 60.59452054794521, 0.1)
        #expect(a3.count == 13)
        #expect(a3[1] == 59.49452054794521)
        #expect(a3[12] == 60.59452054794522)

        let a4 = npArange(167.6, 172.4, 0.4)
        #expect(a4.count == 13)
        #expect(a4[12] == 172.40000000000006)

        let a5 = npArange(142.0, 238.0, 1.0)
        #expect(a5.count == 96)
        #expect(a5[95] == 237.0)
    }
}

// MARK: - grid.py pure logic

struct GridLogicTests {
    // grid._profile_peaks(prof, min_sep=0.6*800/20) on the planted comb ->
    // exactly the 13 tooth positions [170, 230, ..., 890] (venv).
    @Test func profilePeaksFindPlantedTeeth() {
        let prof = plantedCombProfile()
        let peaks = gridProfilePeaks(prof, minSep: 0.6 * 800.0 / 20.0)
        let expected: [Double] = (0..<13).map { Double(170 + 60 * $0) }
        #expect(peaks == expected)
    }

    // grid._comb_candidates(prof, 13, peaks) (venv):
    //   cand0 = (52.88461685180664, 169.6, 59.994520547945214)
    //   cand1 = (45.81247359055739, 229.6, 59.994520547945214)
    //   cand2 = (4.637574049142691, 187.6, 58.09452054794521)
    // The comb-fit brute force finds the planted spacing/offset (cand0's teeth
    // round to exactly 170 + 60k).
    @Test func combCandidatesFindPlantedComb() {
        let prof = plantedCombProfile()
        let peaks = gridProfilePeaks(prof, minSep: 24.0)
        let cands = gridCombCandidates(prof, peaks, n: 13, k: 3)
        #expect(cands.count == 3)
        let expected: [(Double, Double, Double)] = [
            (52.88461685180664, 169.6, 59.994520547945214),
            (45.81247359055739, 229.6, 59.994520547945214),
            (4.637574049142691, 187.6, 58.09452054794521),
        ]
        for (got, want) in zip(cands, expected) {
            #expect(abs(got.0 - want.0) < 1e-9)
            #expect(abs(got.1 - want.1) < 1e-9)
            #expect(abs(got.2 - want.2) < 1e-9)
        }
    }

    // grid._penalized(prof, peaks, 13, 170.0, 60.0) -> 52.88461685180664 (venv);
    // every peak is explained by a tooth, so no penalty fires and the score
    // equals the plain normalized tooth mean.
    @Test func penalizedExplainedPeaksNoPenalty() {
        let prof = plantedCombProfile()
        let peaks = gridProfilePeaks(prof, minSep: 24.0)
        let score = gridPenalized(prof, peaks, n: 13, o: 170.0, s: 60.0)
        #expect(abs(score - 52.88461685180664) < 1e-9)
    }

    // A 9-comb forced onto the 13-planted profile leaves teeth unexplained and
    // scores far below the true comb: venv cand9_0 = (8.487654156155056,
    // 170.00000000000003, 89.97169811320752).
    @Test func penalizedFiresOnSubComb() {
        let prof = plantedCombProfile()
        let peaks = gridProfilePeaks(prof, minSep: 24.0)
        let cands9 = gridCombCandidates(prof, peaks, n: 9, k: 3)
        #expect(abs(cands9[0].0 - 8.487654156155056) < 1e-9)
        #expect(abs(cands9[0].1 - 170.00000000000003) < 1e-9)
        #expect(abs(cands9[0].2 - 89.97169811320752) < 1e-9)
    }

    // grid._weak_teeth on a 300x300 avg map, n=3 lattice at o=100, s=50:
    // prof_x = 90/80/0 at 100/150/200 (third x-tooth has NO line response),
    // prof_y = 70 at all three, stones only at (100,100).
    //   -> weak == 1 (venv)
    // Planting stone support along x=200 (avg[100|150|200, 200] = 5, scale 10
    // -> 0.5 >= 0.12) rescues the tooth -> weak == 0 (venv).
    // A control with prof_x[200] = 85 -> weak == 0 (venv).
    @Test func weakToothPenaltyFiresAndRescues() {
        let rows = 300, cols = 300
        var avg = [Double](repeating: 0, count: rows * cols)
        avg[100 * cols + 100] = 5.0
        var profX = [Float](repeating: 0, count: 300)
        var profY = [Float](repeating: 0, count: 300)
        profX[100] = 90.0
        profX[150] = 80.0
        profX[200] = 0.0
        for p in [100, 150, 200] { profY[p] = 70.0 }
        #expect(gridWeakTeeth(avg: avg, rows: rows, cols: cols, scale: 10.0,
                              profX: profX, profY: profY, n: 3,
                              ox: 100.0, sx: 50.0, oy: 100.0, sy: 50.0) == 1)

        var avgRescued = avg
        for r in [100, 150, 200] { avgRescued[r * cols + 200] = 5.0 }
        #expect(gridWeakTeeth(avg: avgRescued, rows: rows, cols: cols, scale: 10.0,
                              profX: profX, profY: profY, n: 3,
                              ox: 100.0, sx: 50.0, oy: 100.0, sy: 50.0) == 0)

        var profXStrong = profX
        profXStrong[200] = 85.0
        #expect(gridWeakTeeth(avg: avg, rows: rows, cols: cols, scale: 10.0,
                              profX: profXStrong, profY: profY, n: 3,
                              ox: 100.0, sx: 50.0, oy: 100.0, sy: 50.0) == 0)
    }

    // grid.snap_lines(prof, [500.4, 703.3, 20.0], 50.0) (venv):
    //   prof = ones(1100); prof[499..501] = 8, 10, 9; prof[703] = 2.5
    //   -> [500.1666564941406, 703.3, 20.0]
    // 500.4 snaps to the float32 parabola vertex (numpy stores i + float32
    // delta); 703.3 is left alone (peak below 3x median); 20.0 has no peak.
    @Test func snapLinesParabolicAndWeakPeak() {
        var prof = [Float](repeating: 1, count: 1100)
        prof[499] = 8.0
        prof[500] = 10.0
        prof[501] = 9.0
        prof[703] = 2.5
        let out = gridSnapLines(prof, positions: [500.4, 703.3, 20.0], spacing: 50.0)
        #expect(out == [500.1666564941406, 703.3, 20.0])
    }
}

// MARK: - choose_size end-to-end on a synthetic drawn grid

struct GridChooseSizeTests {
    /// The exact image the venv snippet draws: 1100x1100 uint8, background 180,
    /// 13 vertical + 13 horizontal 1px lines of value 60 at
    /// int(round(150 + k*800/12)) spanning [150, 950] inclusive.
    private func syntheticRect13() -> (img: [UInt8], positions: [Int]) {
        let side = 1100
        var img = [UInt8](repeating: 180, count: side * side)
        var positions: [Int] = []
        for k in 0..<13 {
            let c = Int((150.0 + Double(k) * 800.0 / 12.0).rounded())
            positions.append(c)
            for r in 150...950 {
                img[r * side + c] = 60  // vertical line
                img[c * side + r] = 60  // horizontal line
            }
        }
        return (img, positions)
    }

    // Venv ground truth (choose_size on the same image):
    //   board_size = 13
    //   scores = {9: 13168909.139543217, 13: 102108405.10145117,
    //             19: 18648824.714429174}
    //   margin = 83459580.387022
    //   xs = ys = the planted [150, 217, 283, 350, 417, 483, 550, 617, 683,
    //             750, 817, 883, 950] exactly (snap_lines lands on the lines).
    // The float comparisons allow 1e-6 relative slack: the stoneness path runs
    // through cv2.filter2D, where the wheel's HAL may differ from our vendored
    // build (Task 1 watch item).
    @Test func chooseSizeDetectsDrawnThirteen() {
        let (img, positions) = syntheticRect13()
        let result = gridStageJSON(img, width: 1100, height: 1100)
        #expect(result["board_size"] as? Int == 13)

        let xs = result["xs"] as? [Double] ?? []
        let ys = result["ys"] as? [Double] ?? []
        #expect(xs == positions.map(Double.init))
        #expect(ys == positions.map(Double.init))

        let scores = result["scores"] as? [String: Double] ?? [:]
        let expectedScores: [String: Double] = [
            "9": 13168909.139543217, "13": 102108405.10145117, "19": 18648824.714429174,
        ]
        for (key, want) in expectedScores {
            let got = scores[key] ?? .nan
            #expect(abs(got - want) <= 1e-6 * abs(want), "scores[\(key)] = \(got)")
        }
        let margin = result["margin"] as? Double ?? .nan
        #expect(abs(margin - 83459580.387022) <= 1e-6 * 83459580.387022)
    }

    // rectify_quad plumbing: an axis-aligned quad maps its TL corner to the
    // canonical (PAD, PAD) = (150, 150), and the output frame is 1100x1100.
    @Test func rectifyQuadMapsCornersToCanonicalFrame() {
        let w = 220, h = 220
        var gray = [UInt8](repeating: 0, count: w * h)
        for r in 0..<h {
            for c in 0..<w {
                gray[r * w + c] = UInt8((r + c) % 256)
            }
        }
        let quad: [Double] = [10, 10, 200, 10, 200, 200, 10, 200]  // TL TR BR BL
        let (side, _, H) = gridRectify(gray: gray, width: w, height: h, quad: quad)
        #expect(side == 1100)
        // H maps (10,10) -> (150,150): [x', y', w'] = H @ [10, 10, 1]
        let xp = H[0] * 10 + H[1] * 10 + H[2]
        let yp = H[3] * 10 + H[4] * 10 + H[5]
        let wp = H[6] * 10 + H[7] * 10 + H[8]
        #expect(abs(xp / wp - 150.0) < 1e-9)
        #expect(abs(yp / wp - 150.0) < 1e-9)
    }
}
