//
//  GobanRecogTestBridge.hpp
//  CGobanRecog
//
//  TEST/DIAGNOSTIC seam (mirrors the precedent set by gobanRecogOpenCVSmoke in
//  GobanRecogCpp.hpp). Exposes the internal numpy-parity helpers, constants,
//  and BoardState across Swift/C++ interop using PLAIN C++ std types only —
//  never cv:: types — so the native SwiftPM test target `GobanRecogNativeTests`
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
