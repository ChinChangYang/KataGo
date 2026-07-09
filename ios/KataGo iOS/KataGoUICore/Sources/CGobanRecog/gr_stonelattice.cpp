//
//  gr_stonelattice.cpp
//  CGobanRecog
//
//  Ports gobanrecog/pipeline/stonelattice.py line-by-line (port-conventions.md
//  rule 1). Only {SlFit, sl_fits, quads_of} are exposed via gr_stonelattice.h
//  (detect.py's import surface); every other stonelattice.py function is
//  file-local here. The gobanrecog::testbridge slat_* wrappers are ALSO defined
//  at the bottom of this file (not in gr_testbridge.cpp) so they can reach the
//  file-local statics — the sanctioned cv-free test/diagnostic seam (pattern
//  established by gr_grid.cpp/gr_stones.cpp).
//
//  dtype fidelity (rule 2), all verified against numpy 2.5.1 in the reference
//  venv (Task 6 probes):
//    - _stone_map_raw: rect = warpPerspective(uint8) stays uint8; med =
//      np.median(uint8 slice) is a float64 scalar; stoneness =
//      abs(rect.astype(f32) - med) promotes to float64 (NEP 50 strong scalar);
//      avg = filter2D(stoneness_f64, -1, _KER_f32) is float64; scale =
//      float(np.percentile(f64, 95)) + 1e-6 is a double.
//    - _peaks_dt: distanceTransform outputs float32; dt vals and radii are
//      float32; `1.4 * max(r, rr)` stays float32 (NEP 50 weak python-float),
//      then the hypot comparison promotes to float64.
//    - _lattice_basis: np.histogram over the float64 angles gives int64 counts;
//      np.median(vv, axis=0) is a float64 per-column median.
//    - lattice coords / lattice steps are float64 integer-valued throughout.
//
//  RNG discipline (port-conventions.md rule 12 / detect.py:929): LMEDS/RANSAC
//  consume OpenCV's global RNG. The caller seeds cv::setRNGSeed(1234) once
//  before sl_fits; this file never touches the seed (the harness bridge does,
//  right before the compared entry, to mirror the Python dump).
//

#include "gr_stonelattice.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <deque>
#include <limits>
#include <optional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include <opencv2/core.hpp>
#include <opencv2/geometry.hpp>
#include <opencv2/imgproc.hpp>

#include "GobanRecogTestBridge.hpp"
#include "gr_constants.h"
#include "gr_parity.h"

// numpy never fuses multiply-add into FMA (each op rounds separately); forbid
// contraction so the float32 arithmetic in the peak detectors rounds like
// numpy's (belt-and-suspenders with the target's -ffp-contract=off).
#pragma STDC FP_CONTRACT OFF

namespace gobanrecog {

namespace {

// ---- Packed (col, row) lattice-cell key -----------------------------------
// stonelattice.py stores occupancy as set[tuple[int,int]]; cell coords are
// small signed integers (roughly -1..19). Pack the pair into an int64:
//   key = (int64(col) << 32) | uint32(row)
// The low 32 bits carry `row` as a two's-complement uint32 so negatives round-
// trip; the high 32 bits carry `col`. Bijective over the int32 range used here.
inline std::int64_t pack_cell(int col, int row) {
    return (static_cast<std::int64_t>(col) << 32) |
           static_cast<std::int64_t>(static_cast<std::uint32_t>(row));
}
inline int unpack_col(std::int64_t key) { return static_cast<int>(key >> 32); }
inline int unpack_row(std::int64_t key) {
    return static_cast<int>(static_cast<std::uint32_t>(key & 0xFFFFFFFF));
}

// ---- Debug capture for the micro-parity harness ----------------------------
// Populated only when passed non-null (mirrors stones.py's out_margins probe).
struct SlDebug {
    std::vector<cv::Point2d> peaks;
    bool has_basis = false;
    cv::Vec2d a1{0, 0}, a2{0, 0};
    int seed_count = 0;
    std::vector<int> grown_counts;  // per grower, in (global, local) order
    cv::Mat W;                      // canonical warp (set by _sl_fits_impl)
};

// numpy `x % np.pi` for floats (result in [0, pi)); fmod-based sign adjust,
// verified bit-exact vs numpy 2.5.1 remainder over 1e5 samples (Task 6 probe).
inline double pymod_pi(double a) {
    const double pi = CV_PI;
    double r = std::fmod(a, pi);
    if (r != 0.0 && (r < 0.0)) r += pi;  // pi > 0, so numpy result is >= 0
    return r;
}

// Closed-form 2x2 inverse (np.linalg.inv). Differs from numpy's LAPACK LU by
// ULPs (like inv3x3's cv::invert closed form); here it feeds only the `steps`
// rounding in _seed_component, whose integer output absorbs the ULP entirely
// (steps/err never reach an output).
cv::Matx22d inv2x2(const cv::Matx22d& B) {
    const double det = B(0, 0) * B(1, 1) - B(0, 1) * B(1, 0);
    return cv::Matx22d(B(1, 1) / det, -B(0, 1) / det, -B(1, 0) / det, B(0, 0) / det);
}

// 3x3 matmul in numpy's left-to-right dot order (a0*b0 + a1*b1) + a2*b2 —
// venv-verified bit-identical to numpy `@` on these inputs (Task 5 precedent).
cv::Matx33d matmul3(const cv::Matx33d& A, const cv::Matx33d& B) {
    cv::Matx33d C;
    for (int i = 0; i < 3; ++i)
        for (int j = 0; j < 3; ++j)
            C(i, j) = (A(i, 0) * B(0, j) + A(i, 1) * B(1, j)) + A(i, 2) * B(2, j);
    return C;
}

cv::Matx33d toMatx33(const cv::Mat& m) {
    cv::Matx33d r;
    for (int i = 0; i < 3; ++i)
        for (int j = 0; j < 3; ++j) r(i, j) = m.at<double>(i, j);
    return r;
}

// ports stonelattice.py::_order_quad. TL = argmin(x+y), TR = argmax(x-y),
// BR = argmax(x+y), BL = argmin(x-y) (numpy argmin/argmax = first occurrence).
cv::Mat _order_quad(const std::vector<cv::Point2d>& pts) {
    int i_smin = 0, i_smax = 0, i_dmax = 0, i_dmin = 0;
    double smin = pts[0].x + pts[0].y, smax = smin;
    double dmax = pts[0].x - pts[0].y, dmin = dmax;
    for (int k = 1; k < static_cast<int>(pts.size()); ++k) {
        const double s = pts[k].x + pts[k].y;
        const double d = pts[k].x - pts[k].y;
        if (s < smin) { smin = s; i_smin = k; }
        if (s > smax) { smax = s; i_smax = k; }
        if (d > dmax) { dmax = d; i_dmax = k; }
        if (d < dmin) { dmin = d; i_dmin = k; }
    }
    cv::Mat q(4, 2, CV_64F);
    const int ord[4] = {i_smin, i_dmax, i_smax, i_dmin};
    for (int r = 0; r < 4; ++r) {
        q.at<double>(r, 0) = pts[ord[r]].x;
        q.at<double>(r, 1) = pts[ord[r]].y;
    }
    return q;
}

// ports stonelattice.py::_corners_of. Perspective-maps the n-1 grid square's
// four corners through H (q = (H @ [cg, 1].T).T; q[:, :2] / q[:, 2:3]).
std::vector<cv::Point2d> _corners_of(const cv::Matx33d& H, int n) {
    const double m = static_cast<double>(n - 1);
    const double cg[4][2] = {{0.0, 0.0}, {m, 0.0}, {m, m}, {0.0, m}};
    std::vector<cv::Point2d> out(4);
    for (int k = 0; k < 4; ++k) {
        const double x = cg[k][0], y = cg[k][1];
        const double wx = (H(0, 0) * x + H(0, 1) * y) + H(0, 2);
        const double wy = (H(1, 0) * x + H(1, 1) * y) + H(1, 2);
        const double ww = (H(2, 0) * x + H(2, 1) * y) + H(2, 2);
        out[k] = cv::Point2d(wx / ww, wy / ww);
    }
    return out;
}

// ports stonelattice.py::_peaks_ring — disk-averaged stoneness maxima with a
// min-falloff-over-8-directions compactness gate (small/medium/dense stones).
std::vector<cv::Point2d> _peaks_ring(const cv::Mat& avg, double thr, int min_sep) {
    cv::Mat small;
    cv::resize(avg, small, cv::Size(avg.cols / 2, avg.rows / 2), 0, 0, cv::INTER_AREA);
    const int sep = std::max(2, min_sep / 2);
    cv::Mat dil;
    cv::dilate(small, dil,
               cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(2 * sep + 1, 2 * sep + 1)));
    // ys, xs = np.where((small >= dil) & (small > thr))  [row-major order]
    struct Cand { double val; int x; int y; };
    std::vector<Cand> cands;
    const int h = small.rows, w = small.cols;
    for (int y = 0; y < h; ++y) {
        const double* sr = small.ptr<double>(y);
        const double* dr = dil.ptr<double>(y);
        for (int x = 0; x < w; ++x) {
            if (sr[x] >= dr[x] && sr[x] > thr) cands.push_back({sr[x], x, y});
        }
    }
    if (cands.empty()) return {};
    // order = np.argsort(-vals)[:600]  (descending val; ties -> row-major)
    std::vector<int> order(cands.size());
    for (size_t i = 0; i < order.size(); ++i) order[i] = static_cast<int>(i);
    std::stable_sort(order.begin(), order.end(),
                     [&](int a, int b) { return cands[a].val > cands[b].val; });
    if (order.size() > 600) order.resize(600);

    std::vector<cv::Point2d> kept;
    const int half = SP / 4;  // 8
    const int diag = static_cast<int>(np_round(half / std::sqrt(2.0)));  // 6
    const int dirs[8][2] = {{half, 0}, {-half, 0}, {0, half}, {0, -half},
                            {diag, diag}, {-diag, diag}, {diag, -diag}, {-diag, -diag}};
    for (int oi : order) {
        const cv::Point2d p(cands[oi].x, cands[oi].y);
        bool tooClose = false;
        for (const cv::Point2d& q : kept) {
            if (std::hypot(p.x - q.x, p.y - q.y) < sep) { tooClose = true; break; }
        }
        if (tooClose) continue;
        const int x = static_cast<int>(p.x), y = static_cast<int>(p.y);
        std::vector<double> ring;
        for (int di = 0; di < 8; ++di) {
            const int dx = dirs[di][0], dy = dirs[di][1];
            if (x + dx >= 0 && x + dx < w && y + dy >= 0 && y + dy < h)
                ring.push_back(small.at<double>(y + dy, x + dx));
        }
        if (ring.empty()) continue;
        const double rmin = *std::min_element(ring.begin(), ring.end());
        if (1.0 - rmin / (small.at<double>(y, x) + 1e-6) < 0.30) continue;
        kept.push_back(p);
    }
    std::vector<cv::Point2d> out;
    out.reserve(kept.size());
    for (const cv::Point2d& p : kept) out.push_back(cv::Point2d(2.0 * p.x, 2.0 * p.y));
    return out;
}

// ports stonelattice.py::_peaks_dt — distance-transform maxima of thresholded
// stoneness (scale adaptive; catches big near-camera stones).
std::vector<cv::Point2d> _peaks_dt(const cv::Mat& stoneness, double scale) {
    cv::Mat binary(stoneness.rows, stoneness.cols, CV_8U);
    const double t = 0.45 * scale;
    for (int y = 0; y < stoneness.rows; ++y) {
        const double* sr = stoneness.ptr<double>(y);
        unsigned char* br = binary.ptr<unsigned char>(y);
        for (int x = 0; x < stoneness.cols; ++x) br[x] = (sr[x] > t) ? 1 : 0;
    }
    cv::Mat dt;  // CV_32F
    cv::distanceTransform(binary, dt, cv::DIST_L2, 5);
    cv::Mat dil;
    cv::dilate(dt, dil, cv::Mat::ones(7, 7, CV_8U));
    // ys, xs = np.where((dt >= dil - 1e-6) & (dt > 5.0) & (dt < 45.0))
    struct Cand { float val; int x; int y; };
    std::vector<Cand> cands;
    for (int y = 0; y < dt.rows; ++y) {
        const float* dtr = dt.ptr<float>(y);
        const float* dlr = dil.ptr<float>(y);
        for (int x = 0; x < dt.cols; ++x) {
            const float thr = dlr[x] - 1e-6f;  // float32 (NEP 50 weak)
            if (dtr[x] >= thr && dtr[x] > 5.0f && dtr[x] < 45.0f) cands.push_back({dtr[x], x, y});
        }
    }
    if (cands.empty()) return {};
    std::vector<int> order(cands.size());
    for (size_t i = 0; i < order.size(); ++i) order[i] = static_cast<int>(i);
    std::stable_sort(order.begin(), order.end(),
                     [&](int a, int b) { return cands[a].val > cands[b].val; });

    std::vector<cv::Point2d> pts;
    std::vector<float> rad;
    const int cap = std::min<int>(4000, static_cast<int>(order.size()));
    for (int oi = 0; oi < cap; ++oi) {
        const int i = order[oi];
        const cv::Point2d p(cands[i].x, cands[i].y);
        const float r = cands[i].val;
        bool tooClose = false;
        for (size_t k = 0; k < pts.size(); ++k) {
            const float thresh = 1.4f * std::max(r, rad[k]);  // float32
            if (std::hypot(p.x - pts[k].x, p.y - pts[k].y) < static_cast<double>(thresh)) {
                tooClose = true;
                break;
            }
        }
        if (tooClose) continue;
        pts.push_back(p);
        rad.push_back(r);
        if (pts.size() >= 600) break;
    }
    return pts;
}

// ports stonelattice.py::_union_peaks.
std::vector<cv::Point2d> _union_peaks(const cv::Mat& avg, const cv::Mat& stoneness,
                                      double scale) {
    const std::vector<cv::Point2d> p1 =
        _peaks_ring(avg, std::max(0.45 * scale, 40.0), static_cast<int>(0.6 * SP));
    const std::vector<cv::Point2d> p2 = _peaks_dt(stoneness, scale);
    if (p1.empty()) return p2;
    if (p2.empty()) return p1;
    // keep = [q for q in p2 if min_i hypot(p1_i - q) > 10.0]
    std::vector<cv::Point2d> out = p1;
    for (const cv::Point2d& q : p2) {
        double mind = std::numeric_limits<double>::infinity();
        for (const cv::Point2d& p : p1) {
            const double dd = std::hypot(p.x - q.x, p.y - q.y);
            if (dd < mind) mind = dd;
        }
        if (mind > 10.0) out.push_back(q);
    }
    return out;
}

// ports stonelattice.py::_lattice_basis. Returns nullopt where Python returns
// None (rule 4/5).
std::optional<std::pair<cv::Vec2d, cv::Vec2d>> _lattice_basis(
    const std::vector<cv::Point2d>& pts, double sp) {
    const int n = static_cast<int>(pts.size());
    // ii, jj = where((dist in (0.6sp, 1.45sp)) & (i < j))  [row-major i<j]
    std::vector<cv::Point2d> v;  // v = pts[i] - pts[j] for the selected i<j
    for (int i = 0; i < n; ++i) {
        for (int j = i + 1; j < n; ++j) {
            const double dx = pts[i].x - pts[j].x;
            const double dy = pts[i].y - pts[j].y;
            const double dist = std::hypot(dx, dy);
            if (dist > 0.6 * sp && dist < 1.45 * sp) v.push_back(cv::Point2d(dx, dy));
        }
    }
    if (v.size() < 12) return std::nullopt;
    // ang = arctan2(vy, vx) % pi
    std::vector<double> ang(v.size());
    for (size_t k = 0; k < v.size(); ++k) ang[k] = pymod_pi(std::atan2(v[k].y, v[k].x));
    // hist, edges = np.histogram(ang, bins=36, range=(0, pi))  [uniform fast path]
    const int nb = 36;
    const double first = 0.0, last = CV_PI;
    const double step = (last - first) / nb;
    std::vector<double> edges(nb + 1);
    for (int i = 0; i < nb; ++i) edges[i] = static_cast<double>(i) * step;
    edges[nb] = last;
    const double norm = nb / (last - first);
    std::vector<std::int64_t> hist(nb, 0);
    for (double a : ang) {
        if (a < first || a > last) continue;
        int idx = static_cast<int>((a - first) * norm);
        if (idx == nb) idx -= 1;
        if (a < edges[idx]) idx -= 1;                                    // numpy ULP correction
        else if (idx != nb - 1 && a >= edges[idx + 1]) idx += 1;
        hist[idx] += 1;
    }
    // h = hist + roll(hist, 1) + roll(hist, -1)  [circular]
    std::vector<std::int64_t> hs(nb);
    for (int i = 0; i < nb; ++i)
        hs[i] = hist[i] + hist[(i - 1 + nb) % nb] + hist[(i + 1) % nb];
    int amax = 0;  // argmax, first occurrence
    for (int i = 1; i < nb; ++i)
        if (hs[i] > hs[amax]) amax = i;
    const double a0 = (edges[amax] + edges[amax + 1]) / 2.0;

    // family(center): median of the ±15° displacement family, sign-aligned.
    const auto family = [&](double center) -> std::optional<cv::Vec2d> {
        const double lim = 15.0 * CV_PI / 180.0;  // deg2rad(15)
        std::vector<int> sel;
        for (size_t k = 0; k < ang.size(); ++k) {
            const double dd = std::fabs(pymod_pi(ang[k] - center + CV_PI / 2.0) - CV_PI / 2.0);
            if (dd < lim) sel.push_back(static_cast<int>(k));
        }
        if (sel.size() < 6) return std::nullopt;
        const double rx = std::cos(center), ry = std::sin(center);
        cv::Mat vv(static_cast<int>(sel.size()), 2, CV_64F);
        for (size_t r = 0; r < sel.size(); ++r) {
            double vx = v[sel[r]].x, vy = v[sel[r]].y;
            if (vx * rx + vy * ry < 0.0) { vx = -vx; vy = -vy; }  // vv[vv@ref<0] *= -1
            vv.at<double>(static_cast<int>(r), 0) = vx;
            vv.at<double>(static_cast<int>(r), 1) = vy;
        }
        const cv::Mat med = np_median_axis0(vv);  // np.median(vv, axis=0)
        return cv::Vec2d(med.at<double>(0, 0), med.at<double>(0, 1));
    };

    const std::optional<cv::Vec2d> a1 = family(a0);
    const std::optional<cv::Vec2d> a2 = family(pymod_pi(a0 + CV_PI / 2.0));
    if (!a1 || !a2) return std::nullopt;
    if (std::fabs((*a1)[0] * (*a2)[1] - (*a1)[1] * (*a2)[0]) < 0.4 * sp * sp) return std::nullopt;
    return std::make_pair(*a1, *a2);
}

// ports stonelattice.py::_seed_component. BFS (FIFO) over unit-step edges;
// returns the point->lattice-coord map of the largest component.
std::unordered_map<int, cv::Vec2d> _seed_component(const std::vector<cv::Point2d>& pts,
                                                   const cv::Vec2d& a1, const cv::Vec2d& a2,
                                                   double sp) {
    // B = [[a1x, a2x], [a1y, a2y]] (columns a1, a2);  Binv = inv(B)
    const cv::Matx22d B(a1[0], a2[0], a1[1], a2[1]);
    const cv::Matx22d Binv = inv2x2(B);
    const int n = static_cast<int>(pts.size());
    // Precompute the `small` adjacency (NxN) + the rounded steps rs (NxN x 2).
    std::vector<unsigned char> small(static_cast<size_t>(n) * n, 0);
    std::vector<double> rsx(static_cast<size_t>(n) * n, 0.0);
    std::vector<double> rsy(static_cast<size_t>(n) * n, 0.0);
    std::vector<int> rowsum(n, 0);
    for (int i = 0; i < n; ++i) {
        for (int j = 0; j < n; ++j) {
            const double dx = pts[i].x - pts[j].x;
            const double dy = pts[i].y - pts[j].y;
            const double dist = std::hypot(dx, dy);
            const double s0 = Binv(0, 0) * dx + Binv(0, 1) * dy;  // einsum "ab,ijb->ija"
            const double s1 = Binv(1, 0) * dx + Binv(1, 1) * dy;
            const double r0 = np_round(s0);
            const double r1 = np_round(s1);
            const double err = std::max(std::fabs(s0 - r0), std::fabs(s1 - r1));
            const double absum = std::fabs(r0) + std::fabs(r1);
            const double abmax = std::max(std::fabs(r0), std::fabs(r1));
            const bool sm = (absum >= 1.0) && (abmax <= 1.0) && (err < 0.22) && (dist < 1.6 * sp);
            const size_t idx = static_cast<size_t>(i) * n + j;
            if (sm) {
                small[idx] = 1;
                rsx[idx] = r0;
                rsy[idx] = r1;
                rowsum[i] += 1;
            }
        }
    }
    // order = np.argsort(-small.sum(axis=1))  (descending rowsum; ties -> index)
    std::vector<int> order(n);
    for (int i = 0; i < n; ++i) order[i] = i;
    std::stable_sort(order.begin(), order.end(),
                     [&](int a, int b) { return rowsum[a] > rowsum[b]; });

    std::vector<char> seen(n, 0);
    std::unordered_map<int, cv::Vec2d> best;
    for (int s : order) {
        if (seen[s]) continue;
        std::unordered_map<int, cv::Vec2d> comp;
        comp.emplace(s, cv::Vec2d(0, 0));
        std::deque<int> queue;
        queue.push_back(s);
        seen[s] = 1;
        while (!queue.empty()) {
            const int i = queue.front();
            queue.pop_front();
            for (int j = 0; j < n; ++j) {  // np.where(small[i])[0] -> ascending j
                if (!small[static_cast<size_t>(i) * n + j]) continue;
                if (comp.count(j)) continue;
                const size_t idx = static_cast<size_t>(i) * n + j;
                comp.emplace(j, comp[i] + cv::Vec2d(rsx[idx], rsy[idx]));
                seen[j] = 1;
                queue.push_back(j);
            }
        }
        if (comp.size() > best.size()) best = std::move(comp);
    }
    return best;
}

// Sorted keys of a coords map (Python's `sorted(coords)`).
std::vector<int> sorted_keys(const std::unordered_map<int, cv::Vec2d>& coords) {
    std::vector<int> idx;
    idx.reserve(coords.size());
    for (const auto& kv : coords) idx.push_back(kv.first);
    std::sort(idx.begin(), idx.end());
    return idx;
}

// Build a Kx1 CV_64FC2 point Mat from a coords/pts selection.
cv::Mat coordsMat(const std::unordered_map<int, cv::Vec2d>& coords, const std::vector<int>& idx) {
    cv::Mat m(static_cast<int>(idx.size()), 1, CV_64FC2);
    for (int k = 0; k < static_cast<int>(idx.size()); ++k) {
        const cv::Vec2d& c = coords.at(idx[k]);
        m.at<cv::Vec2d>(k, 0) = cv::Vec2d(c[0], c[1]);
    }
    return m;
}
cv::Mat ptsMat(const std::vector<cv::Point2d>& pts, const std::vector<int>& idx) {
    cv::Mat m(static_cast<int>(idx.size()), 1, CV_64FC2);
    for (int k = 0; k < static_cast<int>(idx.size()); ++k)
        m.at<cv::Vec2d>(k, 0) = cv::Vec2d(pts[idx[k]].x, pts[idx[k]].y);
    return m;
}

// ports stonelattice.py::_grow_global.
std::unordered_map<int, cv::Vec2d> _grow_global(const std::vector<cv::Point2d>& pts,
                                                const std::unordered_map<int, cv::Vec2d>& coords0,
                                                double sp, double tol = 0.28, int rounds = 12) {
    std::unordered_map<int, cv::Vec2d> coords = coords0;
    const int n = static_cast<int>(pts.size());
    // pts as a Nx1 CV_64FC2 Mat, reused across rounds (perspectiveTransform arg).
    cv::Mat ptsAll(n, 1, CV_64FC2);
    for (int k = 0; k < n; ++k) ptsAll.at<cv::Vec2d>(k, 0) = cv::Vec2d(pts[k].x, pts[k].y);

    for (int round = 0; round < rounds; ++round) {
        const std::vector<int> idx = sorted_keys(coords);
        const cv::Mat src = coordsMat(coords, idx);  // lattice coords
        const cv::Mat dst = ptsMat(pts, idx);        // image points
        cv::Mat T;
        if (static_cast<int>(idx.size()) >= 12) {
            T = cv::findHomography(src, dst, cv::LMEDS);
        } else {
            cv::Mat srcF, dstF;
            src.convertTo(srcF, CV_32FC2);
            dst.convertTo(dstF, CV_32FC2);
            const cv::Mat M = cv::estimateAffine2D(srcF, dstF, cv::noArray(), cv::LMEDS);
            if (M.empty()) return coords;
            T = cv::Mat::eye(3, 3, CV_64F);
            M.copyTo(T(cv::Rect(0, 0, 3, 2)));
        }
        if (T.empty()) return coords;
        cv::Mat g;
        try {
            const cv::Mat Tinv = inv3x3(T);  // np.linalg.inv(T)
            cv::perspectiveTransform(ptsAll, g, Tinv);
        } catch (const LinAlgError&) {
            return coords;
        } catch (const cv::Exception&) {
            return coords;
        }
        // r = round(g); e = abs(g - r).max(axis=1)
        std::vector<double> rx(n), ry(n), e(n);
        for (int j = 0; j < n; ++j) {
            const cv::Vec2d gj = g.at<cv::Vec2d>(j, 0);
            rx[j] = np_round(gj[0]);
            ry[j] = np_round(gj[1]);
            e[j] = std::max(std::fabs(gj[0] - rx[j]), std::fabs(gj[1] - ry[j]));
        }
        // occupied = {tuple(map(int, coords[i]))}
        std::unordered_set<std::int64_t> occ;
        std::vector<std::pair<int, int>> occv;
        for (const auto& kv : coords) {
            const int cx = static_cast<int>(kv.second[0]);
            const int cy = static_cast<int>(kv.second[1]);
            if (occ.insert(pack_cell(cx, cy)).second) occv.push_back({cx, cy});
        }
        // for j in np.argsort(e): stop at e > tol
        std::vector<int> ord(n);
        for (int j = 0; j < n; ++j) ord[j] = j;
        std::stable_sort(ord.begin(), ord.end(), [&](int a, int b) { return e[a] < e[b]; });
        int added = 0;
        for (int j : ord) {
            if (e[j] > tol) break;
            if (coords.count(j)) continue;
            const int cx = static_cast<int>(rx[j]);
            const int cy = static_cast<int>(ry[j]);
            if (occ.count(pack_cell(cx, cy))) continue;
            bool near = false;
            for (const auto& c : occv) {
                if (std::max(std::abs(cx - c.first), std::abs(cy - c.second)) <= 2) { near = true; break; }
            }
            if (!near) continue;
            coords[j] = cv::Vec2d(rx[j], ry[j]);
            occ.insert(pack_cell(cx, cy));
            occv.push_back({cx, cy});
            added += 1;
        }
        if (added == 0) break;
    }
    return coords;
}

// ports stonelattice.py::_grow_local.
std::unordered_map<int, cv::Vec2d> _grow_local(const std::vector<cv::Point2d>& pts,
                                               const std::unordered_map<int, cv::Vec2d>& coords0,
                                               double sp, double tol = 0.28, int rounds = 40) {
    std::unordered_map<int, cv::Vec2d> coords = coords0;
    const int n = static_cast<int>(pts.size());
    for (int round = 0; round < rounds; ++round) {
        const std::vector<int> aidx = sorted_keys(coords);
        const int k = static_cast<int>(aidx.size());
        std::vector<cv::Vec2d> asrc(k), adst(k);
        for (int a = 0; a < k; ++a) {
            asrc[a] = coords.at(aidx[a]);
            adst[a] = cv::Vec2d(pts[aidx[a]].x, pts[aidx[a]].y);
        }
        std::unordered_set<std::int64_t> occ;
        std::vector<std::pair<int, int>> occv;
        for (const cv::Vec2d& c : asrc) {
            const int cx = static_cast<int>(c[0]);
            const int cy = static_cast<int>(c[1]);
            if (occ.insert(pack_cell(cx, cy)).second) occv.push_back({cx, cy});
        }
        std::vector<int> unassigned;
        for (int j = 0; j < n; ++j)
            if (!coords.count(j)) unassigned.push_back(j);
        if (unassigned.empty()) break;
        int added = 0;
        for (int j : unassigned) {
            // d = hypot(adst - pts[j]); order = argsort(d)[:min(8, k)]
            std::vector<double> d(k);
            for (int a = 0; a < k; ++a)
                d[a] = std::hypot(adst[a][0] - pts[j].x, adst[a][1] - pts[j].y);
            std::vector<int> ord(k);
            for (int a = 0; a < k; ++a) ord[a] = a;
            std::stable_sort(ord.begin(), ord.end(), [&](int a, int b) { return d[a] < d[b]; });
            const int take = std::min(8, k);
            ord.resize(take);
            if (static_cast<int>(ord.size()) < 4 || d[ord[0]] > 2.5 * sp) continue;
            // A = [asrc[order] | 1]  (take x 3);  M = lstsq(A, adst[order])  (3 x 2)
            const int m = static_cast<int>(ord.size());
            cv::Mat A(m, 3, CV_64F), Bm(m, 2, CV_64F);
            for (int r = 0; r < m; ++r) {
                A.at<double>(r, 0) = asrc[ord[r]][0];
                A.at<double>(r, 1) = asrc[ord[r]][1];
                A.at<double>(r, 2) = 1.0;
                Bm.at<double>(r, 0) = adst[ord[r]][0];
                Bm.at<double>(r, 1) = adst[ord[r]][1];
            }
            if (matrix_rank(A) < 3) continue;
            const cv::Mat Msol = lstsq(A, Bm);  // 3 x 2
            // Minv = pinv(vstack([M.T, [0, 0, 1]]))
            cv::Mat lifted(3, 3, CV_64F);
            for (int c = 0; c < 3; ++c) {
                lifted.at<double>(0, c) = Msol.at<double>(c, 0);  // M.T row 0
                lifted.at<double>(1, c) = Msol.at<double>(c, 1);  // M.T row 1
            }
            lifted.at<double>(2, 0) = 0.0;
            lifted.at<double>(2, 1) = 0.0;
            lifted.at<double>(2, 2) = 1.0;
            const cv::Mat Minv = pinv(lifted);
            // g = Minv @ [x, y, 1]; g = g[:2] / (g[2] if |g[2]| > 1e-9 else 1.0)
            const double px = pts[j].x, py = pts[j].y;
            double g[3];
            for (int a = 0; a < 3; ++a)
                g[a] = (Minv.at<double>(a, 0) * px + Minv.at<double>(a, 1) * py) +
                       Minv.at<double>(a, 2) * 1.0;
            const double denom = (std::fabs(g[2]) > 1e-9) ? g[2] : 1.0;
            const double gx = g[0] / denom, gy = g[1] / denom;
            const double rx = np_round(gx), ry = np_round(gy);
            if (std::max(std::fabs(gx - rx), std::fabs(gy - ry)) > tol) continue;
            const int cx = static_cast<int>(rx), cy = static_cast<int>(ry);
            if (occ.count(pack_cell(cx, cy))) continue;
            bool near = false;
            for (const auto& c : occv) {
                if (std::max(std::abs(cx - c.first), std::abs(cy - c.second)) <= 2) { near = true; break; }
            }
            if (!near) continue;
            coords[j] = cv::Vec2d(rx, ry);
            occ.insert(pack_cell(cx, cy));
            occv.push_back({cx, cy});
            added += 1;
        }
        if (added == 0) break;
    }
    return coords;
}

// ports stonelattice.py::_core_extent. Largest Chebyshev(<=2)-connected
// component (DFS / LIFO, rule 9), then trimmed of sparse boundary rows/cols.
// Returns the trimmed cell list; sl_fits takes its min/max for the extent.
std::vector<std::pair<int, int>> _core_extent(const std::vector<std::pair<int, int>>& cellsIn) {
    // unseen = set(cells); iterate seeds in insertion order (deterministic;
    // the largest component is a set, invariant to seed/DFS order — cross-
    // component ties are the only order-sensitive case and are absent on real
    // boards, verified by micro-parity).
    std::vector<std::pair<int, int>> cells = cellsIn;
    std::unordered_set<std::int64_t> unseen;
    for (const auto& c : cells) unseen.insert(pack_cell(c.first, c.second));
    std::vector<std::pair<int, int>> best;
    for (const auto& seed : cells) {
        const std::int64_t sk = pack_cell(seed.first, seed.second);
        if (!unseen.count(sk)) continue;
        unseen.erase(sk);
        std::vector<std::pair<int, int>> comp;
        comp.push_back(seed);
        std::vector<std::pair<int, int>> queue;  // LIFO (DFS)
        queue.push_back(seed);
        while (!queue.empty()) {
            const std::pair<int, int> c = queue.back();
            queue.pop_back();
            std::vector<std::int64_t> near;
            for (std::int64_t ok : unseen) {
                if (std::max(std::abs(unpack_col(ok) - c.first),
                             std::abs(unpack_row(ok) - c.second)) <= 2)
                    near.push_back(ok);
            }
            for (std::int64_t ok : near) {
                unseen.erase(ok);
                const std::pair<int, int> o{unpack_col(ok), unpack_row(ok)};
                comp.push_back(o);
                queue.push_back(o);
            }
        }
        if (comp.size() > best.size()) best = std::move(comp);
    }
    // Trim sparse boundary rows/cols (single stone) up to 6 passes.
    std::vector<std::pair<int, int>> arr = best;
    for (int pass = 0; pass < 6; ++pass) {
        int x0 = arr[0].first, y0 = arr[0].second, x1 = arr[0].first, y1 = arr[0].second;
        for (const auto& c : arr) {
            x0 = std::min(x0, c.first);
            y0 = std::min(y0, c.second);
            x1 = std::max(x1, c.first);
            y1 = std::max(y1, c.second);
        }
        bool trimmed = false;
        // axis 0 = x, axis 1 = y; iterate ((lo_v, keep>lo), (hi_v, keep<hi))
        struct AxisSpec { int axis; int lo; int hi; };
        const AxisSpec specs[2] = {{0, x0, x1}, {1, y0, y1}};
        for (const AxisSpec& sp : specs) {
            const int bounds[2] = {sp.lo, sp.hi};
            for (int bi = 0; bi < 2; ++bi) {
                const int v = bounds[bi];
                int onEdge = 0, keepCount = 0;
                for (const auto& c : arr) {
                    const int comp = (sp.axis == 0) ? c.first : c.second;
                    if (comp == v) onEdge += 1;
                    const bool keep = (bi == 0) ? (comp > v) : (comp < v);
                    if (keep) keepCount += 1;
                }
                if (onEdge <= 1 && keepCount >= 8) {
                    std::vector<std::pair<int, int>> next;
                    for (const auto& c : arr) {
                        const int comp = (sp.axis == 0) ? c.first : c.second;
                        const bool keep = (bi == 0) ? (comp > v) : (comp < v);
                        if (keep) next.push_back(c);
                    }
                    arr = std::move(next);
                    trimmed = true;
                    break;
                }
            }
            if (trimmed) break;
        }
        if (!trimmed) break;
    }
    return arr;
}

// ports stonelattice.py::_stone_map_raw. Throws (cv::Exception / LinAlgError)
// exactly where Python raises cv2.error / np.linalg.LinAlgError.
struct StoneMap {
    cv::Mat avg;        // CV_64F
    cv::Mat stoneness;  // CV_64F
    double scale;
    cv::Mat W;          // CV_64F 3x3
};
StoneMap _stone_map_raw(const cv::Mat& gray, const cv::Mat& H, int n, int margin) {
    const int side = 2 * PAD + (n - 1) * SP;
    const cv::Matx33d A(SP, 0.0, PAD + margin * SP, 0.0, SP, PAD + margin * SP, 0.0, 0.0, 1.0);
    const int big = side + 2 * margin * SP;
    const cv::Matx33d Wmat = matmul3(A, toMatx33(inv3x3(H)));  // W = A @ inv(H)
    cv::Mat W(3, 3, CV_64F);
    for (int i = 0; i < 3; ++i)
        for (int j = 0; j < 3; ++j) W.at<double>(i, j) = Wmat(i, j);
    cv::Mat rect;
    cv::warpPerspective(gray, rect, W, cv::Size(big, big));
    const int lo = PAD + margin * SP;
    const int hi = lo + (n - 1) * SP;
    const double med = np_median(rect(cv::Range(lo, hi), cv::Range(lo, hi)));
    cv::Mat stoneness(rect.rows, rect.cols, CV_64F);
    for (int y = 0; y < rect.rows; ++y) {
        const unsigned char* rr = rect.ptr<unsigned char>(y);
        double* sr = stoneness.ptr<double>(y);
        for (int x = 0; x < rect.cols; ++x)
            sr[x] = std::fabs(static_cast<double>(rr[x]) - med);
    }
    cv::Mat avg;
    cv::filter2D(stoneness, avg, -1, stoneKernel());  // _KER (17x17, normalized f32)
    std::vector<double> interior;
    interior.reserve(static_cast<size_t>(hi - lo) * (hi - lo));
    for (int y = lo; y < hi; ++y) {
        const double* sr = stoneness.ptr<double>(y);
        interior.insert(interior.end(), sr + lo, sr + hi);
    }
    const double scale = np_percentile(interior, 95.0) + 1e-6;
    return {avg, stoneness, scale, W};
}

// The post-warp core of sl_fits (peak union -> basis -> seed -> two growers ->
// RANSAC refit + core-extent gate). Split out so the harness can drive it from
// a bit-identical (avg, stoneness, scale, W) to isolate the ported logic from
// the warpPerspective HAL.
// The lattice-fit core (basis -> seed -> two growers -> RANSAC refit +
// core-extent gate), starting from an already-detected peak set. Split from the
// peak detectors so the harness can drive it from a bit-identical `pts` to
// isolate the ported numpy logic from the peak detectors' cv-op HAL (resize /
// dilate / distanceTransform).
std::vector<SlFit> _sl_fits_from_peaks(const std::vector<cv::Point2d>& pts, const cv::Mat& W,
                                       SlDebug* dbg) {
    std::vector<SlFit> out;
    if (dbg) dbg->peaks = pts;
    if (pts.size() < 24) return out;
    const double sp = static_cast<double>(SP);
    const std::optional<std::pair<cv::Vec2d, cv::Vec2d>> basis = _lattice_basis(pts, sp);
    if (dbg && basis) {
        dbg->has_basis = true;
        dbg->a1 = basis->first;
        dbg->a2 = basis->second;
    }
    if (!basis) return out;
    const std::unordered_map<int, cv::Vec2d> seed =
        _seed_component(pts, basis->first, basis->second, sp);
    if (dbg) dbg->seed_count = static_cast<int>(seed.size());
    if (seed.size() < 5) return out;

    cv::Matx33d Winv33;  // = np.linalg.inv(W), reused below
    bool haveWinv = false;
    for (int gi = 0; gi < 2; ++gi) {
        const std::unordered_map<int, cv::Vec2d> coords =
            (gi == 0) ? _grow_global(pts, seed, sp) : _grow_local(pts, seed, sp);
        if (dbg) dbg->grown_counts.push_back(static_cast<int>(coords.size()));
        if (coords.size() < 16) continue;
        const std::vector<int> idx = sorted_keys(coords);
        const cv::Mat src = coordsMat(coords, idx);
        const cv::Mat dst = ptsMat(pts, idx);
        cv::Mat Hc, mask;
        try {
            Hc = cv::findHomography(src, dst, cv::RANSAC, 0.25 * sp, mask);
        } catch (const cv::Exception&) {
            continue;
        }
        if (Hc.empty() || mask.empty() || cv::countNonZero(mask) < 16) continue;
        // inliers, preserving order
        std::vector<int> inlIdx;
        for (int k = 0; k < static_cast<int>(idx.size()); ++k)
            if (mask.at<unsigned char>(k, 0)) inlIdx.push_back(k);
        cv::Mat srcInl(static_cast<int>(inlIdx.size()), 1, CV_64FC2);
        cv::Mat dstInl(static_cast<int>(inlIdx.size()), 1, CV_64FC2);
        std::vector<std::pair<int, int>> cells;  // src[inl] as integer cells
        for (int k = 0; k < static_cast<int>(inlIdx.size()); ++k) {
            srcInl.at<cv::Vec2d>(k, 0) = src.at<cv::Vec2d>(inlIdx[k], 0);
            dstInl.at<cv::Vec2d>(k, 0) = dst.at<cv::Vec2d>(inlIdx[k], 0);
            const cv::Vec2d c = src.at<cv::Vec2d>(inlIdx[k], 0);
            cells.push_back({static_cast<int>(c[0]), static_cast<int>(c[1])});
        }
        const cv::Mat Hc2 = cv::findHomography(srcInl, dstInl, 0);
        cv::Matx33d HcM = toMatx33(Hc2.empty() ? Hc : Hc2);
        const std::vector<std::pair<int, int>> ints = _core_extent(cells);
        int x0 = ints[0].first, y0 = ints[0].second, x1 = ints[0].first, y1 = ints[0].second;
        for (const auto& c : ints) {
            x0 = std::min(x0, c.first);
            y0 = std::min(y0, c.second);
            x1 = std::max(x1, c.first);
            y1 = std::max(y1, c.second);
        }
        const int ext_cols = x1 - x0 + 1, ext_rows = y1 - y0 + 1;
        const cv::Matx33d S(1.0, 0.0, x0, 0.0, 1.0, y0, 0.0, 0.0, 1.0);
        if (!haveWinv) {
            try {
                Winv33 = toMatx33(inv3x3(W));
            } catch (const LinAlgError&) {
                continue;
            }
            haveWinv = true;
        }
        // Hd = inv(W) @ Hc @ S
        const cv::Matx33d Hd = matmul3(matmul3(Winv33, HcM), S);
        if (std::fabs(Hd(2, 2)) < 1e-12) continue;
        bool finite = true;
        for (int i = 0; i < 3 && finite; ++i)
            for (int j = 0; j < 3 && finite; ++j)
                if (!std::isfinite(Hd(i, j))) finite = false;
        if (!finite) continue;
        cv::Mat HdMat(3, 3, CV_64F);
        for (int i = 0; i < 3; ++i)
            for (int j = 0; j < 3; ++j) HdMat.at<double>(i, j) = Hd(i, j) / Hd(2, 2);
        out.push_back({HdMat, ext_cols, ext_rows});
    }
    return out;
}

// The post-warp core: peak union then the lattice fit. Split so the harness can
// drive it from a bit-identical (avg, stoneness, scale) map.
std::vector<SlFit> _sl_fits_core(const cv::Mat& avg, const cv::Mat& stoneness, double scale,
                                 const cv::Mat& W, SlDebug* dbg) {
    const std::vector<cv::Point2d> pts = _union_peaks(avg, stoneness, scale);
    return _sl_fits_from_peaks(pts, W, dbg);
}

// sl_fits with the debug capture (public sl_fits passes nullptr).
std::vector<SlFit> _sl_fits_impl(const cv::Mat& gray, const cv::Mat& H_seed, int n_seed,
                                 int margin, SlDebug* dbg) {
    StoneMap sm;
    try {
        sm = _stone_map_raw(gray, H_seed, n_seed, margin);
    } catch (const cv::Exception&) {
        return {};
    } catch (const LinAlgError&) {
        return {};
    }
    if (dbg) dbg->W = sm.W;
    return _sl_fits_core(sm.avg, sm.stoneness, sm.scale, sm.W, dbg);
}

}  // namespace

// ---- Public surface (gr_stonelattice.h) ------------------------------------

std::vector<SlFit> sl_fits(const cv::Mat& gray, const cv::Mat& H_seed, int n_seed, int margin) {
    return _sl_fits_impl(gray, H_seed, n_seed, margin, nullptr);
}

std::vector<cv::Mat> quads_of(const cv::Mat& Hd, int ext_cols, int ext_rows) {
    std::vector<cv::Mat> quads;
    const cv::Matx33d H = toMatx33(Hd);
    if (std::min(ext_cols, ext_rows) >= 6) {
        // quad_l = [[-1,-1],[ext0,-1],[ext0,ext1],[-1,ext1]]; q = perspectiveTransform(quad_l, Hd)
        const double ql[4][2] = {{-1.0, -1.0}, {static_cast<double>(ext_cols), -1.0},
                                 {static_cast<double>(ext_cols), static_cast<double>(ext_rows)},
                                 {-1.0, static_cast<double>(ext_rows)}};
        cv::Mat in(4, 1, CV_64FC2), q;
        for (int k = 0; k < 4; ++k) in.at<cv::Vec2d>(k, 0) = cv::Vec2d(ql[k][0], ql[k][1]);
        cv::perspectiveTransform(in, q, Hd);
        std::vector<cv::Point2d> qp(4);
        bool finite = true;
        for (int k = 0; k < 4; ++k) {
            const cv::Vec2d v = q.at<cv::Vec2d>(k, 0);
            qp[k] = cv::Point2d(v[0], v[1]);
            if (!std::isfinite(v[0]) || !std::isfinite(v[1])) finite = false;
        }
        if (finite) quads.push_back(_order_quad(qp));
    }
    if (ext_cols == ext_rows && (ext_cols == 9 || ext_cols == 13 || ext_cols == 19)) {
        const std::vector<cv::Point2d> c = _corners_of(H, ext_cols);
        bool finite = true;
        for (const cv::Point2d& p : c)
            if (!std::isfinite(p.x) || !std::isfinite(p.y)) finite = false;
        if (finite) quads.push_back(_order_quad(c));
    }
    return quads;
}

// ---- Test/diagnostic bridge (declared in GobanRecogTestBridge.hpp) ---------
// Defined HERE, not in gr_testbridge.cpp, so the wrappers can reach the file-
// local statics above without widening gr_stonelattice.h's surface.

namespace testbridge {

namespace {

void append_double(std::string& out, double v) {
    if (std::isnan(v)) { out += "NaN"; return; }
    if (std::isinf(v)) { out += (v > 0 ? "Infinity" : "-Infinity"); return; }
    char buf[40];
    std::snprintf(buf, sizeof(buf), "%.17g", v);
    out += buf;
}
void append_array(std::string& out, const double* v, size_t n) {
    out += '[';
    for (size_t i = 0; i < n; ++i) {
        if (i) out += ", ";
        append_double(out, v[i]);
    }
    out += ']';
}
void append_point_list(std::string& out, const std::vector<cv::Point2d>& pts) {
    out += '[';
    for (size_t i = 0; i < pts.size(); ++i) {
        if (i) out += ", ";
        const double xy[2] = {pts[i].x, pts[i].y};
        append_array(out, xy, 2);
    }
    out += ']';
}

std::string emit_json(const std::vector<gobanrecog::SlFit>& fits, const gobanrecog::SlDebug& dbg,
                      int nSeed, int margin, const double* seed9) {
    std::string out;
    out.reserve(1 << 16);
    out += "{\"stage\": \"slat\"";
    out += ", \"n_seed\": " + std::to_string(nSeed);
    out += ", \"margin\": " + std::to_string(margin);
    if (seed9) {
        out += ", \"H_seed\": ";
        append_array(out, seed9, 9);
    }
    if (!dbg.W.empty()) {
        out += ", \"W\": ";
        double w9[9];
        for (int i = 0; i < 9; ++i) w9[i] = dbg.W.at<double>(i / 3, i % 3);
        append_array(out, w9, 9);
    }
    out += ", \"peaks\": ";
    append_point_list(out, dbg.peaks);
    out += ", \"basis\": ";
    if (dbg.has_basis) {
        const double b4[4] = {dbg.a1[0], dbg.a1[1], dbg.a2[0], dbg.a2[1]};
        append_array(out, b4, 4);
    } else {
        out += "null";
    }
    out += ", \"seed_count\": " + std::to_string(dbg.seed_count);
    out += ", \"grown_counts\": [";
    for (size_t i = 0; i < dbg.grown_counts.size(); ++i) {
        if (i) out += ", ";
        out += std::to_string(dbg.grown_counts[i]);
    }
    out += "]";
    // fits
    out += ", \"fits\": [";
    for (size_t i = 0; i < fits.size(); ++i) {
        if (i) out += ", ";
        out += "{\"Hd\": ";
        double h9[9];
        for (int k = 0; k < 9; ++k) h9[k] = fits[i].Hd.at<double>(k / 3, k % 3);
        append_array(out, h9, 9);
        out += ", \"ext\": [" + std::to_string(fits[i].ext_cols) + ", " +
               std::to_string(fits[i].ext_rows) + "]}";
    }
    out += "]";
    // quads (all quads_of outputs across fits, concatenated in order)
    out += ", \"quads\": [";
    bool firstQuad = true;
    for (const gobanrecog::SlFit& f : fits) {
        const std::vector<cv::Mat> qs = gobanrecog::quads_of(f.Hd, f.ext_cols, f.ext_rows);
        for (const cv::Mat& q : qs) {
            if (!firstQuad) out += ", ";
            firstQuad = false;
            std::vector<cv::Point2d> qp(4);
            for (int k = 0; k < 4; ++k)
                qp[k] = cv::Point2d(q.at<double>(k, 0), q.at<double>(k, 1));
            append_point_list(out, qp);
        }
    }
    out += "]}";
    return out;
}

}  // namespace

int slat_lattice_basis(const double* ptsXY, int n, double sp, double* out4) {
    std::vector<cv::Point2d> pts(n);
    for (int i = 0; i < n; ++i) pts[i] = cv::Point2d(ptsXY[2 * i], ptsXY[2 * i + 1]);
    const std::optional<std::pair<cv::Vec2d, cv::Vec2d>> b = gobanrecog::_lattice_basis(pts, sp);
    if (!b) return 0;
    out4[0] = b->first[0];
    out4[1] = b->first[1];
    out4[2] = b->second[0];
    out4[3] = b->second[1];
    return 1;
}

int slat_seed_component_size(const double* ptsXY, int n, const double* basis4, double sp) {
    std::vector<cv::Point2d> pts(n);
    for (int i = 0; i < n; ++i) pts[i] = cv::Point2d(ptsXY[2 * i], ptsXY[2 * i + 1]);
    const cv::Vec2d a1(basis4[0], basis4[1]), a2(basis4[2], basis4[3]);
    return static_cast<int>(gobanrecog::_seed_component(pts, a1, a2, sp).size());
}

int slat_core_extent(const int* cellsXY, int n, int* outExt2) {
    std::vector<std::pair<int, int>> cells(n);
    for (int i = 0; i < n; ++i) cells[i] = {cellsXY[2 * i], cellsXY[2 * i + 1]};
    const std::vector<std::pair<int, int>> arr = gobanrecog::_core_extent(cells);
    int x0 = arr[0].first, y0 = arr[0].second, x1 = arr[0].first, y1 = arr[0].second;
    for (const auto& c : arr) {
        x0 = std::min(x0, c.first);
        y0 = std::min(y0, c.second);
        x1 = std::max(x1, c.first);
        y1 = std::max(y1, c.second);
    }
    outExt2[0] = x1 - x0 + 1;
    outExt2[1] = y1 - y0 + 1;
    return static_cast<int>(arr.size());
}

long long slat_pack_cell(int col, int row) {
    return static_cast<long long>(gobanrecog::pack_cell(col, row));
}
void slat_unpack_cell(long long key, int* outColRow) {
    outColRow[0] = gobanrecog::unpack_col(static_cast<std::int64_t>(key));
    outColRow[1] = gobanrecog::unpack_row(static_cast<std::int64_t>(key));
}

std::string slat_stage_json(const unsigned char* gray, int width, int height,
                            const double* seed9, int nSeed, int margin) {
    const cv::Mat grayMat(height, width, CV_8U, const_cast<unsigned char*>(gray));
    const cv::Mat H(3, 3, CV_64F, const_cast<double*>(seed9));
    gobanrecog::SlDebug dbg;
    cv::setRNGSeed(1234);  // mirror detect.py:929 / the Python dump, before the RANSAC entry
    const std::vector<gobanrecog::SlFit> fits =
        gobanrecog::_sl_fits_impl(grayMat, H, nSeed, margin, &dbg);
    return emit_json(fits, dbg, nSeed, margin, seed9);
}

std::string slat_stage_json_premapped(const double* avg, const double* stoneness, int side,
                                      double scale, const double* W9) {
    const cv::Mat avgMat(side, side, CV_64F, const_cast<double*>(avg));
    const cv::Mat stMat(side, side, CV_64F, const_cast<double*>(stoneness));
    const cv::Mat W(3, 3, CV_64F, const_cast<double*>(W9));
    gobanrecog::SlDebug dbg;
    dbg.W = W.clone();
    cv::setRNGSeed(1234);
    const std::vector<gobanrecog::SlFit> fits =
        gobanrecog::_sl_fits_core(avgMat, stMat, scale, W, &dbg);
    return emit_json(fits, dbg, -1, -1, nullptr);
}

std::string slat_stage_json_prepeaks(const double* peaksXY, int nPeaks, const double* W9) {
    std::vector<cv::Point2d> pts(nPeaks);
    for (int i = 0; i < nPeaks; ++i) pts[i] = cv::Point2d(peaksXY[2 * i], peaksXY[2 * i + 1]);
    const cv::Mat W(3, 3, CV_64F, const_cast<double*>(W9));
    gobanrecog::SlDebug dbg;
    dbg.W = W.clone();
    cv::setRNGSeed(1234);
    const std::vector<gobanrecog::SlFit> fits = gobanrecog::_sl_fits_from_peaks(pts, W, &dbg);
    return emit_json(fits, dbg, -1, -1, nullptr);
}

int slat_find_homography_lmeds(const double* srcXY, const double* dstXY, int n, double* outT9) {
    cv::Mat src(n, 1, CV_64FC2), dst(n, 1, CV_64FC2);
    for (int i = 0; i < n; ++i) {
        src.at<cv::Vec2d>(i, 0) = cv::Vec2d(srcXY[2 * i], srcXY[2 * i + 1]);
        dst.at<cv::Vec2d>(i, 0) = cv::Vec2d(dstXY[2 * i], dstXY[2 * i + 1]);
    }
    cv::setRNGSeed(1234);
    const cv::Mat T = cv::findHomography(src, dst, cv::LMEDS);
    if (T.empty()) return 0;
    for (int i = 0; i < 9; ++i) outT9[i] = T.at<double>(i / 3, i % 3);
    return 1;
}

int slat_grow_debug(const double* peaksXY, int nPeaks, int which, int* outIdxColRow, int cap) {
    std::vector<cv::Point2d> pts(nPeaks);
    for (int i = 0; i < nPeaks; ++i) pts[i] = cv::Point2d(peaksXY[2 * i], peaksXY[2 * i + 1]);
    const double sp = static_cast<double>(gobanrecog::SP);
    const std::optional<std::pair<cv::Vec2d, cv::Vec2d>> basis = gobanrecog::_lattice_basis(pts, sp);
    if (!basis) return -1;
    const std::unordered_map<int, cv::Vec2d> seed =
        gobanrecog::_seed_component(pts, basis->first, basis->second, sp);
    cv::setRNGSeed(1234);
    const std::unordered_map<int, cv::Vec2d> coords =
        (which == 0) ? gobanrecog::_grow_global(pts, seed, sp)
                     : gobanrecog::_grow_local(pts, seed, sp);
    std::vector<int> keys;
    for (const auto& kv : coords) keys.push_back(kv.first);
    std::sort(keys.begin(), keys.end());
    const int m = std::min(static_cast<int>(keys.size()), cap);
    for (int i = 0; i < m; ++i) {
        const cv::Vec2d c = coords.at(keys[i]);
        outIdxColRow[3 * i] = keys[i];
        outIdxColRow[3 * i + 1] = static_cast<int>(c[0]);
        outIdxColRow[3 * i + 2] = static_cast<int>(c[1]);
    }
    return static_cast<int>(coords.size());
}

int slat_peaks_ring(const double* avg, int side, double thr, int minSep, double* outXY, int cap) {
    const cv::Mat avgMat(side, side, CV_64F, const_cast<double*>(avg));
    const std::vector<cv::Point2d> pk = gobanrecog::_peaks_ring(avgMat, thr, minSep);
    const int m = std::min(static_cast<int>(pk.size()), cap);
    for (int i = 0; i < m; ++i) { outXY[2 * i] = pk[i].x; outXY[2 * i + 1] = pk[i].y; }
    return static_cast<int>(pk.size());
}

int slat_peaks_dt(const double* stoneness, int side, double scale, double* outXY, int cap) {
    const cv::Mat stMat(side, side, CV_64F, const_cast<double*>(stoneness));
    const std::vector<cv::Point2d> pk = gobanrecog::_peaks_dt(stMat, scale);
    const int m = std::min(static_cast<int>(pk.size()), cap);
    for (int i = 0; i < m; ++i) { outXY[2 * i] = pk[i].x; outXY[2 * i + 1] = pk[i].y; }
    return static_cast<int>(pk.size());
}

}  // namespace testbridge

}  // namespace gobanrecog
