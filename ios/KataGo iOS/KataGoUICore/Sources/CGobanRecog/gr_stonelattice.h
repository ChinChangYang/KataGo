//
//  gr_stonelattice.h
//  CGobanRecog
//
//  Ports gobanrecog/pipeline/stonelattice.py (the last-resort quad proposer:
//  fits a homography directly to lattice-independent stone centers). INTERNAL
//  header (uses cv:: types; kept out of include/).
//
//  Cross-module surface only: detect.py imports {sl_fits, quads_of} from
//  stonelattice (detect.py:644,664,668). Everything else stonelattice.py
//  defines (_order_quad, _corners_of, the two peak detectors, _union_peaks,
//  _lattice_basis, _seed_component, the two growers, _core_extent,
//  _stone_map_raw) is file-local to gr_stonelattice.cpp. SP=32/PAD=48 and the
//  17x17 stone kernel _KER live in gr_constants.h (SP/PAD/stoneKernel()).
//
//  Peak detection = union of two complementary detectors on a seed-warped map:
//  ring peaks (disk-averaged stoneness maxima with min-falloff compactness) and
//  DT peaks (distance-transform maxima of thresholded stoneness). Integer
//  lattice coords: basis from neighbor-displacement angle clustering -> largest
//  unit-step BFS component -> region growing with BOTH a global LMEDS-homography
//  grower and a local-affine grower; each grower's result becomes its own fit.
//

#ifndef gr_stonelattice_h
#define gr_stonelattice_h

#include <utility>
#include <vector>

#include <opencv2/core.hpp>

#include "gr_constants.h"

namespace gobanrecog {

// ports one element of stonelattice.py::sl_fits's return list: (Hd, ext). Hd
// (CV_64F 3x3, normalized so Hd[2,2]==1) maps 0-based lattice ints -> image
// pixels; ext = (ncols, nrows) is the trimmed core extent of the inlier set.
struct SlFit {
    cv::Mat Hd;
    int ext_cols;  // ext[0]
    int ext_rows;  // ext[1]
};

// ports stonelattice.py::sl_fits. One full detect+grow+fit round from the
// grayscale image and a seed homography H_seed (CV_64F 3x3) with n_seed board
// size (only sizes the canonical warp frame). Returns the LMEDS-grown and
// local-affine-grown fits that survive the RANSAC refit + core-extent gate.
//
// DETERMINISM: LMEDS/RANSAC consume OpenCV's global RNG. detect.py calls
// cv::setRNGSeed(1234) once before the proposer (detect.py:929); the caller
// (or the harness) must do the same before sl_fits for reproducible sampling.
std::vector<SlFit> sl_fits(const cv::Mat& gray, const cv::Mat& H_seed, int n_seed,
                           int margin = 3);

// ports stonelattice.py::quads_of. Candidate quads for one fit: the stone bbox
// expanded by 1 unit (when min(ext) >= 6), plus the grid-outline quad when the
// extent is a legal square (9/13/19). Each quad is a 4x2 CV_64F Mat, ordered
// TL,TR,BR,BL by _order_quad.
std::vector<cv::Mat> quads_of(const cv::Mat& Hd, int ext_cols, int ext_rows);

}  // namespace gobanrecog

#endif /* gr_stonelattice_h */
