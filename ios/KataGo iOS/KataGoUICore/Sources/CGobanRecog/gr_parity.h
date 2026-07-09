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

#include <vector>

#include <opencv2/core.hpp>

#include "gr_errors.h"

namespace gobanrecog {

// np.round: round-half-to-even (banker's rounding). np.round(x) for scalars.
double np_round(double x);

// np.percentile with numpy's default "linear" method. `v` is copied + sorted
// internally.
double np_percentile(std::vector<double> v, double q);

// np.median of a 1-D sequence: mean of the middle two on even counts.
double np_median(std::vector<double> v);

// np.median over ALL elements of a single-channel Mat -> double. Preserves the
// Mat's dtype during the even-count average (numpy medians a float32 array in
// float32, an integer/float64 array in float64).
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

}  // namespace gobanrecog

#endif /* gr_parity_h */
