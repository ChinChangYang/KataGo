//
//  gr_stones.h
//  CGobanRecog
//
//  Ports gobanrecog/pipeline/stones.py (per-intersection stone classification,
//  anchored on the wood appearance). INTERNAL header (uses cv:: types; kept
//  out of include/).
//
//  Cross-module surface only: run.py imports exactly {classify_stones} from
//  stones (run.py:13); StoneClassification is its return type. Everything else
//  stones.py defines (_rectify_lattice, _disk_indices, _w_fires, the offset
//  search) is file-local to gr_stones.cpp. SPACING=32/PAD=48 live in
//  gr_constants.h (SP/PAD).
//
//  The wood reference comes from cell centers — the centers of the unit
//  squares between intersections, which stones can never cover — so the scheme
//  is safe on boards with any number of stones including none. Luminance is
//  compared against a LOCAL wood reference; chroma separates white stones from
//  pale wood.
//

#ifndef gr_stones_h
#define gr_stones_h

#include <opencv2/core.hpp>

#include "gr_types.h"

namespace gobanrecog {

// ports stones.py::StoneClassification (dataclass). stones.py's `debug` field
// is always the empty dict {} (stones.py:173) and run.py only merges it into
// det.debug — a no-op — so the struct carries no debug member (Task 9 note).
struct StoneClassification {
    BoardState board;
    double confidence;  // min decision margin over all intersections, 0..1
};

// ports stones.py::classify_stones. img_bgr: uint8 BGR HxWx3; H_grid (CV_64F
// 3x3) maps grid coords -> image pixels; n = board size.
StoneClassification classify_stones(const cv::Mat& img_bgr, const cv::Mat& H_grid, int n);

}  // namespace gobanrecog

#endif /* gr_stones_h */
