//
//  gr_detect.h
//  CGobanRecog
//
//  Ports the cross-module surface of gobanrecog/pipeline/detect.py. INTERNAL
//  header (uses cv:: types; kept out of include/).
//
//  detect.py is ported across TWO tasks (port-conventions.md, gr_detect row):
//    - Task 7 (gr_detect_proposers.cpp): the quad-proposer layer (part A). Its
//      A<->B seam lives in gr_detect_internal.h.
//    - Task 8 (gr_detect.cpp): fit / arbitrate / refine + detect_board (part B).
//
//  This header exposes only what OTHER modules (run.py's port) consume: the
//  BoardDetection result type and the detect_board entry point (Task 8), plus
//  DetectionError (re-exported from gr_errors.h - run.py catches it). The
//  proposer signatures the two detect halves share are NOT here; they live in
//  gr_detect_internal.h so they never leak past the module.
//

#ifndef gr_detect_h
#define gr_detect_h

#include <map>
#include <string>

#include <opencv2/core.hpp>

#include "gr_errors.h"  // DetectionError (detect.py:38); run.py's port catches it

namespace gobanrecog {

// ports detect.py::BoardDetection.debug (dict payload -> struct, rule 6). run.py
// reads debug["quad_source"] for the recognition result; size_scores mirrors
// debug["size_scores"] = size_res.scores (detect.py:1131).
struct DebugInfo {
    std::string quad_source;
    std::map<int, double> size_scores;
};

// ports detect.py::BoardDetection (dataclass, detect.py:42-48).
struct BoardDetection {
    int board_size = 0;
    cv::Mat corners;  // 4x2 CV_64F outer grid intersections, TL TR BR BL
    cv::Mat H_grid;   // CV_64F 3x3, grid coords (col,row) -> image pixels
    double size_margin = 0.0;
    DebugInfo debug;
};

// ports detect.py::detect_board. IMPLEMENTED IN TASK 8 (gr_detect.cpp) - declared
// here so run.py's port and the module surface are stable while Task 7 lands the
// proposer half. Throws DetectionError on every abstention path.
//
// `userQuad` / `forcedSize` are an app-only extension with NO Python
// counterpart (see port-conventions.md), for the manual-grid UI where the user
// places the board's four outer grid-line intersections themselves. Both absent
// — the default, and all the ported auto path ever passes — leaves behaviour
// bit-identical to Python.
//
// With a `userQuad` (4x2 CV_64F, TL TR BR BL, image pixels) the five quad
// proposers are SKIPPED and the candidate set is seeded from that quad alone.
// The user is answering the question the proposers failed to answer, so letting
// `hough` or `slab` outvote them during arbitration would defeat the point.
// Everything downstream — the vetoes, arbitration, the refinement loop and the
// stone-anchored refit — still runs, which is what lets a corner placed a few
// pixels off snap onto the true lattice instead of shifting the whole grid.
//
// Callers on that path should also pass a permissive `min_size_margin`: the
// ambiguity gate exists to catch the detector guessing between board sizes, and
// has nothing to say when the user has stated the size outright.
BoardDetection detect_board(const cv::Mat& img_bgr, double min_size_margin = 2.0,
                            const cv::Mat* userQuad = nullptr, int forcedSize = 0);

}  // namespace gobanrecog

#endif /* gr_detect_h */
