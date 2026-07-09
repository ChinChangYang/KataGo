//
//  StonesPortTests.swift
//  GobanRecogNativeTests
//
//  Native tests for the gr_stones port of gobanrecog/pipeline/stones.py
//  (Task 5). All ground truth was generated with the reference venv
//  (numpy 2.5.1, cv2 5.0.0); the generating snippets are inline.
//

import CGobanRecog
import Testing

// MARK: - Bridge helpers

private func diskIndices(_ radius: Int) -> (dy: [Int32], dx: [Int32]) {
    let cap = (2 * radius + 1) * (2 * radius + 1)
    var dy = [Int32](repeating: 0, count: cap)
    var dx = [Int32](repeating: 0, count: cap)
    let n = dy.withUnsafeMutableBufferPointer { dyp in
        dx.withUnsafeMutableBufferPointer { dxp in
            gobanrecog.testbridge.stones_disk_indices(Int32(radius), dyp.baseAddress, dxp.baseAddress)
        }
    }
    return (Array(dy[0..<Int(n)]), Array(dx[0..<Int(n)]))
}

private func wFires(gap: Double, ratio: Double, mc: Double, woodC: Double) -> Bool {
    gobanrecog.testbridge.stones_w_fires(gap, ratio, mc, woodC) != 0
}

private func classifyRect(_ rect: [UInt8], side: Int, boardSize: Int) -> (rows: [String], confidence: Double) {
    let s = rect.withUnsafeBufferPointer {
        String(gobanrecog.testbridge.stones_classify_rect($0.baseAddress, Int32(side), Int32(boardSize)))
    }
    let parts = s.split(separator: "|")
    let rows = parts[0].split(separator: "\n").map(String.init)
    return (rows, Double(parts[1])!)
}

// MARK: - _disk_indices (stones.py:53-56)

@Test
func diskIndicesMatchNumpyMgridOrder() {
    // venv: yy, xx = np.mgrid[-2:3, -2:3]; m = xx**2 + yy**2 <= 4
    //   yy[m].tolist() -> [-2,-1,-1,-1,0,0,0,0,0,1,1,1,2]
    //   xx[m].tolist() -> [0,-1,0,1,-2,-1,0,1,2,-1,0,1,0]
    // (row-major C-order selection: yy outer ascending, xx inner ascending)
    let d2 = diskIndices(2)
    #expect(d2.dy == [-2, -1, -1, -1, 0, 0, 0, 0, 0, 1, 1, 1, 2])
    #expect(d2.dx == [0, -1, 0, 1, -2, -1, 0, 1, 2, -1, 0, 1, 0])
    // venv: len(_disk_indices(7)[0]) == 149  (cell disk: int(round(0.22*32)) == 7)
    //       len(_disk_indices(12)[0]) == 441 (node disk: int(round(0.36*32)) == 12)
    #expect(diskIndices(7).dy.count == 149)
    #expect(diskIndices(12).dy.count == 441)
}

// MARK: - _w_fires (stones.py:59-70)

@Test
func wFiresThreeRuleBoundaries() {
    // Rule 1: gap > 0.10 and ratio > 0.90 (both strict)
    #expect(wFires(gap: 0.101, ratio: 0.901, mc: 0.5, woodC: 0.5))
    #expect(!wFires(gap: 0.10, ratio: 0.901, mc: 0.5, woodC: 0.5))   // gap == 0.10 does not fire
    #expect(!wFires(gap: 0.101, ratio: 0.90, mc: 0.5, woodC: 0.5))   // ratio == 0.90 does not fire
    // Rule 2: gap > 0.055 and ratio > 1.00 (both strict)
    #expect(wFires(gap: 0.056, ratio: 1.001, mc: 0.5, woodC: 0.5))
    #expect(!wFires(gap: 0.055, ratio: 1.001, mc: 0.5, woodC: 0.5))  // gap == 0.055 does not fire
    #expect(!wFires(gap: 0.056, ratio: 1.00, mc: 0.5, woodC: 0.5))   // ratio == 1.00 does not fire
    // Rule 3: ratio > 1.10 and mc < 0.65 * wood_c (both strict)
    #expect(wFires(gap: 0.0, ratio: 1.101, mc: 0.32, woodC: 0.5))    // 0.32 < 0.325
    #expect(!wFires(gap: 0.0, ratio: 1.101, mc: 0.325, woodC: 0.5))  // mc == 0.65*wood_c does not fire
    #expect(!wFires(gap: 0.0, ratio: 1.10, mc: 0.32, woodC: 0.5))    // ratio == 1.10 does not fire
}

// MARK: - classify on a synthetic pre-rectified frame

@Test
func classifySyntheticRectUnambiguousLabels() {
    // venv generating snippet (all-integer construction, no float ambiguity):
    //   n = 9; side = 2*48 + 8*32  # 352
    //   rect = np.zeros((side, side, 3), np.uint8); rect[:, :] = (100, 150, 200)
    //   def draw(cx, cy, rad, bgr):
    //       for y in range(cy-rad, cy+rad+1):
    //           for x in range(cx-rad, cx+rad+1):
    //               if (x-cx)**2 + (y-cy)**2 <= rad*rad: rect[y, x] = bgr
    //   draw(48+2*32, 48+3*32, 13, (20, 20, 20))     # black stone at col 2, row 3
    //   draw(48+6*32, 48+5*32, 13, (245, 245, 245))  # white stone at col 6, row 5
    //   A = np.array([[32,0,48],[0,32,48],[0,0,1]], float)
    //   cls = classify_stones(rect, A, 9)  # identity lattice; warp verified byte-exact
    //   -> rows below, confidence 0.7488226059654631
    let side = 2 * 48 + 8 * 32  // 352
    var rect = [UInt8](repeating: 0, count: side * side * 3)
    for i in 0..<(side * side) {
        rect[3 * i] = 100      // B
        rect[3 * i + 1] = 150  // G
        rect[3 * i + 2] = 200  // R (wood is the warmest surface)
    }
    func draw(_ cx: Int, _ cy: Int, _ radius: Int, _ bgr: (UInt8, UInt8, UInt8)) {
        for y in (cy - radius)...(cy + radius) {
            for x in (cx - radius)...(cx + radius) {
                if (x - cx) * (x - cx) + (y - cy) * (y - cy) <= radius * radius {
                    let i = 3 * (y * side + x)
                    rect[i] = bgr.0
                    rect[i + 1] = bgr.1
                    rect[i + 2] = bgr.2
                }
            }
        }
    }
    draw(48 + 2 * 32, 48 + 3 * 32, 13, (20, 20, 20))      // pure black disk -> 'B'
    draw(48 + 6 * 32, 48 + 5 * 32, 13, (245, 245, 245))   // white disk -> 'W'
    let res = classifyRect(rect, side: side, boardSize: 9)
    #expect(res.rows == [
        ".........",
        ".........",
        ".........",
        "..B......",
        ".........",
        "......W..",
        ".........",
        ".........",
        ".........",
    ])
    // Bit-exact: the micro-parity same-bytes leg (compare_stage.py --exact)
    // proved the entire rect -> astype -> cvtColor(f32) -> warmth -> median ->
    // classification path bit-identical to the venv on three real inputs, so
    // the venv confidence is pinned with ==.
    #expect(res.confidence == 0.7488226059654631)
}
