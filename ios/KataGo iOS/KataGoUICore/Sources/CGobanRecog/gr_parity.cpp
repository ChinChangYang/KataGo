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

// numpy's element-wise ufunc arithmetic does not fuse multiply-add into FMA
// (each op rounds separately); forbid contraction so the float32 lerp below
// rounds exactly like numpy's. NOTE: numpy.arange's fill is the exception — its
// C fill loop (buffer[i] = start + i*delta) IS emitted as a hardware FMA, so
// np_arange below calls std::fma explicitly instead of relying on contraction.
#pragma STDC FP_CONTRACT OFF

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
    // handing an out-of-range virtual index downstream. q=NaN also fails
    // numpy's `0 <= q <= 100` check (so numpy raises), and floor(NaN)->size_t
    // would be UB here, so reject it explicitly.
    if (std::isnan(q) || q < 0.0 || q > 100.0) {
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

// np.percentile of a float32 array: PURE float32 lerp with gamma cast to
// float32 (numpy 2.5.1 casts gamma to the array dtype before _lerp; verified
// empirically in Task 4 — the float64 lerp differs on the same inputs).
float np_percentile(std::vector<float> v, double q) {
    if (std::isnan(q) || q < 0.0 || q > 100.0) {  // q=NaN: numpy raises; floor(NaN) UB
        throw std::invalid_argument("Percentiles must be in the range [0, 100]");
    }
    for (float x : v) {
        if (std::isnan(x)) return std::numeric_limits<float>::quiet_NaN();
    }
    std::sort(v.begin(), v.end());
    const size_t n = v.size();
    if (n == 0) return std::numeric_limits<float>::quiet_NaN();
    if (n == 1) return v[0];
    const double virtualIndex = (q / 100.0) * static_cast<double>(n - 1);
    double prev = std::floor(virtualIndex);
    size_t pi = static_cast<size_t>(prev);
    if (pi > n - 1) pi = n - 1;
    size_t ni = pi + 1;
    if (ni > n - 1) ni = n - 1;
    const float gamma = static_cast<float>(virtualIndex - prev);  // numpy casts to arr dtype
    const float a = v[pi];
    const float b = v[ni];
    const float diff = b - a;
    if (gamma >= 0.5f) {
        const float t = diff * (1.0f - gamma);
        return b - t;
    }
    const float t = diff * gamma;
    return a + t;
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

// numpy's pairwise_sum_@TYPE@ (numpy/_core/src/umath/loops.c.src): naive for
// n < 8; one 8-accumulator unrolled block with a tree combine plus a naive
// remainder for n <= 128 (PW_BLOCKSIZE); otherwise recursive halving with the
// split rounded down to a multiple of 8. Verified bit-exact against
// np.sum/np.mean (numpy 2.5.1) for n in {5, 8, 19, 127, 128, 129, 801, 950,
// 1100, 4096, 8192, 8193, 20000} — and NOT reproducible by a naive
// left-to-right sum or by seeding with the first element.
template <typename T>
static T pairwise_sum_impl(const T* a, size_t n) {
    if (n < 8) {
        T res = static_cast<T>(0);
        for (size_t i = 0; i < n; ++i) res += a[i];
        return res;
    }
    if (n <= 128) {
        T r0 = a[0], r1 = a[1], r2 = a[2], r3 = a[3];
        T r4 = a[4], r5 = a[5], r6 = a[6], r7 = a[7];
        size_t i = 8;
        for (; i < n - (n % 8); i += 8) {
            r0 += a[i + 0];
            r1 += a[i + 1];
            r2 += a[i + 2];
            r3 += a[i + 3];
            r4 += a[i + 4];
            r5 += a[i + 5];
            r6 += a[i + 6];
            r7 += a[i + 7];
        }
        T res = ((r0 + r1) + (r2 + r3)) + ((r4 + r5) + (r6 + r7));
        for (; i < n; ++i) res += a[i];
        return res;
    }
    size_t n2 = n / 2;
    n2 -= n2 % 8;
    return pairwise_sum_impl(a, n2) + pairwise_sum_impl(a + n2, n - n2);
}

float np_pairwise_sum(const float* a, size_t n) {
    return pairwise_sum_impl(a, n);
}

double np_pairwise_sum(const double* a, size_t n) {
    return pairwise_sum_impl(a, n);
}

// np.mean, dtype-faithful: float32 divides the float32 pairwise sum by
// float32(n) (numpy computes the mean in the array dtype).
float np_mean(const float* a, size_t n) {
    return np_pairwise_sum(a, n) / static_cast<float>(n);
}

double np_mean(const double* a, size_t n) {
    return np_pairwise_sum(a, n) / static_cast<double>(n);
}

// np.arange for float64: length = ceil((stop-start)/step); the fill computes
// b[0]=start, b[1]=start+step, delta=b[1]-b[0], b[i]=start+i*delta (numpy's
// @NAME@_fill), so the final value may overshoot `stop` by a rounding error.
// numpy's fill loop compiles `start + i*delta` to a single hardware FMA (one
// rounding), so we call std::fma to match bit-for-bit — verified against numpy
// 2.5.1 where the naive multiply-then-add differs by 1 ULP at e.g. 0.06/0.07/
// 0.10 in np.arange(0.01, 0.12, 0.01).
std::vector<double> np_arange(double start, double stop, double step) {
    const double len = std::ceil((stop - start) / step);
    if (!(len > 0)) return {};
    const size_t n = static_cast<size_t>(len);
    std::vector<double> out(n);
    out[0] = start;
    if (n > 1) {
        out[1] = start + step;
        const double delta = out[1] - out[0];
        for (size_t i = 2; i < n; ++i) {
            out[i] = std::fma(static_cast<double>(i), delta, start);
        }
    }
    return out;
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
