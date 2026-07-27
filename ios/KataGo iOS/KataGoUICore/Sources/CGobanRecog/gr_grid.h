//
//  gr_grid.h
//  CGobanRecog
//
//  Ports gobanrecog/pipeline/grid.py (rectification + closed-world board-size
//  test). INTERNAL header (uses cv:: types; kept out of include/).
//
//  Cross-module surface only: detect.py imports exactly {PAD, SPAN, SizeResult,
//  choose_size, line_profiles, rectify_quad} from grid (detect.py:28-35). PAD
//  and SPAN live in gr_constants.h (RECT_PAD / SPAN); everything else grid.py
//  defines (_profile_peaks, _penalized, _comb_candidates, stoneness_map,
//  stone_alignment_score, _stone_offset_candidates, _continuation_count,
//  _weak_teeth, snap_lines) is file-local to gr_grid.cpp.
//
//  Size detection is a closed-world hypothesis test: for each n in {9, 13, 19}
//  fit an n-tooth comb (free offset + spacing per axis) to gradient projection
//  profiles of the rectified image, combined with stone-center lattice evidence
//  (dense positions hide the lines but stones sit exactly on the lattice).
//  Sub-combs (e.g. a 9-comb riding every other line of a 19-grid) are rejected
//  by penalizing strong profile peaks left unexplained inside the comb span.
//

#ifndef gr_grid_h
#define gr_grid_h

#include <map>
#include <utility>
#include <vector>

#include <opencv2/core.hpp>

#include "gr_constants.h"

namespace gobanrecog {

// ports grid.py::SizeResult (dataclass). xs/ys are the n grid-line positions
// along canonical x / y (float64); margin = best minus second-best hypothesis
// score; scores maps each hypothesized n to its best comb score.
struct SizeResult {
    int board_size = 0;
    std::vector<double> xs;
    std::vector<double> ys;
    double score = 0.0;
    double margin = 0.0;
    std::map<int, double> scores;
};

// ports grid.py::rectify_quad. Warp so `quad` (TL,TR,BR,BL; a 4x2 Mat, any
// depth) maps to the centered canonical square. Returns (rectified, H) with H
// (CV_64F 3x3) mapping image -> canonical pixels.
std::pair<cv::Mat, cv::Mat> rectify_quad(const cv::Mat& gray, const cv::Mat& quad,
                                         int span = SPAN, int pad = RECT_PAD);

// ports grid.py::line_profiles. Thin-dark-ridge projection profiles restricted
// to the quad interior (each a 1 x rect.cols / 1 x rect.rows CV_32F row).
// Blackhat with a short 1-D kernel responds to grid lines (thin dark on wood)
// but not to stone bodies or stone rims, so the profiles stay clean even on
// dense positions where most of each line is hidden.
std::pair<cv::Mat, cv::Mat> line_profiles(const cv::Mat& rect, int pad = RECT_PAD,
                                          int span = SPAN, bool mask = true);

// ports grid.py::choose_size. `rect` is the rectified frame from rectify_quad
// (uint8). Requires at least two hypothesized sizes (Python indexes ranked[1]).
//
// `forcedSize` is an app-only extension with NO Python counterpart (see
// port-conventions.md). 0 — the default, and the only value the ported auto
// path ever passes — leaves behaviour bit-identical to Python. A non-zero value
// present in `sizes` selects that hypothesis instead of the top-scoring one,
// for the manual-grid path where the user has stated the board size outright.
// Every size is still scored, so `scores` and `margin` remain meaningful; the
// margin then measures the stated size against its best rival, and may be
// negative when the user contradicts the image evidence. A `forcedSize` absent
// from `sizes` falls back to the automatic choice.
SizeResult choose_size(const cv::Mat& rect, const std::vector<int>& sizes = {9, 13, 19},
                       int forcedSize = 0);

}  // namespace gobanrecog

#endif /* gr_grid_h */
