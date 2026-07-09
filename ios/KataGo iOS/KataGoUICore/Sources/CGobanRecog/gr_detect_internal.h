//
//  gr_detect_internal.h
//  CGobanRecog
//
//  The part A <-> part B seam for the detect.py port. INTERNAL header (uses cv::
//  types; kept out of include/ and out of gr_detect.h so nothing here leaks past
//  the module). Both detect halves include this; nothing else does.
//
//  ---------------------------------------------------------------------------
//  A/B BOUNDARY (decided in Task 7 - read task-7-report.md for the rationale):
//
//    Part A  = detect.py's candidate-quad GENERATION layer:
//       _order_quad, _degenerate_quad (shared geometry helpers, file-local),
//       _line_params, _extreme_lines, _intersect (hough helpers, file-local),
//       and the proposers _quad_hull / _quad_hough / _quad_texture / _quad_slab
//       + the wood-slab mask builder _wood_mask.
//       -> gr_detect_proposers.cpp (Task 7).
//
//    Part B  = everything that EVALUATES / fits / arbitrates / refines a
//       candidate: _extension_counts, _try_extension, _fit_lattice,
//       lattice_quality, _spacing_anisotropy, _cut_score, _slab_edge_scores,
//       _slab_consistency, _shift_search, _stone_map, _stone_peaks, stone_stats,
//       stone_anchor_refit, _stone_lattice_candidate_quads, _verified,
//       _nocont_margin, _eff_margin, _corners_of, _measure_nodes,
//       _refine_H_nodes, _is_subgrid, and detect_board.
//       -> gr_detect.cpp (Task 8).
//
//  Only the seam below crosses the boundary: detect_board (part B) calls all
//  four proposers and _wood_mask directly (detect.py:863,882-888). The part-A
//  helpers _order_quad/_degenerate_quad/_line_params/_extreme_lines/_intersect
//  are used ONLY within the proposers, so they stay file-local to
//  gr_detect_proposers.cpp (reachable by that file's test bridge, not here).
//  ---------------------------------------------------------------------------
//

#ifndef gr_detect_internal_h
#define gr_detect_internal_h

#include <cstdint>
#include <optional>

#include <opencv2/core.hpp>

#include "gr_errors.h"  // DetectionError / LinAlgError (control flow, rule 3)

namespace gobanrecog {

// ports detect.py::stone_stats's dict payload (rule 6: dict -> struct wrapped in
// std::optional; None below 12 on-board stones -> nullopt). n_in is int and B is
// an integer count in Python; B is kept as double per port-conventions.md's
// StoneStats spec (its uses are all comparisons and its values are exact ints).
struct StoneStats {
    int n_in;      // detect.py: n_in  (on-board detected stones)
    double A;      // fraction of on-board stones sitting off-lattice
    double B;      // off-board stones that ALIGN with the extended lattice
    double resid;  // median match error of on-lattice stones
};

// ==== Part A: quad proposers (gr_detect_proposers.cpp, Task 7) ===============
//
// Each proposer runs on the RAW image with FIXED-PIXEL kernels (never on a
// rectified frame) and returns a 4x2 CV_64F quad ordered TL,TR,BR,BL (via
// _order_quad), or throws DetectionError / LinAlgError / cv::Exception as
// control flow (rule 3) - detect_board collects the DetectionError reason
// strings into "all quad proposers failed: <joined>".

// detect.py::_quad_hull - convex hull of the largest Canny edge blob at the
// given dilation radius, approximated to 4 corners. detect_board uses radius 2
// ("hull") and radius 1 ("hull1").
cv::Mat _quad_hull(const cv::Mat& gray, int dilate_iterations = 2);

// detect.py::_quad_hough - quad from the extreme merged lines of the two
// angular families (HoughLinesP on Canny edges).
cv::Mat _quad_hough(const cv::Mat& gray);

// detect.py::_quad_texture - quad from the largest high-local-variance blob.
cv::Mat _quad_texture(const cv::Mat& gray);

// detect.py::_quad_slab - quad from the wood-slab mask (operates on BGR).
cv::Mat _quad_slab(const cv::Mat& img_bgr);

// detect.py::_wood_mask - binary uint8 0/1 mask of the pale wooden slab, or
// nullopt when unconfident (rule 5: None sentinel -> std::optional). SHARED:
// detect_board (part B) calls this directly (detect.py:863) and the Task-8 slab
// consistency / shift helpers consume its output.
std::optional<cv::Mat> _wood_mask(const cv::Mat& img_bgr);

// ==== Part B: fit / arbitrate / refine (gr_detect.cpp, Task 8) ===============
//
// Task 8 adds its cross-file declarations HERE (e.g. _fit_lattice, choose-and-
// score helpers, stone_stats, lattice_quality, _cut_score, _corners_of,
// _slab_edge_scores, _shift_search, _measure_nodes, _refine_H_nodes,
// _try_extension, _spacing_anisotropy, _is_subgrid,
// _stone_lattice_candidate_quads, _verified/_eff_margin) as it encounters them,
// so part A never has to be reshuffled. detect_board itself is declared in the
// public-to-the-module gr_detect.h.

}  // namespace gobanrecog

#endif /* gr_detect_internal_h */
