//
//  GobanRecogNativeTests.swift
//  GobanRecogNativeTests
//
//  Native parity tests for the CGobanRecog port (Task 3): numpy-parity helpers,
//  BoardState, and import-time constants. Every expected value is generated from
//  the reference venv (numpy 2.5.1 / cv2 5.0.0) at
//  /Users/chinchangyang/Code/GobanRecog/.venv/bin/python, with the generating
//  snippet inline in a comment. The tests reach the internal gobanrecog::
//  helpers through the cv-free test bridge (GobanRecogTestBridge.hpp).
//

import CGobanRecog
import Testing

// MARK: - Swift wrappers over the C++ test bridge (pointer / string marshalling)

private func npRound(_ x: Double) -> Double {
    gobanrecog.testbridge.np_round(x)
}

private func npPercentile(_ v: [Double], _ q: Double) -> Double {
    v.withUnsafeBufferPointer { gobanrecog.testbridge.np_percentile($0.baseAddress, Int32(v.count), q) }
}

private func npPercentileRangeThrows(_ v: [Double], _ q: Double) -> Int {
    Int(v.withUnsafeBufferPointer {
        gobanrecog.testbridge.np_percentile_range_throws($0.baseAddress, Int32(v.count), q)
    })
}

private func npMedian(_ v: [Double]) -> Double {
    v.withUnsafeBufferPointer { gobanrecog.testbridge.np_median($0.baseAddress, Int32(v.count)) }
}

private func npMedianF32(_ v: [Float]) -> Double {
    v.withUnsafeBufferPointer { gobanrecog.testbridge.np_median_f32($0.baseAddress, Int32(v.count)) }
}

private func npMedianU8(_ v: [UInt8]) -> Double {
    v.withUnsafeBufferPointer { gobanrecog.testbridge.np_median_u8($0.baseAddress, Int32(v.count)) }
}

private func npMedianAxis0(_ data: [Double], rows: Int, cols: Int) -> [Double] {
    var out = [Double](repeating: 0, count: cols)
    data.withUnsafeBufferPointer { dp in
        out.withUnsafeMutableBufferPointer { op in
            gobanrecog.testbridge.np_median_axis0(dp.baseAddress, Int32(rows), Int32(cols), op.baseAddress)
        }
    }
    return out
}

private func lstsq(_ A: [Double], m: Int, n: Int, _ B: [Double], bcols: Int) -> [Double] {
    var out = [Double](repeating: 0, count: n * bcols)
    A.withUnsafeBufferPointer { ap in
        B.withUnsafeBufferPointer { bp in
            out.withUnsafeMutableBufferPointer { op in
                gobanrecog.testbridge.lstsq(ap.baseAddress, Int32(m), Int32(n), bp.baseAddress, Int32(bcols), op.baseAddress)
            }
        }
    }
    return out
}

private func pinv(_ A: [Double], n: Int) -> [Double] {
    var out = [Double](repeating: 0, count: n * n)
    A.withUnsafeBufferPointer { ap in
        out.withUnsafeMutableBufferPointer { op in
            gobanrecog.testbridge.pinv(ap.baseAddress, Int32(n), op.baseAddress)
        }
    }
    return out
}

private func matrixRank(_ A: [Double], m: Int, n: Int) -> Int {
    Int(A.withUnsafeBufferPointer { gobanrecog.testbridge.matrix_rank($0.baseAddress, Int32(m), Int32(n)) })
}

private func inv3x3(_ H: [Double]) -> (code: Int, out: [Double]) {
    var out = [Double](repeating: 0, count: 9)
    let code = H.withUnsafeBufferPointer { hp in
        out.withUnsafeMutableBufferPointer { op in
            gobanrecog.testbridge.inv3x3(hp.baseAddress, op.baseAddress)
        }
    }
    return (Int(code), out)
}

private func solve2x2(_ A4: [Double], _ b2: [Double]) -> (code: Int, out: [Double]) {
    var out = [Double](repeating: 0, count: 2)
    let code = A4.withUnsafeBufferPointer { ap in
        b2.withUnsafeBufferPointer { bp in
            out.withUnsafeMutableBufferPointer { op in
                gobanrecog.testbridge.solve2x2(ap.baseAddress, bp.baseAddress, op.baseAddress)
            }
        }
    }
    return (Int(code), out)
}

private func stoneKernel() -> (nonzero: Int, values: [Double]) {
    var k = [Double](repeating: 0, count: 289)
    let nz = k.withUnsafeMutableBufferPointer { gobanrecog.testbridge.stone_kernel($0.baseAddress) }
    return (Int(nz), k)
}

private func nodeOffsets() -> [Double] {
    var o = [Double](repeating: 0, count: 50)
    o.withUnsafeMutableBufferPointer { gobanrecog.testbridge.node_offsets($0.baseAddress) }
    return o
}

private func boardValidate(_ size: Int, _ rows: [String]) -> String {
    rows.joined(separator: "\n").withCString { String(gobanrecog.testbridge.board_validate(Int32(size), $0)) }
}

private func boardPoints(_ size: Int, _ rows: [String], _ color: Character) -> String {
    rows.joined(separator: "\n").withCString {
        String(gobanrecog.testbridge.board_points(Int32(size), $0, Int32(color.asciiValue!)))
    }
}

private func boardStoneAt(_ size: Int, _ rows: [String], col: Int, row: Int) -> Int {
    Int(rows.joined(separator: "\n").withCString {
        gobanrecog.testbridge.board_stone_at(Int32(size), $0, Int32(col), Int32(row))
    })
}

private func boardEmpty(_ size: Int) -> String {
    String(gobanrecog.testbridge.board_empty(Int32(size)))
}

private func boardFromGrid(_ rows: [String]) -> String {
    rows.joined(separator: "\n").withCString { String(gobanrecog.testbridge.board_from_grid($0)) }
}

private func approxEqual(_ a: [Double], _ b: [Double], _ tol: Double) -> Bool {
    guard a.count == b.count else { return false }
    for i in a.indices where abs(a[i] - b[i]) > tol { return false }
    return true
}

// MARK: - np_round (half-to-even)

@Test
func npRoundHalfToEven() {
    // venv: [float(np.round(x)) for x in (...)]
    #expect(npRound(0.5) == 0.0)     // tie -> even (0)
    #expect(npRound(1.5) == 2.0)     // tie -> even (2)
    #expect(npRound(2.5) == 2.0)     // tie -> even (2)
    #expect(npRound(-0.5) == 0.0)    // -> -0.0
    #expect(npRound(-1.5) == -2.0)
    #expect(npRound(-2.5) == -2.0)
    #expect(npRound(3.5) == 4.0)
    #expect(npRound(4.5) == 4.0)
    #expect(npRound(2.675) == 3.0)   // NOT a tie; nearest integer is 3
    #expect(npRound(100.5) == 100.0) // tie -> even
    #expect(npRound(101.5) == 102.0) // tie -> even
    #expect(npRound(0.49999999999999994) == 0.0)  // just below 0.5
    #expect(npRound(2.0000000000000004) == 2.0)
    #expect(npRound(1.9999999999999998) == 2.0)
}

// MARK: - np_percentile (default "linear")

@Test
func npPercentileLinear() {
    // venv:
    //   A7=[3.,1.,4.,1.5,5.,9.,2.]  (unsorted)
    //   A8=[3.,1.,4.,1.,5.,9.,2.,6.] (unsorted + duplicate 1.0)
    //   [float(np.percentile(A, q)) for q in (80,90,95,99,99.5)]
    let a7: [Double] = [3, 1, 4, 1.5, 5, 9, 2]
    #expect(abs(npPercentile(a7, 80) - 4.800000000000001) < 1e-12)
    #expect(abs(npPercentile(a7, 90) - 6.600000000000001) < 1e-12)
    #expect(abs(npPercentile(a7, 95) - 7.799999999999997) < 1e-12)
    #expect(abs(npPercentile(a7, 99) - 8.759999999999998) < 1e-12)
    #expect(abs(npPercentile(a7, 99.5) - 8.879999999999999) < 1e-12)

    let a8: [Double] = [3, 1, 4, 1, 5, 9, 2, 6]
    #expect(abs(npPercentile(a8, 80) - 5.6000000000000005) < 1e-12)
    #expect(abs(npPercentile(a8, 90) - 6.8999999999999995) < 1e-12)
    #expect(abs(npPercentile(a8, 95) - 7.949999999999998) < 1e-12)
    #expect(abs(npPercentile(a8, 99) - 8.79) < 1e-12)
    #expect(abs(npPercentile(a8, 99.5) - 8.895) < 1e-12)
}

@Test
func npPercentileNaNPropagates() {
    // venv: np.percentile([1.0, nan, 3.0], 50) -> nan
    #expect(npPercentile([1.0, .nan, 3.0], 50).isNaN)
}

@Test
func npPercentileOutOfRangeThrows() {
    // venv: np.percentile([1,2,3], -1) and np.percentile([1,2,3], 101) both
    // raise ValueError("Percentiles must be in the range [0, 100]").
    #expect(npPercentileRangeThrows([1, 2, 3], -1) == 1)
    #expect(npPercentileRangeThrows([1, 2, 3], 101) == 1)
    #expect(npPercentileRangeThrows([1, 2, 3], 50) == 0)  // in-range: no throw
}

// MARK: - np_median (1-D, CV_32F, uint8, axis0)

@Test
func npMedianSequences() {
    // venv: np.median([3,1,4,1.5,5]) == 3.0 ; np.median([3,1,4,1.5,5,9]) == 3.5
    #expect(npMedian([3, 1, 4, 1.5, 5]) == 3.0)          // odd
    #expect(npMedian([3, 1, 4, 1.5, 5, 9]) == 3.5)       // even (mean of middle two)
}

@Test
func npMedianNaNPropagates() {
    // venv: np.median([1.0, nan, 3.0]) -> nan
    #expect(npMedian([1.0, .nan, 3.0]).isNaN)
    // venv: np.median(np.array([1.0, nan], dtype=np.float32)) -> nan
    #expect(npMedianF32([1.0, .nan]).isNaN)
}

@Test
func npMedianFloat32() {
    // venv: np.median(np.array([0.1..0.7], float32)) -> 0.4000000059604645 (odd, middle f32)
    #expect(abs(npMedianF32([0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7]) - 0.4000000059604645) < 1e-12)
    // venv: np.median(np.array([[0.5,1.5],[2.5,3.5],[4.5,5.5],[6.5,7.5]], float32)) -> 4.0
    #expect(npMedianF32([0.5, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5]) == 4.0)
    // FLOAT32-FIDELITY case: venv np.median(np.array([0.1,0.2,0.30000001,0.7000001],
    // float32)) == 0.25 (float32); the double path would give 0.2500000074505806.
    #expect(abs(npMedianF32([0.1, 0.2, 0.30000001, 0.7000001]) - 0.25) < 1e-12)
}

@Test
func npMedianUInt8() {
    // venv: np.median(np.array([10,20,30,41], uint8)) -> 25.0 (float64, even)
    #expect(npMedianU8([10, 20, 30, 41]) == 25.0)
    // venv: np.median(np.array([10,21,30,40,55], uint8)) -> 30.0 (odd)
    #expect(npMedianU8([10, 21, 30, 40, 55]) == 30.0)
}

@Test
func npMedianAxis0CV64F() {
    // venv:
    //   M = [[1,2,3],[4,0.5,-1],[2,2,9],[-3,7,0],[5,1,4]]  (5x3 float64)
    //   np.median(M, axis=0) -> [2.0, 2.0, 3.0]
    let data: [Double] = [1, 2, 3, 4, 0.5, -1, 2, 2, 9, -3, 7, 0, 5, 1, 4]
    #expect(approxEqual(npMedianAxis0(data, rows: 5, cols: 3), [2.0, 2.0, 3.0], 1e-12))
}

// MARK: - lstsq (stonelattice.py:250 shape)

@Test
func lstsqAffineFit() {
    // venv:
    //   asrc = [[0,0],[1,0],[0,1],[1,1],[2,0],[0,2],[2,1],[1,2]]
    //   A = hstack([asrc, ones((8,1))])       # 8x3
    //   B = [[10,20],[42.1,19.8],[9.9,52.3],[42,52],[74.2,20.1],[9.8,84],[74,52.2],[41.9,84.1]]
    //   M,*_ = np.linalg.lstsq(A, B, rcond=None)   # 3x2
    let A: [Double] = [
        0, 0, 1, 1, 0, 1, 0, 1, 1, 1, 1, 1,
        2, 0, 1, 0, 2, 1, 2, 1, 1, 1, 2, 1,
    ]
    let B: [Double] = [
        10, 20, 42.1, 19.8, 9.9, 52.3, 42, 52,
        74.2, 20.1, 9.8, 84, 74, 52.2, 41.9, 84.1,
    ]
    let expected: [Double] = [
        32.07499999999999, 0.026666666666666252,
        -0.10833333333333281, 32.06,
        10.016666666666652, 19.98666666666665,
    ]
    #expect(approxEqual(lstsq(A, m: 8, n: 3, B, bcols: 2), expected, 1e-12))
}

// MARK: - pinv (well-conditioned + rank-deficient)

@Test
func pinvWellConditioned() {
    // venv: np.linalg.pinv([[2,0,1],[0,3,0],[1,0,4]])
    let A: [Double] = [2, 0, 1, 0, 3, 0, 1, 0, 4]
    let expected: [Double] = [
        0.5714285714285713, 0.0, -0.14285714285714282,
        0.0, 0.3333333333333333, 0.0,
        -0.14285714285714288, 0.0, 0.28571428571428575,
    ]
    #expect(approxEqual(pinv(A, n: 3), expected, 1e-12))
}

@Test
func pinvRankDeficient() {
    // venv: np.linalg.pinv([[1,2,3],[4,5,6],[5,7,9]])  (row3 = row1+row2 -> rank 2)
    let A: [Double] = [1, 2, 3, 4, 5, 6, 5, 7, 9]
    let expected: [Double] = [
        -0.7777777777777772, 0.6111111111111128, -0.166666666666668,
        -0.11111111111111223, 0.1111111111111123, -4.791221379209586e-16,
        0.5555555555555564, -0.38888888888889095, 0.1666666666666679,
    ]
    #expect(approxEqual(pinv(A, n: 3), expected, 1e-12))
}

// MARK: - matrix_rank (stonelattice.py:248 shape)

@Test
func matrixRankFullAndDeficient() {
    // venv: np.linalg.matrix_rank(hstack([[[0,0],[1,0],[0,1],[1,1]], ones((4,1))])) == 3
    #expect(matrixRank([0, 0, 1, 1, 0, 1, 0, 1, 1, 1, 1, 1], m: 4, n: 3) == 3)
    // venv: collinear points -> hstack([[[0,0],[1,0],[2,0],[3,0]], ones]) == rank 2
    #expect(matrixRank([0, 0, 1, 1, 0, 1, 2, 0, 1, 3, 0, 1], m: 4, n: 3) == 2)
    // venv: np.linalg.matrix_rank([[1,2,3],[2,4,6],[3,6,9]]) == 1
    #expect(matrixRank([1, 2, 3, 2, 4, 6, 3, 6, 9], m: 3, n: 3) == 1)
}

// MARK: - inv3x3 (round-trip + singular)

@Test
func inv3x3RoundTripAndSingular() {
    // venv: H = [[1,0.02,5],[0.01,1,3],[1e-4,2e-4,1]] ; np.linalg.inv(H) matches.
    let H: [Double] = [1, 0.02, 5, 0.01, 1, 3, 1e-4, 2e-4, 1]
    let (code, inv) = inv3x3(H)
    #expect(code == 0)
    // Compare to numpy inv (LAPACK LU vs cv LU: ~1e-13).
    let expected: [Double] = [
        1.0006848793851304, -0.019024427364736318, -4.946351114831443,
        -0.009712470812523279, 1.0007850079502079, -2.9537926697880077,
        -9.81259937760084e-05, -0.000198254558853568, 1.0010853936454407,
    ]
    #expect(approxEqual(inv, expected, 1e-9))
    // Round-trip H * inv(H) == I within 1e-12.
    var prod = [Double](repeating: 0, count: 9)
    for r in 0..<3 {
        for c in 0..<3 {
            var s = 0.0
            for k in 0..<3 { s += H[r * 3 + k] * inv[k * 3 + c] }
            prod[r * 3 + c] = s
        }
    }
    #expect(approxEqual(prod, [1, 0, 0, 0, 1, 0, 0, 0, 1], 1e-12))

    // Singular -> LinAlgError -> bridge returns code 1.
    let (scode, _) = inv3x3([1, 2, 3, 2, 4, 6, 0, 0, 1])
    #expect(scode == 1)
}

// MARK: - solve2x2 (round-trip + singular)

@Test
func solve2x2RoundTripAndSingular() {
    // venv:
    //   a = [[sin(0.3),-cos(0.3)],[sin(1.9),-cos(1.9)]]
    //     = [[0.29552020666133955,-0.955336489125606],
    //        [0.9463000876874145, 0.32328956686350335]]
    //   b = [10, 7] ; np.linalg.solve(a,b) = [9.92448286182119, -7.397513707590109]
    let A4: [Double] = [0.29552020666133955, -0.955336489125606,
                        0.9463000876874145, 0.32328956686350335]
    let b2: [Double] = [10, 7]
    let (code, x) = solve2x2(A4, b2)
    #expect(code == 0)
    #expect(approxEqual(x, [9.92448286182119, -7.397513707590109], 1e-9))
    // Round-trip A * x == b within 1e-12.
    let bx0 = A4[0] * x[0] + A4[1] * x[1]
    let bx1 = A4[2] * x[0] + A4[3] * x[1]
    #expect(abs(bx0 - 10) < 1e-12 && abs(bx1 - 7) < 1e-12)

    // Singular -> code 1.
    let (scode, _) = solve2x2([1, 2, 2, 4], [1, 2])
    #expect(scode == 1)
}

// MARK: - stone kernel constant (detect.py:516-517)

@Test
func stoneKernelNormalizedEllipse() {
    let (nonzero, k) = stoneKernel()
    // venv: cv2.getStructuringElement(MORPH_ELLIPSE,(17,17)).sum() == 213
    #expect(nonzero == 213)
    // Normalized: nonzero cells == 1/213 in float32 == 0.004694835748523474
    #expect(abs(k[8 * 17 + 8] - 0.004694835748523474) < 1e-9)  // center
    #expect(abs(k[0 * 17 + 8] - 0.004694835748523474) < 1e-9)  // top-edge midpoint
    #expect(k[0] == 0.0)                                        // corner is outside the disk
    // Sums to 1.
    #expect(abs(k.reduce(0, +) - 1.0) < 1e-5)
}

// MARK: - node offsets constant (stones.py:26-33)

@Test
func nodeOffsetsCenterFirstOrdering() {
    // venv: sorted(((dx,dy) for dx in (-0.25,-0.125,0,0.125,0.25)
    //                       for dy in (-0.25,-0.125,0,0.125,0.25)),
    //              key=lambda o: o[0]*o[0]+o[1]*o[1])  # stable, center first
    let expected: [Double] = [
        0.0, 0.0,
        -0.125, 0.0, 0.0, -0.125, 0.0, 0.125, 0.125, 0.0,
        -0.125, -0.125, -0.125, 0.125, 0.125, -0.125, 0.125, 0.125,
        -0.25, 0.0, 0.0, -0.25, 0.0, 0.25, 0.25, 0.0,
        -0.25, -0.125, -0.25, 0.125, -0.125, -0.25, -0.125, 0.25,
        0.125, -0.25, 0.125, 0.25, 0.25, -0.125, 0.25, 0.125,
        -0.25, -0.25, -0.25, 0.25, 0.25, -0.25, 0.25, 0.25,
    ]
    #expect(nodeOffsets() == expected)  // exact: all offsets are multiples of 0.125
}

// MARK: - BoardState (types.py)

@Test
func boardStateValidConstruction() {
    let rows = [".B.......", ".........", "..W......", ".........", "....B....",
                ".........", ".........", ".......W.", "........."]
    #expect(boardValidate(9, rows) == "")
    // venv: bs.points("B") == [(1,0),(4,4)] ; bs.points("W") == [(2,2),(7,7)]
    #expect(boardPoints(9, rows, "B") == "1,0;4,4")
    #expect(boardPoints(9, rows, "W") == "2,2;7,7")
    // venv: stone_at(col,row): (1,0)->'B'(66), (2,2)->'W'(87), (0,0)->'.'(46)
    #expect(boardStoneAt(9, rows, col: 1, row: 0) == 66)
    #expect(boardStoneAt(9, rows, col: 2, row: 2) == 87)
    #expect(boardStoneAt(9, rows, col: 0, row: 0) == 46)
}

@Test
func boardStateValidationMessages() {
    // venv-verified ValueError messages (matched verbatim):
    #expect(boardValidate(5, ["x"]) == "unsupported board size 5")
    #expect(boardValidate(9, Array(repeating: dots(9), count: 8)) == "expected 9 rows, got 8")
    let badLen = [dots(9), dots(9), dots(9), dots(8), dots(9), dots(9), dots(9), dots(9), dots(9)]
    #expect(boardValidate(9, badLen) == "row 3 has length 8, expected 9")
    let badChars = [dots(9), dots(9), "XZ.......", dots(9), dots(9), dots(9), dots(9), dots(9), dots(9)]
    #expect(boardValidate(9, badChars) == "row 2 contains invalid chars ['X', 'Z']")
}

@Test
func boardStateEmptyAndFromGrid() {
    // empty(9): 9 rows of 9 dots.
    let e = boardEmpty(9)
    #expect(e == Array(repeating: dots(9), count: 9).joined(separator: "\n"))
    // from_grid round-trips size + rows.
    let rows = [".B.......", ".........", "..W......", ".........", "....B....",
                ".........", ".........", ".......W.", "........."]
    #expect(boardFromGrid(rows) == "9|" + rows.joined(separator: "\n"))
}

// Small helper: a String of n dots.
private func dots(_ n: Int) -> String { String(repeating: ".", count: n) }
