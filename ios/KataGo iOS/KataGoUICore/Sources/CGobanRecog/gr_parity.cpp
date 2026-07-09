//
//  gr_parity.cpp
//  CGobanRecog
//
//  numpy-parity helpers. Tolerances verified against numpy 2.5.1 (reference
//  venv). Key facts confirmed empirically (see task-3-report.md):
//    - lstsq rcond=None       -> cutoff = eps*max(M,N) * largest_singular_value
//    - pinv default           -> cutoff = 1e-15        * largest_singular_value
//    - matrix_rank default tol -> largest_singular_value * max(M,N) * eps
//    - np.median of a float32 array is computed in float32
//    - np.linalg.inv / solve raise LinAlgError("Singular matrix") on singular
//

#include "gr_parity.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <vector>

namespace gobanrecog {

// np.round: half-to-even. std::nearbyint uses the current rounding mode, which
// defaults to FE_TONEAREST (ties-to-even) — matching numpy's rint-based round.
double np_round(double x) {
    return std::nearbyint(x);
}

// np.percentile, default method "linear". Reproduces numpy's virtual-index +
// _lerp exactly (numpy/lib/_function_base_impl _lerp): the >=0.5 branch anchors
// on b for numerical stability, so bit-exact parity requires the same split.
double np_percentile(std::vector<double> v, double q) {
    // numpy raises ValueError for q outside [0, 100]; mirror that instead of
    // handing an out-of-range virtual index downstream.
    if (q < 0.0 || q > 100.0) {
        throw std::invalid_argument("Percentiles must be in the range [0, 100]");
    }
    // A NaN violates std::sort's strict weak ordering (UB); numpy propagates
    // NaN through percentile/median, so short-circuit the same way.
    for (double x : v) {
        if (std::isnan(x)) return std::numeric_limits<double>::quiet_NaN();
    }
    std::sort(v.begin(), v.end());
    const size_t n = v.size();
    if (n == 0) return std::numeric_limits<double>::quiet_NaN();
    if (n == 1) return v[0];
    const double virtualIndex = (q / 100.0) * static_cast<double>(n - 1);
    double prev = std::floor(virtualIndex);
    size_t pi = static_cast<size_t>(prev);
    if (pi > n - 1) pi = n - 1;
    size_t ni = pi + 1;
    if (ni > n - 1) ni = n - 1;
    const double gamma = virtualIndex - prev;
    const double a = v[pi];
    const double b = v[ni];
    const double diff = b - a;
    if (gamma >= 0.5) {
        return b - diff * (1.0 - gamma);
    }
    return a + diff * gamma;
}

// np.median of a 1-D sequence.
double np_median(std::vector<double> v) {
    // NaN violates std::sort's strict weak ordering (UB); numpy's np.median
    // propagates NaN, so short-circuit the same way.
    for (double x : v) {
        if (std::isnan(x)) return std::numeric_limits<double>::quiet_NaN();
    }
    std::sort(v.begin(), v.end());
    const size_t n = v.size();
    if (n == 0) return std::numeric_limits<double>::quiet_NaN();
    if (n % 2 == 1) return v[n / 2];
    return (v[n / 2 - 1] + v[n / 2]) / 2.0;
}

// np.median over all elements of a single-channel Mat. Dtype-faithful: numpy
// medians a float32 array in float32, so the CV_32F even-count average is done
// in float; everything else (uint8, CV_64F, ...) promotes to double.
double np_median(const cv::Mat& m) {
    CV_Assert(m.channels() == 1);
    const size_t n = m.total();
    if (n == 0) return std::numeric_limits<double>::quiet_NaN();

    if (m.type() == CV_32F) {
        std::vector<float> vals;
        vals.reserve(n);
        for (auto it = m.begin<float>(), end = m.end<float>(); it != end; ++it) {
            // NaN violates std::sort's strict weak ordering (UB); numpy
            // propagates NaN, so short-circuit the same way (double NaN
            // converts from float NaN fine).
            if (std::isnan(*it)) return std::numeric_limits<double>::quiet_NaN();
            vals.push_back(*it);
        }
        std::sort(vals.begin(), vals.end());
        if (n % 2 == 1) return static_cast<double>(vals[n / 2]);
        // float32 arithmetic to match numpy's float32 median.
        const float mid = (vals[n / 2 - 1] + vals[n / 2]) / 2.0f;
        return static_cast<double>(mid);
    }

    cv::Mat d;
    m.convertTo(d, CV_64F);
    std::vector<double> vals;
    vals.reserve(n);
    for (auto it = d.begin<double>(), end = d.end<double>(); it != end; ++it) {
        vals.push_back(*it);
    }
    return np_median(vals);
}

// np.median(v, axis=0): per-column median. Delegates per column to the
// dtype-aware Mat median above.
cv::Mat np_median_axis0(const cv::Mat& m) {
    CV_Assert(m.dims == 2);
    cv::Mat out(1, m.cols, CV_64F);
    for (int c = 0; c < m.cols; ++c) {
        out.at<double>(0, c) = np_median(m.col(c));
    }
    return out;
}

// np.linalg.lstsq(A, B, rcond=None) via SVD.
cv::Mat lstsq(const cv::Mat& A, const cv::Mat& B) {
    cv::Mat Ad, Bd;
    A.convertTo(Ad, CV_64F);
    B.convertTo(Bd, CV_64F);
    const int m = Ad.rows;
    const int n = Ad.cols;

    cv::Mat w, u, vt;  // thin SVD: u (m x k), w (k x 1), vt (k x n), k=min(m,n)
    cv::SVD::compute(Ad, w, u, vt);

    const double smax = w.at<double>(0);
    const double eps = std::numeric_limits<double>::epsilon();
    const double cutoff = eps * std::max(m, n) * smax;  // rcond=None default

    cv::Mat utb = u.t() * Bd;  // k x K
    for (int i = 0; i < w.rows; ++i) {
        const double s = w.at<double>(i);
        const double inv = (s > cutoff) ? (1.0 / s) : 0.0;
        utb.row(i) *= inv;
    }
    return vt.t() * utb;  // n x K
}

// np.linalg.pinv(A) via SVD, default relative cutoff 1e-15.
cv::Mat pinv(const cv::Mat& A) {
    cv::Mat Ad;
    A.convertTo(Ad, CV_64F);

    cv::Mat w, u, vt;  // thin SVD
    cv::SVD::compute(Ad, w, u, vt);

    const double smax = w.at<double>(0);
    const double cutoff = 1e-15 * smax;  // numpy pinv default rcond

    cv::Mat sinv = cv::Mat::zeros(w.rows, w.rows, CV_64F);
    for (int i = 0; i < w.rows; ++i) {
        const double s = w.at<double>(i);
        if (s > cutoff) sinv.at<double>(i, i) = 1.0 / s;
    }
    // pinv = V * S^+ * U^T
    return vt.t() * sinv * u.t();
}

// np.linalg.matrix_rank(A), default tolerance maxSV * max(M,N) * eps.
int matrix_rank(const cv::Mat& A) {
    cv::Mat Ad;
    A.convertTo(Ad, CV_64F);
    const int m = Ad.rows;
    const int n = Ad.cols;

    cv::Mat w;  // singular-values-only overload
    cv::SVD::compute(Ad, w);

    const double smax = w.at<double>(0);
    const double tol = smax * std::max(m, n) * std::numeric_limits<double>::epsilon();

    int rank = 0;
    for (int i = 0; i < w.rows; ++i) {
        if (w.at<double>(i) > tol) ++rank;
    }
    return rank;
}

// np.linalg.inv for a 3x3; raises on singular.
cv::Mat inv3x3(const cv::Mat& H) {
    cv::Mat Hd;
    H.convertTo(Hd, CV_64F);
    cv::Mat inv;
    // DECOMP_LU returns a nonzero value iff the (<=3x3) input is invertible —
    // OpenCV only guarantees this fast-path return equals the determinant for
    // n<=3, not in general; 0.0 => singular => numpy raises.
    const double det = cv::invert(Hd, inv, cv::DECOMP_LU);
    if (det == 0.0) throw LinAlgError("Singular matrix");
    return inv;
}

// np.linalg.solve for a 2x2 (Cramer's rule; matches LAPACK to ~1e-13, well
// within the pipeline's tolerances). Raises on singular.
cv::Vec2d solve2x2(const cv::Mat& A, const cv::Vec2d& b) {
    cv::Mat Ad;
    A.convertTo(Ad, CV_64F);
    const double a00 = Ad.at<double>(0, 0);
    const double a01 = Ad.at<double>(0, 1);
    const double a10 = Ad.at<double>(1, 0);
    const double a11 = Ad.at<double>(1, 1);
    const double det = a00 * a11 - a01 * a10;
    if (det == 0.0) throw LinAlgError("Singular matrix");
    const double x0 = (a11 * b[0] - a01 * b[1]) / det;
    const double x1 = (-a10 * b[0] + a00 * b[1]) / det;
    return cv::Vec2d(x0, x1);
}

}  // namespace gobanrecog
