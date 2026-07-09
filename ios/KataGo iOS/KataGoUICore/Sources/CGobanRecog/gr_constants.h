//
//  gr_constants.h
//  CGobanRecog
//
//  Single source for constants scattered across the Python pipeline. INTERNAL
//  header (kept out of include/). Each constant cites its Python origin
//  (file + name). Per port-conventions.md, the Python source duplicates the
//  32/48/8 stone frame at five sites and L=13 at four; the C++ port hoists
//  each ONCE here.
//
//  SUPPORTED_SIZES {9,13,19} lives in gr_types.h (its Python origin is
//  types.py:22); it is not re-defined here to keep a single source.
//

#ifndef gr_constants_h
#define gr_constants_h

#include <utility>
#include <vector>

#include <opencv2/core.hpp>

namespace gobanrecog {

// ---- Stone frame (canonical warp around a lattice). ------------------------
// detect.py:515  `_SP, _PAD, _R = 32, 48, 8`  (also stones.py SPACING=32/PAD=48,
// stonelattice.py SP=32/PAD=48). Hoisted once (port-conventions.md).
constexpr int SP = 32;   // canonical spacing (rectified pixels per grid unit)
constexpr int PAD = 48;  // canonical border padding around the lattice
constexpr int R = 8;     // stone disk radius; kernel side = 2*R+1 = 17

// ---- Blackhat structuring-element length. ----------------------------------
// grid.py:58 / detect.py:247,387,727  `L = 13`
// "longer than any plausible line width, shorter than any stone".
constexpr int L = 13;

// ---- Rectification frame (grid.py:18-20). ----------------------------------
// grid.py:18  SPAN = 800   the detected quad is rectified to [PAD, PAD+SPAN]^2
// grid.py:19  PAD  = 150   (rectification padding; distinct from the stone PAD=48)
// grid.py:20  MAX_MARGIN = 1.3   max plausible slab margin beyond the grid (grid units)
constexpr int SPAN = 800;
constexpr int RECT_PAD = 150;
constexpr double MAX_MARGIN = 1.3;

// ---- Tuned weights (jointly eval-calibrated; do NOT retune). ---------------
constexpr double STONE_WEIGHT = 12.0;         // grid.py:198
constexpr double WEAK_TOOTH_PENALTY = 1.2;    // grid.py:199
constexpr double CONT_THR = 0.65;             // grid.py:200
constexpr double CONT_PENALTY = 8.0;          // grid.py:201
constexpr double MAX_SPACING_ANISO = 1.5;     // detect.py:355
constexpr double CUT_ABS = 1.5;               // detect.py:375
constexpr double CUT_REL_MULT = 2.0;          // detect.py:376
constexpr double CUT_REL_ADD = 0.8;           // detect.py:377
constexpr double SHIFT_BONUS_WEIGHT = 2.0;    // detect.py:453
constexpr double SHIFT_MIN_GAIN = 0.10;       // detect.py:454 (rival must beat incumbent by this)
constexpr double QUALITY_GAIN = 0.25;         // detect.py:512
constexpr double VERIFIED_GATE = 0.5;         // detect.py:513
constexpr double CONF_FLOOR = 0.049;          // run.py:33

// ---- Module-level constants built at import time (rule 8: function-local
//      `static const` built on first use). ---------------------------------

/// The normalized 17x17 ellipse disk kernel `_KER`. Built identically to
/// detect.py:516-517:
///   cv2.getStructuringElement(MORPH_ELLIPSE, (2*R+1, 2*R+1)).astype(float32)
///   _KER /= _KER.sum()
/// CV_32F, sums to 1. Returned by reference from a function-local static.
const cv::Mat& stoneKernel();

/// The 5x5 offset grid `_NODE_OFFSETS` (stones.py:26-33), sorted by radius^2
/// with CENTER FIRST. Tie order is load-bearing: it replicates Python's stable
/// `sorted(...)` over the generator's (dx outer, dy inner) emission order.
const std::vector<std::pair<double, double>>& nodeOffsets();

}  // namespace gobanrecog

#endif /* gr_constants_h */
