//
//  GobanRecogCpp.hpp
//  CGobanRecog
//
//  Public seam for the GobanRecog board-recognition port. This is the ONLY
//  public header of the CGobanRecog module: it is imported by Swift through
//  Swift/C++ interop, so it must expose PLAIN C++ std types only — never any
//  cv:: types (those stay internal to the .cpp implementation files).
//
//  Value-semantic members only. Never return a named-local swift::Optional
//  from these functions (project-known interop landmine:
//  __fatalError_Cxx_move undefined at link time).
//

#ifndef GobanRecogCpp_hpp
#define GobanRecogCpp_hpp

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

using namespace std;

/// Result of recognizing a Go board from a photo. Mirrors the Python
/// RecognitionResult, reduced to value-semantic std types for the Swift seam.
struct GobanRecogResult {
    string status;          // "ok" | "failed:<reason>"
    int boardSize = 0;
    vector<string> rows;    // rows[row][col]; row 0 = topmost image row; '.', 'B', 'W'
    double confidence = 0.0;
    string quadSource;
    /// The board's four OUTER GRID-LINE INTERSECTIONS in image pixels, as
    /// x0,y0,x1,y1,x2,y2,x3,y3 (TL, TR, BR, BL) — 8 values, or empty when no
    /// detection was reached. Note these sit on the grid, not on the wooden
    /// edge. Exposed so the manual-grid UI can start from what the app found
    /// rather than from scratch, which turns "place the corners" into "correct
    /// the corners".
    vector<double> corners;
};

/// Recognize the board in a BGR uint8 image (HxWx3, `bytesPerRow` stride;
/// pass 0 for a tightly-packed width*3 stride). Wraps the buffer as a cv::Mat
/// (no copy), runs the full pipeline (run.py::recognize_image), and returns the
/// value-semantic result: status "ok" | "failed:<reason>", boardSize + rows +
/// confidence + quadSource on success (rows empty, boardSize 0 on failure).
/// Defined in gr_run.cpp.
///
/// NOT safe for concurrent calls: seeds OpenCV's process-global RNG
/// (cv::setRNGSeed) at entry and relies on OpenCV global state, so overlapping
/// invocations race. Callers must serialize (the app presents one import sheet
/// at a time); a future batch caller must run recognitions sequentially.
GobanRecogResult recognizeGoban(const uint8_t* bgr, int width, int height, size_t bytesPerRow);

/// Recognize with the board's four outer grid-line intersections supplied by
/// the user, instead of searching for them.
///
/// `quadXY` is 8 doubles — x0,y0,x1,y1,x2,y2,x3,y3 for TL,TR,BR,BL in image
/// pixels — and must describe a convex quadrilateral. `boardSize` is 9, 13 or
/// 19; any other value falls back to automatic size choice.
///
/// This skips the five quad proposers entirely: the caller is answering the
/// question those proposers exist to answer, so nothing may outvote them. It
/// also lifts the confidence floor, because "low confidence, try again" gives a
/// user who has just placed the grid by hand nothing to act on — inspect
/// `confidence` and warn instead. Everything else (the vetoes, arbitration, the
/// refinement loop, the stone-anchored refit, stone classification) is the same
/// code the automatic path runs, so a corner placed a few pixels off still
/// snaps onto the true lattice.
///
/// Same concurrency contract as recognizeGoban: NOT safe for concurrent calls.
/// Defined in gr_run.cpp.
GobanRecogResult recognizeGobanWithQuad(const uint8_t* bgr, int width, int height,
                                        size_t bytesPerRow,
                                        const double* quadXY, int boardSize);

#endif /* GobanRecogCpp_hpp */
