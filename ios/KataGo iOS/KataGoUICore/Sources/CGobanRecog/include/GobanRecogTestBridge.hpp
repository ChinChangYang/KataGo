//
//  GobanRecogTestBridge.hpp
//  CGobanRecog
//
//  TEST/DIAGNOSTIC seam (mirrors the precedent set by gobanRecogOpenCVSmoke in
//  GobanRecogCpp.hpp). Exposes the internal numpy-parity helpers, constants,
//  and BoardState across Swift/C++ interop using PLAIN C++ std types only -
//  never cv:: types - so the native SwiftPM test target `GobanRecogNativeTests`
//  can drive them without importing OpenCV. Each function is a thin wrapper
//  over the real gobanrecog:: implementation in gr_parity.cpp / gr_types.cpp /
//  gr_constants.cpp.
//
//  Array parameters are raw pointers (Swift passes them via
//  withUnsafe[Mutable]BufferPointer); board rows are newline-joined C strings
//  (Swift passes them via withCString). Error-throwing helpers catch the C++
//  exception in the wrapper and signal failure through a return code, because
//  C++ exceptions cannot cross into Swift.
//

#ifndef GobanRecogTestBridge_hpp
#define GobanRecogTestBridge_hpp

#include <string>

namespace gobanrecog {
namespace testbridge {

// ---- parity helpers ----
double np_round(double x);
double np_percentile(const double* v, int n, double q);
// np_percentile's out-of-range guard: returns 1 if q outside [0,100] threw
// std::invalid_argument (mirrors numpy's ValueError), 0 otherwise.
int np_percentile_range_throws(const double* v, int n, double q);
double np_median(const double* v, int n);
double np_median_f32(const float* v, int n);   // exercises the CV_32F path
double np_median_u8(const unsigned char* v, int n);  // exercises the uint8 path
// per-column median of a rows x cols CV_64F Mat -> out[cols]
void np_median_axis0(const double* data, int rows, int cols, double* out);
// lstsq: A (m x n, row-major), B (m x bcols, row-major) -> out (n x bcols)
void lstsq(const double* A, int m, int n, const double* B, int bcols, double* out);
// pinv: A (n x n) -> out (n x n)
void pinv(const double* A, int n, double* out);
int matrix_rank(const double* A, int m, int n);
// inv3x3: H (9) -> out9 (9). Returns 0 on success, 1 if LinAlgError was thrown.
int inv3x3(const double* H, double* out9);
// solve2x2: A4 (2 x 2, row-major), b2 (2) -> out2 (2). 0 ok, 1 if LinAlgError.
int solve2x2(const double* A4, const double* b2, double* out2);

// ---- parity helpers added by Task 4 (gr_parity.cpp) ----
// np.mean of a float32 array: numpy pairwise summation in float32, divided by
// float32(n). Returned promoted to double (exact).
double np_mean_f32(const float* v, int n);
// np.mean of a float64 array (numpy pairwise summation in double).
double np_mean_f64(const double* v, int n);
// np.percentile of a float32 array: sorted + lerped in PURE float32 (gamma is
// cast to float32), matching numpy 2.5.1. Returned promoted to double (exact).
double np_percentile_f32(const float* v, int n, double q);
// np.arange(start, stop, step) for float64. Fills out (up to cap elements) and
// returns the length numpy would produce.
int np_arange(double start, double stop, double step, double* out, int cap);

// ---- gr_grid internals (wrappers DEFINED in gr_grid.cpp so they can reach the
//      file-local statics; grid.py port, Task 4) ----
// _profile_peaks: fills out (caller-allocated, profLen doubles worst case) with
// the kept peak indices (ascending); returns the count.
int grid_profile_peaks(const float* prof, int profLen, double minSep, double* out);
// _penalized comb score.
double grid_penalized(const float* prof, int profLen, const double* peaks,
                      int peaksLen, int n, double o, double s);
// _comb_candidates: fills outTriples with up to k (score, offset, spacing)
// triples (row-major, k*3 doubles); returns the count.
int grid_comb_candidates(const float* prof, int profLen, const double* peaks,
                         int peaksLen, int n, int k, double* outTriples);
// _weak_teeth over a rows x cols float64 `avg` map (row-major).
int grid_weak_teeth(const double* avg, int rows, int cols, double scale,
                    const float* profX, int lenX, const float* profY, int lenY,
                    int n, double ox, double sx, double oy, double sy);
// snap_lines: fills out[n] with the snapped positions.
void grid_snap_lines(const float* prof, int profLen, const double* positions,
                     int n, double spacing, double* out);
// Micro-parity harness core (also used by the gobanrecog-dev executable):
// img is row-major grayscale uint8. If quad8 is non-null (TL,TR,BR,BL x/y
// pairs) the image is first rectified with rectify_quad and the JSON gains an
// "H" key; otherwise img IS the rectified frame. Runs choose_size and returns
// a JSON object: rect size, per-axis masked/full profiles, peaks, per-size comb
// scores, chosen board_size, score, margin, xs/ys. Python-flavored JSON
// (NaN/Infinity tokens permitted, as accepted by Python's json module).
std::string grid_stage_json(const unsigned char* img, int width, int height,
                            const double* quad8);
// rectify_quad alone: fills outRect ((SPAN+2*RECT_PAD)^2 bytes, caller-
// allocated) and outH9 (row-major 3x3); returns the side length.
int grid_rectify(const unsigned char* gray, int width, int height,
                 const double* quad8, unsigned char* outRect, double* outH9);
// Silences OpenCV's logger (its lazy init banner goes to stdout, corrupting
// the gobanrecog-dev harness JSON; the OPENCV_LOG_LEVEL env var is cached
// before main runs, so it must be the API call). Diagnostic-only.
void quiet_opencv_logs();

// ---- gr_stones internals (wrappers DEFINED in gr_stones.cpp so they can
//      reach the file-local statics; stones.py port, Task 5) ----
// _disk_indices: fills dy/dx (caller-allocated, (2*radius+1)^2 entries worst
// case) with the disk offsets in numpy's row-major mgrid order; returns the
// count of in-disk offsets.
int stones_disk_indices(int radius, int* dy, int* dx);
// _w_fires shared three-rule white condition. Returns 1 if it fires, 0 if not.
int stones_w_fires(double gap, double ratio, double mc, double wood_c);
// classify_stones on a PRE-RECTIFIED canonical frame (row-major uint8 BGR
// side x side x 3, exactly what _rectify_lattice outputs). Returns
// "<rows joined by '\n'>|<confidence %.17g>".
std::string stones_classify_rect(const unsigned char* rect, int side, int boardSize);
// Micro-parity harness core (also used by the gobanrecog-dev executable):
// img is row-major uint8 BGR HxWx3. If h9 is non-null (row-major 3x3 H_grid)
// the image is first rectified with _rectify_lattice and the JSON gains an
// "M" key (the canonical warp A @ inv(H_grid)); otherwise img IS the
// pre-rectified frame (width == height == 2*PAD + (n-1)*SP). Runs the
// classifier and returns a JSON object: stage, board_size, rect size, [M],
// rows, confidence, margins (n x n clamped per-node decision margins).
// Python-flavored JSON (NaN/Infinity tokens permitted).
std::string stones_stage_json(const unsigned char* img, int width, int height,
                              const double* h9, int boardSize);
// _rectify_lattice alone: fills outRect (side*side*3 bytes, caller-allocated,
// side = 2*PAD + (n-1)*SP) and outM9 (row-major 3x3 canonical warp); returns
// the side length.
int stones_rectify(const unsigned char* img, int width, int height,
                   const double* h9, int boardSize,
                   unsigned char* outRect, double* outM9);

// ---- gr_stonelattice internals (wrappers DEFINED in gr_stonelattice.cpp so
//      they can reach the file-local statics; stonelattice.py port, Task 6) ----
// _lattice_basis on a flat [x0,y0,x1,y1,...] point set. Returns 1 and fills
// out4 (a1x, a1y, a2x, a2y) when a basis is found, 0 (None) otherwise.
int slat_lattice_basis(const double* ptsXY, int n, double sp, double* out4);
// _seed_component's largest-component size for the given points + basis
// (basis4 = a1x, a1y, a2x, a2y). Exercises the FIFO BFS.
int slat_seed_component_size(const double* ptsXY, int n, const double* basis4, double sp);
// _core_extent (DFS / LIFO) on a flat [col0,row0,col1,row1,...] cell set:
// fills outExt2 (ext_cols, ext_rows) of the trimmed core and returns the
// trimmed cell count.
int slat_core_extent(const int* cellsXY, int n, int* outExt2);
// Packed (col, row) lattice-cell key round-trip (documents the packing).
long long slat_pack_cell(int col, int row);
void slat_unpack_cell(long long key, int* outColRow);
// Micro-parity harness core (also used by the gobanrecog-dev executable). Full
// mode: gray is row-major uint8 HxW, seed9 the row-major 3x3 seed homography.
// Seeds cv::setRNGSeed(1234) internally right before the RANSAC entry (mirrors
// detect.py:929 / the Python dump), runs sl_fits, and returns a JSON object:
// stage, n_seed, margin, H_seed, W, peaks, basis, seed_count, grown_counts,
// fits ({Hd, ext}), quads (4x2 each). Python-flavored JSON (NaN/Infinity ok).
std::string slat_stage_json(const unsigned char* gray, int width, int height,
                            const double* seed9, int nSeed, int margin);
// Pre-mapped mode (same-float64-bytes leg): avg/stoneness are row-major CV_64F
// side x side, scale the percentile, W9 the row-major 3x3 canonical warp. Runs
// _sl_fits_core (peak union onward) on the identical float64 map, isolating the
// ported logic from the warpPerspective HAL. Same JSON schema (n_seed/margin
// emitted as -1).
std::string slat_stage_json_premapped(const double* avg, const double* stoneness, int side,
                                      double scale, const double* W9);
// Pre-peaks mode (bit-exact gate): feed the identical detected peak set (flat
// [x0,y0,...]) + the 3x3 canonical warp W9, run _sl_fits_from_peaks (basis ->
// seed -> growers -> RANSAC refit -> quads). No peak-detector cv ops, so this
// isolates the ported numpy logic; the only remaining cv work is
// findHomography/RANSAC (deterministic under setRNGSeed(1234)).
std::string slat_stage_json_prepeaks(const double* peaksXY, int nPeaks, const double* W9);
// Detector-level attribution: _peaks_ring / _peaks_dt on a pre-mapped
// avg/stoneness (fills outXY up to cap points, returns the total count).
int slat_peaks_ring(const double* avg, int side, double thr, int minSep, double* outXY, int cap);
int slat_peaks_dt(const double* stoneness, int side, double scale, double* outXY, int cap);
// Debug: run grower `which` (0=global, 1=local) on the basis+seed derived from
// the fed peaks; fill outIdxColRow (triples) and return the grown count (-1 if
// no basis). For attributing grow divergences to findHomography ULPs.
int slat_grow_debug(const double* peaksXY, int nPeaks, int which, int* outIdxColRow, int cap);
// Debug: single cv::findHomography(src, dst, LMEDS) after setRNGSeed(1234).
// Fills outT9 (row-major) and returns 1 (0 if degenerate). For proving the
// homography solve differs across the cv2-wheel / vendored-OpenCV builds.
int slat_find_homography_lmeds(const double* srcXY, const double* dstXY, int n, double* outT9);

// ---- gr_detect proposers (wrappers DEFINED in gr_detect_proposers.cpp so they
//      can reach the file-local statics; detect.py part-A port, Task 7) ----
// _order_quad on a 4x2 (flat pts8 = x0,y0,...,x3,y3) -> out8 ordered TL,TR,BR,BL.
void detect_order_quad(const double* pts8, double* out8);
// _degenerate_quad on an ordered 4x2 quad (flat 8 doubles). Returns 1/0.
int detect_degenerate_quad(const double* quad8);
// The _quad_hull approxPolyDP sweep on a supplied integer hull (flat xy pairs,
// nHull points): arcLength + arange(0.01,0.12,0.01) sweep + approxPolyDP + the
// len==4 gate + _order_quad. Returns 1 + fills outQuad8 (ordered TL,TR,BR,BL)
// when a 4-vertex approx is found, 0 otherwise (the "hull not quad-like" path).
// Isolates the sweep/order logic from Canny/dilate/findContours (which is a cv
// op, not ported code).
int detect_hull_sweep(const int* hullXY, int nHull, double* outQuad8);
// _quad_hough's post-HoughLinesP tail on supplied integer segments (flat
// x0,y0,x1,y1 quadruples, nSegs of them): _line_params -> horiz/vert split ->
// _extreme_lines -> _intersect -> isfinite -> _order_quad. Returns 1 + outQuad8
// on success; on a DetectionError returns 0 and writes the verbatim reason into
// `reason` (reasonCap bytes). Exercises the full pure hough logic without
// Canny/HoughLinesP (cv ops).
int detect_hough_from_segments(const int* segsXYXY, int nSegs, double* outQuad8,
                               char* reason, int reasonCap);
// Micro-parity harness core (also used by the gobanrecog-dev executable). bgr is
// row-major uint8 BGR HxWx3. Runs all five proposers (hull/hough/hull1/texture/
// slab) on the RAW image exactly as detect_board does (cvtColor to gray first;
// slab uses the BGR image) and returns a JSON object:
//   {"stage":"proposers", "<name>": {"ok":true,"quad":[[x,y]*4]}  |
//                                    {"ok":false,"error_type":"DetectionError"|
//                                     "cv2.error"|"LinAlgError","reason":"..."}}
// The reason is the VERBATIM DetectionError message (empty for cv2.error/
// LinAlgError, whose library messages differ across builds). Python-flavored
// JSON (NaN/Infinity tokens permitted).
std::string proposers_stage_json(const unsigned char* bgr, int width, int height);

// ---- constants ----
// Fills out[289] with the 17x17 stone kernel (float32 values promoted to
// double). Returns the count of nonzero cells.
int stone_kernel(double* out289);
// Fills out[50] with the 25 node offsets, interleaved (dx0,dy0,dx1,dy1,...).
void node_offsets(double* out50);

// ---- BoardState (rows joined by '\n') ----
// Returns "" if construction succeeds, else the std::invalid_argument message.
std::string board_validate(int size, const char* rowsNL);
// Returns points holding `colorCode` as "c,r;c,r;..." (row-major). Assumes the
// board is valid; returns "!" if construction threw.
std::string board_points(int size, const char* rowsNL, int colorCode);
// Returns the stone char code at (col,row), or -1 if construction threw.
int board_stone_at(int size, const char* rowsNL, int col, int row);
// Returns BoardState::empty(size)'s rows joined by '\n' (or "!" if it threw).
std::string board_empty(int size);
// Builds via BoardState::fromGrid(rowsNL split on '\n') and returns
// "size|rowsNL" (or "!" if it threw) so the test can verify the round-trip.
std::string board_from_grid(const char* rowsNL);

}  // namespace testbridge
}  // namespace gobanrecog

#endif /* GobanRecogTestBridge_hpp */
