//
//  RunPortTests.swift
//  GobanRecogNativeTests
//
//  Native end-to-end smoke for the gr_run port of run.py::recognize_image
//  (Task 9). Feeds the bundled img0811.bgr.raw (602x626x3 BGR, exactly
//  cv2.imread(tests/fixtures/img0811.jpg).tofile) through the cv-free
//  recognize_status_line bridge and asserts the full pipeline recognizes the
//  board: status "ok", size 19, and the emitted SGF byte-for-byte equal to the
//  Python reference (tests/fixtures/img0811_expected.sgf). This is the same
//  parity the gobanrecog-cli fixture sanity proves at the process boundary,
//  captured as an in-process regression test.
//

import CGobanRecog
import Foundation
import Testing

// img0811.jpg dimensions (cv2 shape (H,W,C) = (626, 602, 3)).
private let img0811Width = 602
private let img0811Height = 626

// The Python reference SGF (tests/fixtures/img0811_expected.sgf), verified equal
// to board_to_sgf(recognize_image(cv2.imread(img0811.jpg)).board).
private let img0811ExpectedSgf =
    "(;GM[1]FF[4]CA[UTF-8]AP[GobanRecog:0.1]SZ[19]" +
    "AB[nd][pd][qd][oe][qe][re][pf][kg][lg][og][pg][kh][mh][oh][qh][ji][mi][ni][pi][qi]" +
    "[lj][jk][lk][ok][qk][ol][pl][ql][nm][pm][mn][nn][qn][lo][po][qo][ro][hp][ip][kp][qp][rp]" +
    "[fq][kq][rq]" +
    "AW[rb][nc][pc][qc][sc][dd][md][rd][me][se][lf][qf][rf][mg][ng][lh][nh][oi][ij][jj][nj]" +
    "[oj][pj][qj][rj][ik][nk][pk][ll][nl][rl][lm][mm][qm][cn][ln][pn][rn][io][jo][ko][dp]" +
    "[qq][sq][rr])"

private func recognizeStatusLine(_ bgr: [UInt8], width: Int, height: Int)
    -> (status: String, boardSize: Int, confidence: Double, quadSource: String, sgf: String) {
    let line = bgr.withUnsafeBufferPointer {
        String(gobanrecog.testbridge.recognize_status_line($0.baseAddress, Int32(width), Int32(height)))
    }
    // "<status>\t<board_size>\t<confidence>\t<quad_source>\t<sgf>" — split on the
    // first four tabs (sgf is last and never contains a tab).
    let parts = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
    return (
        status: String(parts[0]),
        boardSize: Int(parts[1]) ?? -1,
        confidence: Double(parts[2]) ?? .nan,
        quadSource: String(parts[3]),
        sgf: parts.count > 4 ? String(parts[4]) : ""
    )
}

@Test
func recognizeImageOnImg0811RecognizesNineteen() throws {
    let url = try #require(Bundle.module.url(forResource: "img0811.bgr.raw", withExtension: nil,
                                             subdirectory: "Resources"))
    let data = try Data(contentsOf: url)
    #expect(data.count == img0811Width * img0811Height * 3)
    let bgr = [UInt8](data)

    let r = recognizeStatusLine(bgr, width: img0811Width, height: img0811Height)
    #expect(r.status == "ok")
    #expect(r.boardSize == 19)
    #expect(r.quadSource == "slab")
    // The classification path is bit-exact to the venv (Task 5), so the emitted
    // SGF matches Python's byte-for-byte.
    #expect(r.sgf == img0811ExpectedSgf)
    // Python confidence 0.23937779622452926, comfortably above CONF_FLOOR 0.049.
    #expect(r.confidence > 0.049)
}
