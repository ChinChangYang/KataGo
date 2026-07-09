//
//  gr_parity.h
//  CGobanRecog
//
//  numpy-semantics parity helpers used by all later port tasks. INTERNAL
//  header (uses cv:: types; kept out of include/). Every helper is
//  double-precision. Tolerances/semantics were verified against the reference
//  venv (numpy 2.5.1) — see gr_parity.cpp comments and task-3-report.md.
//

#ifndef gr_parity_h
#define gr_parity_h

#include <cmath>
#include <vector>

#include <opencv2/core.hpp>

#include "gr_errors.h"

namespace gobanrecog {

// ---- NaN-safe strict-weak-ordering comparators -----------------------------
//
// A bare `a < b` / `a > b` over IEEE doubles is NOT a valid C++ strict-weak
// ordering once a NaN is present: NaN compares false against every value, so it
// is "incomparable" to every finite number while those finite numbers ARE
// comparable to each other — that breaks transitivity of incomparability. Under
// libc++ hardening (the iOS-simulator Debug config) std::sort/std::stable_sort
// then trap in strict_weak_ordering_check.h; unhardened it is undefined
// behaviour, so a Release build can order differently from a Debug build.
//
// numpy's argsort (and, empirically, np.sort) treats a NaN as the LARGEST
// value: it lands LAST for both ascending and descending input. These wrappers
// reproduce that exactly while keeping the order of finite values identical to
// a bare `<` / `>`, so they are drop-in for the ported `np.argsort` / Python
// `sorted` sites without perturbing any NaN-free result. Both are valid SWOs:
// all NaNs form one equivalence class ordered after every finite value.
inline bool nanLastAscending(double a, double b) {
    if (std::isnan(a)) return false;  // a is NaN -> never precedes (sorts last)
    if (std::isnan(b)) return true;   // finite a precedes NaN b
    return a < b;
}
inline bool nanLastDescending(double a, double b) {
    if (std::isnan(a)) return false;  // a is NaN -> never precedes (sorts last)
    if (std::isnan(b)) return true;   // finite a precedes NaN b
    return a > b;
}

// np.round: round-half-to-even (banker's rounding). np.round(x) for scalars.
double np_round(double x);

// np.percentile with numpy's default "linear" method. `v` is copied + sorted
// internally. Throws std::invalid_argument if q is outside [0, 100] (mirrors
// numpy's ValueError). Returns NaN if `v` contains a NaN (mirrors numpy).
double np_percentile(std::vector<double> v, double q);

// np.percentile of a float32 array: numpy 2.5.1 sorts in float32, computes the
// virtual index / gamma in float64, then CASTS gamma to float32 and performs
// the _lerp in PURE float32 (verified empirically, Task 4 — the float64 lerp of
// the same inputs differs). Same q-range guard and NaN propagation as the
// double overload. Returns the float32 result (promote at the call site).
float np_percentile(std::vector<float> v, double q);

// np.median of a 1-D sequence: mean of the middle two on even counts. Returns
// NaN if `v` contains a NaN (mirrors numpy).
double np_median(std::vector<double> v);

// np.median over ALL elements of a single-channel Mat -> double. Preserves the
// Mat's dtype during the even-count average (numpy medians a float32 array in
// float32, an integer/float64 array in float64). Returns NaN if the Mat
// contains a NaN (mirrors numpy).
double np_median(const cv::Mat& m);

// np.median(v, axis=0): per-column median of a 2-D Mat. Returns a 1 x cols
// CV_64F row.
cv::Mat np_median_axis0(const cv::Mat& m);

// np.linalg.lstsq(A, B, rcond=None): least-squares solution via SVD. numpy's
// rcond=None default cutoff = eps*max(M,N) (relative to the largest singular
// value). B may have multiple columns; returns the N x K solution.
cv::Mat lstsq(const cv::Mat& A, const cv::Mat& B);

// np.linalg.pinv(A): Moore-Penrose pseudoinverse via SVD. numpy default
// relative cutoff rcond = 1e-15.
cv::Mat pinv(const cv::Mat& A);

// np.linalg.matrix_rank(A): count of singular values above numpy's default
// tolerance maxSV * max(M,N) * eps.
int matrix_rank(const cv::Mat& A);

// np.linalg.inv for a 3x3. Throws LinAlgError("Singular matrix") on a singular
// input (mirrors numpy).
cv::Mat inv3x3(const cv::Mat& H);

// np.linalg.solve for the 2x2 line-intersection case. Throws
// LinAlgError("Singular matrix") on a singular A.
cv::Vec2d solve2x2(const cv::Mat& A, const cv::Vec2d& b);

// ---- Task 4 additions (grid.py port call shapes) ---------------------------

// np.add.reduce's pairwise summation (numpy pairwise_sum_@TYPE@: naive < 8,
// 8-way unrolled blocks up to 128, then recursive halving to a multiple of 8).
// np.sum/np.mean over a 1-D array accumulate with EXACTLY this order — a naive
// left-to-right float32 sum diverges (verified against numpy 2.5.1 for n in
// 5..20000, whole-array pairwise, NOT seeded with the first element).
float np_pairwise_sum(const float* a, size_t n);
double np_pairwise_sum(const double* a, size_t n);

// np.mean of a 1-D array, dtype-faithful: float32 input accumulates via the
// float32 pairwise sum and divides by float32(n) (numpy mean keeps the input
// dtype); float64 input stays double throughout.
float np_mean(const float* a, size_t n);
double np_mean(const double* a, size_t n);

// np.arange(start, stop, step) for float64 scalars. numpy semantics (verified
// against numpy 2.5.1): length = ceil((stop - start) / step) computed in
// double; values filled as b[0] = start, b[1] = start + step,
// delta = b[1] - b[0], b[i] = std::fma(i, delta, start) — numpy's fill loop
// emits `start + i*delta` as a single hardware FMA, so the fma form matches
// bit-for-bit (naive multiply-then-add is 1 ULP off at some indices). The last
// value can exceed `stop` by a rounding error, exactly as numpy's does.
// Returns an empty vector when length <= 0.
std::vector<double> np_arange(double start, double stop, double step);

}  // namespace gobanrecog

#endif /* gr_parity_h */
