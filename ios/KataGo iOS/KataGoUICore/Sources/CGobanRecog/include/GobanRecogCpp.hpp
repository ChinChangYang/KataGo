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

/// Recognize the board in a BGR uint8 image (HxWx3, `bytesPerRow` stride).
/// Real pipeline lands in Tasks 3-9; the skeleton returns a failed status.
GobanRecogResult recognizeGoban(const uint8_t* bgr, int width, int height, size_t bytesPerRow);

/// TEMPORARY (removed in a later task): exercises cv:: end-to-end to prove
/// core + imgproc + geometry (homography) compile, link, and run on every
/// platform the app test suite touches. Returns a string like "5.0.0|h_ok=1".
string gobanRecogOpenCVSmoke();

#endif /* GobanRecogCpp_hpp */
