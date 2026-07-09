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

#endif /* GobanRecogCpp_hpp */
